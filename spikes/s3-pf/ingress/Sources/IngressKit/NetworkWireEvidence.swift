import Foundation
import SanjboxNetworkProvenance

/// Explicit content import. These names are identifiers, never paths to open.
public struct NetworkArtifact: Codable, Sendable {
    public var name: String
    public var count: Int
    public var sha256: String
    public var base64: String
    static let shape: Shape = .object(["name": .scalar, "count": .scalar, "sha256": .scalar, "base64": .scalar])
    var data: Data? {
        let limit = ["expect.json", "probe.json"].contains(name) ? 16_384 : 4096
        guard ["expect.json", "probe.json", "sent.bin"].contains(name) ||
                name.range(of: #"^received-([1-9]|1[0-6])\.bin$"#, options: .regularExpression) != nil,
              (0...limit).contains(count), base64.utf8.count <= 4 * ((limit + 2) / 3),
              let bytes = Data(base64Encoded: base64), bytes.base64EncodedString() == base64,
              bytes.count == count, networkHashValid(sha256), provenanceDigest(bytes) == sha256 else { return nil }
        return bytes
    }
}
public struct NetworkBinding: Codable, Sendable {
    public var senderSourceID: String
    public var receiverSourceID: String
    public var contactID: Int
    static let shape: Shape = .object(["senderSourceID": .scalar, "receiverSourceID": .scalar, "contactID": .scalar])
}
public struct NetworkArtifactReceipt: Codable, Sendable {
    public var name: String
    public var declaredCount: Int
    public var declaredSHA256: String
    public var verified: Bool
}
public struct NetworkSourceReport: Codable, Sendable {
    public var records: [WireRecord<NetworkEvent>]
    public var artifacts: [NetworkArtifactReceipt]
    public var checks: [String]
    public var warning = "Recorded own identity/signature and preregistration are supplied claims, not authenticated peer credentials. Monotonic values are ordered only inside this producer instance. Raw bytes are application data, not packet capture."
}

// Strict opt-in shapes. Public producer models are reused, but their runtime preflight,
// current-clock expiry checks, identity capture and network operations are never called.
private let signatureShape: Shape = .object(["valid": .scalar, "hardenedRuntime": .scalar,
    "getTaskAllowAbsent": .scalar, "codeHash": .scalar])
private let challengeShape: Shape = .object(["runID": .scalar, "flowID": .scalar,
    "challenge": .scalar, "preparedAtUTC": .scalar])
private let registrationShape: Shape = .object(["schemaVersion": .scalar, "scope": .scalar,
    "flow": challengeShape, "transport": .scalar, "endpoint": WireEndpoint.shape,
    "controlledTarget": .scalar, "durationMilliseconds": .scalar, "maximumContacts": .scalar])
private let expectationShape: Shape = .object(["schemaVersion": .scalar, "scope": .scalar,
    "identity": Identity.shape, "signature": signatureShape, "forbiddenAuditSessionIDs": .array(.scalar)])
private let eventShape: Shape = .object([
    "format": .scalar, "schemaVersion": .scalar, "sequence": .scalar,
    "timestamp": .object(["utc": .scalar, "monotonicNanoseconds": .scalar]), "kind": .scalar,
    "runID": .scalar, "flowID": .scalar, "instanceID": .scalar, "role": .scalar, "scope": .scalar,
    "pid": .scalar, "parentPID": .scalar, "transport": .scalar, "family": .scalar,
    "identity": Identity.shape, "signature": signatureShape, "registration": registrationShape,
    "expectationSHA256": .scalar, "registrationSHA256": .scalar,
    "target": WireEndpoint.shape, "local": WireEndpoint.shape, "remote": WireEndpoint.shape,
    "contactID": .scalar, "bytes": .scalar, "localKernelAcceptedBytes": .scalar,
    "rawFile": .scalar, "rawSHA256": .scalar, "rawTruncated": .scalar,
    "payloadClaims": .object(["runID": .scalar, "flowID": .scalar, "challenge": .scalar]),
    "matchesRegisteredPayload": .scalar, "repeatedRegisteredPayload": .scalar,
    "reason": .scalar, "operationFinished": .scalar])

func rejectNetworkNulls(_ value: Any) throws {
    if value is NSNull { throw IngressError("null in network provenance schema") }
    if let object = value as? [String: Any] { for value in object.values { try rejectNetworkNulls(value) } }
    if let array = value as? [Any] { for value in array { try rejectNetworkNulls(value) } }
}
private func networkDecode<T: Decodable>(_ type: T.Type, _ data: Data, _ shape: Shape) throws -> T {
    let value = try strictDecode(type, data: data, shape: shape)
    let object = try JSONSerialization.jsonObject(with: data)
    try rejectNetworkNulls(object)
    func checkUUIDs(_ value: Any, foreignClaims: Bool = false) throws {
        if let object = value as? [String: Any] {
            for (key, item) in object {
                if ["runID", "flowID", "instanceID"].contains(key) {
                    guard let text = item as? String, let uuid = UUID(uuidString: text), uuid.uuidString == text,
                          (foreignClaims || text != "00000000-0000-0000-0000-000000000000") else { throw IngressError("noncanonical network UUID") }
                }
                try checkUUIDs(item, foreignClaims: foreignClaims || key == "payloadClaims")
            }
        } else if let array = value as? [Any] { for item in array { try checkUUIDs(item, foreignClaims: foreignClaims) } }
    }
    try checkUUIDs(object)
    return value
}
private func networkHashValid(_ hash: String) -> Bool { hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
func networkEndpoint(_ endpoint: NetworkEndpoint?) -> WireEndpoint? {
    endpoint.map { WireEndpoint(host: $0.host, port: $0.port) }
}
private func exactEndpoint(_ endpoint: NetworkEndpoint, ephemeral: Bool = false, failedLocal: Bool = false) -> Bool {
    if failedLocal {
        let wire = WireEndpoint(host: endpoint.host, port: endpoint.port == 0 ? 1024 : endpoint.port)
        guard let address = wire.address, address.canonical == endpoint.host,
              (ephemeral && endpoint.port == 0) || endpoint.port >= 1024 else { return false }
        if address.wildcard { return true }
    }
    // Numeric parser and canonical round-trip only; validate never opens a socket or resolves DNS.
    do { try endpoint.validate(allowZeroPort: ephemeral); return true } catch { return false }

}
func networkPayloadClaims(_ data: Data) -> PayloadClaims? {
    guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\n") else { return nil }
    let fields = text.dropLast().split(separator: "|", omittingEmptySubsequences: false)
    guard fields.count == 4, fields[0] == "SANJBOX-NETWORK-PROVENANCE-V1",
          let run = UUID(uuidString: String(fields[1])), run.uuidString == fields[1],
          let flow = UUID(uuidString: String(fields[2])), flow.uuidString == fields[2], networkHashValid(String(fields[3])) else { return nil }
    // Public model has no public memberwise initializer; Codable is the construction API.
    return try? JSONDecoder().decode(PayloadClaims.self, from: JSONSerialization.data(withJSONObject:
        ["runID": run.uuidString, "flowID": flow.uuidString, "challenge": String(fields[3])]))
}
func networkRaw(_ source: ImportSource, name: String) -> Data? {
    let artifacts = source.artifacts?.filter { $0.name == name } ?? []
    return artifacts.count == 1 ? artifacts[0].data : nil
}

func parseNetworkSource(_ source: ImportSource) -> SourceReport {
    var report = SourceReport(id: source.id, format: source.format, origin: source.origin, clock: source.clock,
        sha256: provenanceDigest(Data(source.text.utf8)), problems: [], sender: [], counterpart: [], packets: [])
    var parsed = NetworkSourceReport(records: [], artifacts: [], checks: [])
    let artifacts = source.artifacts ?? []
    for artifact in artifacts {
        let verified = artifact.data != nil && artifacts.filter { $0.name == artifact.name }.count == 1
        parsed.artifacts.append(.init(name: artifact.name, declaredCount: artifact.count, declaredSHA256: artifact.sha256, verified: verified))
        if !verified { report.problems.append("artifact name/base64/count/hash invalid or duplicate; bytes not trusted") }
    }
    var lines = source.text.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last?.isEmpty == true { lines.removeLast() }
    if lines.isEmpty { report.problems.append("empty network JSONL source") }
    if !source.text.hasSuffix("\n") { report.problems.append("network journal missing final newline; interrupted prefix possible") }
    if lines.count > 256 { report.problems.append("network source exceeds 256 records; uninterpreted findings may exist") }
    for (i, line) in lines.prefix(256).enumerated() {
        do {
            guard !line.isEmpty, line.utf8.count <= 16_384 else { throw IngressError("network record limit") }
            let bytes = Data(line.utf8)
            let event = try networkDecode(NetworkEvent.self, bytes, eventShape)
            let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            parsed.records.append(.init(line: i + 1, endLine: i + 1, record: event,
                problems: networkEventProblems(event, keys: Set(object.keys))))
        } catch { report.problems.append("line \(i + 1): strict network JSON/schema rejected; uninterpreted findings may exist") }
    }
    checkNetworkLifecycle(source, parsed: &parsed, problems: &report.problems)
    report.problems = Array(Set(report.problems)).sorted()
    parsed.checks = Array(Set(parsed.checks)).sorted()
    report.network = parsed
    return report
}

private func networkEventProblems(_ e: NetworkEvent, keys: Set<String>) -> [String] {
    var p: [String] = []
    let header: Set<String> = ["format", "schemaVersion", "sequence", "timestamp", "kind", "runID", "flowID",
        "instanceID", "role", "scope", "pid", "parentPID", "transport", "family"]
    let fields: [String: (Set<String>, Set<String>)] = [
        "registered": (["identity", "signature", "registration", "expectationSHA256", "registrationSHA256"], []),
        "attemptStarted": (["target", "bytes", "rawFile", "rawSHA256", "localKernelAcceptedBytes"], []),
        "connected": (["local", "remote"], []),
        "kernelAccepted": (["local", "remote", "localKernelAcceptedBytes"], []),
        "attemptEnded": (["target", "bytes", "localKernelAcceptedBytes", "reason", "operationFinished"], ["local", "remote"]),
        "receiverStarted": (["local"], []),
        "accepted": (["contactID"], ["local", "remote"]),
        "datagramContact": (["contactID", "local", "bytes", "rawTruncated"], ["remote"]),
        "closed": (["contactID", "bytes", "rawFile", "rawSHA256", "rawTruncated", "reason", "operationFinished", "matchesRegisteredPayload", "repeatedRegisteredPayload"], ["local", "remote", "payloadClaims"]),
        "datagram": (["contactID", "bytes", "rawFile", "rawSHA256", "rawTruncated", "reason", "operationFinished", "matchesRegisteredPayload", "repeatedRegisteredPayload"], ["local", "remote", "payloadClaims"]),
        "receiverStopped": (["contactID", "reason", "operationFinished"], [])]
    if let (required, optional) = fields[e.kind] {
        if !header.union(required).isSubset(of: keys) || !keys.isSubset(of: header.union(required).union(optional)) { p.append("missing/unexpected event-kind fields") }
    } else { p.append("unsupported network event kind") }
    if e.format != "sanjboxNetworkProvenanceV1" || e.schemaVersion != 1 || !(1...256).contains(e.sequence) ||
        e.pid <= 0 || e.parentPID < 0 || utcDate(e.timestamp.utc) == nil || e.timestamp.monotonicNanoseconds == 0 ||
        !["sender", "receiver"].contains(e.role) || !["ipv4", "ipv6"].contains(e.family) { p.append("invalid network event header") }
    let senderKinds = ["attemptStarted", "connected", "kernelAccepted", "attemptEnded"]
    let receiverKinds = ["receiverStarted", "accepted", "closed", "datagramContact", "datagram", "receiverStopped"]
    if senderKinds.contains(e.kind) && e.role != "sender" || receiverKinds.contains(e.kind) && e.role != "receiver" ||
        ["accepted", "closed"].contains(e.kind) && e.transport != .tcp ||
        ["datagramContact", "datagram"].contains(e.kind) && e.transport != .udp { p.append("event role/transport mismatch") }
    if let id = e.contactID, !(e.kind == "receiverStopped" ? 0...16 : 1...16).contains(id) { p.append("invalid contact ID") }
    if let count = e.bytes, !(0...4096).contains(count) { p.append("invalid application byte count") }
    if let count = e.localKernelAcceptedBytes, !(0...169).contains(count) { p.append("invalid local kernel accepted count") }
    for (label, endpoint) in [("target", e.target), ("local", e.local), ("remote", e.remote)] {
        if let endpoint, !exactEndpoint(endpoint, ephemeral: e.kind == "attemptEnded" && label == "local",
            failedLocal: e.kind == "attemptEnded" && label == "local") || endpoint.family != e.family { p.append("invalid \(label) tuple/family") }
    }
    if let reason = e.reason, reason.isEmpty || reason.utf8.count > 256 { p.append("invalid terminal reason") }
    for hash in [e.rawSHA256, e.expectationSHA256, e.registrationSHA256].compactMap({ $0 }) {
        if !networkHashValid(hash) { p.append("invalid SHA256") }
    }
    if let raw = e.rawFile, raw != (e.role == "sender" ? "sent.bin" : "received-\(e.contactID ?? 0).bin") { p.append("raw basename does not match role/contact (never opened)") }
    return p
}

private func checkNetworkLifecycle(_ source: ImportSource, parsed: inout NetworkSourceReport, problems: inout [String]) {
    let rows = parsed.records
    guard let first = rows.first?.record else { problems.append("network registered/lifecycle missing"); return }
    for (i, row) in rows.enumerated() {
        let e = row.record
        if e.sequence != row.line || row.line != i + 1 { problems.append("network sequence gap/duplicate/reorder; incomplete journal") }
        if e.runID != first.runID || e.flowID != first.flowID || e.instanceID != first.instanceID ||
            e.pid != first.pid || e.parentPID != first.parentPID || e.role != first.role || e.scope != first.scope ||
            e.transport != first.transport || e.family != first.family { problems.append("network run/flow/instance/PID/role/scope/transport changed") }
        if i > 0, e.timestamp.monotonicNanoseconds < rows[i - 1].record.timestamp.monotonicNanoseconds || e.timestamp.utc < rows[i - 1].record.timestamp.utc { problems.append("network UTC/instance monotonic order decreased") }
    }
    guard first.kind == "registered", rows.filter({ $0.record.kind == "registered" }).count == 1,
          let registration = first.registration else { problems.append("network missing/duplicate/out-of-order registered record"); return }
    do {
        guard let expectationBytes = networkRaw(source, name: "expect.json"), let registrationBytes = networkRaw(source, name: "probe.json") else { throw IngressError("missing exact preregistration inputs") }
        let expectation = try networkDecode(NetworkExpectation.self, expectationBytes, expectationShape)
        try expectation.validate() // Pure structure/policy validation, no capture, membership lookup or time read.
        let supplied = try networkDecode(NetworkRegistration.self, registrationBytes, registrationShape)
        guard provenanceDigest(expectationBytes) == first.expectationSHA256,
              provenanceDigest(registrationBytes) == first.registrationSHA256,
              try encodeJSON(supplied) == encodeJSON(registration), expectation.identity == first.identity,
              expectation.signature == first.signature, expectation.scope == first.scope else { throw IngressError("preregistration mismatch") }
        parsed.checks.append("exact supplied expectation/registration hashes and recorded own identity/signature match")
    } catch { problems.append("missing/invalid/mismatched exact preregistration bytes, own identity or signature") }
    let flow = registration.flow
    if registration.schemaVersion != 1 || !registration.controlledTarget ||
        !(100...10000).contains(registration.durationMilliseconds) || !(1...16).contains(registration.maximumContacts) ||
        !exactEndpoint(registration.endpoint, ephemeral: first.role == "receiver") ||
        registration.transport != first.transport || registration.scope != first.scope || registration.endpoint.family != first.family ||
        flow.runID != first.runID || flow.flowID != first.flowID || !networkHashValid(flow.challenge) {
        problems.append("invalid registered scope/run/flow/challenge/endpoint/bounds")
    }
    if let prepared = utcDate(flow.preparedAtUTC), let registered = utcDate(first.timestamp.utc) {
        let age = registered.timeIntervalSince(prepared)
        if age < -1 || age > 600 { problems.append("registered flow preparation outside producer historical 10-minute window") }
    } else { problems.append("invalid registered preparation UTC") }
    // Do not apply today's TTL to historical imports or compare monotonic clocks across instances.
    if first.role == "sender" { checkNetworkSender(source, rows: rows, registration: registration, parsed: &parsed, problems: &problems) }
    else { checkNetworkReceiver(source, rows: rows, registration: registration, parsed: &parsed, problems: &problems) }
    let used = Set(["expect.json", "probe.json"] + rows.compactMap { $0.record.rawFile } + rows.compactMap {
        ["accepted", "datagramContact"].contains($0.record.kind) ? "received-\($0.record.contactID ?? 0).bin" : nil
    })
    if (source.artifacts ?? []).contains(where: { !used.contains($0.name) }) { problems.append("unreferenced artifact; no event association invented") }
}

private func checkNetworkSender(_ source: ImportSource, rows: [WireRecord<NetworkEvent>], registration: NetworkRegistration,
                                parsed: inout NetworkSourceReport, problems: inout [String]) {
    let events = rows.map(\.record), kinds = events.map(\.kind)
    let starts = events.filter { $0.kind == "attemptStarted" }, ends = events.filter { $0.kind == "attemptEnded" }
    let connected = events.filter { $0.kind == "connected" }
    let progress = events.filter { $0.kind == "kernelAccepted" }
    if starts.count != 1 || ends.count != 1 || kinds.dropFirst().first != "attemptStarted" || kinds.last != "attemptEnded" || connected.count > 1 ||
        kinds.contains(where: { !["registered", "attemptStarted", "connected", "kernelAccepted", "attemptEnded"].contains($0) }) {
        problems.append("sender missing/duplicate/out-of-order attempt lifecycle")
    }
    let intended = networkRaw(source, name: "sent.bin")
    if let intended, intended == registration.flow.bytes, let start = starts.first,
       start.bytes == intended.count, start.rawSHA256 == provenanceDigest(intended), start.localKernelAcceptedBytes == 0,
       start.target == registration.endpoint { parsed.checks.append("sender intent verified against exact supplied sent.bin frame") }
    else { problems.append("sender intent/raw hash/count/frame/target missing or mismatched") }
    var last = 0
    for e in progress {
        if let c = connected.first, e.sequence > c.sequence, e.local == c.local, e.remote == c.remote,
           let count = e.localKernelAcceptedBytes, count > last { last = count }
        else { problems.append("sender accepted progress lacks prior connected tuple or monotonic count") }
    }
    if let c = connected.first, c.sequence <= (starts.first?.sequence ?? Int.max) || c.remote != registration.endpoint { problems.append("sender connected order/target mismatch") }
    if let end = ends.first {
        if end.target != registration.endpoint || end.bytes != 169 || (end.localKernelAcceptedBytes ?? -1) < last ||
            (connected.first != nil && (end.local != connected.first?.local || end.remote != connected.first?.remote)) ||
            (connected.isEmpty && (end.remote != nil || !progress.isEmpty)) { problems.append("sender ending tuple/count/target mismatch") }
        if end.localKernelAcceptedBytes != last { problems.append("sender ending accepted count lacks journaled progress; partial evidence") }
        if end.operationFinished != true || end.localKernelAcceptedBytes != 169 || end.reason != "localKernelAcceptedFrame" || connected.count != 1 {
            problems.append("sender attempt incomplete/failed; preserved accepted bytes are not delivery proof")
        }
    }
}

private func checkNetworkReceiver(_ source: ImportSource, rows: [WireRecord<NetworkEvent>], registration: NetworkRegistration,
                                  parsed: inout NetworkSourceReport, problems: inout [String]) {
    let events = rows.map(\.record)
    let starts = events.filter { $0.kind == "receiverStarted" }, stops = events.filter { $0.kind == "receiverStopped" }
    let contacts = events.filter { ["accepted", "datagramContact"].contains($0.kind) }
    if starts.count != 1 || stops.count != 1 || events.dropFirst().first?.kind != "receiverStarted" || events.last?.kind != "receiverStopped" ||
        events.contains(where: { !["registered", "receiverStarted", "accepted", "closed", "datagramContact", "datagram", "receiverStopped"].contains($0.kind) }) {
        problems.append("receiver missing/duplicate/out-of-order listener lifecycle")
    }
    if let start = starts.first, let local = start.local {
        if local.host != registration.endpoint.host || (registration.endpoint.port != 0 && local.port != registration.endpoint.port) { problems.append("actual receiver bound tuple differs from registered endpoint") }
    }
    if let stop = stops.first, stop.contactID != contacts.count || contacts.count > registration.maximumContacts ||
        stop.operationFinished != true || stop.reason != "windowElapsed" { problems.append("receiver stopped count/limit/error/incomplete operation") }
    let groups = Dictionary(grouping: events.filter { ["accepted", "closed", "datagramContact", "datagram"].contains($0.kind) }, by: { $0.contactID ?? 0 })
    if contacts.map(\.contactID) != (1...max(1, contacts.count)).prefix(contacts.count).map({ Optional($0) }) { problems.append("receiver contact IDs duplicate/gapped/out-of-order") }
    var seenMatch = false
    for id in groups.keys.sorted() {
        let pair = groups[id]!, contact = pair.first!, terminal = pair.last!
        let opener = registration.transport == .tcp ? "accepted" : "datagramContact"
        let ending = registration.transport == .tcp ? "closed" : "datagram"
        if pair.count != 2 || contact.kind != opener || terminal.kind != ending || terminal.sequence != contact.sequence + 1 ||
            contact.sequence <= (starts.first?.sequence ?? Int.max) || terminal.sequence >= (stops.first?.sequence ?? Int.max) {
            problems.append("contact \(id): missing/duplicate/reordered ending; received count unknown without terminal")
        }
        for e in pair {
            if e.local == nil || e.remote == nil || e.local != starts.first?.local || e.local != contact.local || e.remote != contact.remote {
                problems.append("contact \(id): missing/changed/outside-listener tuple")
            }
        }
        guard terminal.kind == ending else { continue }
        if registration.transport == .udp && (contact.bytes != terminal.bytes || contact.rawTruncated != terminal.rawTruncated) { problems.append("contact \(id): UDP contact/terminal count or truncation mismatch") }
        if terminal.rawTruncated != false || terminal.operationFinished != true || terminal.reason != (registration.transport == .tcp ? "peerEOF" : "datagramReceived") { problems.append("contact \(id): partial/truncated/incomplete raw preserved") }
        guard let raw = networkRaw(source, name: "received-\(id).bin") else { problems.append("contact \(id): exact raw bytes missing; hash is not bytes"); continue }
        if terminal.bytes != raw.count || terminal.rawSHA256 != provenanceDigest(raw) { problems.append("contact \(id): received raw count/hash mismatch") }
        let claims = networkPayloadClaims(raw), match = raw == registration.flow.bytes && terminal.rawTruncated == false
        if terminal.payloadClaims != claims || terminal.matchesRegisteredPayload != match || terminal.repeatedRegisteredPayload != (match && seenMatch) {
            problems.append("contact \(id): payload claims/match/replay flags differ from exact raw bytes")
        }
        if match && seenMatch { parsed.checks.append("contact \(id): repeated registered frame retained; nonce is not replay prevention") }
        seenMatch = seenMatch || match
        parsed.checks.append("contact \(id): raw application bytes independently imported; \(raw.isEmpty ? "zero byte contact" : claims == nil ? "malformed/partial payload" : match ? "registered payload" : "foreign run/flow/challenge payload")")
    }
}
