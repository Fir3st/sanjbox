import Darwin
import Foundation

/// v1 changes mode only. v2 prepends explicit, non-inheritable deny ACEs only.
struct HardeningPlan: Codable {
    var schema = "sanjbox.host-harden.plan.v1"
    var roots: [String]
    var mode: UInt16? = 0o700
    var deny: [ACLDeny]?

    init(schema: String = "sanjbox.host-harden.plan.v1", roots: [String], mode: UInt16? = 0o700, deny: [ACLDeny]? = nil) {
        self.schema = schema; self.roots = roots; self.mode = mode; self.deny = deny
    }
    init(from decoder: Decoder) throws {
        try rejectUnknownPlanKeys(decoder, allowed: ["schema", "roots", "mode", "deny"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(String.self, forKey: .schema)
        roots = try c.decode([String].self, forKey: .roots)
        mode = try c.decodeIfPresent(UInt16.self, forKey: .mode)
        deny = try c.decodeIfPresent([ACLDeny].self, forKey: .deny)
    }

    func validate() throws {
        guard (1...16).contains(roots.count), Set(roots).count == roots.count,
              roots.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 })
        else { throw AuditFailure("invalid bounded hardening plan: require 1...16 unique root IDs") }
        if schema == "sanjbox.host-harden.plan.v1", mode == 0o700, deny == nil { return }
        guard schema == "sanjbox.host-harden.plan.v2", mode == nil, let deny else {
            throw AuditFailure("v1 requires mode 448 only; v2 requires deny only (no combined mode/ACL operation)")
        }
        try validateDenies(deny)
    }
}

struct HardenStamp: Codable, Equatable {
    var stat: StatMetadata
    var birthSeconds: Int64
    var birthNanoseconds: Int64
    var generation: UInt32
    var acl: ACLMetadata
    var mount: MountMetadata

    func replacingMode(_ mode: UInt16, change: StatMetadata) -> HardenStamp {
        var result = self
        result.stat.mode = mode
        result.stat.changeSeconds = change.changeSeconds
        result.stat.changeNanoseconds = change.changeNanoseconds
        return result
    }
    /// Directory ctime/link count may change when siblings are created. The ancestor guard
    /// compares object identity and protection, not a claim of immutable directory contents.
    var ancestorGuard: HardenStamp {
        var result = self
        result.stat.changeSeconds = 0
        result.stat.changeNanoseconds = 0
        result.stat.links = 0
        return result
    }
}

struct HardenChange: Codable, Equatable {
    var rootID: String
    var path: String
    var before: HardenStamp
    var ancestors: [HardenStamp]
    var mode: UInt16 = 0o700
    /// Absent in legacy journals. Non-nil selects an ACL-only operation, preserving mode.
    var acl: ACLMetadata?

    func result(from stamp: HardenStamp, restoring: Bool = false, observed: StatMetadata) -> HardenStamp {
        var result = stamp.replacingMode(restoring ? before.stat.mode : mode, change: observed)
        if let acl { result.acl = restoring ? before.acl : acl }
        return result
    }
}

struct HardenManifest: Codable {
    var schema = "sanjbox.host-harden.journal.v1"
    var transaction: String
    var bootSession: String
    var ownerUID: UInt32
    var statePath: String
    var stateIdentity: HardenStamp
    var stateAncestors: [HardenStamp]
    var changes: [HardenChange]
}

struct HardenEvent: Codable {
    var schema = "sanjbox.host-harden.event.v1"
    var transaction: String
    var index: Int
    var phase: String
    var before: HardenStamp
    var after: HardenStamp?
}

struct HardenResult: Codable {
    var schema = "sanjbox.host-harden.result.v1"
    var operation: String
    var dryRun: Bool
    var statePath: String
    var changes: [HardenChange]
    var status: String
    var detail: String
    var limitations = [
        "Only explicit owned directories on local writable APFS. v1 installs mode 0700 with empty ACL; v2 prepends non-inheritable deny ACEs and preserves mode and existing ACL order. Ancestors/journal require empty ACL. No recursive, file, socket, mount, user or system changes; no descendant ACL ownership.",
        "Requires a quiescent trusted host namespace. Descriptor pinning and comparisons detect some races; metadata setters have no atomic compare-and-swap. A concurrent change in the final check-to-set interval can be overwritten or a renamed pinned inode changed. Detected post-operation races remain conflicts, never automatically rolled back.",
        "Durable intent without durable completion is ambiguous, even if current mode matches. Uninstall refuses automatic recovery. Reboot, metadata drift, identity/ancestor changes and journal corruption require manual review.",
        "This is bounded preparation for RB-09/10, not continuous R2 enforcement, a host compatibility result, a crash-atomic transaction or an S4 gate verdict."
    ]
}

struct HardenConflict: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Internal deterministic test hooks; no environment variable/CLI injection or subprocess hooks.
struct HardenHooks {
    var beforeFinalCheck: (Int, String) throws -> Void = { _, _ in }
    var afterMutation: (Int, String) throws -> Void = { _, _ in }
}

func emptyACL(_ acl: ACLMetadata) -> Bool {
    acl.comparable && acl.entries.isEmpty && acl.flags.isEmpty
}

func bootSession() throws -> String {
    var bytes = [CChar](repeating: 0, count: 128)
    var size = bytes.count
    guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0,
          size > 1, size <= bytes.count else { throw AuditFailure("boot session identity unavailable") }
    let value = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    guard UUID(uuidString: value) != nil else { throw AuditFailure("invalid boot session identity") }
    return value
}
