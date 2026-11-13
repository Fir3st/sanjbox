import Darwin
import Foundation

private struct DescendantFixtureRequest: Codable {
    var level: Int
    var parentPID: Int32
    var expected: IdentityExpectation
}
private struct DescendantFixtureHello: Codable {
    var process: ProcessRelation
    var identity: IdentityCheck
    var signature: ProbeSignature
}
private struct DescendantFixtureTruth: Codable {
    var level: Int
    var process: ProcessRelation
    var started: Double
    var allocatedAt: Double?
    var finished: Double
    var fixtureMiB: Int
    var reason: String
    var child: [DescendantFixtureTruth]
    var childCleanupComplete: Bool
}
private func descendantLine<T: Encodable>(_ value: T) throws {
    let data = try JSONEncoder().encode(value) + Data([10])
    try require(data.count <= 16384, "fixture protocol bound")
    try FileHandle.standardOutput.write(contentsOf: data)
}
private func descendantInput(_ milliseconds: Int32) throws -> Bool {
    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
    let status = poll(&descriptor, 1, milliseconds)
    if status < 0 && errno == EINTR { return false }
    try require(status >= 0, "fixture pipe poll failed")
    return status > 0
}
private final class DescendantFixtureChild {
    let task = Process(), input = Pipe(), output = Pipe()
    var pending = Data(), closed = false
    init(request: DescendantFixtureRequest) throws {
        guard let binary = Bundle.main.executableURL else { throw InstrumentError("own binary unavailable") }
        task.executableURL = binary
        task.arguments = ["owned-descendant-fixture", "--fixture-json", String(decoding: try JSONEncoder().encode(request), as: UTF8.self), "--apply"]
        task.environment = [:]; task.standardInput = input; task.standardOutput = output; task.standardError = FileHandle.nullDevice
        try require(fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0, "fixture pipe setup failed")
        try task.run()
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        let fd = output.fileHandleForReading.fileDescriptor
        try require(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0, "fixture output bound failed")
    }
    func line<T: Codable>(_ type: T.Type, seconds: Double) throws -> T {
        let deadline = InstrumentClock.now() + seconds
        while InstrumentClock.now() < deadline {
            if let end = pending.firstIndex(of: 10) {
                let data = pending.prefix(upTo: end); pending.removeSubrange(...end)
                return try StrictJSON.decodeExact(type, from: data)
            }
            var buffer = [UInt8](repeating: 0, count: 2048)
            let count = read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            if count > 0 { pending.append(contentsOf: buffer.prefix(count)); try require(pending.count <= 16384, "fixture output bound") }
            else if count == 0 { throw InstrumentError("fixture output ended") }
            else if errno != EAGAIN && errno != EINTR { throw InstrumentError("fixture output failed") }
            else { Thread.sleep(forTimeInterval: 0.005) }
        }
        throw InstrumentError("fixture output timeout")
    }
    func arm() throws { try input.fileHandleForWriting.write(contentsOf: Data([0x47])) }
    func stop() { if !closed { try? input.fileHandleForWriting.close(); closed = true } }
    func wait(seconds: Double) -> Bool {
        let end = InstrumentClock.now() + seconds
        while task.isRunning && InstrumentClock.now() < end { Thread.sleep(forTimeInterval: 0.01) }
        return !task.isRunning && task.terminationStatus == 0
    }
    deinit { stop(); try? output.fileHandleForReading.close() }
}
extension InstrumentRunner {
    /// Native test producer only. No collector calls this path. The external harness registers
    /// ONLY its root hello, then reads recursive truth AFTER the normal descendant-memory CLI exits.
    public static func ownedDescendantFixture(requestJSON: Data) throws {
        let request = try StrictJSON.decodeExact(DescendantFixtureRequest.self, from: requestJSON)
        try request.expected.validate()
        try require((0...2).contains(request.level) && request.parentPID > 1, "invalid descendant fixture request")
        signal(SIGALRM, SIG_DFL); alarm(20)
        let identity = request.expected.capture(), signature = try ProbeSignature.capture()
        try require(identity.matches(request.expected) && signature.valid, "invalid descendant fixture credentials/signature")
        var input = stat(), output = stat()
        try require(getppid() == request.parentPID && fstat(STDIN_FILENO, &input) == 0 && fstat(STDOUT_FILENO, &output) == 0 &&
            input.st_mode & S_IFMT == S_IFIFO && output.st_mode & S_IFMT == S_IFIFO, "fixture requires owned parent pipes")
        let process = try DescendantReader.native.relation(getpid())
        try descendantLine(DescendantFixtureHello(process: process, identity: identity, signature: signature))
        let armDeadline = InstrumentClock.now() + 4
        while InstrumentClock.now() < armDeadline { if try descendantInput(20) { break } }
        var command: UInt8 = 0
        try require(InstrumentClock.now() < armDeadline && read(STDIN_FILENO, &command, 1) == 1 && command == 0x47 && getppid() == request.parentPID, "fixture not armed")
        let started = InstrumentClock.now(), lifetime = [12.0, 6.0, 2.5][request.level], mib = (request.level + 1) * 4
        var allocation: UnsafeMutableRawPointer?, allocatedAt: Double?, child: DescendantFixtureChild?, reason = "lifetime"
        defer { child?.stop(); allocation?.deallocate() }
        while InstrumentClock.now() < started + lifetime {
            if allocation == nil && InstrumentClock.now() >= started + 0.6 {
                allocation = .allocate(byteCount: mib * 1024 * 1024, alignment: 16384)
                memset(allocation!, 0x5a, mib * 1024 * 1024); allocatedAt = InstrumentClock.now()
            }
            if request.level < 2 && child == nil && InstrumentClock.now() >= started + 1.5 {
                child = try DescendantFixtureChild(request: DescendantFixtureRequest(level: request.level + 1, parentPID: getpid(), expected: request.expected))
                let hello = try child!.line(DescendantFixtureHello.self, seconds: 3)
                try require(hello.process.identity.pid == child!.task.processIdentifier && hello.process.parentPID == getpid() && hello.identity.matches(request.expected) && hello.signature.valid, "fixture child handshake failed")
                try child!.arm()
            }
            if getppid() != request.parentPID { reason = "parent-exit"; break }
            if try descendantInput(20) { var byte: UInt8 = 0; reason = read(STDIN_FILENO, &byte, 1) == 0 ? "parent-closed" : "protocol-stop"; break }
        }
        var descendants: [DescendantFixtureTruth] = [], cleaned = true
        if let child {
            child.stop()
            descendants = [try child.line(DescendantFixtureTruth.self, seconds: 3)]
            cleaned = child.wait(seconds: 1) && descendants[0].childCleanupComplete
        }
        if let allocation { try require(allocation.load(as: UInt8.self) == 0x5a, "fixture allocation changed") }
        try descendantLine(DescendantFixtureTruth(level: request.level, process: process, started: started, allocatedAt: allocatedAt,
            finished: InstrumentClock.now(), fixtureMiB: mib, reason: reason, child: descendants, childCleanupComplete: cleaned))
    }
}
