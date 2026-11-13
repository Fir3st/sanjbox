import Darwin
import Darwin.membership
import Foundation

/// UUIDs identify principals; names are never guessed. Reopen-sensitive rights require
/// an authoritative membership lookup to avoid denying the installing owner's metadata access.
struct ACLDeny: Codable, Equatable {
    var principalUUID: String
    var permissions: [String]

    init(principalUUID: String, permissions: [String]) {
        self.principalUUID = principalUUID
        self.permissions = permissions
    }
    init(from decoder: Decoder) throws {
        try rejectUnknownPlanKeys(decoder, allowed: ["principalUUID", "permissions"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        principalUUID = try c.decode(String.self, forKey: .principalUUID)
        permissions = try c.decode([String].self, forKey: .permissions)
    }
    var entry: ACLEntry {
        .init(principalUUID: principalUUID, tag: ACL_EXTENDED_DENY.rawValue,
              permissions: permissions.reduce(0) { $0 | (denyPermissions[$1] ?? 0) }, flags: [])
    }
}

// No security/ownership denies and no new inheritance: undo never owns descendant ACEs.
let denyPermissions: [String: UInt64] = [
    "list": UInt64(ACL_LIST_DIRECTORY.rawValue), "search": UInt64(ACL_SEARCH.rawValue),
    "add_file": UInt64(ACL_ADD_FILE.rawValue), "add_subdirectory": UInt64(ACL_ADD_SUBDIRECTORY.rawValue),
    "delete": UInt64(ACL_DELETE.rawValue), "delete_child": UInt64(ACL_DELETE_CHILD.rawValue),
    "readattr": UInt64(ACL_READ_ATTRIBUTES.rawValue), "writeattr": UInt64(ACL_WRITE_ATTRIBUTES.rawValue),
    "readextattr": UInt64(ACL_READ_EXTATTRIBUTES.rawValue), "writeextattr": UInt64(ACL_WRITE_EXTATTRIBUTES.rawValue)
]
private let knownPermissions = denyPermissions.values.reduce(0, |) | UInt64(ACL_READ_SECURITY.rawValue)
    | UInt64(ACL_WRITE_SECURITY.rawValue) | UInt64(ACL_CHANGE_OWNER.rawValue) | UInt64(ACL_SYNCHRONIZE.rawValue)
private let entryFlags = [ACL_ENTRY_INHERITED, ACL_ENTRY_FILE_INHERIT, ACL_ENTRY_DIRECTORY_INHERIT,
                          ACL_ENTRY_LIMIT_INHERIT, ACL_ENTRY_ONLY_INHERIT].map(\.rawValue)

private func canonicalUUID(_ text: String) -> Bool {
    UUID(uuidString: text)?.uuidString == text && text != "00000000-0000-0000-0000-000000000000"
}

func validateDenies(_ deny: [ACLDeny]) throws {
    guard (1...16).contains(deny.count), Set(deny.map(\.principalUUID)).count == deny.count,
          deny.allSatisfy({ canonicalUUID($0.principalUUID) && !$0.permissions.isEmpty
              && $0.permissions.count <= denyPermissions.count
              && Set($0.permissions).count == $0.permissions.count
              && $0.permissions.allSatisfy { denyPermissions[$0] != nil } })
    else { throw AuditFailure("deny requires 1...16 unique canonical nonzero UUIDs and unique supported directory rights; no inheritance/security/ownership flags") }
}

func protectCallerAccess(_ entries: [ACLEntry]) throws {
    let needed = UInt64(ACL_LIST_DIRECTORY.rawValue | ACL_SEARCH.rawValue | ACL_READ_ATTRIBUTES.rawValue)
    for entry in entries where entry.permissions & needed != 0 {
        guard var principal = UUID(uuidString: entry.principalUUID)?.uuid else { throw HardenConflict("invalid principal UUID") }
        var id: id_t = 0, type: Int32 = -1
        guard mbr_uuid_to_id(&principal, &id, &type) == 0 else {
            throw HardenConflict("cannot establish denied principal identity for caller reopen safety")
        }
        if type == ID_TYPE_UID {
            guard id != geteuid() else { throw HardenConflict("deny would remove installing owner's metadata/reopen access") }
        } else if type == ID_TYPE_GID {
            var caller = UUID().uuid, member: Int32 = -1
            guard mbr_uid_to_uuid(geteuid(), &caller) == 0,
                  mbr_check_membership(&caller, &principal, &member) == 0, member == 0 else {
                throw HardenConflict("denied group includes caller or membership is unresolved; cannot preserve reopen access")
            }
        } else { throw HardenConflict("unsupported principal kind for caller reopen safety") }
    }
}

func supportedACL(_ acl: ACLMetadata) -> Bool {
    guard acl.comparable, acl.errorNumber == nil, acl.entries.count <= 128,
          acl.status != "absent" || (acl.entries.isEmpty && acl.flags.isEmpty),
          acl.flags == [] || acl.flags == [ACL_FLAG_NO_INHERIT.rawValue] else { return false }
    return acl.entries.allSatisfy {
        canonicalUUID($0.principalUUID) && [ACL_EXTENDED_ALLOW.rawValue, ACL_EXTENDED_DENY.rawValue].contains($0.tag)
        && $0.permissions & ~knownPermissions == 0
        && $0.flags == entryFlags.filter(Set($0.flags).contains)
    }
}

func prepending(_ deny: [ACLDeny], to before: ACLMetadata) throws -> ACLMetadata {
    try validateDenies(deny)
    guard supportedACL(before), deny.count + before.entries.count <= 128,
          !deny.contains(where: { before.entries.contains($0.entry) }) else {
        throw HardenConflict("unsupported/oversized ACL or requested deny already present; no duplicate change to claim")
    }
    return .init(status: "observed", entries: deny.map(\.entry) + before.entries, flags: before.flags)
}

/// Build through the SDK API, never parse chmod text or reorder/merge existing entries.
private func nativeACL(_ metadata: ACLMetadata) throws -> acl_t {
    guard supportedACL(metadata), let allocated = acl_init(Int32(metadata.entries.count)) else {
        throw HardenConflict("ACL metadata cannot be represented")
    }
    var acl: acl_t? = allocated
    do {
        try setFlags(UnsafeMutableRawPointer(allocated), metadata.flags)
        for value in metadata.entries {
            var entry: acl_entry_t?
            guard acl_create_entry(&acl, &entry) == 0, let entry,
                  acl_set_tag_type(entry, acl_tag_t(rawValue: value.tag)) == 0,
                  acl_set_permset_mask_np(entry, value.permissions) == 0,
                  var uuid = UUID(uuidString: value.principalUUID)?.uuid,
                  withUnsafePointer(to: &uuid, { acl_set_qualifier(entry, $0) }) == 0
            else { throw HardenConflict("ACL entry encoding failed") }
            try setFlags(UnsafeMutableRawPointer(entry), value.flags)
        }
        guard let acl, acl_valid(acl) == 0 else { throw HardenConflict("invalid native ACL") }
        return acl
    } catch {
        if let acl { acl_free(UnsafeMutableRawPointer(acl)) }
        throw error
    }
}

private func setFlags(_ object: UnsafeMutableRawPointer, _ flags: [UInt32]) throws {
    var flagset: acl_flagset_t?
    guard acl_get_flagset_np(object, &flagset) == 0, let flagset, acl_clear_flags_np(flagset) == 0
    else { throw HardenConflict("ACL flags unavailable") }
    for flag in flags {
        guard acl_add_flag_np(flagset, acl_flag_t(rawValue: flag)) == 0 else { throw HardenConflict("invalid ACL flag") }
    }
}

private func externalACL(_ acl: acl_t) throws -> Data {
    let size = acl_size(acl)
    guard size > 0, size <= 16384 else { throw HardenConflict("native ACL size unsupported") }
    var data = Data(count: size)
    guard data.withUnsafeMutableBytes({ acl_copy_ext($0.baseAddress, acl, size) }) == size
    else { throw HardenConflict("native ACL encoding unavailable") }
    return data
}

/// Reject any native bits that the B1 metadata reader cannot faithfully represent.
func requireLosslessACL(_ fd: Int32, _ metadata: ACLMetadata) throws {
    guard supportedACL(metadata) else { throw HardenConflict("unsupported ACL metadata") }
    guard let original = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
        guard errno == ENOENT, metadata.status == "absent" else { throw HardenConflict("ACL changed/unavailable") }
        return
    }
    defer { acl_free(UnsafeMutableRawPointer(original)) }
    let rebuilt = try nativeACL(metadata)
    defer { acl_free(UnsafeMutableRawPointer(rebuilt)) }
    guard metadata.status == "observed", try externalACL(original) == externalACL(rebuilt)
    else { throw HardenConflict("ACL contains unrepresented bits or changed during observation") }
}

func setHardenACL(_ fd: Int32, _ metadata: ACLMetadata) throws {
    guard supportedACL(metadata) else { throw HardenConflict("unsupported ACL restore/install") }
    if metadata.status == "absent" {
        guard let security = filesec_init() else { throw HardenConflict("ACL removal allocation failed") }
        defer { filesec_free(security) }
        // sys/fcntl.h: _FILESEC_REMOVE_ACL == ((void *)1), unavailable as a Swift macro.
        guard filesec_set_property(security, FILESEC_ACL, UnsafeRawPointer(bitPattern: 1)) == 0,
              fchmodx_np(fd, security) == 0 else { throw HardenConflict("ACL removal failed; intent retained") }
    } else {
        let acl = try nativeACL(metadata)
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0 else { throw HardenConflict("ACL set failed; intent retained") }
    }
}

private struct PlanKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
func rejectUnknownPlanKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    guard Set(try decoder.container(keyedBy: PlanKey.self).allKeys.map(\.stringValue)).isSubset(of: allowed)
    else { throw AuditFailure("unknown hardening plan key") }
}
