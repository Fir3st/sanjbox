import CryptoKit
import Darwin
import Foundation
import SanjboxProbeKit

// Read-only DTOs for the producer formats pinned in ADAPTER.md. No socket, subprocess,
// file lookup, identity capture or counterpart enforcement implementation lives here.
public enum ImportOrigin: String, Codable, Sendable { case fixture, importedMeasured, unknown }
public struct ImportClock: Codable, Sendable {
    public var id: String
    /// Add this offset to the producer's UTC timestamp before subtracting runStartUTC.
    public var offsetMs: Int?
    public var uncertaintyMs: Int?
    public var discontinuities: Int?
    public var calibrationID: String?
    static let shape: Shape = .object(["id": .scalar, "offsetMs": .scalar, "uncertaintyMs": .scalar,
        "discontinuities": .scalar, "calibrationID": .scalar])
    var usable: Bool {
        validLabel(id) && offsetMs.map { (-86_400_000...86_400_000).contains($0) } == true &&
        uncertaintyMs.map { (1...60_000).contains($0) } == true && discontinuities == 0 &&
        calibrationID.map(validLabel) == true
    }
}
public struct ImportSource: Codable, Sendable {
    public var id: String
    public var format: String
    public var origin: ImportOrigin
    public var clock: ImportClock?
    public var text: String
    public var artifacts: [NetworkArtifact]? = nil
    static let shape: Shape = .object(["id": .scalar, "format": .scalar, "origin": .scalar,
        "clock": ImportClock.shape, "text": .scalar, "artifacts": .array(NetworkArtifact.shape)])
}
public struct WireEndpoint: Codable, Equatable, Sendable {
    public var host: String
    public var port: UInt16
    static let shape: Shape = .object(["host": .scalar, "port": .scalar])
    // Numeric literals only. Scoped/link-local and mapped/dual-stack need a separate adapter.
    var address: (family: IPFamily, canonical: String, wildcard: Bool, loopback: Bool)? {
        guard port > 0, host.utf8.count <= 45,
              host.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 46 || $0 == 58 }) else { return nil }
        var v4 = in_addr(), v6 = in6_addr()
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, host, &v4) == 1 {
            let bytes = withUnsafeBytes(of: &v4) { Array($0) }
            guard bytes[0] < 224, !(bytes[0] == 169 && bytes[1] == 254),
                  inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return (.ipv4, String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), bytes.allSatisfy { $0 == 0 }, bytes[0] == 127)
        }
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            guard bytes[0] != 255, !(bytes[0] == 254 && bytes[1] & 192 == 128),
                  !(bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255),
                  inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return (.ipv6, String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), bytes.allSatisfy { $0 == 0 }, bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1)
        }
        return nil
    }
    func matches(_ other: WireEndpoint) -> Bool {
        guard let a = address, let b = other.address else { return false }
        return a.family == b.family && a.canonical == b.canonical && port == other.port
    }
}
public enum WireTransport: String, Codable, Sendable { case tcp, udp }
public struct WireListener: Codable, Sendable {
    public var transport: WireTransport
    public var endpoint: WireEndpoint
    static let shape: Shape = .object(["transport": .scalar, "endpoint": WireEndpoint.shape])
}
public struct EndpointRegistration: Codable, Sendable {
    public var id: String
    public var scenarioID: String
    public var transport: WireTransport
    public var bind: WireEndpoint
    public var local: WireEndpoint
    public var remote: WireEndpoint
    static let shape: Shape = .object(["id": .scalar, "scenarioID": .scalar, "transport": .scalar,
        "bind": WireEndpoint.shape, "local": WireEndpoint.shape, "remote": WireEndpoint.shape])
    var problems: [String] {
        guard let s = Scenario.all.first(where: { $0.id == scenarioID }), let b = bind.address,
              let l = local.address, let r = remote.address else { return ["invalid/unsupported endpoint registration"] }
        var p: [String] = []
        if !validLabel(id) || b.family != s.family || l.family != s.family || r.family != s.family || l.wildcard || r.wildcard || bind.port != local.port {
            p.append("endpoint family/port/literal mismatch")
        }
        if s.bind == .wildcard ? !b.wildcard : !b.loopback { p.append("listener bind does not match matrix bind mode") }
        if !b.wildcard && !bind.matches(local) && !(s.route == .lanToZone && s.bind == .loopback && !l.loopback) {
            p.append("target local endpoint does not match listener bind")
        }
        if s.route == .lanToZone && (l.loopback || r.loopback) { p.append("LAN route must address the target machine, not LAN localhost") }
        return p
    }
}
public struct RecordReference: Codable, Hashable, Sendable {
    public var sourceID: String
    public var line: Int // one based in exact JSONL bytes
    static let shape: Shape = .object(["sourceID": .scalar, "line": .scalar])
}
public struct CounterpartReference: Codable, Hashable, Sendable {
    public var sourceID: String
    public var flowID: Int
    static let shape: Shape = .object(["sourceID": .scalar, "flowID": .scalar])
}
public struct CaptureReference: Codable, Sendable {
    public var sourceID: String
    public var captureID: UUID
    static let shape: Shape = .object(["sourceID": .scalar, "captureID": .scalar])
}
public struct FlowBinding: Codable, Sendable {
    public var flowID: UUID
    public var scenarioID: String
    public var stage: Stage
    public var endpointID: String
    public var canary: String?
    public var sender: RecordReference?
    public var senderIdentity: RecordReference?
    public var counterpart: CounterpartReference?
    public var capture: CaptureReference?
    public var network: NetworkBinding? = nil
    static let shape: Shape = .object(["flowID": .scalar, "scenarioID": .scalar, "stage": .scalar,
        "endpointID": .scalar, "canary": .scalar, "sender": RecordReference.shape,
        "senderIdentity": RecordReference.shape, "counterpart": CounterpartReference.shape, "capture": CaptureReference.shape, "network": NetworkBinding.shape])
}
public struct AdapterInput: Codable, Sendable {
    public var schemaVersion: Int
    public var runID: UUID
    public var runStartUTC: String
    /// The existing evaluate input, embedded unchanged. An invalid matrix cannot erase raw findings.
    public var matrixJSON: String?
    public var sources: [ImportSource]
    public var endpoints: [EndpointRegistration]
    public var bindings: [FlowBinding]
    static let shape: Shape = .object(["schemaVersion": .scalar, "runID": .scalar, "runStartUTC": .scalar,
        "matrixJSON": .scalar, "sources": .array(ImportSource.shape), "endpoints": .array(EndpointRegistration.shape),
        "bindings": .array(FlowBinding.shape)])
    public static func decode(_ data: Data) throws -> Self {
        let input = try strictDecode(Self.self, data: data, shape: shape)
        guard input.schemaVersion == 1, utcDate(input.runStartUTC) != nil,
              input.sources.count <= 16, input.endpoints.count <= 84, input.bindings.count <= 84,
              Set(input.sources.map(\.id)).count == input.sources.count,
              input.sources.allSatisfy({ validLabel($0.id) && validLabel($0.format) && $0.text.utf8.count <= 524_288 }),
              Set(input.endpoints.map(\.id)).count == input.endpoints.count else { throw IngressError("invalid adapter envelope/bounds/duplicate source or endpoint ID") }
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for source in object["sources"] as? [[String: Any]] ?? [] {
            if source["format"] as? String == "sanjboxNetworkProvenanceV1" { try rejectNetworkNulls(source) }
            else if let artifacts = source["artifacts"] { try rejectNetworkNulls(artifacts) }
        }
        for binding in object["bindings"] as? [[String: Any]] ?? [] {
            if let network = binding["network"] { try rejectNetworkNulls(network) }
        }
        guard input.sources.allSatisfy({ ($0.artifacts?.count ?? 0) <= 18 &&
            ($0.artifacts == nil || $0.format == "sanjboxNetworkProvenanceV1") }),
            input.bindings.allSatisfy({ $0.network.map { validLabel($0.senderSourceID) && validLabel($0.receiverSourceID) && (1...16).contains($0.contactID) } ?? true })
        else { throw IngressError("invalid network artifact/binding bounds or legacy mixing") }
        return input
    }
}

public struct SenderWire: Codable, Sendable {
    public var timestamp: String
    public var probe: String
    public var caseID: String?
    public var outcome: RunRecord.Outcome
    public var context: ProbeContext
    public var mismatches: [Mismatch]
    public var details: [String: String]
    static let contextShape: Shape = .object([
        "pid": .scalar, "parentPID": .scalar, "realUID": .scalar, "effectiveUID": .scalar, "realGID": .scalar,
        "effectiveGID": .scalar, "userName": .scalar, "kernelGroups": .array(.scalar),
        "groupMembership": .array(.object(["gid": .scalar, "isMember": .scalar])),
        "audit": .object(["sessionID": .scalar, "auditUID": .scalar, "flags": .scalar]),
        "launchdManager": .object(["name": .scalar, "uid": .scalar]),
        "windowSession": .object(["userID": .scalar, "userName": .scalar, "auditSessionID": .scalar,
            "onConsole": .scalar, "loginDone": .scalar])])
    static let shape: Shape = .object(["timestamp": .scalar, "probe": .scalar, "caseID": .scalar,
        "outcome": .scalar, "context": contextShape,
        "mismatches": .array(.object(["field": .scalar, "expected": .scalar, "actual": .scalar])),
        "details": .object(["expectedAuditSessionID": .scalar, "actualAuditSessionID": .scalar,
            "localKernelAcceptedBytes": .scalar, "clientError": .scalar, "verdict": .scalar])])
    var problems: [String] {
        var p: [String] = []
        if utcDate(timestamp) == nil { p.append("invalid UTC millisecond timestamp") }
        if context.pid <= 0 || context.parentPID < 0 || context.kernelGroups.count > 64 ||
            Set(context.kernelGroups).count != context.kernelGroups.count || context.groupMembership.count > 64 ||
            Set(context.groupMembership.map(\.gid)).count != context.groupMembership.count { p.append("invalid sender context/group bounds") }
        if probe == "sanjbox-s3-probe.identity" {
            if caseID != nil || !Set(details.keys).isSubset(of: ["expectedAuditSessionID", "actualAuditSessionID"]) ||
                details.count != 2 { p.append("invalid C1 identity details") }
        } else if probe == "sanjbox-s3-probe.send" {
            if caseID?.range(of: #"^NET-(0[1-9]|1[0-9]|2[0-7])$"#, options: .regularExpression) == nil || outcome != .unclear ||
                !Set(details.keys).isSubset(of: ["localKernelAcceptedBytes", "clientError", "verdict"]) || details.count != 2 {
                p.append("invalid C1 send fields")
            }
            if let bytes = details["localKernelAcceptedBytes"] {
                if Int(bytes).map({ (0...5_152).contains($0) && String($0) == bytes }) != true || details["verdict"] != "external oracle required" {
                    p.append("invalid C1 byte count/verdict")
                }
            } else if details["clientError"] == nil || details["verdict"] != "client failure is not proof of isolation" {
                p.append("invalid C1 error/verdict")
            }
        } else { p.append("unsupported RunRecord producer") }
        return p
    }
}
public enum CounterpartKind: String, Codable, Sendable { case started, accepted, closed, datagram, stopped }
public struct CounterpartWire: Codable, Sendable {
    public var timestamp: String
    public var kind: CounterpartKind
    public var listeners: [WireListener]?
    public var flowID: Int?
    public var transport: WireTransport?
    public var local: WireEndpoint?
    public var remote: WireEndpoint?
    public var bytes: Int?
    public var findings: [CanaryScanner.Finding]?
    public var rawFile: String?
    public var rawTruncated: Bool?
    public var endReason: String?
    static let shape: Shape = .object(["timestamp": .scalar, "kind": .scalar, "listeners": .array(WireListener.shape),
        "flowID": .scalar, "transport": .scalar, "local": WireEndpoint.shape, "remote": WireEndpoint.shape,
        "bytes": .scalar, "findings": .array(.object(["token": .scalar, "encoding": .scalar])),
        "rawFile": .scalar, "rawTruncated": .scalar, "endReason": .scalar])
    var problems: [String] {
        var p: [String] = []
        if utcDate(timestamp) == nil { p.append("invalid UTC millisecond timestamp") }
        if let flowID, !(1...1_000_000).contains(flowID) { p.append("counterpart flow ID out of bounds") }
        if let bytes, !(0...1_073_741_824).contains(bytes) { p.append("counterpart byte count out of bounds") }
        if let local, local.address == nil { p.append("invalid/unsupported local endpoint") }
        if let remote, remote.address == nil || remote.address?.wildcard == true { p.append("invalid/unsupported remote endpoint") }
        if let rawFile, rawFile.range(of: #"^[1-9][0-9]{0,6}-(tcp|udp)-[1-9][0-9]{0,4}\.bin$"#, options: .regularExpression) == nil {
            p.append("invalid raw basename (never opened)")
        }
        if let findings, findings.count > 64 || Set(findings).count != findings.count || findings.contains(where: {
            ($0.token != Canary.tokenPrefix && !validCanary($0.token)) || !["raw", "hex", "dns-qname-raw", "dns-qname-hex"].contains($0.encoding)
        }) { p.append("invalid canary findings") }
        switch kind {
        case .started:
            if listeners?.isEmpty != false || listeners!.count > 16 || listeners!.contains(where: { $0.endpoint.address == nil }) { p.append("invalid/missing started listeners") }
            if flowID != nil || transport != nil || local != nil || remote != nil || bytes != nil || findings != nil || rawFile != nil || rawTruncated != nil || endReason != nil { p.append("unexpected started fields") }
        case .stopped:
            if listeners != nil || flowID != nil || transport != nil || local != nil || remote != nil || bytes != nil || findings != nil || rawFile != nil || rawTruncated != nil || endReason != nil { p.append("unexpected stopped fields") }
        case .accepted:
            if flowID == nil || transport != .tcp || local == nil || remote == nil { p.append("accepted missing flow/tuple/TCP") }
            if listeners != nil || bytes != nil || findings != nil || rawFile != nil || rawTruncated != nil || endReason != nil { p.append("unexpected accepted fields") }
        case .closed, .datagram:
            if flowID == nil || local == nil || remote == nil || bytes == nil || findings == nil || rawTruncated == nil ||
                transport != (kind == .closed ? .tcp : .udp) { p.append("terminal event missing flow/tuple/count/findings/transport") }
            if listeners != nil || (kind == .closed ? endReason == nil : endReason != nil) { p.append("invalid terminal event fields") }
            if bytes == 0 && rawFile != nil || (bytes ?? 0) > 0 && rawFile == nil { p.append("raw basename inconsistent with bytes") }
            if endReason?.contains("drain limit") == true { p.append("counterpart drain limit reached") }
        }
        return p
    }
}

/// An explicitly imported packet observer transcript, NOT a common listener or pcap parser.
/// All metadata are operator assertions requiring review of the separate original capture.
public struct PacketWire: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case captureStarted, packetContact, captureStopped }
    public var timestamp: String
    public var kind: Kind
    public var runID: UUID
    public var scenarioID: String
    public var captureID: UUID
    public var clockID: String
    public var interface: String
    public var oracleInstanceID: UUID
    public var family: IPFamily
    public var flowID: UUID?
    public var transport: WireTransport?
    public var local: WireEndpoint?
    public var remote: WireEndpoint?
    public var droppedPackets: Int?
    public var gapsMs: Int?
    static let shape: Shape = .object(["timestamp": .scalar, "kind": .scalar, "runID": .scalar, "scenarioID": .scalar,
        "captureID": .scalar, "clockID": .scalar, "interface": .scalar, "oracleInstanceID": .scalar, "family": .scalar,
        "flowID": .scalar, "transport": .scalar, "local": WireEndpoint.shape, "remote": WireEndpoint.shape,
        "droppedPackets": .scalar, "gapsMs": .scalar])
    var problems: [String] {
        var p: [String] = []
        if utcDate(timestamp) == nil || !validLabel(clockID) || !validLabel(interface) || interface.utf8.count > 16 { p.append("invalid capture timestamp/clock/interface") }
        if !Scenario.all.contains(where: { $0.id == scenarioID && $0.family == family }) { p.append("capture scenario/family mismatch") }
        if kind == .packetContact {
            if flowID == nil || transport == nil || local?.address?.family != family || remote?.address?.family != family ||
                local?.address?.wildcard == true || remote?.address?.wildcard == true { p.append("packet missing/invalid flow or endpoint tuple") }
            if droppedPackets != nil || gapsMs != nil { p.append("packet contains lifecycle fields") }
        } else {
            if flowID != nil || transport != nil || local != nil || remote != nil { p.append("capture lifecycle contains packet fields") }
            if kind == .captureStarted && (droppedPackets != nil || gapsMs != nil) { p.append("capture started contains loss totals") }
        }
        for count in [droppedPackets, gapsMs].compactMap({ $0 }) where !(0...3_600_000).contains(count) { p.append("capture loss/gap count out of bounds") }
        return p
    }
}
public struct WireRecord<T: Codable & Sendable>: Codable, Sendable {
    public var line: Int
    public var endLine: Int
    public var record: T
    public var problems: [String]
}
public struct SourceReport: Codable, Sendable {
    public var id: String
    public var format: String
    public var origin: ImportOrigin
    public var clock: ImportClock?
    /// Computed from EXACT supplied source bytes; integrity fingerprint, never attestation.
    public var sha256: String
    public var problems: [String]
    public var sender: [WireRecord<SenderWire>]
    public var counterpart: [WireRecord<CounterpartWire>]
    public var packets: [WireRecord<PacketWire>]
    public var network: NetworkSourceReport? = nil
    var recordProblems: Bool { network?.records.contains { !$0.problems.isEmpty } == true || sender.contains { !$0.problems.isEmpty } || counterpart.contains { !$0.problems.isEmpty } || packets.contains { !$0.problems.isEmpty } }
}

func validLabel(_ text: String) -> Bool { text.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil }
func validCanary(_ text: String) -> Bool { text.range(of: #"^SANJBOX-CANARY-[A-Za-z0-9_-]{1,64}-[a-f0-9]{32}$"#, options: .regularExpression) != nil }
func utcDate(_ text: String) -> Date? {
    guard text.range(of: #"^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$"#, options: .regularExpression) != nil,
          let milliseconds = Int(text.dropFirst(20).prefix(3)) else { return nil }
    // The producer truncates binary Date fractions when encoding. Parsing and formatting
    // that fraction again can lose another millisecond; validate whole calendar seconds
    // separately and preserve the literal millisecond field. Require >=1ms clock uncertainty.
    let seconds = String(text.prefix(19)) + "Z"
    let style = Date.ISO8601FormatStyle()
    guard let whole = try? style.parse(seconds), whole.formatted(style) == seconds else { return nil }
    return whole.addingTimeInterval(Double(milliseconds) / 1000)
}

func parseSource(_ source: ImportSource) -> SourceReport {
    if source.format == "sanjboxNetworkProvenanceV1" { return parseNetworkSource(source) }
    var report = SourceReport(id: source.id, format: source.format, origin: source.origin, clock: source.clock,
        sha256: SHA256.hash(data: Data(source.text.utf8)).map { String(format: "%02x", $0) }.joined(),
        problems: [], sender: [], counterpart: [], packets: [])
    guard ["c1RunRecordStream", "commonCounterpartJSONL", "packetImportV1JSONL"].contains(source.format) else {
        report.problems.append("unsupported source format; no records interpreted"); return report
    }
    if source.clock?.usable != true { report.problems.append("missing/invalid clock calibration, uncertainty or discontinuity bound") }
    let chunks: [WireChunk]
    if source.format == "c1RunRecordStream" {
        let framed = frameC1(source.text)
        chunks = framed.chunks
        report.problems += framed.problems
    } else {
        var lines = source.text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { report.problems.append("empty JSONL source"); return report }
        if lines.count > 256 { report.problems.append("source exceeds 256 records; remaining records uninterpreted and may contain findings") }
        chunks = lines.prefix(256).enumerated().map { WireChunk(line: $0.offset + 1, endLine: $0.offset + 1, bytes: Data($0.element.utf8)) }
    }
    for chunk in chunks {
        let number = chunk.line
        guard !chunk.bytes.isEmpty, chunk.bytes.count <= 16_384 else { report.problems.append("line \(number): empty/oversized record; uninterpreted findings may exist"); continue }
        do {
            let bytes = chunk.bytes
            switch source.format {
            case "c1RunRecordStream":
                let r = try strictDecode(SenderWire.self, data: bytes, shape: SenderWire.shape)
                report.sender.append(.init(line: number, endLine: chunk.endLine, record: r, problems: r.problems))
            case "commonCounterpartJSONL":
                let r = try strictDecode(CounterpartWire.self, data: bytes, shape: CounterpartWire.shape)
                report.counterpart.append(.init(line: number, endLine: chunk.endLine, record: r, problems: r.problems))
            default:
                let r = try strictDecode(PacketWire.self, data: bytes, shape: PacketWire.shape)
                report.packets.append(.init(line: number, endLine: chunk.endLine, record: r, problems: r.problems))
            }
        } catch {
            // Never echo untrusted decoder values. Keep valid sibling records and their findings.
            report.problems.append("line \(number): strict JSON/schema rejected; uninterpreted findings may exist")
        }
    }
    let timestamps = report.sender.map { $0.record.timestamp } + report.counterpart.map { $0.record.timestamp } + report.packets.map { $0.record.timestamp }
    if zip(timestamps, timestamps.dropFirst()).contains(where: { $0 > $1 }) { report.problems.append("raw timestamps decrease; clock/order provenance incomplete") }
    if source.format == "commonCounterpartJSONL" { checkCounterpartLifecycle(&report) }
    return report
}

private func checkCounterpartLifecycle(_ report: inout SourceReport) {
    let rows = report.counterpart
    if rows.first?.record.kind != .started || rows.last?.record.kind != .stopped ||
        rows.filter({ $0.record.kind == .started }).count != 1 || rows.filter({ $0.record.kind == .stopped }).count != 1 {
        report.problems.append("counterpart lifecycle missing/duplicate/out-of-order started or stopped")
    }
    let listeners = rows.first(where: { $0.record.kind == .started })?.record.listeners ?? []
    var seen = Set<String>()
    for listener in listeners {
        let key = "\(listener.transport.rawValue):\(listener.endpoint.address?.canonical ?? listener.endpoint.host):\(listener.endpoint.port)"
        if !seen.insert(key).inserted { report.problems.append("duplicate started listener") }
    }
    let flows = Dictionary(grouping: rows.filter { $0.record.flowID != nil }, by: { $0.record.flowID! })
    for id in flows.keys.sorted() {
        let flow = flows[id]!
        let accepts = flow.filter { $0.record.kind == .accepted }
        let closes = flow.filter { $0.record.kind == .closed }
        let datagrams = flow.filter { $0.record.kind == .datagram }
        if !datagrams.isEmpty {
            if datagrams.count != 1 || flow.count != 1 { report.problems.append("flow \(id): duplicate/reused UDP flow") }
        } else if accepts.count != 1 || closes.count != 1 || accepts.first!.line >= closes.first!.line {
            report.problems.append("flow \(id): missing/duplicate/reversed TCP accept/close")
        }
        if let first = flow.first?.record {
            for row in flow {
                let event = row.record
                if event.transport != first.transport || event.local != first.local || event.remote != first.remote {
                    report.problems.append("flow \(id): tuple/transport changed")
                }
                if let local = event.local, !listeners.contains(where: {
                    $0.transport == event.transport && $0.endpoint.port == local.port &&
                    $0.endpoint.address?.family == local.address?.family &&
                    ($0.endpoint.address?.wildcard == true || $0.endpoint.matches(local))
                }) { report.problems.append("flow \(id): local endpoint outside started listeners") }
                if let raw = event.rawFile, let t = event.transport, let port = event.local?.port, raw != "\(id)-\(t.rawValue)-\(port).bin" {
                    report.problems.append("flow \(id): raw basename does not match flow/transport/port")
                }
            }
        }
    }
    report.problems = Array(Set(report.problems)).sorted()
}

// printJSON() used by C1 emits pretty JSON documents separated by whitespace. This is
// a bounded framing pass only; strictDecode still validates every document in full.
private struct WireChunk { var line: Int; var endLine: Int; var bytes: Data }
private func frameC1(_ text: String) -> (chunks: [WireChunk], problems: [String]) {
    let bytes = Array(text.utf8)
    var index = 0, line = 1
    var chunks: [WireChunk] = []
    while index < bytes.count {
        while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) {
            if bytes[index] == 10 { line += 1 }
            index += 1
        }
        if index == bytes.count { break }
        guard chunks.count < 256, bytes[index] == 123 else {
            return (chunks, ["C1 object stream framing rejected at line \(line); uninterpreted findings may exist"])
        }
        let start = index, startLine = line
        var depth = 0, quoted = false, escaped = false
        repeat {
            let byte = bytes[index]
            if byte == 10 { line += 1 }
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 { depth += 1 }
            else if byte == 125 { depth -= 1 }
            index += 1
        } while index < bytes.count && depth > 0
        guard depth == 0, !quoted else {
            return (chunks, ["C1 unterminated object at line \(startLine); uninterpreted findings may exist"])
        }
        chunks.append(WireChunk(line: startLine, endLine: line, bytes: Data(bytes[start..<index])))
    }
    return (chunks, chunks.isEmpty ? ["empty C1 object stream"] : [])
}
