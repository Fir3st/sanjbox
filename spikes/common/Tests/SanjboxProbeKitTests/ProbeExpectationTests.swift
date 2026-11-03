import Foundation
import Testing
@testable import SanjboxProbeKit

/// A compartment-like context: UID 450 in its own non-console window session.
private func zoneContext() -> ProbeContext {
    ProbeContext(
        pid: 100, parentPID: 1,
        realUID: 450, effectiveUID: 450, realGID: 450, effectiveGID: 450,
        userName: "_sanjbox_t1", kernelGroups: [450, 701],
        groupMembership: [
            .init(gid: 20, isMember: false),
            .init(gid: 80, isMember: false),
            .init(gid: 701, isMember: true),
        ],
        audit: .init(sessionID: 200_001, auditUID: 450, flags: 0),
        launchdManager: .init(name: "Aqua", uid: 450),
        windowSession: .init(userID: 450, userName: "_sanjbox_t1", auditSessionID: 200_001, onConsole: false, loginDone: true)
    )
}

private func zoneExpectation() -> ProbeExpectation {
    ProbeExpectation(
        effectiveUID: 450, realUID: 450, effectiveGID: 450, realGID: 450, userName: "_sanjbox_t1",
        requiredGroups: [701], forbiddenGroups: [20, 80],
        launchdManagerName: "Aqua", launchdManagerUID: 450,
        windowSessionUID: 450, onConsole: false, forbiddenAuditSessionIDs: [100_015]
    )
}

@Test func matchingContextIsValid() {
    #expect(zoneExpectation().mismatches(in: zoneContext()).isEmpty)
}

@Test func hostConsoleContextIsRejectedOnEveryIdentityField() {
    var host = zoneContext()
    host.realUID = 501
    host.effectiveUID = 501
    host.userName = "host"
    host.launchdManager = .init(name: "Aqua", uid: 501)
    host.windowSession = .init(userID: 501, userName: "host", auditSessionID: 100_015, onConsole: true, loginDone: true)
    host.audit = .init(sessionID: 100_015, auditUID: 501, flags: 0)

    let fields = Set(zoneExpectation().mismatches(in: host).map(\.field))
    #expect(fields == ["effectiveUID", "realUID", "userName", "launchdManagerUID", "windowSessionUID", "onConsole", "auditSessionID"])
}

@Test func forbiddenGroupMembershipIsAMismatch() {
    var context = zoneContext()
    context.groupMembership[0] = .init(gid: 20, isMember: true)
    let mismatches = zoneExpectation().mismatches(in: context)
    #expect(mismatches == [Mismatch(field: "forbiddenGroup 20", expected: "not member", actual: "member")])
}

@Test func unverifiableFactsAreMismatchesNotPasses() {
    var context = zoneContext()
    context.groupMembership = [.init(gid: 20, isMember: nil)]   // 80 and 701 not captured, 20 unresolved
    context.windowSession = nil
    context.audit = nil

    let byField = Dictionary(uniqueKeysWithValues: zoneExpectation().mismatches(in: context).map { ($0.field, $0.actual) })
    #expect(byField["forbiddenGroup 20"] == "unresolved")
    #expect(byField["forbiddenGroup 80"] == "not captured")
    #expect(byField["requiredGroup 701"] == "not captured")
    #expect(byField["windowSessionUID"] == "none")
    #expect(byField["onConsole"] == "none")
    #expect(byField["auditSessionID"] == "none")
}

@Test func onlySetFieldsAreChecked() {
    var context = zoneContext()
    context.windowSession = nil
    context.launchdManager = nil
    #expect(ProbeExpectation(effectiveUID: 450).mismatches(in: context).isEmpty)
}

@Test func expectationWithoutEffectiveUIDDoesNotDecode() {
    let json = Data(#"{"userName": "_sanjbox_t1"}"#.utf8)
    #expect(throws: DecodingError.self) { try JSONLines.decoder.decode(ProbeExpectation.self, from: json) }
}

@Test func groupsOfInterestCoverRequiredAndForbidden() {
    #expect(zoneExpectation().groupsOfInterest == [20, 80, 701])
}
