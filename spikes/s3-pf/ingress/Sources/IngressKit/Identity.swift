import CoreGraphics
import Darwin
import Darwin.membership
import Foundation
import SanjboxProbeKit
import Security

public struct Identity: Codable, Equatable, Sendable {
    public var realUID: UInt32
    public var effectiveUID: UInt32
    public var realGID: UInt32
    public var effectiveGID: UInt32
    public var kernelGroups: [UInt32]
    public var requiredGroups: [UInt32]
    public var forbiddenGroups: [UInt32]
    public var auditSessionID: Int32
    public var auditUID: UInt32
    public var auditFlags: UInt64
    public var managerName: String
    public var managerUID: UInt32
    public var windowUID: UInt32?
    public var windowAuditSessionID: Int32?
    public var onConsole: Bool?
    public var loginDone: Bool?

    static let shape: Shape = .object([
        "realUID": .scalar, "effectiveUID": .scalar, "realGID": .scalar, "effectiveGID": .scalar,
        "kernelGroups": .array(.scalar), "requiredGroups": .array(.scalar), "forbiddenGroups": .array(.scalar),
        "auditSessionID": .scalar, "auditUID": .scalar, "auditFlags": .scalar,
        "managerName": .scalar, "managerUID": .scalar, "windowUID": .scalar,
        "windowAuditSessionID": .scalar, "onConsole": .scalar, "loginDone": .scalar
    ])
    public static func decode(_ data: Data) throws -> Identity {
        let value = try strictDecode(Self.self, data: data, shape: shape)
        try value.validate(); return value
    }
    public func validate() throws {
        for groups in [kernelGroups, requiredGroups, forbiddenGroups] {
            guard groups.count <= 64, groups == groups.sorted(), Set(groups).count == groups.count else {
                throw IngressError("groups must be sorted, unique, at most 64")
            }
        }
        guard Set(requiredGroups).isDisjoint(with: forbiddenGroups),
              ["Aqua", "Background", "System", "LoginWindow"].contains(managerName), auditSessionID >= 0,
              [windowUID != nil, windowAuditSessionID != nil, onConsole != nil, loginDone != nil].allSatisfy({ $0 }) ||
                [windowUID == nil, windowAuditSessionID == nil, onConsole == nil, loginDone == nil].allSatisfy({ $0 })
        else { throw IngressError("invalid identity expectation") }
    }
    var commonExpectation: ProbeExpectation {
        .init(effectiveUID: effectiveUID, realUID: realUID, effectiveGID: effectiveGID, realGID: realGID,
              requiredGroups: requiredGroups, forbiddenGroups: forbiddenGroups,
              launchdManagerName: managerName, launchdManagerUID: managerUID, windowSessionUID: windowUID, onConsole: onConsole)
    }
    init(context: ProbeContext, required: [UInt32], forbidden: [UInt32]) throws {
        guard let audit = context.audit, let manager = context.launchdManager else { throw IngressError("missing audit/bootstrap identity") }
        realUID = context.realUID; effectiveUID = context.effectiveUID
        realGID = context.realGID; effectiveGID = context.effectiveGID
        kernelGroups = context.kernelGroups.sorted(); requiredGroups = required; forbiddenGroups = forbidden
        auditSessionID = audit.sessionID; auditUID = audit.auditUID; auditFlags = audit.flags
        managerName = manager.name; managerUID = manager.uid
        windowUID = context.windowSession?.userID; windowAuditSessionID = context.windowSession?.auditSessionID
        onConsole = context.windowSession?.onConsole; loginDone = context.windowSession?.loginDone
        try validate()
    }
}

/// Own metadata only. Fixed launchctl queries use bounded child lifetimes and finite output.
/// Uses common public models/validator; common capture() itself has unbounded subprocess I/O.
public enum OwnIdentity {
    public static func capture(expected: Identity? = nil) throws -> Identity {
        let euid = geteuid()
        let count = getgroups(0, nil)
        guard count >= 0, count <= 64 else { throw IngressError("getgroups unavailable/out of bounds") }
        var groups = [gid_t](repeating: 0, count: Int(count))
        let filled = getgroups(count, &groups)
        guard filled == count else { throw IngressError("groups changed during capture") }
        var audit = auditinfo_addr()
        guard getaudit_addr(&audit, Int32(MemoryLayout<auditinfo_addr>.size)) == 0 else { throw IngressError("audit unavailable") }
        let name = try manager("managername")
        guard let uid = UInt32(try manager("manageruid")) else { throw IngressError("invalid manager UID") }
        let info = CGSessionCopyCurrentDictionary() as? [String: Any]
        let window: ProbeContext.WindowSession? = try info.map {
            try commonValue(["userID": $0["kCGSSessionUserIDKey"] ?? NSNull(), "userName": NSNull(),
                "auditSessionID": $0["kCGSSessionAuditIDKey"] ?? NSNull(), "onConsole": $0["kCGSSessionOnConsoleKey"] ?? NSNull(),
                "loginDone": $0["kCGSessionLoginDoneKey"] ?? NSNull()], as: ProbeContext.WindowSession.self)
        }
        let interest = expected?.commonExpectation.groupsOfInterest ?? []
        let membership: [ProbeContext.GroupMembership] = try interest.sorted().map { gid in
            var user = UUID().uuid; var group = UUID().uuid; var result: Int32 = 0
            let status = withUnsafeMutableBytes(of: &user) { u in
                withUnsafeMutableBytes(of: &group) { g -> Int32 in
                    let up = u.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let gp = g.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    guard mbr_uid_to_uuid(euid, up) == 0, mbr_gid_to_uuid(gid, gp) == 0 else { return -1 }
                    return mbr_check_membership(up, gp, &result)
                }
            }
            return try commonValue(["gid": gid, "isMember": status == 0 ? (result != 0) as Any : NSNull()], as: ProbeContext.GroupMembership.self)
        }
        let context = ProbeContext(pid: getpid(), parentPID: getppid(), realUID: getuid(), effectiveUID: euid,
            realGID: getgid(), effectiveGID: getegid(), userName: nil, kernelGroups: groups,
            groupMembership: membership, audit: try commonValue(["sessionID": audit.ai_asid, "auditUID": audit.ai_auid, "flags": audit.ai_flags], as: ProbeContext.AuditSession.self),
            launchdManager: try commonValue(["name": name, "uid": uid], as: ProbeContext.LaunchdManager.self), windowSession: window)
        let actual = try Identity(context: context, required: expected?.requiredGroups ?? [], forbidden: expected?.forbiddenGroups ?? [])
        if let expected {
            guard expected == actual, expected.commonExpectation.mismatches(in: context).isEmpty else {
                throw IngressError("invalid measurement: exact identity/session or membership mismatch; no sockets opened")
            }
        }
        return actual
    }
    // Nested common model initializers are internal; Codable is its public construction API.
    private static func commonValue<T: Decodable>(_ value: [String: Any], as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
    private static func manager(_ command: String) throws -> String {
        var disposition = sigaction()
        guard sigaction(SIGCHLD, nil, &disposition) == 0,
              unsafeBitCast(disposition.__sigaction_u.__sa_handler, to: UInt.self) == unsafeBitCast(SIG_DFL, to: UInt.self),
              disposition.sa_flags & SA_NOCLDWAIT == 0 else { throw IngressError("SIGCHLD must retain exclusive child ownership") }
        var pipes: [Int32] = [-1, -1]
        guard pipe(&pipes) == 0 else { throw IngressError("identity pipe failed") }
        defer { close(pipes[0]); if pipes[1] >= 0 { close(pipes[1]) } }
        guard fcntl(pipes[0], F_SETFL, O_NONBLOCK) == 0 else { throw IngressError("identity pipe nonblock failed") }
        let null = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard null >= 0 else { throw IngressError("identity stderr setup failed") }
        defer { close(null) }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw IngressError("identity spawn actions failed") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, pipes[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, pipes[1]) == 0 else { throw IngressError("identity spawn I/O setup failed") }
        let strings = ["/bin/launchctl", command].map { $0.withCString { strdup($0)! } }
        let environment = ["PATH=/usr/bin:/bin", "LC_ALL=C"].map { $0.withCString { strdup($0)! } }
        defer { strings.forEach { free($0) }; environment.forEach { free($0) } }
        var argv: [UnsafeMutablePointer<CChar>?] = strings + [nil]
        var env: [UnsafeMutablePointer<CChar>?] = environment + [nil]
        var pid: pid_t = 0
        guard posix_spawn(&pid, "/bin/launchctl", &actions, nil, &argv, &env) == 0 else { throw IngressError("fixed identity child spawn failed") }
        close(pipes[1]); pipes[1] = -1
        // SIG_DFL + exclusive waitpid: an exited child stays ours until reaped. Never signal after ECHILD.
        var owned = true
        var status: Int32 = 0
        func reap() throws -> Bool {
            let rc = waitpid(pid, &status, WNOHANG)
            if rc == pid { owned = false; return true }
            if rc == 0 || (rc < 0 && errno == EINTR) { return false }
            owned = false
            throw IngressError("identity child ownership lost; no signal sent")
        }
        func stop() throws {
            guard owned else { return }
            if try reap() { return }
            guard kill(pid, SIGTERM) == 0 || errno == ESRCH else { throw IngressError("cannot terminate own child") }
            let grace = ProcessInfo.processInfo.systemUptime + 0.2
            while ProcessInfo.processInfo.systemUptime < grace { if try reap() { return }; usleep(5_000) }
            if try reap() { return }
            guard owned, kill(pid, SIGKILL) == 0 || errno == ESRCH else { throw IngressError("cannot kill own child") }
            let end = ProcessInfo.processInfo.systemUptime + 0.5
            while ProcessInfo.processInfo.systemUptime < end { if try reap() { return }; usleep(5_000) }
            throw IngressError("own identity child did not reap within cleanup budget")
        }
        var output = Data(); var buffer = [UInt8](repeating: 0, count: 129)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        do {
            while true {
                let n = read(pipes[0], &buffer, buffer.count)
                if n > 0 { output.append(contentsOf: buffer.prefix(n)) }
                if n < 0 && ![EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { throw IngressError("identity pipe read failed") }
                guard output.count <= 128 else { throw IngressError("identity child output oversized") }
                if try reap() { break }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw IngressError("identity child deadline exceeded") }
                usleep(5_000)
            }
            // Drain the finite remainder after the child was reaped.
            while true {
                let n = read(pipes[0], &buffer, buffer.count)
                if n <= 0 { break }
                output.append(contentsOf: buffer.prefix(n))
                guard output.count <= 128 else { throw IngressError("identity child output oversized") }
            }
            guard status == 0, !output.isEmpty else { throw IngressError("bootstrap query failed") }
        } catch {
            try stop()
            throw error
        }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

public struct SignatureReport: Codable, Equatable, Sendable {
    public var valid: Bool
    public var hardenedRuntime: Bool
    public var getTaskAllowAbsent: Bool
    public var metadataComplete: Bool
    static let shape: Shape = .object(["valid": .scalar, "hardenedRuntime": .scalar, "getTaskAllowAbsent": .scalar, "metadataComplete": .scalar])
    public var permitsLive: Bool { valid && hardenedRuntime && getTaskAllowAbsent && metadataComplete }
    // Pure policy seam: tests need no prohibited-entitlement binaries.
    public static func inspect(valid: Bool, flags: UInt32?, rawEntitlementsPresent: Bool,
                               entitlements: [String: Any]?) -> SignatureReport {
        let complete = flags != nil && (!rawEntitlementsPresent || entitlements != nil)
        return .init(valid: valid, hardenedRuntime: flags.map { $0 & 0x10000 != 0 } ?? false,
            getTaskAllowAbsent: complete && entitlements?["com.apple.security.get-task-allow"] == nil && entitlements?["get-task-allow"] == nil,
            metadataComplete: complete)
    }
    public static func own() throws -> SignatureReport {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw IngressError("own code identity unavailable") }
        // CSCommon.h kSecCSNoNetworkAccess (Swift imports this as an option member).
        let noNetwork = SecCSFlags(rawValue: 1 << 29)
        let valid = SecCodeCheckValidity(code, noNetwork, nil) == errSecSuccess
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { throw IngressError("own static code unavailable") }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { throw IngressError("own signing metadata unavailable") }
        return inspect(valid: valid, flags: (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value,
            rawEntitlementsPresent: dictionary[kSecCodeInfoEntitlements as String] != nil || dictionary[kSecCodeInfoEntitlementsDict as String] != nil,
            entitlements: dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any])
    }
}
