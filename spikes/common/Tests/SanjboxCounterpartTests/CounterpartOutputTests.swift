import Darwin
import Foundation
import SanjboxProbeKit
import Testing
@testable import SanjboxCounterpart

private final class OutputFixture {
    let root: URL
    let run: URL
    var log: URL { run.appendingPathComponent("events.jsonl") }
    var raw: URL { run.appendingPathComponent("raw") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sanjbox-owned-output-\(UUID().uuidString)")
        run = root.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func configuration() -> Counterpart.Configuration {
        .init(bindAddress: "127.0.0.1", tcpPorts: [0], udpPorts: [0], logURL: log, rawDirectory: raw, canaries: [])
    }
    func events(at url: URL? = nil) throws -> [CounterpartEvent] {
        try JSONLines.read(CounterpartEvent.self, from: url ?? log)
    }
    func marker(_ name: String = "synthetic-canary.txt") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("synthetic output canary\n".utf8).write(to: url)
        return url
    }
}

private func outputWait(_ condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(5)
    while try !condition() {
        try #require(Date() < deadline, "timed out waiting for own counterpart")
        usleep(10_000)
    }
}

private func outputSendUDP(_ port: UInt16, _ data: Data) throws {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    try #require(fd >= 0)
    defer { Darwin.close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let sent = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
            data.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, target, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
    try #require(sent == data.count)
}

@Test func outputLogReplacementCannotRedirectStoppedEvent() throws {
    let fixture = try OutputFixture()
    let counterpart = try Counterpart.start(fixture.configuration())
    defer { counterpart.stop() }
    let original = fixture.run.appendingPathComponent("original.jsonl")
    let marker = try fixture.marker()
    let before = try Data(contentsOf: marker)
    try FileManager.default.moveItem(at: fixture.log, to: original)
    try FileManager.default.createSymbolicLink(at: fixture.log, withDestinationURL: marker)
    counterpart.stop()
    counterpart.stop()
    #expect(try Data(contentsOf: marker) == before)
    let events = try fixture.events(at: original)
    #expect(events.map(\.kind) == [.started, .stopped])
    #expect(CounterpartReport(events: events).complete)
}

@Test func outputAncestorReplacementRetainsLogAndRawObjects() throws {
    let fixture = try OutputFixture()
    let counterpart = try Counterpart.start(fixture.configuration())
    defer { counterpart.stop() }
    let original = fixture.root.appendingPathComponent("original")
    let decoy = fixture.root.appendingPathComponent("decoy")
    try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: false)
    try FileManager.default.moveItem(at: fixture.run, to: original)
    try FileManager.default.createSymbolicLink(at: fixture.run, withDestinationURL: decoy)
    let port = try #require(counterpart.listeners.first { $0.transport == .udp }).endpoint.port
    let payload = Data("synthetic UDP bytes".utf8)
    try outputSendUDP(port, payload)
    let originalLog = original.appendingPathComponent("events.jsonl")
    try outputWait { (try? fixture.events(at: originalLog).contains { $0.kind == .datagram }) == true }
    counterpart.stop()
    let events = try fixture.events(at: originalLog)
    let event = try #require(events.first { $0.kind == .datagram })
    let name = try #require(event.rawFile)
    #expect(try Data(contentsOf: original.appendingPathComponent("raw").appendingPathComponent(name)) == payload)
    #expect(try FileManager.default.contentsOfDirectory(atPath: decoy.path).isEmpty)
    #expect(CounterpartReport(events: events).complete)
    #expect(event.bytes == payload.count)
}

@Test func outputRawDirectoryReplacementBeforeFirstByteKeepsOriginalDirectory() throws {
    let fixture = try OutputFixture()
    let output = try CounterpartOutput(log: fixture.log, raw: fixture.raw)
    defer { output.close() }
    let original = fixture.run.appendingPathComponent("original-raw")
    try FileManager.default.moveItem(at: fixture.raw, to: original)
    try FileManager.default.createDirectory(at: fixture.raw, withIntermediateDirectories: false)
    var capture = RawCapture(directory: output.raw, name: "1-tcp-1234.bin")
    capture.write(Data("first".utf8))
    capture.close()
    #expect(try Data(contentsOf: original.appendingPathComponent("1-tcp-1234.bin")) == Data("first".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.raw.path).isEmpty)
}

@Test func outputCaptureReplacementKeepsOriginalFile() throws {
    let fixture = try OutputFixture()
    let output = try CounterpartOutput(log: fixture.log, raw: fixture.raw)
    defer { output.close() }
    var capture = RawCapture(directory: output.raw, name: "1-tcp-1234.bin")
    capture.write(Data("first".utf8))
    let path = fixture.raw.appendingPathComponent("1-tcp-1234.bin")
    let original = fixture.raw.appendingPathComponent("original.bin")
    let marker = try fixture.marker()
    let before = try Data(contentsOf: marker)
    try FileManager.default.moveItem(at: path, to: original)
    try FileManager.default.createSymbolicLink(at: path, withDestinationURL: marker)
    capture.write(Data("second".utf8))
    capture.close()
    capture.close()
    #expect(try Data(contentsOf: original) == Data("firstsecond".utf8))
    #expect(try Data(contentsOf: marker) == before)
}

@Test(arguments: ["file", "symlink", "hardlink", "directory", "fifo"])
func outputExistingLogConflictsRemainUntouched(kind: String) throws {
    let fixture = try OutputFixture()
    let marker = try fixture.marker()
    let before = try Data(contentsOf: marker)
    switch kind {
    case "file": try before.write(to: fixture.log)
    case "symlink": try FileManager.default.createSymbolicLink(at: fixture.log, withDestinationURL: marker)
    case "hardlink": try #require(link(marker.path, fixture.log.path) == 0)
    case "directory": try FileManager.default.createDirectory(at: fixture.log, withIntermediateDirectories: false)
    default: try #require(mkfifo(fixture.log.path, 0o600) == 0)
    }
    var initial = stat()
    try #require(lstat(fixture.log.path, &initial) == 0)
    #expect(throws: CounterpartError.self) { try Counterpart.start(fixture.configuration()) }
    var after = stat()
    try #require(lstat(fixture.log.path, &after) == 0)
    #expect(initial.st_ino == after.st_ino && initial.st_mode == after.st_mode)
    #expect(try Data(contentsOf: marker) == before)
    if kind == "file" { #expect(try Data(contentsOf: fixture.log) == before) }
}

@Test(arguments: ["raw", "raw-parent", "log-parent"])
func outputRejectsArbitraryDirectorySymlinks(location: String) throws {
    let fixture = try OutputFixture()
    let target = fixture.root.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    var configuration = fixture.configuration()
    if location == "raw" {
        try FileManager.default.createSymbolicLink(at: fixture.raw, withDestinationURL: target)
    } else {
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        if location == "raw-parent" { configuration.rawDirectory = alias.appendingPathComponent("raw") }
        else { configuration.logURL = alias.appendingPathComponent("events.jsonl") }
    }
    #expect(throws: CounterpartError.self) { try Counterpart.start(configuration) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.log.path))
}

@Test func outputRejectsWritableRawDirectoryAndLogInsideRaw() throws {
    let fixture = try OutputFixture()
    try FileManager.default.createDirectory(at: fixture.raw, withIntermediateDirectories: false)
    try #require(chmod(fixture.raw.path, 0o777) == 0)
    #expect(throws: CounterpartError.self) { try CounterpartOutput(log: fixture.log, raw: fixture.raw) }
    try #require(chmod(fixture.raw.path, 0o700) == 0)
    #expect(throws: CounterpartError.self) {
        try CounterpartOutput(log: fixture.raw.appendingPathComponent("events.jsonl"), raw: fixture.raw)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.raw.path).isEmpty)
}

@Test func outputStartupFailureRetainsCreatedEvidence() throws {
    let fixture = try OutputFixture()
    var configuration = fixture.configuration()
    configuration.bindAddress = "invalid numeric address"
    #expect(throws: CounterpartError.self) { try Counterpart.start(configuration) }
    #expect(try Data(contentsOf: fixture.log).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.raw.path).isEmpty)
    #expect(throws: CounterpartError.self) { try Counterpart.start(configuration) }
    #expect(try Data(contentsOf: fixture.log).isEmpty)
}

@Test func outputEmptyContactAndCaptureLimitPreserveSemantics() throws {
    let fixture = try OutputFixture()
    let output = try CounterpartOutput(log: fixture.log, raw: fixture.raw)
    defer { output.close() }
    var capture = RawCapture(directory: output.raw, name: "1-tcp-1234.bin")
    capture.write(Data())
    #expect(capture.fileName == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.raw.path).isEmpty)
    let bytes = Data(repeating: 0x42, count: Counterpart.rawLimit + 12)
    capture.write(bytes)
    capture.write(Data("tail".utf8))
    capture.close()
    #expect(capture.truncated)
    #expect(try Data(contentsOf: fixture.raw.appendingPathComponent("1-tcp-1234.bin")) == bytes.prefix(Counterpart.rawLimit))
    for (url, mode) in [(fixture.log, mode_t(0o600)), (fixture.raw, mode_t(0o700)),
                        (fixture.raw.appendingPathComponent("1-tcp-1234.bin"), mode_t(0o600))] {
        var info = stat()
        try #require(lstat(url.path, &info) == 0)
        #expect(info.st_uid == geteuid())
        #expect(info.st_mode & 0o777 == mode)
    }
}

@Test func outputZeroByteUDPStillCountsWithoutRawFile() throws {
    let fixture = try OutputFixture()
    let counterpart = try Counterpart.start(fixture.configuration())
    defer { counterpart.stop() }
    let port = try #require(counterpart.listeners.first { $0.transport == .udp }).endpoint.port
    try outputSendUDP(port, Data())
    try outputWait { (try? fixture.events().contains { $0.kind == .datagram }) == true }
    counterpart.stop()
    let events = try fixture.events()
    let report = CounterpartReport(events: events)
    #expect(report.complete && report.receivedAnything)
    #expect(report.udpDatagrams == 1 && report.bytes == 0)
    #expect(events.first { $0.kind == .datagram }?.rawFile == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.raw.path).isEmpty)
}

@Test func outputWriterRetriesInterruptedAndPartialWrites() throws {
    let payload = Data("all output bytes".utf8)
    var calls = 0
    var actual = Data()
    try CounterpartOutputFile.writeAll(payload, to: -1) { _, bytes, count in
        calls += 1
        if calls == 1 || calls == 4 { errno = EINTR; return -1 }
        let count = min(count, 3)
        actual.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
        return count
    }
    #expect(actual == payload)
    #expect(calls > 4)
}

@Test(arguments: [0, -1])
func outputWriterRejectsNoProgressAndTerminalFailure(result: Int) throws {
    var calls = 0
    #expect(throws: CounterpartError.self) {
        try CounterpartOutputFile.writeAll(Data("partial".utf8), to: -1) { _, _, _ in
            calls += 1
            if calls == 1 { return 2 }
            errno = ENOSPC
            return result
        }
    }
    #expect(calls == 2)
}

@Test(arguments: ["hardlink", "mode"])
func outputWriterFailureCannotBeResumedOrClaimStopped(change: String) throws {
    let fixture = try OutputFixture()
    let output = try CounterpartOutput(log: fixture.log, raw: fixture.raw)
    defer { output.close() }
    try output.record(.init(kind: .started, listeners: []))
    let alias = fixture.root.appendingPathComponent("log-alias")
    if change == "hardlink" { try #require(link(fixture.log.path, alias.path) == 0) }
    else { try #require(chmod(fixture.log.path, 0o666) == 0) }
    #expect(throws: CounterpartError.self) { try output.record(.init(kind: .stopped)) }
    if change == "hardlink" { try #require(unlink(alias.path) == 0) }
    else { try #require(chmod(fixture.log.path, 0o600) == 0) }
    #expect(throws: CounterpartError.self) { try output.record(.init(kind: .stopped)) }
    output.close()
    output.close()
    #expect(try fixture.events().map(\.kind) == [.started])
    #expect(try !CounterpartReport(events: fixture.events()).complete)
}

@Test func outputStandardTemporaryAliasWorks() throws {
    let path = "/private/tmp/sanjbox-output-alias-\(UUID().uuidString)"
    try #require(mkdir(path, 0o700) == 0)
    defer { try? FileManager.default.removeItem(atPath: path) }
    let alias = path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")
    let counterpart = try Counterpart.start(.init(
        bindAddress: "127.0.0.1", tcpPorts: [0], udpPorts: [],
        logURL: URL(fileURLWithPath: alias + "/events.jsonl"),
        rawDirectory: URL(fileURLWithPath: alias + "/raw"), canaries: []
    ))
    counterpart.stop()
    let events = try JSONLines.read(CounterpartEvent.self, from: URL(fileURLWithPath: path + "/events.jsonl"))
    #expect(CounterpartReport(events: events).complete)
}

@Test(arguments: ["file", "symlink", "hardlink"])
func outputCaptureConflictsAfterSetupRemainUntouched(kind: String) throws {
    let fixture = try OutputFixture()
    let output = try CounterpartOutput(log: fixture.log, raw: fixture.raw)
    defer { output.close() }
    let marker = try fixture.marker()
    let before = try Data(contentsOf: marker)
    let path = fixture.raw.appendingPathComponent("1-tcp-1234.bin")
    if kind == "file" { try before.write(to: path) }
    else if kind == "hardlink" { try #require(link(marker.path, path.path) == 0) }
    else { try FileManager.default.createSymbolicLink(at: path, withDestinationURL: marker) }
    #expect(throws: CounterpartError.self) { try output.raw.createFile(named: "1-tcp-1234.bin") }
    #expect(try Data(contentsOf: path) == before)
    #expect(try Data(contentsOf: marker) == before)
}
