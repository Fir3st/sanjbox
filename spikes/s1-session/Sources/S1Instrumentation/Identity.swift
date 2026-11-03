import Foundation
import SanjboxProbeKit

/// Small local prerequisite wrapper: common supplies credentials/bootstrap matching;
/// exact process AND window ASID and audit UID are additionally required here.
public struct IdentityExpectation: Codable, Equatable, Sendable {
    public var uid: UInt32
    public var gid: UInt32
    public var kernelGroups: [UInt32]
    public var requiredGroups: [UInt32]
    public var forbiddenGroups: [UInt32]
    public var auditSessionID: Int32
    public var onConsole: Bool
    public func validate() throws {
        try require(uid > 0 && auditSessionID > 0, "root or unspecified audit session unsupported")
        for groups in [kernelGroups, requiredGroups, forbiddenGroups] {
            try require(groups.count <= 64 && Set(groups).count == groups.count, "duplicate or excessive groups")
        }
        try require(!kernelGroups.isEmpty && !requiredGroups.isEmpty, "explicit kernel and required groups mandatory")
        try require(Set(requiredGroups).isDisjoint(with: forbiddenGroups), "contradictory group expectation")
    }
    var common: ProbeExpectation {
        ProbeExpectation(effectiveUID: uid, realUID: uid, effectiveGID: gid, realGID: gid,
            requiredGroups: requiredGroups, forbiddenGroups: forbiddenGroups,
            launchdManagerName: "Aqua", launchdManagerUID: uid, windowSessionUID: uid, onConsole: onConsole)
    }
    public func check(_ context: ProbeContext) -> IdentityCheck {
        var reasons = common.mismatches(in: context).map { $0.field }
        if context.kernelGroups.sorted() != kernelGroups.sorted() { reasons.append("kernelGroups") }
        if context.audit?.sessionID != auditSessionID { reasons.append("exactAuditSessionID") }
        if context.audit?.auditUID != uid { reasons.append("auditUID") }
        if context.windowSession?.auditSessionID != auditSessionID { reasons.append("exactWindowAuditSessionID") }
        if context.windowSession?.loginDone != true { reasons.append("loginDone") }
        return IdentityCheck(uid: context.effectiveUID, gid: context.effectiveGID,
            realUID: context.realUID, realGID: context.realGID, kernelGroups: context.kernelGroups,
            auditSessionID: context.audit?.sessionID, windowAuditSessionID: context.windowSession?.auditSessionID,
            onConsole: context.windowSession?.onConsole, auditUID: context.audit?.auditUID,
            managerName: context.launchdManager?.name, managerUID: context.launchdManager?.uid,
            windowUID: context.windowSession?.userID, loginDone: context.windowSession?.loginDone,
            groupMembership: context.groupMembership, mismatches: reasons)
    }
    public func capture() -> IdentityCheck { check(.capture(groupsOfInterest: common.groupsOfInterest)) }
}
/// No username, process command line, process environment or inventory in new raw records.
public struct IdentityCheck: Codable, Equatable, Sendable {
    public var uid: UInt32
    public var gid: UInt32
    public var realUID: UInt32
    public var realGID: UInt32
    public var kernelGroups: [UInt32]
    public var auditSessionID: Int32?
    public var windowAuditSessionID: Int32?
    public var onConsole: Bool?
    public var auditUID: UInt32?
    public var managerName: String?
    public var managerUID: UInt32?
    public var windowUID: UInt32?
    public var loginDone: Bool?
    public var groupMembership: [ProbeContext.GroupMembership]
    public var mismatches: [String]
    public var valid: Bool { mismatches.isEmpty }
    func matches(_ expected: IdentityExpectation) -> Bool {
        let membership = Dictionary(groupMembership.map { ($0.gid, $0.isMember) }, uniquingKeysWith: { first, _ in first })
        return auditUID == expected.uid && managerName == "Aqua" && managerUID == expected.uid &&
        windowUID == expected.uid && loginDone == true &&
        Set(groupMembership.map(\.gid)).count == groupMembership.count &&
        expected.requiredGroups.allSatisfy { membership[$0] == .some(true) } &&
        expected.forbiddenGroups.allSatisfy { membership[$0] == .some(false) } &&
        valid && uid == expected.uid && realUID == expected.uid && gid == expected.gid && realGID == expected.gid &&
        kernelGroups.sorted() == expected.kernelGroups.sorted() && auditSessionID == expected.auditSessionID &&
        windowAuditSessionID == expected.auditSessionID && onConsole == expected.onConsole
    }
}
