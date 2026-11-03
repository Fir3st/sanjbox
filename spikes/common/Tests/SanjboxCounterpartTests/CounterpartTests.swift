import Darwin
import Foundation
import SanjboxProbeKit
import Testing
@testable import SanjboxCounterpart

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sanjbox-counterpart-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func loopback(_ port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return address
}

/// Test sender: connects over IPv4 loopback and writes each chunk separately.
private func tcpSend(port: UInt16, chunks: [Data], close shouldClose: Bool) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = loopback(port)
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    try #require(connected == 0)
    for chunk in chunks {
        let sent = chunk.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        try #require(sent == chunk.count)
    }
    if shouldClose { close(fd) }
    return fd
}

private func udpSend(port: UInt16, _ data: Data) throws {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    defer { close(fd) }
    var address = loopback(port)
    let sent = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
            data.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, target, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
    try #require(sent == data.count)
}

/// DNS query for `<labels>.exfil.example.` as a recursive resolver would forward it.
private func dnsQuery(labels: [String]) -> Data {
    var bytes: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
    for label in labels + ["exfil", "example"] { bytes += [UInt8(label.utf8.count)] + Array(label.utf8) }
    bytes += [0, 0x00, 0x10, 0x00, 0x01]  // root, TXT, IN
    return Data(bytes)
}

/// Splits hex into 63-byte labels with alternating case, like DNS 0x20 randomization.
private func hexLabels(_ token: String) -> [String] {
    let hex = token.utf8.map { String(format: "%02x", $0) }.joined()
    let mixed = String(hex.enumerated().map { $0.offset.isMultiple(of: 2) ? Character($0.element.uppercased()) : $0.element })
    return stride(from: 0, to: mixed.count, by: 63).map { start in
        let from = mixed.index(mixed.startIndex, offsetBy: start)
        return String(mixed[from..<mixed.index(from, offsetBy: min(63, mixed.count - start))])
    }
}

private struct Run {
    let directory: URL
    let counterpart: Counterpart
    var log: URL { directory.appendingPathComponent("events.jsonl") }
    var raw: URL { directory.appendingPathComponent("raw") }

    init(canaries: [Canary], tcp: Bool = true, udp: Bool = true) throws {
        directory = try temporaryDirectory()
        counterpart = try Counterpart.start(.init(
            bindAddress: "::", tcpPorts: tcp ? [0] : [], udpPorts: udp ? [0] : [],
            logURL: directory.appendingPathComponent("events.jsonl"),
            rawDirectory: directory.appendingPathComponent("raw"), canaries: canaries
        ))
    }

    func port(_ transport: CounterpartEvent.Transport) throws -> UInt16 {
        try #require(counterpart.listeners.first { $0.transport == transport }).endpoint.port
    }

    func events() throws -> [CounterpartEvent] { try JSONLines.read(CounterpartEvent.self, from: log) }

    /// Waits until the counterpart has logged what the test sent. A real run likewise stops only
    /// after a settle time: a flow still in flight at stop is not recorded.
    func waitFor(_ condition: ([CounterpartEvent]) -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition((try? events()) ?? []) {  // a line may be half-written while polling
            try #require(Date() < deadline, "counterpart did not record the expected flows")
            usleep(10_000)
        }
    }
}

private func count(_ kind: CounterpartEvent.Kind, in events: [CounterpartEvent]) -> Int {
    events.filter { $0.kind == kind }.count
}

@Test func recordsTCPAndUDPFlowsWithCanaries() throws {
    let canary = try Canary.make(label: "net")
    let unregistered = try Canary.make(label: "late")
    let run = try Run(canaries: [canary])
    defer { try? FileManager.default.removeItem(at: run.directory) }

    let half = canary.token.utf8.count / 2
    let payload = Array(canary.token.utf8)
    _ = try tcpSend(port: try run.port(.tcp), chunks: [Data(payload[..<half]), Data(payload[half...])], close: true)
    try udpSend(port: try run.port(.udp), dnsQuery(labels: hexLabels(canary.token)))
    try udpSend(port: try run.port(.udp), Data(unregistered.token.utf8))
    try run.waitFor { count(.closed, in: $0) == 1 && count(.datagram, in: $0) == 2 }
    run.counterpart.stop()

    let report = CounterpartReport(events: try run.events())
    #expect(report.complete, "\(report.problems)")
    #expect(report.receivedAnything)
    #expect(report.tcpConnections == 1)
    #expect(report.udpDatagrams == 2)
    #expect(report.remoteHosts == ["::ffff:127.0.0.1"])
    #expect(report.findings.contains(.init(token: canary.token, encoding: "raw")))
    #expect(report.findings.contains(.init(token: canary.token, encoding: "dns-qname-hex")))
    #expect(report.findings.contains(.init(token: Canary.tokenPrefix, encoding: "raw")))

    let closed = try #require(try run.events().first { $0.kind == .closed })
    #expect(closed.bytes == payload.count)
    let rawFile = try #require(closed.rawFile)
    #expect(FileManager.default.contents(atPath: run.raw.appendingPathComponent(rawFile).path) == Data(payload))
}

@Test func stopClosesAndCountsOpenConnections() throws {
    let run = try Run(canaries: [], udp: false)
    defer { try? FileManager.default.removeItem(at: run.directory) }

    // Left open: the sender never closes, the counterpart must still count what arrived.
    let open = try (0..<3).map { _ in try tcpSend(port: try run.port(.tcp), chunks: [Data("held".utf8)], close: false) }
    defer { open.forEach { close($0) } }
    try run.waitFor { count(.accepted, in: $0) == 3 }
    run.counterpart.stop()

    let events = try run.events()
    let report = CounterpartReport(events: events)
    #expect(report.complete, "\(report.problems)")
    #expect(report.tcpConnections == 3)
    #expect(report.bytes == 12)
    #expect(events.filter { $0.kind == .closed }.allSatisfy { $0.endReason == "counterpartStopped" })
}

@Test func contactWithoutBytesStillCounts() throws {
    let run = try Run(canaries: [], udp: false)
    defer { try? FileManager.default.removeItem(at: run.directory) }

    _ = try tcpSend(port: try run.port(.tcp), chunks: [], close: true)
    try run.waitFor { count(.closed, in: $0) == 1 }
    run.counterpart.stop()

    let report = CounterpartReport(events: try run.events())
    #expect(report.complete)
    #expect(report.bytes == 0)
    #expect(report.receivedAnything)
}

@Test func quietRunIsCompleteAndEmpty() throws {
    let run = try Run(canaries: [])
    defer { try? FileManager.default.removeItem(at: run.directory) }
    run.counterpart.stop()
    run.counterpart.stop()

    let report = CounterpartReport(events: try run.events())
    #expect(report.complete)
    #expect(!report.receivedAnything)
    #expect(report.listeners.count == 2)
}

@Test func existingLogOrRawCapturesAreNeverReused() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("events.jsonl")
    FileManager.default.createFile(atPath: log.path, contents: Data("earlier run\n".utf8))

    #expect(throws: CounterpartError.self) {
        try Counterpart.start(.init(
            bindAddress: "::", tcpPorts: [0], udpPorts: [], logURL: log,
            rawDirectory: directory.appendingPathComponent("raw"), canaries: []
        ))
    }
    #expect(FileManager.default.contents(atPath: log.path) == Data("earlier run\n".utf8))

    let raw = directory.appendingPathComponent("used-raw")
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: raw.appendingPathComponent("1-tcp-80.bin").path, contents: Data())
    let fresh = directory.appendingPathComponent("fresh.jsonl")
    #expect(throws: CounterpartError.self) {
        try Counterpart.start(.init(bindAddress: "::", tcpPorts: [0], udpPorts: [], logURL: fresh, rawDirectory: raw, canaries: []))
    }
    #expect(!FileManager.default.fileExists(atPath: fresh.path))
}

@Test func incompleteLogsAreReported() {
    let started = CounterpartEvent(kind: .started, listeners: [])
    let accepted = CounterpartEvent(kind: .accepted, flowID: 1, transport: .tcp)
    let stopped = CounterpartEvent(kind: .stopped)

    #expect(CounterpartReport(events: []).complete == false)
    #expect(CounterpartReport(events: [started]).problems == ["last event is not stopped"])
    #expect(CounterpartReport(events: [started, accepted, stopped]).problems == ["flow 1 accepted but not closed"])
    #expect(CounterpartReport(events: [started, stopped, started, stopped]).complete == false)
    #expect(CounterpartReport(events: [started, stopped]).complete)
}

@Test func dnsQuestionJoinsLabelsAndRejectsOtherData() {
    #expect(DNSQuestion.joinedLabels(in: dnsQuery(labels: ["ab", "cd"])) == Data("abcdexfilexample".utf8))
    #expect(DNSQuestion.joinedLabels(in: Data("GET / HTTP/1.1\r\n\r\n".utf8)) == nil)

    var response = [UInt8](dnsQuery(labels: ["ab"]))
    response[2] |= 0x80
    #expect(DNSQuestion.joinedLabels(in: Data(response)) == nil)

    var pointer = [UInt8](dnsQuery(labels: []))
    pointer[12] = 0xC0
    #expect(DNSQuestion.joinedLabels(in: Data(pointer)) == nil)

    let truncated = dnsQuery(labels: ["abcdef"]).prefix(16)
    #expect(DNSQuestion.joinedLabels(in: truncated) == nil)
}
