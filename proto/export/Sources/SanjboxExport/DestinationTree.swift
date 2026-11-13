import Darwin
import Foundation

struct DirectoryIdentity: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
    }

    static func read(_ fd: Int32) throws -> DirectoryIdentity {
        var status = stat()
        guard fstat(fd, &status) == 0 else {
            throw ExportError.io(path: "<directory>", operation: "fstat", errno: errno)
        }
        guard FileKind(mode: status.st_mode) == .directory else {
            throw ExportError.io(path: "<directory>", operation: "fstat-type", errno: ENOTDIR)
        }
        return DirectoryIdentity(status)
    }
}

/// Pins the existing parent before checking containment or creating anything.
/// Alias retargeting cannot redirect mkdirat/openat. The caller must still own a
/// trusted namespace: an actor able to rename the pinned parent can move it later.
final class DestinationParent {
    let fd: Int32
    let name: String
    let path: String

    init(path: String) throws {
        guard !path.isEmpty, !path.utf8.contains(0) else {
            throw ExportError.destinationInvalid(path: path, errno: EINVAL)
        }
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        let split = trimmed.lastIndex(of: "/")
        let parent = split.map { $0 == trimmed.startIndex ? "/" : String(trimmed[..<$0]) } ?? "."
        name = split.map { String(trimmed[trimmed.index(after: $0)...]) } ?? trimmed
        guard !name.isEmpty, name != ".", name != ".." else {
            throw ExportError.destinationInvalid(path: path, errno: EINVAL)
        }
        self.path = path
        fd = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ExportError.destinationInvalid(path: path, errno: errno) }
    }

    deinit { close(fd) }

    func requireOutside(rootFD: Int32, rootPath: String) throws {
        let rootIdentity = try DirectoryIdentity.read(rootFD)
        var current = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw ExportError.destinationInvalid(path: path, errno: errno) }
        defer { close(current) }
        // Bounded ancestry walk; inability to prove containment fails closed.
        for _ in 0..<1024 {
            let identity = try DirectoryIdentity.read(current)
            guard identity != rootIdentity else {
                throw ExportError.destinationInsideRoot(destination: path, root: rootPath)
            }
            let parent = openat(current, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw ExportError.destinationInvalid(path: path, errno: errno) }
            let parentIdentity: DirectoryIdentity
            do { parentIdentity = try DirectoryIdentity.read(parent) }
            catch { close(parent); throw error }
            close(current)
            current = parent
            if identity == parentIdentity { return }
        }
        throw ExportError.destinationInvalid(path: path, errno: ELOOP)
    }
}

/// Keeps descriptors for directories created by this apply. EEXIST is never
/// accepted for an untracked name, and a tracked name must still name its fd.
final class DestinationTree {
    let parent: DestinationParent
    let rootFD: Int32
    private var directories: [String: Int32] = [:]

    init(parent: DestinationParent) throws {
        self.parent = parent
        guard mkdirat(parent.fd, parent.name, 0o700) == 0 else {
            let code = errno
            if code == EEXIST { throw ExportError.destinationExists(path: parent.path) }
            throw ExportError.destinationInvalid(path: parent.path, errno: code)
        }
        rootFD = try Self.openCreatedDirectory(parentFD: parent.fd, name: parent.name, path: parent.path)
    }

    deinit {
        for fd in directories.values { close(fd) }
        close(rootFD)
    }

    func directory(components: [String], relativePath: String) throws -> Int32 {
        try Self.requireLinked(parentFD: parent.fd, name: parent.name, fd: rootFD, path: parent.path)
        var current = rootFD
        var prefix: [String] = []
        for name in components {
            prefix.append(name)
            let key = prefix.joined(separator: "/")
            if let existing = directories[key] {
                try Self.requireLinked(parentFD: current, name: name, fd: existing, path: relativePath)
                current = existing
                continue
            }
            guard mkdirat(current, name, 0o700) == 0 else {
                throw ExportError.io(path: relativePath, operation: "mkdirat-destination", errno: errno)
            }
            let created = try Self.openCreatedDirectory(parentFD: current, name: name, path: relativePath)
            directories[key] = created
            current = created
        }
        return current
    }

    static func requireLinked(parentFD: Int32, name: String, fd: Int32, path: String) throws {
        var status = stat()
        guard fstatat(parentFD, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ExportError.io(path: path, operation: "fstatat-destination", errno: errno)
        }
        guard FileKind(mode: status.st_mode) == .directory,
              DirectoryIdentity(status) == (try DirectoryIdentity.read(fd)) else {
            throw ExportError.io(path: path, operation: "destination-directory-changed", errno: ESTALE)
        }
    }

    private static func openCreatedDirectory(parentFD: Int32, name: String, path: String) throws -> Int32 {
        var status = stat()
        guard fstatat(parentFD, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ExportError.destinationInvalid(path: path, errno: errno)
        }
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ExportError.destinationInvalid(path: path, errno: errno) }
        guard FileKind(mode: status.st_mode) == .directory,
              status.st_uid == geteuid(), status.st_mode & 0o777 == 0o700,
              SafePath.openedDirectoryMatches(classified: status, openedFD: fd) else {
            close(fd)
            throw ExportError.destinationInvalid(path: path, errno: ESTALE)
        }
        return fd
    }
}
