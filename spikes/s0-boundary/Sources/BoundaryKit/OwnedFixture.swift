import Darwin
import Foundation

/// Private, non-recursive, descriptor-relative fixture. Paths and filenames are generated here;
/// no caller path, restored state file, or manifest is accepted as authority to read/delete.
/// In-memory receipts pin original descriptors and identities, including files made unreadable.
final class OwnedFixture {
    enum Name: String { case control, denied }
    struct Receipt {
        let name: Name
        let fd: Int32
        let device: dev_t
        let inode: ino_t
        let group: gid_t
        let flags: UInt32
        let mode: mode_t
        let bytes: Data
    }
    let name: String
    let parentFD: Int32
    let directoryFD: Int32
    let directoryIdentity: stat
    private(set) var receipts: [Receipt] = []
    private(set) var removed = false

    init() throws {
        guard getuid() != 0, geteuid() != 0 else { throw BoundaryError.invalid("root fixture execution forbidden") }
        name = "sanjbox-a4-fixture-" + UUID().uuidString.lowercased()
        parentFD = open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw BoundaryError.io("cannot open fixture parent") }
        guard mkdirat(parentFD, name, 0o700) == 0 else {
            close(parentFD)
            throw BoundaryError.io("cannot create new UUID fixture")
        }
        directoryFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var identity = stat()
        guard directoryFD >= 0, fstat(directoryFD, &identity) == 0,
              identity.st_uid == geteuid(), identity.st_mode & 0o7777 == 0o700, identity.st_flags == 0
        else {
            if directoryFD >= 0 { close(directoryFD) }
            close(parentFD)
            // No blind cleanup if the just-created name cannot be verified.
            throw BoundaryError.conflict("new UUID fixture could not be verified: \(name)")
        }
        // Darwin inherits the parent directory GID (often wheel for /private/tmp). Establish our
        // effective GID on this new, verified object so later test changes can be restored by us.
        guard fchown(directoryFD, uid_t.max, getegid()) == 0, fstat(directoryFD, &identity) == 0,
              identity.st_gid == getegid() else {
            close(directoryFD); close(parentFD)
            throw BoundaryError.conflict("new UUID fixture group setup failed: \(name)")
        }
        directoryIdentity = identity
        do { try Self.requireNoACL(directoryFD) }
        catch { throw BoundaryError.conflict("new UUID fixture ACL unavailable/present: \(name)") }
    }
    deinit {
        receipts.forEach { close($0.fd) }
        close(directoryFD)
        close(parentFD)
    }
    func create(_ name: Name, bytes: Data, mode: mode_t) throws {
        guard !removed, bytes.count <= 1024, [mode_t(0o600), 0].contains(mode),
              !receipts.contains(where: { $0.name == name })
        else { throw BoundaryError.invalid("fixture creation contract") }
        try verifyDirectory()
        let fd = openat(directoryFD, name.rawValue, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BoundaryError.io("exclusive fixture creation failed") }
        var value = stat()
        guard fstat(fd, &value) == 0, isRegularOwned(value), value.st_nlink == 1, value.st_flags == 0 else {
            close(fd)
            throw BoundaryError.conflict("created fixture type or ownership changed")
        }
        do { try Self.requireNoACL(fd) } catch { close(fd); throw error }
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count, fchmod(fd, mode) == 0 else {
            close(fd)
            throw BoundaryError.conflict("fixture write/setup incomplete; retained for review: \(self.name)")
        }
        receipts.append(Receipt(name: name, fd: fd, device: value.st_dev, inode: value.st_ino,
                                group: value.st_gid, flags: value.st_flags, mode: mode, bytes: bytes))
    }

    /// Fresh open tests the kernel permission check, not the retained setup descriptor.
    func read(_ name: Name) throws -> Data {
        try verifyDirectory()
        guard let receipt = receipts.first(where: { $0.name == name }) else { throw BoundaryError.invalid("unknown fixture") }
        try verifyName(receipt)
        let fd = openat(directoryFD, name.rawValue, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw OpenFailure(errno: errno) }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, matches(value, receipt) else {
            throw BoundaryError.conflict("fixture changed during open")
        }
        try Self.requireNoACL(fd)
        let data = try readExact(fd, expected: receipt.bytes.count)
        var after = stat()
        guard fstat(fd, &after) == 0, matches(after, receipt), data == receipt.bytes else {
            throw BoundaryError.conflict("fixture changed during read")
        }
        return data
    }

    struct OpenFailure: Error { let errno: Int32 }

    /// Verify every file BEFORE deleting any. No traversal; extra entries and later changes conflict.
    /// The check/unlink pair is not atomic against a hostile same-UID writer (documented limitation).
    func cleanup() throws {
        if removed { return }
        try verifyDirectory()
        let names = try childNames()
        let registered = Set(receipts.map { $0.name.rawValue })
        guard names.isSubset(of: registered) else { throw BoundaryError.conflict("cleanup: unregistered fixture entry in \(name)") }
        for receipt in receipts where !names.contains(receipt.name.rawValue) {
            var original = stat()
            guard fstat(receipt.fd, &original) == 0, original.st_nlink == 0
            else { throw BoundaryError.conflict("cleanup: missing fixture was moved or relinked: \(name)") }
        }
        for receipt in receipts where names.contains(receipt.name.rawValue) {
            try verifyName(receipt)
            var value = stat()
            guard fstat(receipt.fd, &value) == 0, matches(value, receipt),
                  try readExact(receipt.fd, expected: receipt.bytes.count) == receipt.bytes
            else { throw BoundaryError.conflict("cleanup: later content change in \(name)") }
        }
        for receipt in receipts where names.contains(receipt.name.rawValue) {
            try verifyDirectory()
            try verifyName(receipt)
            guard unlinkat(directoryFD, receipt.name.rawValue, 0) == 0 else { throw BoundaryError.conflict("cleanup: unlink failed in \(name)") }
        }
        try verifyDirectory()
        guard unlinkat(parentFD, name, AT_REMOVEDIR) == 0 else { throw BoundaryError.conflict("cleanup: nonempty/changed UUID directory \(name)") }
        removed = true
    }

    private func verifyDirectory() throws {
        var named = stat(), opened = stat()
        guard !removed, fstatat(parentFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(directoryFD, &opened) == 0,
              named.st_dev == directoryIdentity.st_dev, named.st_ino == directoryIdentity.st_ino,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
              named.st_mode & S_IFMT == S_IFDIR, named.st_uid == geteuid(), named.st_mode & 0o7777 == 0o700,
              named.st_gid == directoryIdentity.st_gid, named.st_flags == directoryIdentity.st_flags,
              opened.st_gid == named.st_gid, opened.st_flags == named.st_flags,
              opened.st_uid == named.st_uid, opened.st_mode == named.st_mode
        else { throw BoundaryError.conflict("fixture directory identity/mode changed: \(name)") }
        try Self.requireNoACL(directoryFD)
    }
    private func verifyName(_ receipt: Receipt) throws {
        var value = stat()
        guard fstatat(directoryFD, receipt.name.rawValue, &value, AT_SYMLINK_NOFOLLOW) == 0,
              matches(value, receipt)
        else { throw BoundaryError.conflict("fixture path/type/link/mode changed: \(name)/\(receipt.name.rawValue)") }
        try Self.requireNoACL(receipt.fd)
    }
    private func matches(_ value: stat, _ receipt: Receipt) -> Bool {
        isRegularOwned(value) && value.st_nlink == 1 && value.st_dev == receipt.device &&
        value.st_ino == receipt.inode && value.st_mode & 0o7777 == receipt.mode && value.st_size == receipt.bytes.count &&
        value.st_gid == receipt.group && value.st_flags == receipt.flags
    }
    private func isRegularOwned(_ value: stat) -> Bool { value.st_mode & S_IFMT == S_IFREG && value.st_uid == geteuid() }
    private static func requireNoACL(_ fd: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            // Darwin returns ENOENT for an absent extended ACL on an existing pinned fd.
            // EBADF/EACCES/ENOTSUP and every other retrieval error remain conflicts.
            if errno == ENOENT { return }
            throw BoundaryError.conflict("fixture ACL unavailable")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw BoundaryError.conflict("fixture ACL invalid") }
        var entry: acl_entry_t?
        errno = 0
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        guard result == -1, errno == EINVAL else { throw BoundaryError.conflict("fixture extended ACL present or changed") }
    }
    private func readExact(_ fd: Int32, expected: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: expected + 1)
        let count = pread(fd, &bytes, bytes.count, 0)
        guard count == expected else { throw BoundaryError.conflict("fixture length/read changed") }
        return Data(bytes.prefix(count))
    }
    private func childNames() throws -> Set<String> {
        // openat(".") gets an independent directory offset; dup would share a consumed offset.
        let fd = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw BoundaryError.io("fixture listing failed") }
        guard let dir = fdopendir(fd) else { close(fd); throw BoundaryError.io("fixture listing failed") }
        defer { closedir(dir) }
        var names = Set<String>()
        errno = 0
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.insert(name) }
            guard names.count <= 2 else { throw BoundaryError.conflict("cleanup: unexpected entries") }
            errno = 0
        }
        guard errno == 0 else { throw BoundaryError.io("fixture listing incomplete") }
        return names
    }
}
