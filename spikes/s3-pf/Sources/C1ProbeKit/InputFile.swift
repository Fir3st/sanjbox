import Darwin
import Foundation

public enum InputFile {
    /// Only our two named JSON schemas. No symlinks (including parent components),
    /// devices, FIFOs, hardlinks, hidden/credential paths, or writable-by-other input.
    public static func read(_ path: String, kind: String) throws -> Data {
        guard ["expect", "probe"].contains(kind), path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096, path.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }) else { throw ProbeError.invalidInput }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard let name = parts.last,
              name.range(of: "^\(kind)(-[a-zA-Z0-9_-]{1,40})?\\.json$", options: .regularExpression) != nil,
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.lowercased().contains("secret") && !$0.lowercased().contains("credential") && !$0.lowercased().contains("token") && !$0.lowercased().contains("keychain") }) else { throw ProbeError.invalidInput }
        var directory = open("/", O_RDONLY | O_DIRECTORY)
        guard directory >= 0 else { throw ProbeError.io(errno) }
        defer { close(directory) }
        for part in parts.dropLast() {
            let child = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard child >= 0 else { throw ProbeError.io(errno) }
            close(directory); directory = child
            var info = stat()
            guard fstat(directory, &info) == 0, info.st_uid == 0 || info.st_uid == geteuid() else { throw ProbeError.invalidInput }
            try rejectACL(directory)
        }
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw ProbeError.io(errno) }
        defer { close(file) }
        var before = stat()
        guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == 0 || before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & 0o022 == 0, before.st_size >= 0, before.st_size <= 16_384 else { throw ProbeError.invalidInput }
        try rejectACL(file)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= 16_384 {
            let count = Darwin.read(file, &buffer, min(buffer.count, 16_385 - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ProbeError.io(errno) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat(), named = stat()
        guard data.count <= 16_384, data.count == before.st_size,
              fstat(file, &after) == 0, fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              same(before, after), same(before, named) else { throw ProbeError.invalidInput }
        return data
    }

    private static func rejectACL(_ fd: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else { throw ProbeError.invalidInput }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw ProbeError.invalidInput }
        var entry: acl_entry_t?
        errno = 0
        // Darwin: 0 means an entry exists; -1/EINVAL on a validated empty ACL.
        guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL else { throw ProbeError.invalidInput }
    }

    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mode == b.st_mode &&
        a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_nlink == b.st_nlink &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
