import Foundation
import SanjboxProbeKit

let maximumEntries = 1024
let maximumRoots = 32
let maximumReportBytes = 32 * 1024 * 1024
let maximumPathBytes = 4096

struct AuditFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Limits: Codable, Equatable {
    var maxDepth: Int
    var maxEntries: Int
}

struct RootSpec: Codable, Equatable {
    var id: String
    var path: String
    var purpose: String
}

struct Configuration: Codable, Equatable {
    var schema = "sanjbox.host-audit.config.v1"
    var roots: [RootSpec]
    var limits: Limits

    func validate() throws {
        guard schema == "sanjbox.host-audit.config.v1",
              (1...maximumRoots).contains(roots.count),
              (0...32).contains(limits.maxDepth),
              (1...maximumEntries).contains(limits.maxEntries),
              Set(roots.map(\.id)).count == roots.count,
              Set(roots.map(\.path)).count == roots.count else { throw AuditFailure("invalid configuration schema, limits or duplicate roots") }
        for root in roots {
            guard (1...64).contains(root.id.utf8.count),
                  root.id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
                  (1...256).contains(root.purpose.utf8.count), validAbsolutePath(root.path), root.path != "/"
            else { throw AuditFailure("invalid explicit root") }
        }
    }
}

func validAbsolutePath(_ path: String) -> Bool {
    path.hasPrefix("/") && path.utf8.count <= maximumPathBytes && !path.utf8.contains(0)
        && (path == "/" || path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." })
}

func validRelativePath(_ path: String) -> Bool {
    path == "." || (!path.hasPrefix("/") && path.utf8.count <= maximumPathBytes && !path.utf8.contains(0)
        && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." })
}

struct IdentityInput: Codable {
    var schema = "sanjbox.host-audit.expect.v1"
    var expectation: ProbeExpectation
    var auditSessionID: Int32

    func validate() throws {
        guard schema == "sanjbox.host-audit.expect.v1", expectation.realUID != nil,
              expectation.realGID != nil, expectation.effectiveGID != nil,
              expectation.launchdManagerName != nil, expectation.launchdManagerUID != nil,
              expectation.requiredGroups != nil, expectation.forbiddenGroups != nil
        else { throw AuditFailure("expectation must specify real/effective UID/GID, both group lists, launchd manager name/UID and auditSessionID") }
    }
}

struct IdentityMismatch: Codable {
    var field: String
    var expected: String
    var actual: String
}

struct IdentityReport: Codable {
    var context: ProbeContext
    var mismatches: [IdentityMismatch]
    var valid: Bool
}

struct StatMetadata: Codable, Equatable {
    var device: Int32
    var inode: UInt64
    var kind: String
    var mode: UInt16
    var uid: UInt32
    var gid: UInt32
    var flags: UInt32
    var links: UInt16
    var changeSeconds: Int64
    var changeNanoseconds: Int64
}

struct ACLEntry: Codable, Equatable {
    var principalUUID: String
    var tag: UInt32
    var permissions: UInt64
    var flags: [UInt32]
}

struct ACLMetadata: Codable, Equatable {
    /// observed, absent, error, unsupported, skipped-special-node, skipped-symlink
    var status: String
    var entries: [ACLEntry] = []
    var flags: [UInt32] = []
    var errorNumber: Int32?
    var comparable: Bool { status == "observed" || status == "absent" }
}

struct MountMetadata: Codable, Equatable {
    var filesystemType: String
    var filesystemID: [Int32]
    var flags: UInt32
    /// No device/source name or system-wide mount list is collected.
    var local: Bool
    var readOnly: Bool
    var ignoresOwnership: Bool
}

struct Entry: Codable, Equatable {
    var path: String
    /// observed, missing, inaccessible, changed, skipped
    var status: String
    var stat: StatMetadata?
    var acl: ACLMetadata?
    /// Obtained from this node's descriptor only, never guessed from a pathname.
    var mount: MountMetadata?
    /// not-directory, complete, pending, depth-limit, entry-limit, mount-boundary,
    /// nonlocal-mount, inaccessible, changed, unreadable-name
    var listing: String
    var errorNumber: Int32?
}

struct Gap: Codable, Equatable {
    var path: String
    /// metadata or subtree
    var scope: String
    var reason: String
}

struct RootReport: Codable {
    var root: RootSpec
    var entries: [Entry]
    var gaps: [Gap]
    var enumerationComplete: Bool
    var metadataComplete: Bool
}

struct DriftEvent: Codable, Equatable {
    var rootID: String
    var path: String?
    var kind: String
    var fields: [String] = []
}

struct Drift: Codable {
    var compared: Bool
    var events: [DriftEvent]
    var limitation = "A missing observation is not a deletion. Added/absent observations require a completed parent listing or an explicit missing root. This is a non-atomic metadata comparison, not an access proof."
}

struct Snapshot: Codable {
    var schema = "sanjbox.host-audit.report.v1"
    var generatedAt: String
    var identity: IdentityReport
    var configuration: Configuration
    var roots: [RootReport]
    var drift: Drift
    var limitations = [
        "Only explicitly configured roots and reported entries were inspected; all other host paths and mounts are outside scope.",
        "Metadata snapshot is not proof of effective access or isolation. Ancestor permissions/ACLs, TCC, service-mediated access, mount policy and TOCTOU are not resolved.",
        "Symlink targets, file contents, xattrs/resource forks, credentials, Keychains, environment and databases are never read. Known special nodes are not opened or contacted; stat/open races are rejected after a nonblocking metadata-only open when identities differ.",
        "Mount data is descriptor-scoped. No system-wide mount list, source/device names, mount attachments or new-mount protection is provided.",
        "Entry/depth/size bounds do not guarantee wall-clock bounds for a blocking kernel metadata call. Nonlocal filesystems are not traversed.",
        "The scan is not atomic: descriptor pinning and before/after checks detect some races only; concurrent changes may remain unobserved. No permission, ACL or mount is changed."
    ]

    func validateBaseline() throws {
        try configuration.validate()
        guard schema == "sanjbox.host-audit.report.v1", identity.valid,
              roots.map(\.root) == configuration.roots,
              roots.reduce(0, { $0 + $1.entries.count }) <= maximumEntries,
              roots.allSatisfy({ Set($0.entries.map(\.path)).count == $0.entries.count })
        else { throw AuditFailure("invalid baseline schema, identity, roots or entry count") }
        for root in roots {
            guard root.entries.allSatisfy({ validRelativePath($0.path) && ($0.acl?.entries.count ?? 0) <= 128 }),
                  root.gaps.count <= 3 * maximumEntries + 1,
                  root.gaps.allSatisfy({ validRelativePath($0.path) }) else { throw AuditFailure("invalid baseline paths or metadata bounds") }
        }
    }
}
