import CoreGraphics
import Darwin
import Darwin.membership
import Foundation

/// Identity and session the current process actually runs with.
///
/// Every probe captures this before measuring anything: a probe running with the
/// wrong credentials or in the wrong session produces an invalid measurement,
/// not evidence of isolation (PLAN §Verifikace).
public struct ProbeContext: Codable, Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    public var realUID: UInt32
    public var effectiveUID: UInt32
    public var realGID: UInt32
    public var effectiveGID: UInt32
    public var userName: String?
    /// Groups in the kernel credential (`getgroups`). macOS resolves further
    /// memberships on demand, so `groupMembership` is the authoritative answer.
    public var kernelGroups: [UInt32]
    /// Membership of the effective user in the groups an expectation asks about,
    /// resolved by `mbr_check_membership`. `isMember == nil` means it could not be resolved.
    public var groupMembership: [GroupMembership]
    public var audit: AuditSession?
    public var launchdManager: LaunchdManager?
    /// Window server session of the process; nil when it has none (e.g. a background job).
    public var windowSession: WindowSession?

    public struct GroupMembership: Codable, Equatable, Sendable {
        public var gid: UInt32
        public var isMember: Bool?
    }

    public struct AuditSession: Codable, Equatable, Sendable {
        public var sessionID: Int32
        public var auditUID: UInt32
        public var flags: UInt64
    }

    /// launchd domain manager as reported by `launchctl managername` / `manageruid`
    /// (e.g. "Aqua" for a GUI login session, "Background" for a user domain without GUI).
    public struct LaunchdManager: Codable, Equatable, Sendable {
        public var name: String
        public var uid: UInt32
    }

    public struct WindowSession: Codable, Equatable, Sendable {
        public var userID: UInt32?
        public var userName: String?
        public var auditSessionID: Int32?
        public var onConsole: Bool?
        public var loginDone: Bool?
    }

    public init(
        pid: Int32, parentPID: Int32,
        realUID: UInt32, effectiveUID: UInt32, realGID: UInt32, effectiveGID: UInt32,
        userName: String?, kernelGroups: [UInt32], groupMembership: [GroupMembership],
        audit: AuditSession?, launchdManager: LaunchdManager?, windowSession: WindowSession?
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.realUID = realUID
        self.effectiveUID = effectiveUID
        self.realGID = realGID
        self.effectiveGID = effectiveGID
        self.userName = userName
        self.kernelGroups = kernelGroups
        self.groupMembership = groupMembership
        self.audit = audit
        self.launchdManager = launchdManager
        self.windowSession = windowSession
    }

    /// Captures the context of the calling process.
    /// - Parameter groupsOfInterest: groups whose membership must be resolved authoritatively.
    public static func capture(groupsOfInterest: Set<UInt32> = []) -> ProbeContext {
        let euid = geteuid()
        return ProbeContext(
            pid: getpid(),
            parentPID: getppid(),
            realUID: getuid(),
            effectiveUID: euid,
            realGID: getgid(),
            effectiveGID: getegid(),
            userName: getpwuid(euid).map { String(cString: $0.pointee.pw_name) },
            kernelGroups: queryKernelGroups(),
            groupMembership: groupsOfInterest.sorted().map {
                GroupMembership(gid: $0, isMember: resolveMembership(uid: euid, gid: $0))
            },
            audit: queryAuditSession(),
            launchdManager: queryLaunchdManager(),
            windowSession: queryWindowSession()
        )
    }
}

// MARK: - System queries

private func queryKernelGroups() -> [UInt32] {
    let count = getgroups(0, nil)
    guard count > 0 else { return [] }
    var groups = [gid_t](repeating: 0, count: Int(count))
    let filled = getgroups(count, &groups)
    return filled > 0 ? Array(groups.prefix(Int(filled))) : []
}

private func resolveMembership(uid: uid_t, gid: gid_t) -> Bool? {
    var userUUID = UUID().uuid
    var groupUUID = UUID().uuid
    var result: Int32 = 0
    let status = withUnsafeMutableBytes(of: &userUUID) { user in
        withUnsafeMutableBytes(of: &groupUUID) { group in
            let userPtr = user.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let groupPtr = group.baseAddress!.assumingMemoryBound(to: UInt8.self)
            guard mbr_uid_to_uuid(uid, userPtr) == 0, mbr_gid_to_uuid(gid, groupPtr) == 0 else { return Int32(-1) }
            return mbr_check_membership(userPtr, groupPtr, &result)
        }
    }
    return status == 0 ? result != 0 : nil
}

private func queryAuditSession() -> ProbeContext.AuditSession? {
    var info = auditinfo_addr()
    guard getaudit_addr(&info, Int32(MemoryLayout<auditinfo_addr>.size)) == 0 else { return nil }
    return .init(sessionID: info.ai_asid, auditUID: info.ai_auid, flags: info.ai_flags)
}

private func queryLaunchdManager() -> ProbeContext.LaunchdManager? {
    LaunchctlQuery.capture()
}

private func queryWindowSession() -> ProbeContext.WindowSession? {
    guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
    // Key names verified against CGSessionCopyCurrentDictionary on macOS 27.2.
    return .init(
        userID: (info["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value,
        userName: info["kCGSSessionUserNameKey"] as? String,
        auditSessionID: (info["kCGSSessionAuditIDKey"] as? NSNumber)?.int32Value,
        onConsole: (info["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue,
        loginDone: (info["kCGSessionLoginDoneKey"] as? NSNumber)?.boolValue
    )
}
