import Darwin
import Foundation
import CryptoKit

/// Fixed internal protocol; it cannot select a target PID, executable, command or shell.
struct OwnedFixtureRequest: Codable {
    var slot: Int
    var parentPID: Int32
    var expected: IdentityExpectation
    func validate() throws {
        try expected.validate()
        try require((1...2).contains(slot) && parentPID > 1, "invalid owned fixture request")
    }
}
struct OwnedFixtureHello: Codable {
    var process: TestProcessIdentity
    var parentPID: Int32
    var identity: IdentityCheck
    var signature: ProbeSignature
}
public struct OwnedFixtureOutcome: Codable, Sendable {
    public var slot: Int
    public var started: Double
    public var allocatedAt: Double?
    public var finished: Double
    public var fixtureMiB: Int
    public var reason: String
    public var finalIdentity: IdentityCheck
}
private func writeFixtureLine<T: Encodable>(_ value: T) throws {
    // encoded() is pretty-printed for evidence; protocol uses compact, single-line JSON.
    let encoder = JSONEncoder(); let compact = try encoder.encode(value) + Data([10])
    try require(compact.count <= 16_384, "fixture message exceeds bound")
    try FileHandle.standardOutput.write(contentsOf: compact)
}
private func pipeInputReady(_ timeout: Int32) throws -> Bool {
    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
    let result = poll(&descriptor, 1, timeout)
    if result < 0 && errno == EINTR { return false }
    try require(result >= 0, "fixture pipe poll failed")
    return result > 0
}
extension InstrumentRunner {
    /// Internal worker entry point. Even direct invocation is self-only, at most 16 MiB/15 seconds,
    /// requires a pipe plus a live parent, exact preregistered identity, and own safe signature.
    public static func ownedMemoryFixture(requestJSON: Data) throws {
        let request = try StrictJSON.decodeExact(OwnedFixtureRequest.self, from: requestJSON)
        try request.validate()
        // Self-only watchdog also bounds the inherited common identity helper's subprocess waits.
        signal(SIGALRM, SIG_DFL); alarm(15)
        let identity = request.expected.capture()
        let signature = try ProbeSignature.capture()
        try require(identity.matches(request.expected) && signature.valid, "invalid owned fixture identity/signature")
        var input = stat(), output = stat()
        try require(fstat(STDIN_FILENO, &input) == 0 && fstat(STDOUT_FILENO, &output) == 0 && input.st_mode & S_IFMT == S_IFIFO && output.st_mode & S_IFMT == S_IFIFO && getppid() == request.parentPID, "owned fixture requires parent pipes")
        let process = try RegisteredProcessReader.native.identity(getpid())
        try process.validate()
        try writeFixtureLine(OwnedFixtureHello(process: process, parentPID: getppid(), identity: identity, signature: signature))
        // Allocation cannot begin until the parent has sealed the numeric registration.
        let armDeadline = InstrumentClock.now() + 3
        var command: UInt8 = 0
        while InstrumentClock.now() < armDeadline {
            if try pipeInputReady(20) { break }
        }
        try require(InstrumentClock.now() < armDeadline && read(STDIN_FILENO, &command, 1) == 1 && command == 0x47 && getppid() == request.parentPID, "owned fixture was not armed")
        let started = InstrumentClock.now()
        let lifetime = request.slot == 1 ? 10.0 : 1.5
        let allocationDelay = request.slot == 1 ? 1.2 : 0.0
        let mib = request.slot == 1 ? 16 : 8
        var allocation: UnsafeMutableRawPointer?
        defer { allocation?.deallocate() }
        var allocatedAt: Double?, reason = "lifetime"
        while InstrumentClock.now() < started + lifetime {
            if allocation == nil && InstrumentClock.now() >= started + allocationDelay {
                allocation = .allocate(byteCount: mib * 1024 * 1024, alignment: 16384)
                memset(allocation!, 0x5a, mib * 1024 * 1024)
                allocatedAt = InstrumentClock.now()
            }
            if getppid() != request.parentPID { reason = "parent-exit"; break }
            if try pipeInputReady(20) {
                var byte: UInt8 = 0
                let count = read(STDIN_FILENO, &byte, 1)
                reason = count == 0 ? "parent-closed" : "protocol-stop"
                break
            }
        }
        if let allocation { try require(allocation.load(as: UInt8.self) == 0x5a, "fixture allocation changed") }
        try writeFixtureLine(OwnedFixtureOutcome(slot: request.slot, started: started, allocatedAt: allocatedAt,
            finished: InstrumentClock.now(), fixtureMiB: mib, reason: reason, finalIdentity: request.expected.capture()))
    }
}

private final class OwnedMemoryChild {
    let task = Process()
    let input = Pipe(), output = Pipe()
    var pending = Data()
    var inputClosed = false
    let slot: Int
    init(slot: Int, expected: IdentityExpectation) throws {
        self.slot = slot
        // Bundle executable is this running collector, not a caller-selected path.
        guard let executable = Bundle.main.executableURL else { throw InstrumentError("own executable unavailable") }
        let request = OwnedFixtureRequest(slot: slot, parentPID: getpid(), expected: expected)
        task.executableURL = executable
        task.arguments = ["owned-memory-fixture", "--fixture-json", String(decoding: try encoded(request), as: UTF8.self), "--apply"]
        task.environment = [:]
        task.standardInput = input; task.standardOutput = output; task.standardError = FileHandle.nullDevice
        try require(fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0, "cannot suppress owned pipe SIGPIPE")
        try task.run()
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        let fd = output.fileHandleForReading.fileDescriptor
        try require(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0, "cannot bound owned fixture pipe")
    }
    func line<T: Codable>(_ type: T.Type, seconds: Double) throws -> T {
        let deadline = InstrumentClock.now() + seconds
        while InstrumentClock.now() < deadline {
            if let end = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: end); pending.removeSubrange(...end)
                return try StrictJSON.decodeExact(type, from: line)
            }
            var buffer = [UInt8](repeating: 0, count: 2048)
            let count = read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            if count > 0 { pending.append(contentsOf: buffer.prefix(count)); try require(pending.count <= 16_384, "fixture response exceeds bound") }
            else if count == 0 { throw InstrumentError("owned fixture pipe ended before response") }
            else if errno != EAGAIN && errno != EINTR { throw InstrumentError("owned fixture pipe unreadable") }
            else { Thread.sleep(forTimeInterval: 0.005) }
        }
        throw InstrumentError("owned fixture response timeout")
    }
    func arm() throws { try input.fileHandleForWriting.write(contentsOf: Data([0x47])) }
    /// No kill-by-PID: close only the pipe held for this child. Child exits on EOF or fixed lifetime.
    func stop() {
        if !inputClosed { try? input.fileHandleForWriting.close(); inputClosed = true }
    }
    func stopped(within seconds: Double) -> Bool {
        stop()
        let deadline = InstrumentClock.now() + seconds
        while task.isRunning && InstrumentClock.now() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return !task.isRunning && task.terminationStatus == 0
    }
    deinit { stop(); try? output.fileHandleForReading.close() }
}
private struct OwnedSeriesIntent: Codable {
    var runID: String
    var expected: IdentityExpectation
    var identity: IdentityCheck
    var signature: ProbeSignature
    var clock: ClockStamp
    var durationSeconds = 6
    var allocationFixtureMiB = 16
    var allocationDelaySeconds = 1.2
    var transientLaunchAfterSeconds = 2
    var transientFixtureMiB = 8
    var transientLifetimeSeconds = 1.5
}
extension InstrumentRunner {
    /// Positive native validation only; two fixed own children, no arbitrary launch options.
    public static func ownedProcessSeries(runID: String, expected: IdentityExpectation) throws -> (path: String, valid: Bool) {
        try require(identifier(runID), "invalid run ID"); try expected.validate()
        let identity = expected.capture(), signature = try ProbeSignature.capture()
        try require(signature.valid, "unsafe collector signature; no child launched")
        let started = try InstrumentClock.stamp()
        var record = ProcessSeriesRecording(source: "measured-owned-fixtures", runID: runID, seconds: 6,
            expectedSlots: [1, 2], expected: expected, initialIdentity: identity, signature: signature, started: started, finished: started)
        let dataset = try Dataset(runID: runID, role: "process-series")
        let intent = OwnedSeriesIntent(runID: runID, expected: expected, identity: identity, signature: signature, clock: started)
        try dataset.write("intent.json", intent)
        let provenance = SHA256.hash(data: try encoded(intent)).map { String(format: "%02x", $0) }.joined()
        var children: [OwnedMemoryChild] = []
        defer { for child in children { child.stop() } }
        func launch(_ slot: Int, into record: inout ProcessSeriesRecording) throws {
            let child = try OwnedMemoryChild(slot: slot, expected: expected)
            children.append(child) // cleanup is owned even if handshake fails
            let hello = try child.line(OwnedFixtureHello.self, seconds: 3)
            try require(hello.process.pid == child.task.processIdentifier && hello.parentPID == getpid() && hello.identity.matches(expected) && hello.signature.valid &&
                hello.process == (try RegisteredProcessReader.native.identity(child.task.processIdentifier)), "owned child registration mismatch")
            let target = TestProcessRegistration(slot: slot, identity: hello.process, role: slot == 1 ? .ownedAllocationFixture : .ownedTransientFixture, provenanceSHA256: provenance)
            try target.validate(uid: expected.uid)
            let binding = ProcessSeriesBinding(registration: target, registeredAt: InstrumentClock.now(), childIdentity: hello.identity, childSignature: hello.signature)
            try dataset.write("registry-\(slot).json", binding)
            record.bindings.append(binding)
            try child.arm()
        }
        if identity.matches(expected) {
            do {
                try launch(1, into: &record)
                var attemptedTransient = false
                try collectProcessSeries(&record, journal: dataset.processSeriesJournal(runID: runID)) { value in
                    if !attemptedTransient && InstrumentClock.now() >= value.window!.start + 2 {
                        attemptedTransient = true
                        do { try launch(2, into: &value) }
                        catch { value.errors.append("owned transient registration/launch failed") }
                    }
                }
            } catch { record.errors.append("owned registration/launch or journal acquisition failed") }
            record.ownedFixtureResults = []
            var cleaned = true
            for child in children {
                child.stop()
                do { record.ownedFixtureResults!.append(try child.line(OwnedFixtureOutcome.self, seconds: 3)) }
                catch { record.errors.append("owned fixture completion unavailable") }
                if !child.stopped(within: 1) { cleaned = false }
            }
            record.ownedCleanupComplete = cleaned && children.count == 2
            record.finalIdentity = expected.capture()
        } else { record.errors.append("invalidMeasurement: initial identity; no children launched") }
        record.finished = try InstrumentClock.stamp()
        try dataset.write("recording.json", record)
        let report = try ProcessSeriesAnalyzer.evaluate(record)
        try dataset.write("report.json", report)
        // The transient intentionally makes attribution incomplete. Exit 3 preserves that fact.
        return (dataset.path, report.acquisitionComplete)
    }
}
