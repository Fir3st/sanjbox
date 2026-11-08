import Foundation
import SanjboxProbeKit
import Testing
@testable import SanjboxCounterpart

private enum ReportFixture {
    static let local = Endpoint(host: "127.0.0.1", port: 43123)
    static let remote = Endpoint(host: "127.0.0.1", port: 54321)
    static let finding = CanaryScanner.Finding(token: "SANJBOX-CANARY-synthetic", encoding: "raw")
    static let start = CounterpartEvent(kind: .started, listeners: [
        Listener(transport: .tcp, endpoint: local), Listener(transport: .udp, endpoint: local),
    ])
    static let stop = CounterpartEvent(kind: .stopped)

    static func accepted(_ id: Int = 1) -> CounterpartEvent {
        CounterpartEvent(kind: .accepted, flowID: id, transport: .tcp, local: local, remote: remote)
    }

    static func receipt(_ kind: CounterpartEvent.Kind = .closed, id: Int = 1, bytes: Int = 8) -> CounterpartEvent {
        let transport: CounterpartEvent.Transport = kind == .datagram ? .udp : .tcp
        return CounterpartEvent(
            kind: kind, flowID: id, transport: transport, local: local, remote: remote, bytes: bytes,
            findings: [], rawFile: bytes > 0 ? "\(id)-\(transport.rawValue)-\(local.port).bin" : nil,
            rawTruncated: bytes > Counterpart.rawLimit, endReason: kind == .closed ? "peerClosed" : nil
        )
    }

    static func event(_ kind: CounterpartEvent.Kind) -> CounterpartEvent {
        switch kind {
        case .started: start
        case .stopped: stop
        case .accepted: accepted()
        case .closed, .datagram: receipt(kind)
        }
    }

    static func run(containing event: CounterpartEvent) -> [CounterpartEvent] {
        switch event.kind {
        case .started: [event, stop]
        case .stopped: [start, event]
        case .accepted: [start, event, receipt(), stop]
        case .closed: [start, accepted(), event, stop]
        case .datagram: [start, event, stop]
        }
    }
}

private let kinds: [CounterpartEvent.Kind] = [.started, .accepted, .closed, .datagram, .stopped]
private let fields = ["listeners", "flowID", "transport", "local", "remote", "bytes", "findings", "rawFile", "rawTruncated", "endReason"]

private func fieldObject(_ event: CounterpartEvent) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: JSONLines.encoder.encode(event)) as? [String: Any])
}

private func decodedEvent(_ object: [String: Any]) throws -> CounterpartEvent {
    try JSONLines.decoder.decode(CounterpartEvent.self, from: JSONSerialization.data(withJSONObject: object))
}

@Test func missingFlowIDsNeverHideTCPContactOrBytes() {
    var accepted = ReportFixture.accepted()
    var closed = ReportFixture.receipt()
    accepted.flowID = nil
    closed.flowID = nil
    closed.findings = [ReportFixture.finding]
    let report = CounterpartReport(events: [ReportFixture.start, accepted, closed, ReportFixture.stop])
    #expect(!report.complete)
    #expect(report.receivedAnything)
    #expect(report.tcpConnections > 0)
    #expect(report.bytes == 8)
    #expect(report.findings == [ReportFixture.finding])
    #expect(report.problems.contains { $0.contains("missing flowID") })
}

@Test(arguments: kinds)
func everyProducerRequiredFieldIsChecked(kind: CounterpartEvent.Kind) throws {
    let baseline = ReportFixture.event(kind)
    let object = try fieldObject(baseline)
    #expect(CounterpartReport(events: ReportFixture.run(containing: baseline)).complete)
    // Every encoded field other than rawFile is required for this kind. rawFile is required
    // separately by positive bytes; timestamp/kind are nonoptional Codable fields.
    for field in object.keys where field != "timestamp" && field != "kind" {
        for null in [false, true] {
            var malformed = object
            if null { malformed[field] = NSNull() } else { malformed.removeValue(forKey: field) }
            let event = try decodedEvent(malformed)
            let report = CounterpartReport(events: ReportFixture.run(containing: event))
            #expect(!report.complete, "\(kind) accepted missing/null \(field)")
        }
    }
}

@Test(arguments: kinds)
func fieldsFromOtherKindsAreForbidden(kind: CounterpartEvent.Kind) throws {
    var allFields = try fieldObject(ReportFixture.start)
    for (key, value) in try fieldObject(ReportFixture.receipt()) { allFields[key] = value }
    let baseline = try fieldObject(ReportFixture.event(kind))
    for field in fields where baseline[field] == nil {
        // rawFile is optional on receipts only when they carry no bytes.
        var malformed = baseline
        let value: Any = try #require(allFields[field])
        malformed[field] = value
        let report = CounterpartReport(events: ReportFixture.run(containing: try decodedEvent(malformed)))
        #expect(!report.complete, "\(kind) accepted forbidden \(field)")
        #expect(report.problems.contains { $0.contains("forbidden \(field)") })
    }
}

@Test func invalidEmptyAndDuplicateListenersCannotProveQuietRun() {
    let valid = ReportFixture.start
    let malformed: [[Listener]?] = [nil, [], valid.listeners! + valid.listeners!,
        [.init(transport: .tcp, endpoint: .init(host: "127.0.0.1", port: 0))],
        [.init(transport: .tcp, endpoint: .init(host: "localhost", port: 1234))],
        [.init(transport: .tcp, endpoint: .init(host: "::1", port: 1234)),
         .init(transport: .tcp, endpoint: .init(host: "0:0:0:0:0:0:0:1", port: 1234))],
    ]
    for listeners in malformed {
        var started = valid
        started.listeners = listeners
        let report = CounterpartReport(events: [started, ReportFixture.stop])
        #expect(!report.complete)
        #expect(!report.problems.isEmpty)
    }
    let quiet = CounterpartReport(events: [valid, ReportFixture.stop])
    #expect(quiet.complete)
    #expect(!quiet.receivedAnything)
}

@Test func lifecycleAndIDViolationsAreInvalid() {
    let s = ReportFixture.start, a = ReportFixture.accepted(), c = ReportFixture.receipt(), e = ReportFixture.stop
    let u = ReportFixture.receipt(.datagram)
    let malformed = [
        [], [s], [e], [s, a, e], [s, c, e], [s, c, a, e],
        [a, s, c, e], [s, e, a, c], [s, a, e, c, e],
        [s, s, e], [s, e, e], [s, e, s, e],
        [s, a, a, c, e], [s, a, c, c, e], [s, a, c, a, c, e],
        [s, u, u, e], [s, a, c, u, e], [s, u, a, c, e],
        [s, ReportFixture.accepted(2), ReportFixture.receipt(id: 2), e],
    ]
    for events in malformed { #expect(!CounterpartReport(events: events).complete) }
}

@Test(arguments: [0, -1, Int.min, Int.max])
func adverseIDsAreInvalidWithoutIndexingOrIteratingTheirRange(id: Int) {
    let tcp = CounterpartReport(events: [ReportFixture.start, ReportFixture.accepted(id), ReportFixture.receipt(id: id), ReportFixture.stop])
    let udp = CounterpartReport(events: [ReportFixture.start, ReportFixture.receipt(.datagram, id: id), ReportFixture.stop])
    #expect(!tcp.complete)
    #expect(!udp.complete)
    #expect(tcp.receivedAnything)
    #expect(udp.receivedAnything)
    #expect(tcp.bytes == 8)
    #expect(udp.bytes == 8)
}

@Test func interleavedIDsAndTimestampsNeedNotIncreaseInLogOrder() {
    var second = ReportFixture.accepted(2)
    second.timestamp = Date(timeIntervalSince1970: 100)
    var first = ReportFixture.accepted(1)
    first.timestamp = Date(timeIntervalSince1970: 90)
    let report = CounterpartReport(events: [ReportFixture.start, second, first, ReportFixture.receipt(id: 1),
        ReportFixture.receipt(.datagram, id: 3, bytes: 0), ReportFixture.receipt(id: 2), ReportFixture.stop])
    #expect(report.complete, "\(report.problems)")
    #expect(report.tcpConnections == 2)
    #expect(report.udpDatagrams == 1)
    #expect(report.bytes == 16)
}

@Test func transportEndpointsAndClosedIdentityMustMatch() {
    var cases: [CounterpartEvent] = []
    var event = ReportFixture.receipt()
    event.remote?.port += 1
    cases.append(event)
    event = ReportFixture.receipt()
    event.local?.port += 1
    cases.append(event)
    event = ReportFixture.receipt()
    event.local?.host = "127.0.0.2"
    cases.append(event)
    event = ReportFixture.receipt()
    event.transport = .udp
    cases.append(event)
    for closed in cases {
        #expect(!CounterpartReport(events: ReportFixture.run(containing: closed)).complete)
    }
    var datagram = ReportFixture.receipt(.datagram)
    datagram.transport = .tcp
    #expect(!CounterpartReport(events: ReportFixture.run(containing: datagram)).complete)
    datagram = ReportFixture.receipt(.datagram)
    datagram.local?.port += 1
    #expect(!CounterpartReport(events: ReportFixture.run(containing: datagram)).complete)
}

@Test(arguments: ["", "localhost", "127.0.0.1\u{0}bad", "127.0.0.1%lo0", "::1%", "::1%lo0%extra", "::1%bad scope", "[::1]", String(repeating: "x", count: 2048)])
func invalidNumericHostsAreRejected(host: String) {
    var accepted = ReportFixture.accepted()
    var closed = ReportFixture.receipt()
    accepted.remote?.host = host
    closed.remote?.host = host
    #expect(!CounterpartReport(events: [ReportFixture.start, accepted, closed, ReportFixture.stop]).complete)
    var start = ReportFixture.start
    start.listeners = [.init(transport: .tcp, endpoint: .init(host: host, port: 1234))]
    #expect(!CounterpartReport(events: [start, ReportFixture.stop]).complete)
}

@Test func wildcardIPv4AndDualStackIPv6ListenersMatchActualProducerEndpoints() {
    for (bind, local, remote) in [("0.0.0.0", "127.0.0.1", "127.0.0.1"),
                                 ("::", "::ffff:127.0.0.1", "::ffff:127.0.0.1"),
                                 ("::", "::1", "::1"), ("::", "fe80::1%lo0", "fe80::2%lo0")] {
        var start = ReportFixture.start
        start.listeners = [.init(transport: .tcp, endpoint: .init(host: bind, port: ReportFixture.local.port)),
                           .init(transport: .udp, endpoint: .init(host: bind, port: ReportFixture.local.port))]
        var accepted = ReportFixture.accepted()
        var closed = ReportFixture.receipt()
        accepted.local?.host = local
        accepted.remote?.host = remote
        closed.local = accepted.local
        closed.remote = accepted.remote
        var datagram = ReportFixture.receipt(.datagram, id: 2)
        datagram.local?.host = bind
        datagram.remote?.host = remote
        let report = CounterpartReport(events: [start, accepted, closed, datagram, ReportFixture.stop])
        #expect(report.complete, "\(report.problems)")
        // UDP's local endpoint is the listener, not the destination reported by TCP getsockname.
        datagram.local?.host = local
        #expect(!CounterpartReport(events: [start, accepted, closed, datagram, ReportFixture.stop]).complete)
    }
}

@Test func dualStackUDPAllowsPlainIPv4SourcesReportedByDarwin() {
    for bind in ["::", "::ffff:127.0.0.1"] {
        var start = ReportFixture.start
        start.listeners = [.init(transport: .udp, endpoint: .init(host: bind, port: ReportFixture.local.port))]
        var datagram = ReportFixture.receipt(.datagram)
        datagram.local?.host = bind
        #expect(CounterpartReport(events: [start, datagram, ReportFixture.stop]).complete)
    }
}

@Test func endpointPortAndAddressFamilyConstraintsRespectUDPSourcePortZero() {
    for remote in [Endpoint(host: "127.0.0.1", port: 0), Endpoint(host: "0.0.0.0", port: 1234), Endpoint(host: "::1", port: 1234)] {
        var accepted = ReportFixture.accepted(), closed = ReportFixture.receipt()
        accepted.remote = remote
        closed.remote = remote
        #expect(!CounterpartReport(events: [ReportFixture.start, accepted, closed, ReportFixture.stop]).complete)
    }
    var datagram = ReportFixture.receipt(.datagram, bytes: 0)
    datagram.remote?.port = 0
    let report = CounterpartReport(events: ReportFixture.run(containing: datagram))
    #expect(report.complete)
    #expect(report.receivedAnything)
    #expect(report.bytes == 0)
    datagram.remote?.host = "::1"
    #expect(!CounterpartReport(events: ReportFixture.run(containing: datagram)).complete)
}

@Test func rawCaptureMetadataMustAgreeWithReceipt() {
    for kind in [CounterpartEvent.Kind.closed, .datagram] {
        for raw in [nil, "", "../1-tcp-43123.bin", "2-tcp-43123.bin", "/tmp/1-tcp-43123.bin"] as [String?] {
            var receipt = ReportFixture.receipt(kind)
            receipt.rawFile = raw
            #expect(!CounterpartReport(events: ReportFixture.run(containing: receipt)).complete)
        }
        var empty = ReportFixture.receipt(kind, bytes: 0)
        empty.rawFile = "1-tcp-43123.bin"
        #expect(!CounterpartReport(events: ReportFixture.run(containing: empty)).complete)
        var truncated = ReportFixture.receipt(kind)
        truncated.rawTruncated = true
        #expect(!CounterpartReport(events: ReportFixture.run(containing: truncated)).complete)
    }
    for count in [0, Counterpart.rawLimit, Counterpart.rawLimit + 1] {
        let receipt = ReportFixture.receipt(bytes: count)
        #expect(CounterpartReport(events: ReportFixture.run(containing: receipt)).complete)
        var wrong = receipt
        wrong.rawTruncated = !(receipt.rawTruncated ?? false)
        #expect(!CounterpartReport(events: ReportFixture.run(containing: wrong)).complete)
    }
    #expect(!CounterpartReport(events: ReportFixture.run(containing: ReportFixture.receipt(.datagram, bytes: 65537))).complete)
}

@Test func producerEndReasonsAreAcceptedAndOtherReasonsAreInvalid() {
    for reason in ["peerClosed", "counterpartStopped", "counterpartStopped (drain limit reached)", "read errno 54"] {
        var closed = ReportFixture.receipt()
        closed.endReason = reason
        #expect(CounterpartReport(events: ReportFixture.run(containing: closed)).complete)
    }
    for reason in ["", "unknown", "read errno 0", "read errno -1", "read errno 054", "read errno 9999999999999999999999999"] {
        var closed = ReportFixture.receipt()
        closed.endReason = reason
        #expect(!CounterpartReport(events: ReportFixture.run(containing: closed)).complete)
    }
}

@Test func negativeCountsCannotCancelEvidenceAndOverflowSaturates() {
    for count in [-1, Int.min] {
        var receipt = ReportFixture.receipt(.datagram, id: 2, bytes: count)
        receipt.findings = [ReportFixture.finding]
        let report = CounterpartReport(events: [ReportFixture.start, ReportFixture.accepted(), ReportFixture.receipt(), receipt, ReportFixture.stop])
        #expect(!report.complete)
        #expect(report.bytes == 8)
        #expect(report.receivedAnything)
        #expect(report.findings == [ReportFixture.finding])
    }
    let report = CounterpartReport(events: [ReportFixture.start, ReportFixture.accepted(),
        ReportFixture.receipt(bytes: Int.max), ReportFixture.receipt(.datagram, id: 2, bytes: 1), ReportFixture.stop])
    #expect(!report.complete)
    #expect(report.bytes == Int.max)
    #expect(report.problems.contains { $0.contains("byte total exceeds") })
    var publicReport = report
    publicReport.tcpConnections = Int.max
    publicReport.udpDatagrams = Int.max
    #expect(publicReport.receivedAnything)
}

@Test func misplacedEvidenceOrOrphanClosureStillReportsContact() {
    var start = ReportFixture.start
    start.bytes = 8
    start.findings = [ReportFixture.finding]
    let misplaced = CounterpartReport(events: [start, ReportFixture.stop])
    #expect(!misplaced.complete)
    #expect(misplaced.bytes == 8)
    #expect(misplaced.findings == [ReportFixture.finding])
    #expect(misplaced.receivedAnything)
    let orphan = CounterpartReport(events: [ReportFixture.start, ReportFixture.receipt(bytes: 0), ReportFixture.stop])
    #expect(!orphan.complete)
    #expect(orphan.receivedAnything)
    #expect(orphan.tcpConnections == 1)
}

@Test func diagnosticsAreBoundedWhileAllObservationsAreRetained() {
    var event = CounterpartEvent(kind: .datagram, bytes: 1, findings: [ReportFixture.finding])
    event.timestamp = Date(timeIntervalSinceReferenceDate: .infinity)
    let report = CounterpartReport(events: [ReportFixture.start] + Array(repeating: event, count: 300) + [ReportFixture.stop])
    #expect(!report.complete)
    #expect(report.problems.count == 100)
    #expect(report.problems.last == "additional problems omitted")
    #expect(report.bytes == 300)
    #expect(report.udpDatagrams == 300)
    #expect(report.findings == [ReportFixture.finding])
}

@Test func malformedFindingsRemainVisible() {
    var event = ReportFixture.receipt()
    event.findings = [.init(token: "synthetic", encoding: "unknown"), ReportFixture.finding, ReportFixture.finding]
    let report = CounterpartReport(events: ReportFixture.run(containing: event))
    #expect(!report.complete)
    #expect(report.findings.count == 2)
    #expect(report.receivedAnything)
    var dns = ReportFixture.receipt(.datagram)
    dns.findings = [.init(token: "synthetic", encoding: "dns-qname-hex")]
    #expect(CounterpartReport(events: ReportFixture.run(containing: dns)).complete)
}

@Test func JSONLRoundTripPreservesValidWireAndMalformedFieldEvidence() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sanjbox-counterpart-report-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("events.jsonl")
    let events = [ReportFixture.start, ReportFixture.accepted(), ReportFixture.receipt(), ReportFixture.stop]
    for event in events { try JSONLines.append(event, to: url) }
    let decoded = try JSONLines.read(CounterpartEvent.self, from: url)
    #expect(CounterpartReport(events: decoded).complete)
    #expect(CounterpartReport(events: decoded).bytes == 8)
    let invalid = directory.appendingPathComponent("invalid.jsonl")
    for var event in events {
        if event.kind == .accepted || event.kind == .closed { event.flowID = nil }
        try JSONLines.append(event, to: invalid)
    }
    let report = CounterpartReport(events: try JSONLines.read(CounterpartEvent.self, from: invalid))
    #expect(!report.complete)
    #expect(report.bytes == 8)
    #expect(report.receivedAnything)
}

/// SwiftPM puts the executable next to its test bundle (Debug and Release). No external build,
/// shell command, PATH lookup or network listener is involved in the CLI regression.
private final class CounterpartTestBundle: NSObject {}

private func counterpartExecutable() throws -> URL {
    var parent = Bundle(for: CounterpartTestBundle.self).bundleURL.deletingLastPathComponent()
    for _ in 0..<6 {
        let candidate = parent.appendingPathComponent("sanjbox-counterpart")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        parent.deleteLastPathComponent()
    }
    throw CLIExecutableMissing()
}

private struct CLIExecutableMissing: Error {}

@Test func CLIExitCodesRejectFormerFalsePassAndKeepValidOutcomes() throws {
    let executable = try counterpartExecutable()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sanjbox-counterpart-cli-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var missingAccepted = ReportFixture.accepted(), missingClosed = ReportFixture.receipt()
    missingAccepted.flowID = nil
    missingClosed.flowID = nil
    let scenarios: [(String, [CounterpartEvent], Int32, Int, Bool)] = [
        ("quiet", [ReportFixture.start, ReportFixture.stop], 0, 0, false),
        ("empty-tcp", [ReportFixture.start, ReportFixture.accepted(), ReportFixture.receipt(bytes: 0), ReportFixture.stop], 1, 0, true),
        ("tcp-bytes", [ReportFixture.start, ReportFixture.accepted(), ReportFixture.receipt(), ReportFixture.stop], 1, 8, true),
        ("empty-udp", [ReportFixture.start, ReportFixture.receipt(.datagram, bytes: 0), ReportFixture.stop], 1, 0, true),
        ("missing-ids", [ReportFixture.start, missingAccepted, missingClosed, ReportFixture.stop], 3, 8, true),
        ("no-listeners", [.init(kind: .started, listeners: []), ReportFixture.stop], 3, 0, false),
        ("duplicate-accept", [ReportFixture.start, ReportFixture.accepted(), ReportFixture.accepted(), ReportFixture.receipt(), ReportFixture.stop], 3, 8, true),
        ("reordered", [ReportFixture.start, ReportFixture.receipt(), ReportFixture.accepted(), ReportFixture.stop], 3, 8, true),
        ("overflow", [ReportFixture.start, ReportFixture.accepted(), ReportFixture.receipt(bytes: Int.max), ReportFixture.receipt(.datagram, id: 2), ReportFixture.stop], 3, Int.max, true),
    ]
    for (name, events, expectedExit, expectedBytes, contact) in scenarios {
        let url = directory.appendingPathComponent("\(name).jsonl")
        for event in events { try JSONLines.append(event, to: url) }
        let (status, output) = try runReport(executable, log: url)
        #expect(status == expectedExit, "\(name): \(String(decoding: output, as: UTF8.self))")
        let report = try JSONDecoder().decode(CounterpartReport.self, from: output)
        #expect(report.complete == (expectedExit != 3))
        #expect(report.bytes == expectedBytes)
        #expect(report.receivedAnything == contact)
    }
    let syntax = directory.appendingPathComponent("syntax.jsonl")
    try Data("{not json}\n".utf8).write(to: syntax)
    #expect(try runReport(executable, log: syntax).0 == 2)
    #expect(try runReport(executable, log: directory.appendingPathComponent("absent.jsonl")).0 == 2)
}

private func runReport(_ executable: URL, log: URL) throws -> (Int32, Data) {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = ["report", "--log", log.path]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationReason == .exit)
    return (process.terminationStatus, data)
}
