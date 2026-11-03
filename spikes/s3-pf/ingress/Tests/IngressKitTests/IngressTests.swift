import Darwin
import Foundation
import Testing
@testable import IngressKit

private func identity(_ uid: UInt32 = 501, _ session: Int32 = 100) throws -> Identity {
    try Identity.decode(Data("""
    {"realUID":\(uid),"effectiveUID":\(uid),"realGID":20,"effectiveGID":20,"kernelGroups":[20],"requiredGroups":[],"forbiddenGroups":[],"auditSessionID":\(session),"auditUID":\(uid),"auditFlags":0,"managerName":"Aqua","managerUID":\(uid),"windowUID":\(uid),"windowAuditSessionID":\(session),"onConsole":false,"loginDone":true}
    """.utf8))
}
private let goodSignature = SignatureReport(valid: true, hardenedRuntime: true, getTaskAllowAbsent: true, metadataComplete: true)
private func fixture(route: Route = .hostToZone, origin: EvidenceOrigin = .measured) throws -> EvidenceInput {
    let roles = try RoleMap(host: identity(), zone: identity(601, 200), otherZone: identity(602, 300), lan: identity(701, 400))
    let identities: (Identity, Identity) = switch route {
    case .hostToZone: (roles.host, roles.zone)
    case .sameZone: (roles.zone, roles.zone)
    case .zoneToHost, .squatHostPort: (roles.zone, roles.host)
    case .otherZoneToZone: (roles.otherZone, roles.zone)
    case .zoneToOtherZone: (roles.zone, roles.otherZone)
    case .lanToZone: (roles.lan!, roles.zone)
    }
    let participants = [Participant(actor: .initiator, instanceID: UUID(), pid: 100, machine: route == .lanToZone ? "lan" : "target", expected: identities.0, observed: identities.0, signature: goodSignature),
        Participant(actor: .listener, instanceID: UUID(), pid: 101, machine: "target", expected: identities.1, observed: identities.1, signature: goodSignature),
        Participant(actor: .oracle, instanceID: UUID(), pid: 102, machine: "target", expected: roles.host, observed: roles.host, signature: goodSignature)]
    let runID = UUID()
    var events: [EvidenceEvent] = []
    func add(_ time: Int, _ stage: Stage, _ actor: Actor, _ kind: EventKind, flow: UUID = UUID(), value: Int = 0) {
        events.append(.init(timeMs: time, stage: stage, actor: actor, instanceID: participants.first(where: { $0.actor == actor })!.instanceID,
            kind: kind, runID: runID, flowID: flow, value: value))
    }
    func control(_ time: Int, _ stage: Stage) {
        let flow = UUID()
        add(time, stage, .initiator, .attempt, flow: flow)
        add(time + 1, stage, .oracle, .packetContact, flow: flow)
        add(time + 2, stage, .initiator, .connected, flow: flow)
        add(time + 3, stage, .listener, .accepted, flow: flow)
        add(time + 4, stage, .listener, .handshake, flow: flow)
        add(time + 5, stage, .initiator, .handshake, flow: flow)
        add(time + 6, stage, .listener, .closed, flow: flow)
    }
    add(0, .before, .oracle, .captureStarted)
    add(1, .before, .listener, .listenerStarted)
    control(10, .before)
    if route == .squatHostPort { add(20, .before, .listener, .hostReservationHeld) }
    if route == .sameZone { control(200, .test) }
    else { add(200, .test, .initiator, .attempt) }
    if route == .squatHostPort { add(210, .test, .initiator, .bindDenied) }
    control(2_010, .after)
    if route == .squatHostPort { add(2_020, .after, .listener, .hostReclaimed) }
    add(2_030, .after, .listener, .listenerStopped)
    add(2_040, .after, .oracle, .captureStopped)
    let scenario = Scenario.all.first { $0.route == route && $0.family == .ipv4 && $0.bind == .loopback }!
    return EvidenceInput(schemaVersion: 1, runID: runID, cells: [.init(scenarioID: scenario.id, origin: origin, portBasis: "fixedHostReservation", participants: participants,
        window: .init(testStartMs: 100, testEndMs: 1_000, drainEndMs: 2_000, retryUpperBoundMs: 100, roundTripUpperBoundMs: 10, captureDrops: 0, captureGapsMs: 0, clockUncertaintyMs: 1), events: events)], roles: roles)
}
private func result(_ input: EvidenceInput) throws -> CellResult { try #require(Adjudicator.evaluate(input).cells.first { $0.scenario.id == input.cells[0].scenarioID }) }

@Test func completeTranscriptRemainsIncompleteUntilRawEndpointAdapter() throws {
    let r = try result(fixture())
    #expect(r.classification == "incomplete")
    #expect(r.problems.count == 1)
    #expect(r.problems[0].contains("endpoint tuple"))
}
@Test func allMatrixCellsArePlannedWhenEvidenceAbsent() throws {
    let report = try Adjudicator.evaluate(.init(schemaVersion: 1, runID: UUID(), cells: [], roles: nil))
    #expect(report.cells.count == 28)
    #expect(report.cells.allSatisfy { $0.classification == "notMeasured" })
}
@Test func measuredMockPlannedRemainSeparate() throws {
    #expect(try result(fixture(origin: .mock)).classification == "mockOnly")
    #expect(try result(fixture(origin: .planned)).classification == "notMeasured")
}
@Test func zeroPayloadAcceptIsStillContactAndPartialCaptureDoesNotEraseFinding() throws {
    var input = try fixture()
    var event = input.cells[0].events.first { $0.kind == .attempt && $0.stage == .test }!
    event.actor = .listener; event.instanceID = input.cells[0].participants[1].instanceID; event.kind = .accepted; event.timeMs = 201
    input.cells[0].events.append(event); input.cells[0].events.sort { $0.timeMs < $1.timeMs }
    input.cells[0].window!.captureDrops = 1
    let r = try result(input)
    #expect(r.payloadBytesObserved == 0)
    #expect(r.forbiddenContactsObserved == 1)
    #expect(r.classification == "observedViolationNeedsReview")
}
@Test func missingOrWrongCredentialsNeverValidate() throws {
    var input = try fixture()
    input.cells[0].participants[0].observed = nil
    #expect(try result(input).classification == "invalidMeasurement")
    input = try fixture(); input.cells[0].participants[0].observed!.auditSessionID += 1
    #expect(try result(input).classification == "invalidMeasurement")
}
@Test func roleMapRejectsHostAsSameZoneAndSwappedHostRoute() throws {
    var input = try fixture(route: .sameZone)
    for i in [0,1] { input.cells[0].participants[i].expected = input.roles!.host; input.cells[0].participants[i].observed = input.roles!.host }
    #expect(try result(input).classification == "invalidMeasurement")
    input = try fixture()
    let a = input.cells[0].participants[0].expected
    input.cells[0].participants[0].expected = input.cells[0].participants[1].expected
    input.cells[0].participants[0].observed = input.cells[0].participants[1].observed
    input.cells[0].participants[1].expected = a; input.cells[0].participants[1].observed = a
    #expect(try result(input).classification == "invalidMeasurement")
}
@Test func missingControlsCoverageAndHandshakeStayIncomplete() throws {
    var input = try fixture(route: .sameZone)
    input.cells[0].events.removeAll { $0.stage == .after && $0.kind == .handshake || $0.stage == .test && $0.kind == .handshake }
    input.cells[0].window!.captureGapsMs = nil
    input.cells[0].window!.retryUpperBoundMs = nil
    let r = try result(input)
    #expect(r.classification == "incomplete")
    #expect(r.problems.contains { $0.contains("positive control after") })
    #expect(r.problems.contains { $0.contains("same-zone counterpart") })
    #expect(r.problems.contains { $0.contains("capture loss") })
    #expect(r.problems.contains { $0.contains("retry/RTT") })
}
@Test func drainSquattingIsFindingAndEphemeralIsNotFixedHostPort() throws {
    var input = try fixture(route: .squatHostPort)
    input.cells[0].portBasis = "ephemeralFixture"
    var event = input.cells[0].events.first { $0.kind == .bindDenied }!
    event.kind = .bindAcquired; event.stage = .drain; event.timeMs = 1_100; event.flowID = UUID()
    input.cells[0].events.append(event); input.cells[0].events.sort { $0.timeMs < $1.timeMs }
    let r = try result(input)
    #expect(r.classification == "observedViolationNeedsReview")
    #expect(r.problems.contains { $0.contains("ephemeral collision") })
}
@Test func reversedHandshakeAndEarlyCloseAreNotPositiveControls() throws {
    for kind in [EventKind.handshake, .closed] {
        var input = try fixture()
        let index = input.cells[0].events.firstIndex { $0.kind == kind && $0.actor == .listener && $0.stage == .before }!
        input.cells[0].events[index].timeMs = 11
        input.cells[0].events.sort { $0.timeMs < $1.timeMs }
        #expect(try result(input).problems.contains { $0.contains("positive control before") })
    }
}
@Test func reusedFlowIDAndActorSpoofAreRejected() throws {
    var input = try fixture()
    let flow = input.cells[0].events.first { $0.kind == .attempt && $0.stage == .before }!.flowID
    let index = input.cells[0].events.firstIndex { $0.kind == .attempt && $0.stage == .after }!
    input.cells[0].events[index].flowID = flow
    #expect(throws: (any Error).self) { try input.validate() }
    input = try fixture(); input.cells[0].events[0].kind = .accepted
    #expect(throws: (any Error).self) { try input.validate() }
}
@Test func malformedUnknownDuplicateOversizedAndDeepJSONRejected() throws {
    for text in ["{}", "{\"schemaVersion\":1,\"schemaVersion\":1}", "{\"schemaVersion\":1,\"unknown\":0}", String(repeating: "[", count: 25) + "0" + String(repeating: "]", count: 25), String(repeating: " ", count: 1_048_577)] {
        #expect(throws: (any Error).self) { try EvidenceInput.decode(Data(text.utf8)) }
    }
    let encoded = try encodeJSON(fixture())
    #expect(try EvidenceInput.decode(encoded).cells.count == 1)
}
@Test func duplicateEscapedJSONKeysAndGroupsRejected() throws {
    #expect(throws: (any Error).self) { try EvidenceInput.decode(Data(#"{"schemaVersion":1,"schema\u0056ersion":1}"#.utf8)) }
    var id = try identity(); id.kernelGroups = [20,20]
    #expect(throws: (any Error).self) { try id.validate() }
    id = try identity(); id.requiredGroups = [80]; id.forbiddenGroups = [80]
    #expect(throws: (any Error).self) { try id.validate() }
}
@Test func signaturePolicyFailClosedWithoutCreatingForbiddenBinaries() {
    #expect(SignatureReport.inspect(valid: true, flags: 0x10000, rawEntitlementsPresent: false, entitlements: nil).permitsLive)
    #expect(!SignatureReport.inspect(valid: true, flags: 0, rawEntitlementsPresent: false, entitlements: nil).permitsLive)
    #expect(!SignatureReport.inspect(valid: true, flags: 0x10000, rawEntitlementsPresent: true, entitlements: nil).permitsLive)
    for value in [true, false] {
        #expect(!SignatureReport.inspect(valid: true, flags: 0x10000, rawEntitlementsPresent: true, entitlements: ["com.apple.security.get-task-allow": value]).permitsLive)
    }
}
private func outputFixture() throws -> (UUID, String) {
    let id = UUID()
    let report = SmokeReport(runID: id, identity: try identity(), signature: goodSignature, families: [])
    return (id, try OwnedOutput.save(report))
}
@Test func outputIsCreateNewCleanupIsDryByDefaultAndIdempotent() throws {
    let (id, path) = try outputFixture()
    #expect(try OwnedOutput.cleanup(runID: id, apply: false).status == "dryRunVerifiedTwoOwnFiles")
    #expect(FileManager.default.fileExists(atPath: path + "/report.json"))
    let report = SmokeReport(runID: id, identity: try identity(), signature: goodSignature, families: [])
    #expect(throws: (any Error).self) { try OwnedOutput.save(report) }
    #expect(try OwnedOutput.cleanup(runID: id, apply: true).status == "removedOwnFiles")
    #expect(try OwnedOutput.cleanup(runID: id, apply: true).status == "alreadyAbsent")
}
@Test func cleanupPreservesChangedBytesAndExtraEntries() throws {
    let (id, path) = try outputFixture()
    let report = path + "/report.json"
    let original = try Data(contentsOf: URL(fileURLWithPath: report))
    let fd = open(report, O_WRONLY | O_TRUNC); #expect(fd >= 0)
    let bytes = Array("changed".utf8); #expect(write(fd, bytes, bytes.count) == bytes.count); close(fd)
    #expect(throws: (any Error).self) { try OwnedOutput.cleanup(runID: id, apply: true) }
    #expect(FileManager.default.fileExists(atPath: path + "/state.json"))
    let restoreFD = open(report, O_WRONLY | O_TRUNC); #expect(restoreFD >= 0)
    #expect(original.withUnsafeBytes { write(restoreFD, $0.baseAddress!, original.count) } == original.count); close(restoreFD)
    let extra = path + "/extra"; let extraFD = open(extra, O_CREAT | O_EXCL | O_WRONLY, 0o600); #expect(extraFD >= 0); close(extraFD)
    #expect(throws: (any Error).self) { try OwnedOutput.cleanup(runID: id, apply: true) }
    #expect(unlink(extra) == 0)
    #expect(try OwnedOutput.cleanup(runID: id, apply: true).status == "removedOwnFiles")
}
@Test func cleanupPreservesImmutableStateUntilExplicitFixtureRestore() throws {
    let (id, path) = try outputFixture()
    #expect(chflags(path + "/state.json", UInt32(UF_IMMUTABLE)) == 0)
    #expect(throws: (any Error).self) { try OwnedOutput.cleanup(runID: id, apply: true) }
    #expect(FileManager.default.fileExists(atPath: path + "/report.json"))
    #expect(chflags(path + "/state.json", 0) == 0)
    #expect(try OwnedOutput.cleanup(runID: id, apply: true).status == "removedOwnFiles")
}
@Test func cleanupPreservesACLConflictUntilExplicitFixtureRestore() throws {
    let (id, path) = try outputFixture()
    func chmodACL(_ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/chmod"); p.arguments = args
        try p.run(); p.waitUntilExit(); #expect(p.terminationStatus == 0)
    }
    try chmodACL(["+a", "everyone deny delete", path + "/state.json"])
    #expect(throws: (any Error).self) { try OwnedOutput.cleanup(runID: id, apply: true) }
    #expect(FileManager.default.fileExists(atPath: path + "/report.json"))
    try chmodACL(["-N", path + "/state.json"])
    #expect(try OwnedOutput.cleanup(runID: id, apply: true).status == "removedOwnFiles")
}

@Test func delayedContactAndAcquisitionPreserveOriginalTestFlow() throws {
    for route in [Route.hostToZone, .squatHostPort] {
        var input = try fixture(route: route)
        var event = input.cells[0].events.first { $0.kind == .attempt && $0.stage == .test }!
        event.timeMs = 1_100; event.stage = .drain
        if route == .squatHostPort { event.kind = .bindAcquired }
        else { event.actor = .listener; event.instanceID = input.cells[0].participants[1].instanceID; event.kind = .accepted }
        input.cells[0].events.append(event); input.cells[0].events.sort { $0.timeMs < $1.timeMs }
        #expect(try result(input).classification == "observedViolationNeedsReview")
    }
}

@Test func cleanupPreservesDirectoryFlagsAndGroupDrift() throws {
    let (id, path) = try outputFixture()
    #expect(chflags(path, UInt32(UF_IMMUTABLE)) == 0)
    #expect(throws: (any Error).self) { try OwnedOutput.cleanup(runID: id, apply: true) }
    #expect(FileManager.default.fileExists(atPath: path + "/report.json"))
    #expect(chflags(path, 0) == 0)
    let count = getgroups(0, nil)
    var groups = [gid_t](repeating: 0, count: Int(max(0, count)))
    #expect(count >= 0 && getgroups(count, &groups) == count)
    if let other = groups.first(where: { $0 != getegid() }) {
        #expect(chown(path + "/state.json", uid_t.max, other) == 0)
        #expect(throws: (any Error).self) { try OwnedOutput.cleanup(runID: id, apply: true) }
        #expect(FileManager.default.fileExists(atPath: path + "/report.json"))
        #expect(chown(path + "/state.json", uid_t.max, getegid()) == 0)
    } else { print("C3 GID drift fixture missing: no second own kernel group") }
    #expect(try OwnedOutput.cleanup(runID: id, apply: true).status == "removedOwnFiles")
}
@Test func cleanupPreservesSymlinkAndHardlinkConflicts() throws {
    let (id, path) = try outputFixture()
    let report = path + "/report.json", held = path + "/held-report.json"
    #expect(rename(report, held) == 0)
    #expect(symlink("held-report.json", report) == 0)
    #expect(throws: (any Error).self) { try OwnedOutput.cleanup(runID: id, apply: true) }
    #expect(unlink(report) == 0)
    #expect(rename(held, report) == 0)
    let outsideLink = "/private/tmp/sanjbox-c3-link-" + id.uuidString
    #expect(link(report, outsideLink) == 0)
    #expect(throws: (any Error).self) { try OwnedOutput.cleanup(runID: id, apply: true) }
    #expect(FileManager.default.fileExists(atPath: path + "/state.json"))
    #expect(unlink(outsideLink) == 0)
    #expect(try OwnedOutput.cleanup(runID: id, apply: true).status == "removedOwnFiles")
}
@Test func cleanupPreservesDirectoryACLConflict() throws {
    let (id, path) = try outputFixture()
    func run(_ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/chmod"); p.arguments = args
        try p.run(); p.waitUntilExit(); #expect(p.terminationStatus == 0)
    }
    try run(["+a", "everyone deny delete_child", path])
    #expect(throws: (any Error).self) { try OwnedOutput.cleanup(runID: id, apply: true) }
    #expect(FileManager.default.fileExists(atPath: path + "/report.json"))
    #expect(FileManager.default.fileExists(atPath: path + "/state.json"))
    try run(["-N", path])
    #expect(try OwnedOutput.cleanup(runID: id, apply: true).status == "removedOwnFiles")
}
