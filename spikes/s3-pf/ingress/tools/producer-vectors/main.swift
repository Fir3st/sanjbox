// Compile with the unchanged common CounterpartEvent.swift and SanjboxProbeKit objects.
// Pure fixed fixtures: no live identity, random input, socket, clock query or file read.
import Foundation
import SanjboxProbeKit

let context = try JSONDecoder().decode(ProbeContext.self, from: Data(#"{"pid":100,"parentPID":99,"realUID":4501,"effectiveUID":4501,"realGID":4501,"effectiveGID":4501,"kernelGroups":[4501],"groupMembership":[{"gid":20,"isMember":false},{"gid":80,"isMember":false},{"gid":4501,"isMember":true}],"audit":{"sessionID":200,"auditUID":4501,"flags":0},"launchdManager":{"name":"Aqua","uid":4501},"windowSession":{"userID":4501,"auditSessionID":200,"onConsole":false,"loginDone":true}}"#.utf8))
let epoch = try JSONLines.timestampStyle.parse("2026-11-04T12:00:00.000Z")
func time(_ ms: Int) -> Date { epoch.addingTimeInterval(Double(ms) / 1000) }
let canary = "SANJBOX-CANARY-c3-0123456789abcdef0123456789abcdef"
let bytes = canary.utf8.count + 1
func c1(_ error: Bool = false, invalid: Bool = false) throws -> String {
    let identity = RunRecord(timestamp: time(1100), probe: "sanjbox-s3-probe.identity", caseID: nil,
        outcome: invalid ? .invalidMeasurement : .passed, context: context,
        details: ["expectedAuditSessionID": invalid ? "201" : "200", "actualAuditSessionID": "200"])
    let send = RunRecord(timestamp: time(1210), probe: "sanjbox-s3-probe.send", caseID: "NET-12", outcome: .unclear,
        context: context, details: error ? ["clientError": "io(61)", "verdict": "client failure is not proof of isolation"] :
            ["localKernelAcceptedBytes": String(bytes), "verdict": "external oracle required"])
    // Exactly the encoder and newline used by common printJSON() called from C1 main.
    let encoder = JSONLines.makeEncoder(prettyPrinted: true)
    return try (invalid ? [identity] : [identity, send]).map { String(decoding: try encoder.encode($0), as: UTF8.self) + "\n" }.joined()
}
func counterpart(zero: Bool = false, udp: Bool = false, v6: Bool = false, wildcard: Bool = false) throws -> String {
    let local = Endpoint(host: v6 ? "::1" : "127.0.0.1", port: 18080)
    let remote = Endpoint(host: v6 ? "::1" : "127.0.0.1", port: 49152)
    let bind = Endpoint(host: wildcard ? (v6 ? "::" : "0.0.0.0") : local.host, port: 18080)
    let transport: CounterpartEvent.Transport = udp ? .udp : .tcp
    var records = [CounterpartEvent(timestamp: time(10), kind: .started, listeners: [Listener(transport: transport, endpoint: bind)])]
    if !udp { records.append(CounterpartEvent(timestamp: time(1203), kind: .accepted, flowID: 1, transport: transport, local: local, remote: remote)) }
    records.append(CounterpartEvent(timestamp: time(1210), kind: udp ? .datagram : .closed, flowID: 1, transport: transport,
        local: local, remote: remote, bytes: zero ? 0 : bytes,
        findings: zero ? [] : [CanaryScanner.Finding(token: canary, encoding: "raw"), CanaryScanner.Finding(token: Canary.tokenPrefix, encoding: "raw")],
        rawFile: zero ? nil : "1-\(transport.rawValue)-18080.bin", rawTruncated: false, endReason: udp ? nil : "peerClosed"))
    records.append(CounterpartEvent(timestamp: time(5000), kind: .stopped))
    return try records.map { String(decoding: try JSONLines.makeEncoder().encode($0), as: UTF8.self) + "\n" }.joined()
}
let output = try ["c1Success": c1(), "c1Error": c1(true), "c1InvalidIdentity": c1(invalid: true),
    "commonTCP": counterpart(), "commonZeroTCP": counterpart(zero: true), "commonUDP": counterpart(udp: true),
    "commonZeroUDP": counterpart(zero: true, udp: true), "commonIPv6": counterpart(v6: true), "commonWildcardIPv6": counterpart(v6: true, wildcard: true)]
try printJSON(output)
