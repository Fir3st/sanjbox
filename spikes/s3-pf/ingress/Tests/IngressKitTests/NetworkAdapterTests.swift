import Foundation
import Testing
import SanjboxNetworkProvenance
@testable import IngressKit

private func networkFixture(_ name: String = "tcp-v4") throws -> AdapterInput {
    let url = try #require(Bundle.module.url(forResource: "network-producer-vectors", withExtension: "json", subdirectory: "Fixtures"))
    let values = try JSONDecoder().decode([String: AdapterInput].self, from: Data(contentsOf: url))
    return try #require(values[name])
}
private func networkReport(_ input: AdapterInput) throws -> AdapterReport { try EvidenceAdapter.link(IngressKit.encodeJSON(input)) }
private func networkIssues(_ report: AdapterReport) -> String {
    (report.sources.flatMap { $0.problems + ($0.network?.records.flatMap(\.problems) ?? []) } + report.links.flatMap(\.problems)).joined(separator: "\n")
}
private func mutateNetwork(_ input: inout AdapterInput, role: String = "receiver", _ edit: (inout [[String: Any]]) throws -> Void) throws {
    let index = try #require(input.sources.firstIndex { $0.id == role })
    input.sources[index].origin = .fixture // Every mutation is explicitly synthetic.
    var rows = try input.sources[index].text.split(separator: "\n").map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    try edit(&rows)
    input.sources[index].text = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) + "\n" }.joined()
}

@Test(arguments: ["tcp-v4", "tcp-v6", "udp-v4", "udp-v6"])
func exactHistoricalProducerBytesRemainDistinctFromMeasurementClaims(_ name: String) throws {
    let input = try networkFixture(name), report = try networkReport(input)
    #expect(report.sources.count == 2)
    #expect(report.sources.allSatisfy { $0.problems.isEmpty && !$0.recordProblems })
    #expect(report.sources.allSatisfy { $0.network?.records.count == 5 && $0.network?.artifacts.allSatisfy(\.verified) == true })
    #expect(report.findings.count == 2 && report.findings.contains { $0.bytes == 169 })
    let link = try #require(report.links.first)
    #expect(link.checks.contains { $0.contains("exact independently supplied receiver bytes") })
    #expect(link.checks.contains { $0.contains("actual sender tuple reverses") })
    #expect(!link.missingBindings.contains { $0.contains("no runID") || $0.contains("C1 sender raw") || $0.contains("common counterpart raw") })
    #expect(link.missingBindings.contains { $0.contains("hostDiagnostic") })
    #expect(link.missingBindings.contains { $0.contains("independent packet capture") })
    #expect(link.problems.contains { $0.contains("time cannot be mapped") })
    #expect(report.matrixProblems == ["missing matrix evidence"])
    #expect(!report.packetAbsenceProven && report.externalReviewRequired)
    #expect(try IngressKit.encodeJSON(report) == IngressKit.encodeJSON(networkReport(input)))
}

@Test(arguments: ["udp-adversarial", "tcp-adversarial", "contact-limit", "interrupted-prefix", "refused-connect"])
func actualAdversarialAndIncompleteProducerJournalsRetainContacts(_ name: String) throws {
    let report = try networkReport(networkFixture(name))
    let expected = ["udp-adversarial": 14, "tcp-adversarial": 6, "contact-limit": 4, "interrupted-prefix": 1, "refused-connect": 0]
    #expect(report.findings.count == expected[name])
    #expect(!networkIssues(report).isEmpty)
    #expect(report.findings.allSatisfy { $0.hasInvalidOrIncompleteSource })
    if name == "interrupted-prefix" {
        #expect(report.findings[0].bytes == nil)
        #expect(report.sources[0].network?.artifacts.contains { $0.name == "received-1.bin" && $0.declaredCount > 0 && $0.verified } == true)
    } else if name == "refused-connect" {
        let end = try #require(report.sources[0].network?.records.last?.record)
        #expect(end.localKernelAcceptedBytes == 0 && end.remote == nil && end.bytes == 169)
    } else { #expect(report.findings.contains { $0.bytes == 0 }) }
    if name == "udp-adversarial" {
        #expect(report.findings.contains { $0.payloadDisposition?.contains("repeated") == true })
        #expect(report.findings.contains { $0.payloadDisposition?.contains("foreign") == true })
        #expect(report.findings.contains { $0.payloadDisposition?.contains("malformed") == true })
        #expect(report.findings.contains { $0.bytes == 4096 })
    }
}

@Test(arguments: ["duplicate", "escapedDuplicate", "unknown", "null", "malformed", "missingEnding", "missingStop", "gap", "reorder", "pid", "parent", "instance", "run", "flow", "monotonic", "utc", "tuple", "count", "nonce", "replay", "unexpectedField", "falseFinished"])
func syntheticNetworkMutationsCannotEraseContactOrSubstantiateLink(_ mutation: String) throws {
    var input = try networkFixture()
    try mutateNetwork(&input) { rows in
        switch mutation {
        case "missingEnding": rows.remove(at: 3)
        case "missingStop": rows.removeLast()
        case "gap": rows[3]["sequence"] = 19
        case "reorder": rows.swapAt(2, 3)
        case "pid": rows[3]["pid"] = 123
        case "parent": rows[3]["parentPID"] = 123
        case "instance": rows[3]["instanceID"] = UUID().uuidString
        case "run": rows[3]["runID"] = UUID().uuidString
        case "flow": rows[3]["flowID"] = UUID().uuidString
        case "monotonic": var time = rows[3]["timestamp"] as! [String: Any]; time["monotonicNanoseconds"] = 1; rows[3]["timestamp"] = time
        case "utc": var time = rows[3]["timestamp"] as! [String: Any]; time["utc"] = "2026-01-01T00:00:00.000Z"; rows[3]["timestamp"] = time
        case "tuple": rows[3]["remote"] = ["host": "127.0.0.2", "port": 16000]
        case "count": rows[3]["bytes"] = 1
        case "nonce": var claims = rows[3]["payloadClaims"] as! [String: Any]; claims["challenge"] = String(repeating: "a", count: 64); rows[3]["payloadClaims"] = claims
        case "replay": rows[3]["repeatedRegisteredPayload"] = true
        case "unknown": rows[3]["unknown"] = true
        case "null": rows[3]["payloadClaims"] = NSNull()
        case "unexpectedField": rows[2]["operationFinished"] = true
        case "falseFinished": rows[3]["operationFinished"] = false
        default: break
        }
    }
    let receiver = try #require(input.sources.firstIndex { $0.id == "receiver" })
    if ["duplicate", "escapedDuplicate", "malformed"].contains(mutation) {
        var lines = input.sources[receiver].text.split(separator: "\n").map(String.init)
        if mutation == "malformed" { lines[3] = "{broken" }
        else { lines[3] = lines[3].replacingOccurrences(of: "\"sequence\":4", with: mutation == "duplicate" ? "\"sequence\":4,\"sequence\":4" : "\"sequence\":4,\"seque\\u006ece\":4") }
        input.sources[receiver].text = lines.joined(separator: "\n") + "\n"
    }
    let report = try networkReport(input)
    #expect(report.findings.contains { $0.kind == "accepted" })
    let source = try #require(report.sources.first { $0.id == "receiver" })
    #expect(!source.problems.isEmpty || source.recordProblems, "\(mutation)")
    #expect(report.links[0].status == "conflictingOrIncompleteLink")
}

@Test(arguments: ["missing", "count", "hash", "base64", "noncanonical", "path", "duplicate", "extra", "rawMismatch", "inputHash", "signature", "identity"])
func syntheticExplicitArtifactsDoNotBecomeBytesOrAuthorityByDeclaration(_ mutation: String) throws {
    var input = try networkFixture()
    let index = try #require(input.sources.firstIndex { $0.id == "receiver" })
    input.sources[index].origin = .fixture
    var artifacts = try #require(input.sources[index].artifacts)
    let raw = try #require(artifacts.firstIndex { $0.name == "received-1.bin" })
    switch mutation {
    case "missing": artifacts.remove(at: raw)
    case "count": artifacts[raw].count = 168
    case "hash": artifacts[raw].sha256 = String(repeating: "0", count: 64)
    case "base64": artifacts[raw].base64 = "!"
    case "noncanonical": artifacts[raw].base64 += "\n"
    case "path": artifacts[raw].name = "/private/tmp/foreign.bin"
    case "duplicate": artifacts.append(artifacts[raw])
    case "extra": var a = artifacts[raw]; a.name = "received-16.bin"; artifacts.append(a)
    case "rawMismatch": let bytes = Data("not a frame".utf8); artifacts[raw].base64 = bytes.base64EncodedString(); artifacts[raw].count = bytes.count; artifacts[raw].sha256 = provenanceDigest(bytes)
    default:
        try mutateNetwork(&input) { rows in
            if mutation == "inputHash" { rows[0]["expectationSHA256"] = String(repeating: "0", count: 64) }
            else if mutation == "signature" { var s = rows[0]["signature"] as! [String: Any]; s["codeHash"] = String(repeating: "a", count: 40); rows[0]["signature"] = s }
            else { var i = rows[0]["identity"] as! [String: Any]; i["effectiveUID"] = 4999; rows[0]["identity"] = i }
        }
    }
    input.sources[index].artifacts = artifacts
    let report = try networkReport(input)
    #expect(report.findings.count == 2)
    #expect(report.sources.first { $0.id == "receiver" }?.problems.isEmpty == false)
}

@Test(arguments: ["unknownBinding", "nullBinding", "nullArtifact", "nullClock", "legacyArtifacts", "oversizeArtifacts"])
func syntheticNewEnvelopeIsStrictAndBounded(_ mutation: String) throws {
    var object = try #require(JSONSerialization.jsonObject(with: IngressKit.encodeJSON(networkFixture())) as? [String: Any])
    var sources = object["sources"] as! [[String: Any]], bindings = object["bindings"] as! [[String: Any]]
    switch mutation {
    case "unknownBinding": var n = bindings[0]["network"] as! [String: Any]; n["path"] = "/foreign"; bindings[0]["network"] = n
    case "nullBinding": bindings[0]["network"] = NSNull()
    case "nullArtifact": sources[0]["artifacts"] = NSNull()
    case "nullClock": sources[0]["clock"] = NSNull()
    case "legacyArtifacts": sources[0]["format"] = "commonCounterpartJSONL"
    default: sources[0]["artifacts"] = Array(repeating: (sources[0]["artifacts"] as! [[String: Any]])[0], count: 19)
    }
    object["sources"] = sources; object["bindings"] = bindings
    #expect(throws: (any Error).self) { try EvidenceAdapter.link(JSONSerialization.data(withJSONObject: object)) }
}

@Test(arguments: ["legacyMix", "reusedSender", "reusedContact", "wrongContact", "crossRun", "wrongFlow", "wrongEndpoint", "wrongTransport", "wildcardScenario", "aliasSource"])
func syntheticNewBindingsCannotHideAmbiguity(_ mutation: String) throws {
    var input = try networkFixture()
    switch mutation {
    case "legacyMix": input.bindings[0].sender = .init(sourceID: "sender", line: 1)
    case "reusedSender", "reusedContact": input.bindings.append(input.bindings[0]); input.bindings[1].flowID = UUID()
    case "wrongContact": input.bindings[0].network?.contactID = 2
    case "crossRun": input.runID = UUID()
    case "wrongFlow": input.bindings[0].flowID = UUID()
    case "wrongEndpoint": input.endpoints[0].remote.port = 12345
    case "wrongTransport": input.endpoints[0].transport = .udp
    case "wildcardScenario": input.bindings[0].scenarioID = "NET-10.ipv4.wildcard.hostToZone"; input.endpoints[0].scenarioID = input.bindings[0].scenarioID; input.endpoints[0].bind.host = "0.0.0.0"
    default: var alias = input.sources.first { $0.id == "receiver" }!; alias.id = "alias"; input.sources.append(alias)
    }
    let report = try networkReport(input)
    let text = networkIssues(report)
    let expected = ["legacyMix": "cannot mix", "reusedSender": "reused", "reusedContact": "reused", "wrongContact": "terminal missing", "crossRun": "binding mismatch", "wrongFlow": "binding mismatch", "wrongEndpoint": "allowlist", "wrongTransport": "allowlist", "wildcardScenario": "exact-bind", "aliasSource": "instance reused"]
    #expect(text.contains(expected[mutation]!))
    #expect(report.findings.count >= 2)
}

@Test(arguments: ["partial", "missingEnd", "progressRegression", "progressAfterEnd", "missingConnected", "intentCount", "wrongTuple", "falseSuccess", "inputRegistration"])
func syntheticSenderSeparatesIntentProgressAndFailure(_ mutation: String) throws {
    var input = try networkFixture()
    try mutateNetwork(&input, role: "sender") { rows in
        switch mutation {
        case "partial": rows[3]["localKernelAcceptedBytes"] = 80; rows[4]["localKernelAcceptedBytes"] = 80; rows[4]["operationFinished"] = false; rows[4]["reason"] = "synthetic partial send"
        case "missingEnd": rows.removeLast()
        case "progressRegression": rows[3]["localKernelAcceptedBytes"] = 0
        case "progressAfterEnd": rows.swapAt(3, 4)
        case "missingConnected": rows.remove(at: 2)
        case "intentCount": rows[1]["bytes"] = 0
        case "wrongTuple": rows[3]["remote"] = ["host": "127.0.0.2", "port": 12345]
        case "falseSuccess": rows[4]["localKernelAcceptedBytes"] = 0
        default: rows[0]["registrationSHA256"] = String(repeating: "0", count: 64)
        }
    }
    let report = try networkReport(input)
    #expect(report.sources.first { $0.id == "sender" }?.problems.isEmpty == false)
    #expect(report.findings.count == 2)
}

@Test func syntheticProducerEncodedForeignZeroUUIDFrameRetainsTerminalAndExactBytes() throws {
    var input = try networkFixture("udp-v4")
    let index = try #require(input.sources.firstIndex { $0.id == "receiver" })
    input.sources[index].origin = .fixture
    let zero = "00000000-0000-0000-0000-000000000000"
    let bytes = Data("SANJBOX-NETWORK-PROVENANCE-V1|\(zero)|\(zero)|\(String(repeating: "0", count: 64))\n".utf8)
    let rawIndex = try #require(input.sources[index].artifacts?.firstIndex { $0.name == "received-1.bin" })
    input.sources[index].artifacts?[rawIndex] = .init(name: "received-1.bin", count: bytes.count, sha256: provenanceDigest(bytes), base64: bytes.base64EncodedString())
    var records = try input.sources[index].text.split(separator: "\n").map { try JSONDecoder().decode(NetworkEvent.self, from: Data($0.utf8)) }
    records[3].rawSHA256 = provenanceDigest(bytes)
    records[3].payloadClaims = try JSONDecoder().decode(PayloadClaims.self, from: JSONSerialization.data(withJSONObject: ["runID": zero, "flowID": zero, "challenge": String(repeating: "0", count: 64)]))
    records[3].matchesRegisteredPayload = false
    let producerEncoder = JSONEncoder(); producerEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    input.sources[index].text = try records.map { String(decoding: try producerEncoder.encode($0), as: UTF8.self) + "\n" }.joined()
    let report = try networkReport(input)
    let source = try #require(report.sources.first { $0.id == "receiver" })
    #expect(source.problems.isEmpty && !source.recordProblems)
    #expect(report.findings.count == 2)
    #expect(report.findings.contains { $0.kind == "datagram" && $0.bytes == 169 && $0.payloadDisposition?.contains("foreign") == true })
    #expect(report.links[0].problems.contains { $0.contains("zero/partial/foreign/replayed") })
}

/// Synthetic matrix/clock overlay on exact historical bytes; deliberately not a measured matrix.
private func networkWithSyntheticMatrix() throws -> AdapterInput {
    var input = try networkFixture()
    input.runStartUTC = "2026-11-06T08:11:00.000Z"
    var participants: [Participant] = [], events: [EvidenceEvent] = []
    for index in input.sources.indices {
        input.sources[index].origin = .fixture
        input.sources[index].clock = .init(id: "synthetic-clock-\(index)", offsetMs: 0, uncertaintyMs: 1, discontinuities: 0, calibrationID: "synthetic-no-real-calibration")
        let source = parseSource(input.sources[index])
        let rows = try #require(source.network?.records)
        let registered = rows[0].record
        let identity = try JSONDecoder().decode(IngressKit.Identity.self, from: IngressKit.encodeJSON(#require(registered.identity)))
        let actor: Actor = registered.role == "sender" ? .initiator : .listener
        let signature = try JSONDecoder().decode(SignatureReport.self, from: Data(#"{"valid":true,"hardenedRuntime":true,"getTaskAllowAbsent":true,"metadataComplete":true}"#.utf8))
        participants.append(.init(actor: actor, instanceID: registered.instanceID, pid: registered.pid, machine: "target", expected: identity, observed: identity, signature: signature))
        for row in rows {
            let kind: EventKind?
            switch row.record.kind {
            case "attemptStarted": kind = .attempt
            case "connected": kind = .connected
            case "accepted": kind = .accepted
            case "closed": kind = .closed
            default: kind = nil
            }
            guard let kind else { continue }
            let time = Int((try #require(utcDate(row.record.timestamp.utc))).timeIntervalSince(try #require(utcDate(input.runStartUTC))) * 1000 + 0.5)
            events.append(.init(timeMs: time, stage: .test, actor: actor, instanceID: registered.instanceID, kind: kind, runID: input.runID, flowID: input.bindings[0].flowID, value: 0))
            if kind == .closed { events.append(.init(timeMs: time, stage: .test, actor: actor, instanceID: registered.instanceID, kind: .payload, runID: input.runID, flowID: input.bindings[0].flowID, value: 169)) }
        }
    }
    events.sort { $0.timeMs < $1.timeMs }
    let first = try #require(events.map(\.timeMs).min()), last = try #require(events.map(\.timeMs).max())
    let cell = CellEvidence(scenarioID: input.bindings[0].scenarioID, origin: .mock, portBasis: "ephemeralFixture", participants: participants,
        window: .init(testStartMs: first - 10, testEndMs: last + 10, drainEndMs: last + 100, retryUpperBoundMs: 1, roundTripUpperBoundMs: 1, captureDrops: 0, captureGapsMs: 0, clockUncertaintyMs: 1), events: events)
    input.matrixJSON = String(decoding: try IngressKit.encodeJSON(EvidenceInput(schemaVersion: 1, runID: input.runID, cells: [cell], roles: nil)), as: UTF8.self)
    return input
}

@Test(arguments: ["matching", "extraPayload", "missingPayload", "wrongCount", "wrongActor", "missingConnected", "extraConnected", "missingAttempt", "clockGap", "clockUnknown"])
func syntheticMatrixMustReconcileEveryNetworkObservation(_ mutation: String) throws {
    var input = try networkWithSyntheticMatrix()
    var matrix = try EvidenceInput.decode(Data(#require(input.matrixJSON).utf8))
    let payload = try #require(matrix.cells[0].events.firstIndex { $0.kind == .payload })
    switch mutation {
    case "extraPayload": matrix.cells[0].events.append(matrix.cells[0].events[payload])
    case "missingPayload": matrix.cells[0].events.remove(at: payload)
    case "wrongCount": matrix.cells[0].events[payload].value = 168
    case "wrongActor": matrix.cells[0].events[payload].actor = .initiator
    case "missingAttempt": matrix.cells[0].events.removeAll { $0.kind == .attempt }
    case "missingConnected": matrix.cells[0].events.removeAll { $0.kind == .connected }
    case "extraConnected": matrix.cells[0].events.append(try #require(matrix.cells[0].events.first { $0.kind == .connected })); matrix.cells[0].events.sort { $0.timeMs < $1.timeMs }
    case "clockGap": input.sources[0].clock?.discontinuities = 1
    case "clockUnknown": input.sources[0].clock?.offsetMs = nil
    default: break
    }
    input.matrixJSON = String(decoding: try IngressKit.encodeJSON(matrix), as: UTF8.self)
    let report = try networkReport(input), link = try #require(report.links.first)
    if mutation == "matching" {
        #expect(!link.problems.contains { $0.contains("one-to-one reconciliation") })
        #expect(link.checks.contains { $0.contains("raw connected") })
        #expect(link.checks.contains { $0.contains("raw payload") })
        #expect(link.checks.contains { $0.contains("identity/PID/instance/signature flags match matrix") })
    } else if mutation == "wrongActor" {
        #expect(report.matrixProblems.contains { $0.contains("strict JSON/schema invalid") })
    } else { #expect(link.problems.contains { $0.contains("one-to-one reconciliation") }, "\(mutation): \(link.problems)") }
    #expect(report.findings.count == 2 && !report.packetAbsenceProven)
}

@Test func syntheticQuietReceiverDoesNotBecomeZeroPacketProof() throws {
    var input = try networkFixture()
    input.sources.removeAll { $0.id == "sender" }; input.bindings = []; input.endpoints = []
    try mutateNetwork(&input) { rows in
        rows.removeSubrange(2...3); rows[2]["sequence"] = 3; rows[2]["contactID"] = 0
    }
    input.sources[0].artifacts?.removeAll { $0.name == "received-1.bin" }
    let report = try networkReport(input)
    #expect(report.sources[0].problems.isEmpty && !report.sources[0].recordProblems)
    #expect(report.findings.isEmpty && !report.packetAbsenceProven && report.externalReviewRequired)
    #expect(report.matrix.cells.allSatisfy { $0.classification == "notMeasured" })
}

private func independentReviewFixture(_ name: String) throws -> AdapterInput {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/NetworkReviewRegressions"))
    return try AdapterInput.decode(Data(contentsOf: url))
}

@Test(arguments: ["contact-limit-false-success", "positive-at-contact-limit", "tcp-4096-false-complete", "sequence-overflow"])
func exactIndependentReviewCounterexamplesRetainIncompleteFindings(_ name: String) throws {
    let report = try networkReport(independentReviewFixture(name))
    let source = try #require(report.sources.first { $0.id == "receiver" })
    #expect(report.findings.count == (name == "contact-limit-false-success" ? 4 : 2))
    #expect(report.findings.allSatisfy { $0.hasInvalidOrIncompleteSource })
    #expect(!source.problems.isEmpty)
    if name == "tcp-4096-false-complete" {
        #expect(source.problems.contains { $0.contains("TCP raw limit reached") })
        #expect(report.findings.contains { $0.bytes == 4096 })
    } else if name == "sequence-overflow" {
        #expect(source.recordProblems)
        #expect(source.network?.records.contains { $0.record.sequence == Int.max } == true)
    } else { #expect(source.problems.contains { $0.contains("stopped count/limit") }) }
}

@Test(arguments: [Int.min, Int.min + 1, Int.max - 1, Int.max])
func syntheticSequenceExtremesCannotTrapOrDiscardContacts(_ sequence: Int) throws {
    var input = try networkFixture()
    try mutateNetwork(&input) { rows in rows[2]["sequence"] = sequence }
    let report = try networkReport(input)
    #expect(report.findings.count == 2)
    #expect(report.findings.allSatisfy { $0.hasInvalidOrIncompleteSource })
    #expect(report.sources.first { $0.id == "receiver" }?.recordProblems == true)
}

@Test(arguments: ["below-contact-limit", "tcp-4095", "udp-4096", "tcp-4096-truncated"])
func syntheticReceiverBoundariesMatchProducerSemantics(_ boundary: String) throws {
    var input = try boundary == "below-contact-limit" ? independentReviewFixture("contact-limit-false-success") : networkFixture(boundary == "udp-4096" ? "udp-v4" : "tcp-v4")
    input.sources.removeAll { $0.id != "receiver" }; input.bindings = []; input.endpoints = []
    input.sources[0].origin = .fixture
    if boundary == "below-contact-limit" {
        let index = try #require(input.sources[0].artifacts?.firstIndex { $0.name == "probe.json" })
        let original = try #require(input.sources[0].artifacts?[index].data)
        var probe = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        probe["maximumContacts"] = 3 // Two observed contacts remain below the configured maximum.
        let bytes = try JSONSerialization.data(withJSONObject: probe, options: [.sortedKeys])
        input.sources[0].artifacts?[index] = .init(name: "probe.json", count: bytes.count, sha256: provenanceDigest(bytes), base64: bytes.base64EncodedString())
        try mutateNetwork(&input) { rows in
            rows[0]["registration"] = probe; rows[0]["registrationSHA256"] = provenanceDigest(bytes)
        }
    } else {
        let count = boundary == "tcp-4095" ? 4095 : 4096
        let bytes = Data(repeating: 65, count: count)
        let index = try #require(input.sources[0].artifacts?.firstIndex { $0.name == "received-1.bin" })
        input.sources[0].artifacts?[index] = .init(name: "received-1.bin", count: count, sha256: provenanceDigest(bytes), base64: bytes.base64EncodedString())
        try mutateNetwork(&input) { rows in
            rows[3]["bytes"] = count; rows[3]["rawSHA256"] = provenanceDigest(bytes)
            rows[3].removeValue(forKey: "payloadClaims"); rows[3]["matchesRegisteredPayload"] = false
            if boundary == "udp-4096" { rows[2]["bytes"] = count }
            if boundary == "tcp-4096-truncated" {
                rows[3]["rawTruncated"] = true; rows[3]["reason"] = "rawLimit"; rows[3]["operationFinished"] = false
                rows[4]["operationFinished"] = false
            }
        }
    }
    let report = try networkReport(input)
    #expect(report.findings.count == (boundary == "below-contact-limit" ? 4 : 2))
    if boundary == "tcp-4096-truncated" {
        #expect(!report.sources[0].problems.isEmpty)
        #expect(report.findings.allSatisfy { $0.hasInvalidOrIncompleteSource })
    } else {
        #expect(report.sources[0].problems.isEmpty && !report.sources[0].recordProblems)
        #expect(report.findings.allSatisfy { !$0.hasInvalidOrIncompleteSource })
    }
    #expect(!report.packetAbsenceProven && report.externalReviewRequired)
}
