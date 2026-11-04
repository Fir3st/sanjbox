import Foundation
import Testing
import SanjboxProbeKit
@testable import IngressKit

private func vectorData(_ name: String) throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
}
private func adapterFixture() throws -> AdapterInput { try AdapterInput.decode(vectorData("link-fixture")) }
private func producerVectors() throws -> [String: String] { try JSONDecoder().decode([String: String].self, from: vectorData("producer-vectors")) }
private func linked(_ input: AdapterInput) throws -> AdapterReport { try EvidenceAdapter.link(encodeJSON(input)) }
private func issues(_ report: AdapterReport) -> String { report.links.flatMap(\.problems).joined(separator: "\n") }
private func rewriteRows(_ input: inout AdapterInput, source: Int = 1, _ edit: (inout [[String: Any]]) throws -> Void) throws {
    var rows = try input.sources[source].text.split(separator: "\n").map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    try edit(&rows)
    input.sources[source].text = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) + "\n" }.joined()
}
private func rewriteMatrix(_ input: inout AdapterInput, _ edit: (inout EvidenceInput) -> Void) throws {
    var matrix = try EvidenceInput.decode(Data(#require(input.matrixJSON).utf8))
    edit(&matrix)
    input.matrixJSON = String(decoding: try encodeJSON(matrix), as: UTF8.self)
}
private func rewriteSender(_ input: inout AdapterInput, _ edit: (inout [SenderWire]) -> Void) throws {
    var records = parseSource(input.sources[0]).sender.map(\.record)
    edit(&records)
    let parts = try records.map { String(decoding: try encodeJSON($0), as: UTF8.self) + "\n" }
    input.sources[0].text = parts.joined()
    if parts.count > 1 { input.bindings[0].sender?.line = parts[0].filter { $0 == "\n" }.count + 1 }
}

@Test func adapterReadsUntouchedProducerWireAndDeterministicallyLinksAvailableFacts() throws {
    let data = try vectorData("link-fixture")
    let r = try EvidenceAdapter.link(data)
    #expect(r.links.count == 1)
    #expect(r.sources.first { $0.id == "sender" }?.sender.count == 2)
    #expect(r.links[0].status == "partialLinkNeedsReview", "\(r.links[0].problems)")
    #expect(r.links[0].checks.contains { $0.contains("shared identity") })
    #expect(r.links[0].checks.contains { $0.contains("canary finding exactly") })
    #expect(r.links[0].sourceRecords.contains { $0.sourceID == "sender" && $0.line == 53 })
    #expect(r.links[0].missingBindings.contains { $0.contains("no runID, flowID, canary") })
    #expect(r.findings.count == 3) // accepted, closed, separate packet; NOT three unique flows.
    #expect(r.matrix.cells.count == 28)
    #expect(r.matrixDeclaration?.roles?.zone.effectiveUID == 4501)
    #expect(r.inputSHA256.count == 64 && r.runStartUTC == "2026-11-04T12:00:00.000Z")
    #expect(r.matrix.cells.filter { $0.classification == "notMeasured" }.count == 27)
    #expect(!r.packetAbsenceProven && r.externalReviewRequired)
    #expect(try encodeJSON(r) == encodeJSON(EvidenceAdapter.link(data)))
}

@Test func vectorsUseCurrentCommonRunRecordEncoderAndCounterpartModel() throws {
    let vectors = try producerVectors()
    for (name, text) in vectors {
        let isC1 = name.hasPrefix("c1")
        let source = ImportSource(id: "vector", format: isC1 ? "c1RunRecordStream" : "commonCounterpartJSONL", origin: .fixture,
            clock: ImportClock(id: "clock", offsetMs: 0, uncertaintyMs: 1, discontinuities: 0, calibrationID: "fixture"), text: text)
        let parsed = parseSource(source)
        #expect(parsed.problems.isEmpty, "\(name): \(parsed.problems)")
        #expect(!parsed.recordProblems, "\(name)")
        if isC1 {
            // Re-encode with the public model/encoder actually called by the C1 executable.
            let common = try parsed.sender.map { row -> RunRecord in
                let data = try encodeJSON(row.record)
                return try JSONLines.decoder.decode(RunRecord.self, from: data)
            }
            let output = try common.map { String(decoding: try JSONLines.makeEncoder(prettyPrinted: true).encode($0), as: UTF8.self) + "\n" }.joined()
            #expect(output == text)
        } else { #expect(parsed.counterpart.count >= 3) }
    }
}

@Test func listenerLogWithoutPacketImportNeverBecomesZeroPacketProof() throws {
    var f = try adapterFixture()
    f.sources.removeLast(); f.bindings[0].capture = nil
    let r = try linked(f)
    #expect(!r.packetAbsenceProven)
    #expect(r.findings.count == 2)
    #expect(r.links[0].missingBindings.contains { $0.contains("independent packet capture") })
    #expect(r.links[0].missingBindings.contains { $0.contains("not packet capture") })
}

@Test(arguments: ["commonZeroTCP", "commonZeroUDP"])
func zeroByteContactsSurviveMissingBindingsInvalidSiblingsAndMatrix(_ vector: String) throws {
    var f = try adapterFixture()
    f.sources[1].text = try #require(producerVectors()[vector])
    f.sources[0].text = "{invalid sender"
    f.sources[2].text = "{\"timestamp\":0,\"timestamp\":0}\n"
    f.matrixJSON = "{invalid matrix"; f.bindings = []; f.endpoints = []
    let r = try linked(f)
    #expect(r.findings.contains { $0.kind == (vector == "commonZeroTCP" ? "accepted" : "datagram") })
    #expect(r.findings.contains { $0.bytes == 0 })
    #expect(r.matrixProblems.contains { $0.contains("invalid") })
    #expect(r.findings.allSatisfy { $0.claimedBindings.isEmpty })
}

@Test(arguments: ["duplicate", "escaped", "unknown", "depth", "oversize", "boolean", "sourceID"])
func adapterRejectsMalformedOuterEnvelopes(_ kind: String) throws {
    let base = String(decoding: try vectorData("link-fixture"), as: UTF8.self)
    let raw: String
    switch kind {
    case "duplicate": raw = base.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 1, \"schemaVersion\": 1")
    case "escaped": raw = base.replacingOccurrences(of: "\"schemaVersion\": 1", with: #""schemaVersion": 1, "schema\u0056ersion": 1"#)
    case "unknown": raw = base.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 1, \"command\": \"echo\"")
    case "depth": raw = String(repeating: "[", count: 25) + "0" + String(repeating: "]", count: 25)
    case "oversize": raw = String(repeating: " ", count: 1_048_577)
    case "boolean": raw = base.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": true")
    default:
        var f = try adapterFixture(); f.sources[1].id = f.sources[0].id
        raw = String(decoding: try encodeJSON(f), as: UTF8.self)
    }
    #expect(throws: (any Error).self) { try EvidenceAdapter.link(Data(raw.utf8)) }
}

@Test(arguments: [#"{"kind":"stopped","kind":"stopped"}"#, #"{"kind":"stopped","k\u0069nd":"stopped"}"#, #"{"kind":"stopped","unknown":1}"#])
func badRawRecordCannotEraseValidSiblingContacts(_ bad: String) throws {
    var f = try adapterFixture()
    f.sources[1].text += bad + "\n"
    let r = try linked(f)
    #expect(r.findings.filter { $0.sourceID == "receiver" }.count == 2)
    #expect(r.sources.first { $0.id == "receiver" }!.problems.contains { $0.contains("strict JSON") })
    #expect(issues(r).contains("strict JSON"))
}

@Test(arguments: ["case", "pid", "audit", "membership", "duplicateGroups", "identityOutcome", "identitySession", "sendOutcome"])
func senderMismatchNeverCreatesTrustedBinding(_ kind: String) throws {
    var f = try adapterFixture()
    try rewriteSender(&f) { rows in
        switch kind {
        case "case": rows[1].caseID = "NET-10"
        case "pid": rows[1].context.pid += 1
        case "audit": rows[1].context.audit?.sessionID += 1
        case "membership": rows[1].context.groupMembership = []
        case "duplicateGroups": rows[1].context.kernelGroups += rows[1].context.kernelGroups
        case "identityOutcome": rows[0].outcome = .invalidMeasurement
        case "identitySession": rows[0].details["expectedAuditSessionID"] = "201"
        default: rows[1].outcome = .passed
        }
    }
    let r = try linked(f)
    #expect(r.links[0].status == "conflictingOrIncompleteLink")
    #expect(r.findings.count == 3)
}

@Test(arguments: ["local", "remote", "port", "family", "canary", "endpoint", "run", "stage"])
func forgedJoinsReportConflictsAndRetainFindings(_ kind: String) throws {
    var f = try adapterFixture()
    switch kind {
    case "local": f.endpoints[0].local.host = "127.0.0.2"
    case "remote": f.endpoints[0].remote.host = "127.0.0.2"
    case "port": f.endpoints[0].remote.port += 1
    case "family": f.endpoints[0].remote.host = "::1"
    case "canary": f.bindings[0].canary = "SANJBOX-CANARY-other-0123456789abcdef0123456789abcdef"
    case "endpoint": f.bindings[0].endpointID = "not-registered"
    case "run": f.runID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
    default: f.bindings[0].stage = .after
    }
    let r = try linked(f)
    #expect(r.links[0].status == "conflictingOrIncompleteLink")
    #expect(r.findings.count == 3)
}

@Test(arguments: ["binding", "rawAccept", "rawClose", "reuse", "changedTuple"])
func duplicateFlowsAreNotSilentlyDeduplicated(_ kind: String) throws {
    var f = try adapterFixture()
    if kind == "binding" || kind == "reuse" {
        var extra = f.bindings[0]
        if kind == "reuse" { extra.flowID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")! }
        f.bindings.append(extra)
    } else {
        try rewriteRows(&f) { rows in
            if kind == "rawAccept" { rows.insert(rows[1], at: 2) }
            else if kind == "rawClose" { rows.insert(rows[2], at: 3) }
            else { rows[2]["remote"] = ["host": "127.0.0.2", "port": 49152] }
        }
    }
    let r = try linked(f)
    #expect(r.links.allSatisfy { $0.status == "conflictingOrIncompleteLink" })
    #expect(r.findings.count >= 3)
}

@Test(arguments: [0, 1, 2, 3])
func missingCounterpartLifecycleRecordsKeepRemainingFindings(_ removed: Int) throws {
    var f = try adapterFixture()
    try rewriteRows(&f) { $0.remove(at: removed) }
    let r = try linked(f)
    #expect(issues(r).contains("counterpart lifecycle") || issues(r).contains("TCP accept/close"))
    #expect(r.findings.filter { $0.sourceID == "receiver" }.count == (removed == 1 || removed == 2 ? 1 : 2))
}

@Test(arguments: ["missing", "uncertainty", "zeroClock", "offset", "jump", "unknownLoss", "drop", "gap", "shortDrain"])
func clockLossAndDrainGapsRemainExplicit(_ kind: String) throws {
    var f = try adapterFixture()
    switch kind {
    case "missing": f.sources[1].clock = nil
    case "uncertainty": f.sources[1].clock?.uncertaintyMs = 50
    case "zeroClock": f.sources[1].clock?.uncertaintyMs = 0
    case "offset": f.sources[1].clock?.offsetMs = 10_000
    case "jump": f.sources[1].clock?.discontinuities = 1
    case "shortDrain": try rewriteMatrix(&f) { $0.cells[0].window?.retryUpperBoundMs = 2_000 }
    default: try rewriteRows(&f, source: 2) { rows in
        if kind == "unknownLoss" { rows[2].removeValue(forKey: "droppedPackets") }
        else { rows[2][kind == "drop" ? "droppedPackets" : "gapsMs"] = 1 }
    }
    }
    let r = try linked(f)
    #expect(r.links[0].status == "conflictingOrIncompleteLink")
    #expect(r.findings.count == 3)
    #expect(!r.packetAbsenceProven)
}

@Test(arguments: ["runID", "scenarioID", "captureID", "clockID", "interface", "oracleInstanceID", "family", "remote"])
func importedCaptureProvenanceCannotBeForgedByFlowIDAlone(_ field: String) throws {
    var f = try adapterFixture()
    try rewriteRows(&f, source: 2) { rows in
        let value: Any = switch field {
        case "runID", "captureID", "oracleInstanceID": "88888888-8888-4888-8888-888888888888"
        case "scenarioID": "NET-10.ipv4.loopback.hostToZone"
        case "family": "ipv6"
        case "remote": ["host": "127.0.0.2", "port": 49152]
        default: "different"
        }
        rows[1][field] = value
    }
    let r = try linked(f)
    #expect(r.links[0].status == "conflictingOrIncompleteLink", "\(field)")
    #expect(r.findings.count == 3)
}

@Test func lateContactInDrainRetainsOriginalFlowAndZeroPayload() throws {
    var f = try adapterFixture()
    f.sources[1].text = try #require(producerVectors()["commonZeroTCP"])
    try rewriteRows(&f) { $0[2]["timestamp"] = "2026-11-04T12:00:02.500Z" }
    try rewriteMatrix(&f) { m in
        m.cells[0].events.removeAll { $0.kind == .payload }
        let i = m.cells[0].events.firstIndex { $0.kind == .closed }!
        m.cells[0].events[i].timeMs = 2500; m.cells[0].events[i].stage = .drain
    }
    let r = try linked(f)
    #expect(r.links[0].status == "partialLinkNeedsReview", "\(r.links[0].problems)")
    #expect(r.findings.contains { $0.kind == "closed" && $0.bytes == 0 })
    #expect(r.links[0].missingBindings.contains { $0.contains("prefix/zero bytes") })
}

@Test(arguments: ["commonIPv6", "commonWildcardIPv6"])
func ipv6AndWildcardListenerTuplesAreParsedWithoutOpeningSockets(_ name: String) throws {
    var f = try adapterFixture()
    f.sources[1].text = try #require(producerVectors()[name])
    let wildcard = name == "commonWildcardIPv6"
    let scenario = "NET-12.ipv6.\(wildcard ? "wildcard" : "loopback").zoneToHost"
    f.endpoints[0].scenarioID = scenario; f.bindings[0].scenarioID = scenario
    f.endpoints[0].bind.host = wildcard ? "::" : "::1"
    f.endpoints[0].local.host = "::1"; f.endpoints[0].remote.host = "::1"
    try rewriteMatrix(&f) { $0.cells[0].scenarioID = scenario }
    try rewriteRows(&f, source: 2) { rows in
        for i in rows.indices {
            rows[i]["scenarioID"] = scenario; rows[i]["family"] = "ipv6"
            if rows[i]["kind"] as? String == "packetContact" {
                rows[i]["local"] = ["host": "0:0:0:0:0:0:0:1", "port": 18080]
                rows[i]["remote"] = ["host": "::1", "port": 49152]
            }
        }
    }
    let r = try linked(f)
    #expect(r.links[0].status == "partialLinkNeedsReview", "\(r.links[0].problems)")
    #expect(r.links[0].checks.contains { $0.contains("started listener") })
}

@Test(arguments: ["::ffff:127.0.0.1", "fe80::1%en0", "example.test", "127.0.0.1\u{0}evil", "0.0.0.0"])
func unsupportedAndWildcardPeerEndpointsAreNotGuessed(_ host: String) throws {
    var f = try adapterFixture(); f.endpoints[0].remote.host = host
    #expect(try linked(f).links[0].status == "conflictingOrIncompleteLink")
}

@Test func everyOriginIsPreservedAndHashIsOnlyComputedIntegrity() throws {
    var f = try adapterFixture()
    for i in f.sources.indices { f.sources[i].origin = .importedMeasured }
    try rewriteMatrix(&f) { $0.cells[0].origin = .measured }
    let r = try linked(f)
    #expect(r.links[0].origins == [.importedMeasured])
    #expect(r.findings.allSatisfy { $0.origin == .importedMeasured })
    #expect(r.externalReviewRequired && !r.packetAbsenceProven)
    #expect(r.provenanceWarning.contains("unauthenticated"))
    let before = r.sources.first { $0.id == "receiver" }!.sha256
    f.sources[1].text += " "
    #expect(try linked(f).sources.first { $0.id == "receiver" }!.sha256 != before)
    f.sources[0].origin = .unknown; f.sources[2].origin = .fixture
    let mixed = try linked(f)
    #expect(issues(mixed).contains("mixed source origins"))
    #expect(Set(mixed.findings.map(\.origin)) == [.fixture, .importedMeasured])
}

@Test func malformedRawMetadataKeepsContactButCannotBecomeLinkedEvidence() throws {
    var f = try adapterFixture()
    try rewriteRows(&f) { rows in
        rows[1].removeValue(forKey: "remote")
        rows[2]["rawFile"] = "/private/tmp/not-opened"
        rows[2]["bytes"] = -1
    }
    let r = try linked(f)
    #expect(r.findings.count == 3)
    #expect(r.findings.filter { $0.sourceID == "receiver" }.allSatisfy { $0.hasInvalidOrIncompleteSource })
    #expect(r.links[0].status == "conflictingOrIncompleteLink")
}

@Test func c1FramerHandlesEscapesAndPreservesCompletedRecordsBeforeMalformedTail() throws {
    var f = try adapterFixture()
    f.sources[0].text = try #require(producerVectors()["c1Error"])
    try rewriteSender(&f) { $0[1].details["clientError"] = "quoted \"brace } and { with \\ newline\n" }
    #expect(parseSource(f.sources[0]).sender.count == 2)
    f.sources[0].text += "{\"unterminated\":\""
    let r = try linked(f)
    #expect(r.sources.first { $0.id == "sender" }!.sender.count == 2)
    #expect(r.links[0].status == "conflictingOrIncompleteLink")
    #expect(r.findings.count == 3)
}

@Test func boundedSourcesAndUnknownFormatsFailExplicitlyWithoutLosingOtherSources() throws {
    var f = try adapterFixture()
    f.sources[0].format = "unrecognizedFormat"
    f.sources[2].text = String(repeating: "{}\n", count: 257)
    let r = try linked(f)
    #expect(r.findings.count == 2)
    #expect(r.sources.first { $0.id == "sender" }!.problems.contains { $0.contains("unsupported") })
    #expect(r.sources.first { $0.id == "packet" }!.problems.contains { $0.contains("256") })
    f.sources[0].text = String(repeating: " ", count: 524_289)
    #expect(throws: (any Error).self) { try linked(f) }
}

@Test func packetCaptureLifecycleCannotBeReplacedByAnEmptySource() throws {
    var f = try adapterFixture()
    try rewriteRows(&f, source: 2) { $0.removeLast() }
    let r = try linked(f)
    #expect(issues(r).contains("capture lifecycle"))
    #expect(r.findings.count == 3)
}

@Test func missingMatrixRawFlowAndUnderstatedTimeAreNotPositiveControls() throws {
    var f = try adapterFixture()
    try rewriteMatrix(&f) { $0.cells[0].events.removeAll { $0.kind == .accepted } }
    #expect(try issues(linked(f)).contains("lacks matching matrix event"))
    try rewriteMatrix(&f) { $0.cells[0].participants[0].signature?.valid = false }
    let r = try linked(f)
    #expect(issues(r).contains("prerequisites invalid"))
    #expect(r.findings.count == 3)
}

@Test func producerMillisecondTimestampsAreNotTruncatedAgainOrCalendarNormalized() {
    for ms in ["009", "010", "201", "999"] { #expect(utcDate("2026-11-04T12:00:00." + ms + "Z") != nil) }
    for timestamp in ["2026-02-30T12:00:00.000Z", "2026-11-04T25:00:00.000Z", "2026-11-04T12:00:00Z", "2026-11-04T12:00:00.000+00:00"] {
        #expect(utcDate(timestamp) == nil)
    }
}

@Test func recordLimitPreservesAlreadyParsedContactsAndFlagsUninterpretedTail() throws {
    var f = try adapterFixture()
    f.sources[1].text += String(repeating: "{}\n", count: 253)
    let r = try linked(f)
    #expect(r.findings.filter { $0.sourceID == "receiver" }.count == 2)
    #expect(r.sources.first { $0.id == "receiver" }!.problems.contains { $0.contains("exceeds 256") })
    #expect(r.links[0].status == "conflictingOrIncompleteLink")
}
