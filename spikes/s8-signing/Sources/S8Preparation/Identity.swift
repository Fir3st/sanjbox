import CoreGraphics
import Darwin
import Darwin.membership
import Foundation
import SanjboxProbeKit

public enum S8Error: Error, CustomStringConvertible {
    case refused(String)
    public var description: String { switch self { case .refused(let reason): return reason } }
}

/// Required fields are deliberately stronger than common's optional ProbeExpectation.
/// A diagnostic observation is only a candidate; the operator must preregister it.
public struct S8Expectation: Codable, Equatable, Sendable {
    public var realUID: UInt32
    public var effectiveUID: UInt32
    public var realGID: UInt32
    public var effectiveGID: UInt32
    public var userName: String
    public var kernelGroups: [UInt32]
    public var requiredGroups: [UInt32]
    public var forbiddenGroups: [UInt32]
    public var auditSessionID: Int32
    public var auditUID: UInt32
    public var launchdManagerName: String
    public var launchdManagerUID: UInt32
    /// All optional WindowSession properties must be known when a session is expected.
    public var windowSession: ProbeContext.WindowSession?
    public var requiresWindowSession: Bool

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(realUID, forKey: .realUID); try c.encode(effectiveUID, forKey: .effectiveUID)
        try c.encode(realGID, forKey: .realGID); try c.encode(effectiveGID, forKey: .effectiveGID)
        try c.encode(userName, forKey: .userName); try c.encode(kernelGroups, forKey: .kernelGroups)
        try c.encode(requiredGroups, forKey: .requiredGroups); try c.encode(forbiddenGroups, forKey: .forbiddenGroups)
        try c.encode(auditSessionID, forKey: .auditSessionID); try c.encode(auditUID, forKey: .auditUID)
        try c.encode(launchdManagerName, forKey: .launchdManagerName); try c.encode(launchdManagerUID, forKey: .launchdManagerUID)
        try c.encode(requiresWindowSession, forKey: .requiresWindowSession)
        // Optional.encode emits null; encodeIfPresent would omit a required schema key.
        try c.encode(windowSession, forKey: .windowSession)
    }

    public init(candidate c: ProbeContext) throws {
        guard let name = c.userName, let audit = c.audit, audit.sessionID > 0,
              audit.auditUID != UInt32.max, let manager = c.launchdManager else {
            throw S8Error.refused("identity is incomplete; cannot propose expectation")
        }
        realUID = c.realUID; effectiveUID = c.effectiveUID
        realGID = c.realGID; effectiveGID = c.effectiveGID; userName = name
        kernelGroups = c.kernelGroups.sorted(); requiredGroups = []; forbiddenGroups = []
        auditSessionID = audit.sessionID; auditUID = audit.auditUID
        launchdManagerName = manager.name; launchdManagerUID = manager.uid
        windowSession = c.windowSession; requiresWindowSession = c.windowSession != nil
    }

    public func configurationIssues() -> [String] {
        var issues: [String] = []
        if realUID != effectiveUID || realGID != effectiveGID || effectiveUID == 0 {
            issues.append("non-root, non-setuid/setgid credentials required")
        }
        if auditSessionID <= 0 || auditUID == UInt32.max || userName.isEmpty || launchdManagerName.isEmpty {
            issues.append("explicit known audit and bootstrap identity required")
        }
        if kernelGroups.isEmpty || Set(kernelGroups).count != kernelGroups.count {
            issues.append("nonempty unique kernel group set required")
        }
        if !Set(requiredGroups).isDisjoint(with: forbiddenGroups) { issues.append("contradictory groups") }
        if requiresWindowSession {
            guard let w = windowSession, w.userID != nil, w.userName != nil,
                  let session = w.auditSessionID, session > 0, w.onConsole != nil, w.loginDone != nil else {
                return issues + ["complete expected window session required"]
            }
        } else if windowSession != nil { issues.append("unexpected window expectation") }
        return issues
    }

    public func mismatches(in c: ProbeContext) -> [String] {
        let base = ProbeExpectation(
            effectiveUID: effectiveUID, realUID: realUID, effectiveGID: effectiveGID, realGID: realGID,
            userName: userName, requiredGroups: requiredGroups, forbiddenGroups: forbiddenGroups,
            launchdManagerName: launchdManagerName, launchdManagerUID: launchdManagerUID
        )
        var issues = configurationIssues() + base.mismatches(in: c).map(\.field)
        if c.kernelGroups.sorted() != kernelGroups.sorted() { issues.append("kernelGroups") }
        if c.audit?.sessionID != auditSessionID { issues.append("auditSessionID") }
        if c.audit?.auditUID != auditUID { issues.append("auditUID") }
        if c.windowSession != windowSession { issues.append("windowSession") }
        return issues
    }
}

/// Same public ProbeContext representation, local bounded launchctl calls instead of the
/// common collector's unbounded Process waits. No service registration or bootstrap call.
public func captureIdentity(groups: Set<UInt32> = []) throws -> ProbeContext {
    let count = getgroups(0, nil)
    guard count > 0, count <= 256 else { throw S8Error.refused("unavailable or excessive group list") }
    var gids = [gid_t](repeating: 0, count: Int(count))
    let actual = getgroups(count, &gids)
    guard actual == count else { throw S8Error.refused("group list changed") }
    var auditInfo = auditinfo_addr()
    let auditOK = getaudit_addr(&auditInfo, Int32(MemoryLayout<auditinfo_addr>.size)) == 0
    let managerName = try BoundedTool.run("/bin/launchctl", ["managername"], seconds: 2)
    let managerUID = try BoundedTool.run("/bin/launchctl", ["manageruid"], seconds: 2)
    let name = String(decoding: managerName, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let uid = UInt32(String(decoding: managerUID, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    // The common nested Codable types have no public memberwise initializers. Construct
    // their public wire representation locally without changing the shared package.
    func decoded<T: Decodable>(_ type: T.Type, _ fields: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: fields))
    }
    let window: ProbeContext.WindowSession?
    if let w = CGSessionCopyCurrentDictionary() as? [String: Any] {
        window = try decoded(ProbeContext.WindowSession.self, [
            "userID": w["kCGSSessionUserIDKey"] ?? NSNull(), "userName": w["kCGSSessionUserNameKey"] ?? NSNull(),
            "auditSessionID": w["kCGSSessionAuditIDKey"] ?? NSNull(), "onConsole": w["kCGSSessionOnConsoleKey"] ?? NSNull(),
            "loginDone": w["kCGSessionLoginDoneKey"] ?? NSNull()])
    } else { window = nil }
    let memberships = try groups.sorted().map { gid -> ProbeContext.GroupMembership in
        var userUUID = UUID().uuid; var groupUUID = UUID().uuid; var member: Int32 = 0
        let result = withUnsafeMutableBytes(of: &userUUID) { user in
            withUnsafeMutableBytes(of: &groupUUID) { group in
                let u = user.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let g = group.baseAddress!.assumingMemoryBound(to: UInt8.self)
                guard mbr_uid_to_uuid(geteuid(), u) == 0, mbr_gid_to_uuid(gid, g) == 0 else { return Int32(-1) }
                return mbr_check_membership(u, g, &member)
            }
        }
        return try decoded(ProbeContext.GroupMembership.self, ["gid": gid, "isMember": result == 0 ? (member != 0) as Any : NSNull()])
    }
    return .init(pid: getpid(), parentPID: getppid(), realUID: getuid(), effectiveUID: geteuid(),
                 realGID: getgid(), effectiveGID: getegid(), userName: getpwuid(geteuid()).map { String(cString: $0.pointee.pw_name) },
                 kernelGroups: gids, groupMembership: memberships,
                 audit: auditOK ? try decoded(ProbeContext.AuditSession.self, ["sessionID": auditInfo.ai_asid, "auditUID": auditInfo.ai_auid, "flags": auditInfo.ai_flags]) : nil,
                 launchdManager: try uid.flatMap { name.isEmpty ? nil : try decoded(ProbeContext.LaunchdManager.self, ["name": name, "uid": $0]) }, windowSession: window)
}
