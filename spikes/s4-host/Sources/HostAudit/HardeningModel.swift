import Darwin
import Foundation

/// B2 intentionally implements one operation, with no recursive or ACL mutations.
struct HardeningPlan: Codable {
    var schema = "sanjbox.host-harden.plan.v1"
    var roots: [String]
    var mode: UInt16 = 0o700

    func validate() throws {
        guard schema == "sanjbox.host-harden.plan.v1", mode == 0o700,
              (1...16).contains(roots.count), Set(roots).count == roots.count,
              roots.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 })
        else { throw AuditFailure("invalid bounded hardening plan; only 1...16 explicit root IDs and mode 448 (0700) are supported") }
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
        "Only explicit owned directories on local writable APFS without ACL entries/flags are supported; only mode 0700 is installed. No recursive, ACL, file, socket, mount, user or system changes.",
        "Requires a quiescent trusted host namespace. Descriptor pinning and comparisons detect some races; chmod has no atomic compare-and-swap. A concurrent change in the final check-to-chmod interval can be overwritten or a renamed pinned inode changed. Detected post-operation races remain conflicts, never automatically rolled back.",
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
