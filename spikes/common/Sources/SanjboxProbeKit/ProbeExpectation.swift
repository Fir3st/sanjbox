/// What a probe must be running as before its measurement counts.
///
/// Written per test case *before* the run (GUIDE §7). Every field that is set is checked;
/// `effectiveUID` is mandatory so that an empty expectation can never validate a run.
public struct ProbeExpectation: Codable, Equatable, Sendable {
    public var effectiveUID: UInt32
    public var realUID: UInt32?
    public var effectiveGID: UInt32?
    public var realGID: UInt32?
    public var userName: String?
    /// The effective user must be a member of each of these groups.
    public var requiredGroups: [UInt32]?
    /// The effective user must not be a member of any of these groups (e.g. 20 staff, 80 admin).
    public var forbiddenGroups: [UInt32]?
    public var launchdManagerName: String?
    public var launchdManagerUID: UInt32?
    /// Set to require a window server session owned by this UID.
    public var windowSessionUID: UInt32?
    /// Set to require (true) or forbid (false) the console session.
    public var onConsole: Bool?
    /// Audit sessions the probe must not share, typically the host console session.
    public var forbiddenAuditSessionIDs: [Int32]?

    public init(
        effectiveUID: UInt32, realUID: UInt32? = nil, effectiveGID: UInt32? = nil, realGID: UInt32? = nil,
        userName: String? = nil, requiredGroups: [UInt32]? = nil, forbiddenGroups: [UInt32]? = nil,
        launchdManagerName: String? = nil, launchdManagerUID: UInt32? = nil,
        windowSessionUID: UInt32? = nil, onConsole: Bool? = nil, forbiddenAuditSessionIDs: [Int32]? = nil
    ) {
        self.effectiveUID = effectiveUID
        self.realUID = realUID
        self.effectiveGID = effectiveGID
        self.realGID = realGID
        self.userName = userName
        self.requiredGroups = requiredGroups
        self.forbiddenGroups = forbiddenGroups
        self.launchdManagerName = launchdManagerName
        self.launchdManagerUID = launchdManagerUID
        self.windowSessionUID = windowSessionUID
        self.onConsole = onConsole
        self.forbiddenAuditSessionIDs = forbiddenAuditSessionIDs
    }

    /// Groups whose membership `ProbeContext.capture` must resolve for this expectation.
    public var groupsOfInterest: Set<UInt32> {
        Set((requiredGroups ?? []) + (forbiddenGroups ?? []))
    }

    /// Every way `context` differs from this expectation. Empty means the measurement is valid.
    /// Anything that cannot be verified (unresolved membership, missing session) is a mismatch.
    public func mismatches(in context: ProbeContext) -> [Mismatch] {
        var found: [Mismatch] = []
        func check<T: Equatable>(_ field: String, _ expected: T?, _ actual: T?) {
            guard let expected, expected != actual else { return }
            found.append(Mismatch(field: field, expected: "\(expected)", actual: actual.map { "\($0)" } ?? "none"))
        }

        check("effectiveUID", effectiveUID, context.effectiveUID)
        check("realUID", realUID, context.realUID)
        check("effectiveGID", effectiveGID, context.effectiveGID)
        check("realGID", realGID, context.realGID)
        check("userName", userName, context.userName)
        check("launchdManagerName", launchdManagerName, context.launchdManager?.name)
        check("launchdManagerUID", launchdManagerUID, context.launchdManager?.uid)
        check("windowSessionUID", windowSessionUID, context.windowSession?.userID)
        check("onConsole", onConsole, context.windowSession?.onConsole)

        let membership = Dictionary(
            context.groupMembership.map { ($0.gid, $0.isMember) },
            uniquingKeysWith: { first, _ in first }
        )
        for gid in requiredGroups ?? [] where membership[gid] != .some(true) {
            found.append(Mismatch(field: "requiredGroup \(gid)", expected: "member", actual: describe(membership[gid])))
        }
        for gid in forbiddenGroups ?? [] where membership[gid] != .some(false) {
            found.append(Mismatch(field: "forbiddenGroup \(gid)", expected: "not member", actual: describe(membership[gid])))
        }

        if let forbidden = forbiddenAuditSessionIDs, !forbidden.isEmpty {
            let session = context.audit?.sessionID
            let isAllowed = session.map { !forbidden.contains($0) } ?? false
            if !isAllowed {
                found.append(Mismatch(
                    field: "auditSessionID", expected: "not in \(forbidden)", actual: session.map { "\($0)" } ?? "none"
                ))
            }
        }
        return found
    }
}

public struct Mismatch: Codable, Equatable, Sendable {
    public var field: String
    public var expected: String
    public var actual: String
}

/// `membership` is nil when the group was not captured and `.some(nil)` when it could not be resolved.
private func describe(_ membership: Bool??) -> String {
    switch membership {
    case .none: "not captured"
    case .some(.none): "unresolved"
    case .some(.some(true)): "member"
    case .some(.some(false)): "not member"
    }
}
