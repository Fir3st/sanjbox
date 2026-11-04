import Darwin
import Foundation

func metadata(_ value: stat) -> StatMetadata {
    let kind: String
    switch value.st_mode & S_IFMT {
    case S_IFDIR: kind = "directory"
    case S_IFREG: kind = "regular"
    case S_IFLNK: kind = "symlink"
    case S_IFSOCK: kind = "socket"
    case S_IFIFO: kind = "fifo"
    case S_IFCHR: kind = "character-device"
    case S_IFBLK: kind = "block-device"
    default: kind = "unknown"
    }
    return .init(device: value.st_dev, inode: value.st_ino, kind: kind,
                 mode: value.st_mode & 0o7777, uid: value.st_uid, gid: value.st_gid,
                 flags: value.st_flags, links: value.st_nlink,
                 changeSeconds: Int64(value.st_ctimespec.tv_sec), changeNanoseconds: Int64(value.st_ctimespec.tv_nsec))
}

func sameObject(_ a: stat, _ b: stat) -> Bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino && (a.st_mode & UInt16(S_IFMT)) == (b.st_mode & UInt16(S_IFMT))
}

private let aclFlags: [acl_flag_t] = [ACL_FLAG_DEFER_INHERIT, ACL_FLAG_NO_INHERIT, ACL_ENTRY_INHERITED,
    ACL_ENTRY_FILE_INHERIT, ACL_ENTRY_DIRECTORY_INHERIT, ACL_ENTRY_LIMIT_INHERIT, ACL_ENTRY_ONLY_INHERIT]

private func flags(_ object: UnsafeMutableRawPointer) throws -> [UInt32] {
    var flagset: acl_flagset_t?
    guard acl_get_flagset_np(object, &flagset) == 0, let flagset else { throw AuditFailure("ACL flag set unavailable") }
    return try aclFlags.compactMap { flag in
        let result = acl_get_flag_np(flagset, flag)
        guard result >= 0 else { throw AuditFailure("ACL flags unavailable") }
        return result == 0 ? nil : flag.rawValue
    }
}

func readACL(_ fd: Int32) -> ACLMetadata {
    guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
        let code = errno
        // Darwin reports ENOENT for an object with no extended ACL; the object is pinned by fd.
        if code == ENOENT { return .init(status: "absent") }
        return .init(status: code == ENOTSUP ? "unsupported" : "error", errorNumber: code)
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    do {
        let globalFlags = try flags(UnsafeMutableRawPointer(acl))
        var entries: [ACLEntry] = []
        var cursor = ACL_FIRST_ENTRY.rawValue
        while true {
            var entry: acl_entry_t?
            // Darwin's API returns 0 for success and -1 at end (unlike POSIX's 1/0).
            errno = 0
            let result = acl_get_entry(acl, cursor, &entry)
            if result != 0 {
                guard errno == EINVAL else { throw AuditFailure("ACL iteration failed") }
                break
            }
            guard let entry, entries.count < 128 else { throw AuditFailure("ACL entry bound exceeded") }
            cursor = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_mask_t = 0
            guard acl_get_tag_type(entry, &tag) == 0,
                  acl_get_permset_mask_np(entry, &permissions) == 0,
                  let qualifier = acl_get_qualifier(entry) else { throw AuditFailure("ACL entry unavailable") }
            let uuid = qualifier.loadUnaligned(as: uuid_t.self)
            acl_free(qualifier)
            entries.append(.init(principalUUID: UUID(uuid: uuid).uuidString, tag: tag.rawValue,
                                 permissions: permissions, flags: try flags(UnsafeMutableRawPointer(entry))))
        }
        return .init(status: "observed", entries: entries, flags: globalFlags)
    } catch { return .init(status: "error", errorNumber: errno == 0 ? EIO : errno) }
}

func readMount(_ fd: Int32) -> MountMetadata? {
    var value = statfs()
    guard fstatfs(fd, &value) == 0 else { return nil }
    let type = withUnsafeBytes(of: &value.f_fstypename) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    let ids = withUnsafeBytes(of: &value.f_fsid) { Array($0.bindMemory(to: Int32.self)) }
    return .init(filesystemType: type, filesystemID: ids, flags: value.f_flags,
                 local: value.f_flags & UInt32(MNT_LOCAL) != 0,
                 readOnly: value.f_flags & UInt32(MNT_RDONLY) != 0,
                 ignoresOwnership: value.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0)
}

/// Content reads exist only here, for caller-owned, bounded schema files. No audited file uses this path.
func readOwnedInput(_ path: String, suffix: String, limit: Int) throws -> Data {
    guard validAbsolutePath(path), path.hasSuffix(suffix) else { throw AuditFailure("input must be an absolute, normalized path ending in \(suffix)") }
    guard !restrictedPath(path) else { throw AuditFailure("restricted schema input name") }
    var named = stat()
    guard fstatat(AT_FDCWD, path, &named, AT_SYMLINK_NOFOLLOW_ANY | AT_SYMLINK_NOFOLLOW) == 0,
          named.st_mode & S_IFMT == S_IFREG, named.st_uid == geteuid(), named.st_nlink == 1,
          named.st_mode & 0o022 == 0, named.st_size > 0, named.st_size <= limit
    else { throw AuditFailure("schema input preflight refused") }
    let fd = open(path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw AuditFailure("cannot open schema input (errno \(errno))") }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, sameObject(named, before), metadata(named) == metadata(before), (before.st_mode & UInt16(S_IFMT)) == UInt16(S_IFREG),
          before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & 0o022 == 0,
          before.st_size > 0, before.st_size <= limit else { throw AuditFailure("schema input must be an owned, single-link regular file, not group/world writable, within its size limit") }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while data.count <= limit {
        let count = read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
        if count < 0 {
            if errno == EINTR { continue }
            throw AuditFailure("schema input read failed")
        }
        if count == 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    var after = stat()
    guard data.count <= limit, fstat(fd, &after) == 0, metadata(before) == metadata(after),
          before.st_size == after.st_size else { throw AuditFailure("schema input changed or exceeded size limit") }
    return data
}

/// Defense in depth for obvious credential/Keychain/database names. This is an exclusion list,
/// never a claim that other names are safe; data reads remain forbidden for every audit entry.
func restrictedPath(_ path: String) -> Bool {
    path.split(separator: "/").contains { component in
        let name = component.lowercased()
        return name.hasPrefix(".env") || ["secret", "token", "credential", "keychain"].contains(where: name.contains)
            || [".ssh", ".gnupg", "id_rsa", "id_ed25519", "login data", "cookies"].contains(name)
            || [".pem", ".key", ".p12", ".p8", ".pfx", ".db", ".sqlite", ".sqlite3"].contains(where: name.hasSuffix)
    }
}
