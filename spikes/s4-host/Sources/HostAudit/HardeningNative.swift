import Darwin
import Foundation

func hardenStamp(_ fd: Int32) throws -> HardenStamp {
    var before = stat()
    guard fstat(fd, &before) == 0 else { throw HardenConflict("descriptor stat unavailable") }
    let acl = readACL(fd)
    guard emptyACL(acl), let mount = readMount(fd), mount.local,
          !mount.ignoresOwnership, mount.filesystemType == "apfs"
    else { throw HardenConflict("unsupported ACL or mount; only empty ACL on writable local ownership-enforcing APFS is supported") }
    var after = stat()
    guard fstat(fd, &after) == 0, metadata(before) == metadata(after), before.st_birthtimespec.tv_sec == after.st_birthtimespec.tv_sec, before.st_birthtimespec.tv_nsec == after.st_birthtimespec.tv_nsec,
          before.st_gen == after.st_gen else { throw HardenConflict("metadata changed during observation") }
    return .init(stat: metadata(before), birthSeconds: Int64(before.st_birthtimespec.tv_sec),
                 birthNanoseconds: Int64(before.st_birthtimespec.tv_nsec), generation: before.st_gen, acl: acl, mount: mount)
}

/// Every component is pinned independently. A later rename is detected on revalidation;
/// there is intentionally no claim that these non-atomic checks lock the namespace.
final class HardenPath {
    let path: String
    private var fds: [Int32] = []
    private var names: [String] = []
    let initial: [HardenStamp]
    var fd: Int32 { fds.last! }
    var ancestors: [HardenStamp] { initial.dropLast().map(\.ancestorGuard) }

    init(_ path: String) throws {
        guard validAbsolutePath(path), path != "/", !restrictedPath(path),
              path.split(separator: "/").count <= 64 else { throw HardenConflict("invalid, restricted or excessively deep path") }
        self.path = path
        var opened: [Int32] = []
        do {
            let root = open("/", O_EVTONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard root >= 0 else { throw HardenConflict("cannot pin filesystem root") }
            opened.append(root)
            var observed = [try hardenStamp(root)]
            for component in path.dropFirst().split(separator: "/") {
                let name = String(component)
                let child = openat(opened.last!, name, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
                guard child >= 0 else { throw HardenConflict("cannot pin directory component (errno \(errno)); missing, symlink or inaccessible path") }
                opened.append(child)
                names.append(name)
                observed.append(try hardenStamp(child))
            }
            initial = observed
            fds = opened
            do { try verifyAncestors() }
            catch { fds = []; throw error } // outer catch owns cleanup until successful initialization
        } catch {
            for fd in opened { close(fd) }
            throw error
        }
    }
    deinit { for fd in fds { close(fd) } }

    private func verifyAncestors() throws {
        for index in 0..<(fds.count - 1) {
            let node = try hardenStamp(fds[index])
            let rootSticky = node.stat.uid == 0 && node.stat.mode & 0o1000 != 0
            guard node.stat.kind == "directory", node.stat.uid == 0 || node.stat.uid == geteuid(),
                  node.stat.mode & 0o022 == 0 || rootSticky,
                  node.ancestorGuard == initial[index].ancestorGuard
            else { throw HardenConflict("ancestor identity or protection changed/unsupported") }
        }
    }

    func verify(ancestors expected: [HardenStamp]? = nil) throws {
        try verifyAncestors()
        if let expected, expected != ancestors { throw HardenConflict("ancestor identity/protection differs from journal") }
        for index in names.indices {
            var named = stat(), pinned = stat()
            guard fstatat(fds[index], names[index], &named, AT_SYMLINK_NOFOLLOW_ANY | AT_SYMLINK_NOFOLLOW) == 0,
                  fstat(fds[index + 1], &pinned) == 0, sameObject(named, pinned),
                  metadata(named) == metadata(pinned), named.st_gen == pinned.st_gen,
                  named.st_birthtimespec.tv_sec == pinned.st_birthtimespec.tv_sec, named.st_birthtimespec.tv_nsec == pinned.st_birthtimespec.tv_nsec
            else { throw HardenConflict("directory binding changed") }
        }
    }

    func requireTarget(_ expected: HardenStamp? = nil) throws -> HardenStamp {
        try verify()
        let current = try hardenStamp(fd)
        guard !current.mount.readOnly, current.stat.kind == "directory", current.stat.uid == geteuid(), current.stat.flags == 0,
              current.stat.mode & 0o7000 == 0, current.stat.mode & 0o700 == 0o700,
              expected == nil || current == expected else { throw HardenConflict("target metadata differs, owner is foreign or mode/flags are unsupported") }
        return current
    }
}

func forceDurable(_ fd: Int32) throws {
    guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw HardenConflict("durable flush unavailable; no further mutation") }
}

func overlap(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") }

/// Read/write only our private journal. Target directory descriptors are never read.
final class HardenJournal {
    let directory: HardenPath
    private var lockFD: Int32 = -1
    let path: String

    static func checkDestination(_ path: String, targets: [String], creating: Bool) throws {
        guard validAbsolutePath(path), path.hasSuffix("/state"), !restrictedPath(path),
              !targets.contains(where: { overlap($0, path) }) else { throw HardenConflict("state must be a separate normalized path ending in /state") }
        let parentPath = String(path.dropLast(6))
        guard !targets.contains(where: { overlap($0, parentPath) }) else { throw HardenConflict("journal parent must be separate from every target") }
        let parent = try HardenPath(parentPath)
        let stamp = try parent.requireTarget()
        guard stamp.stat.mode == 0o700 else { throw HardenConflict("journal parent must be caller-owned mode 0700") }
        if creating {
            var value = stat()
            errno = 0
            guard fstatat(parent.fd, "state", &value, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT
            else { throw HardenConflict("state already exists; never reuse or overwrite a journal") }
        }
    }

    init(_ path: String, create: Bool) throws {
        guard validAbsolutePath(path), path.hasSuffix("/state"), !restrictedPath(path) else { throw HardenConflict("invalid state path") }
        self.path = path
        if create {
            let parent = try HardenPath(String(path.dropLast(6)))
            guard try parent.requireTarget().stat.mode == 0o700 else { throw HardenConflict("journal parent is not private") }
            try parent.verify()
            guard mkdirat(parent.fd, "state", 0o700) == 0 else { throw HardenConflict("cannot exclusively create state") }
            guard fsync(parent.fd) == 0 else { throw HardenConflict("cannot persist state directory creation") }
            try parent.verify()
        }
        directory = try HardenPath(path)
        guard try directory.requireTarget().stat.mode == 0o700 else { throw HardenConflict("state is not caller-owned mode 0700") }
        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK | (create ? O_CREAT | O_EXCL : 0)
        let fd = openat(directory.fd, "lock", flags, 0o600)
        guard fd >= 0 else { throw HardenConflict("cannot open exclusive journal lock") }
        do {
            try validateFile(fd, limit: 0, allowEmpty: true)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw HardenConflict("journal is busy") }
            try directory.verify()
            if create {
                try forceDurable(fd)
                guard fsync(directory.fd) == 0 else { throw HardenConflict("cannot persist lock") }
                try forceDurable(fd)
            }
            lockFD = fd // transfer ownership only after every throwing initialization step
        } catch { close(fd); throw error }
    }
    deinit { if lockFD >= 0 { close(lockFD) } }

    func verify() throws {
        try directory.verify()
        guard try directory.requireTarget().stat.mode == 0o700 else { throw HardenConflict("state protection changed") }
        var named = stat(), pinned = stat()
        guard fstatat(directory.fd, "lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(lockFD, &pinned) == 0, sameObject(named, pinned) else { throw HardenConflict("journal lock replaced") }
        try validateFile(lockFD, limit: 0, allowEmpty: true)
    }

    func write<T: Encodable>(_ value: T, name: String) throws {
        try verify()
        let data = try encode(value)
        guard data.count <= 1024 * 1024 else { throw HardenConflict("journal record too large") }
        let fd = openat(directory.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW_ANY | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HardenConflict("journal record already exists or cannot be created") }
        defer { close(fd) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw HardenConflict("journal write interrupted; retain state for manual review") }
                offset += count
            }
        }
        try forceDurable(fd)
        guard fsync(directory.fd) == 0 else { throw HardenConflict("journal directory flush failed") }
        // Flush device cache again after persisting the new directory entry.
        try forceDurable(fd)
        try verify()
    }

    func names() throws -> Set<String> {
        try verify()
        let fd = openat(directory.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0, let stream = fdopendir(fd) else { if fd >= 0 { close(fd) }; throw HardenConflict("journal listing failed") }
        defer { closedir(stream) }
        var result = Set<String>()
        while true {
            errno = 0
            guard let item = readdir(stream) else { if errno != 0 { throw HardenConflict("journal listing failed") }; break }
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard result.count < 66 else { throw HardenConflict("journal entry limit exceeded") }
            result.insert(name)
        }
        try verify()
        return result
    }

    func read<T: Codable>(_ name: String) throws -> T {
        try verify()
        let fd = openat(directory.fd, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw HardenConflict("journal record unavailable") }
        defer { close(fd) }
        try validateFile(fd, limit: 1024 * 1024)
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw HardenConflict("journal stat unavailable") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while data.count <= 1024 * 1024 {
            let count = Darwin.read(fd, &buffer, min(buffer.count, 1024 * 1024 + 1 - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw HardenConflict("journal read failed") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat(), named = stat()
        guard data.count <= 1024 * 1024, fstat(fd, &after) == 0,
              metadata(before) == metadata(after), before.st_size == after.st_size,
              fstatat(directory.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0, metadata(named) == metadata(after)
        else { throw HardenConflict("journal changed during read") }
        try verify()
        do {
            let value = try JSONDecoder().decode(T.self, from: data)
            // Journals are generated only by this binary in canonical sorted-key encoding.
            // Round-trip equality rejects unknown/duplicate keys, trailing JSON and noncanonical edits.
            guard try encode(value) == data else { throw HardenConflict("noncanonical journal") }
            return value
        } catch { throw HardenConflict("invalid/truncated/noncanonical journal; manual review required") }
    }
}

private func validateFile(_ fd: Int32, limit: Int, allowEmpty: Bool = false) throws {
    var value = stat()
    guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(),
          value.st_mode & 0o7777 == 0o600, value.st_nlink == 1, value.st_flags == 0,
          value.st_size >= (allowEmpty ? 0 : 1), value.st_size <= limit, emptyACL(readACL(fd))
    else { throw HardenConflict("journal file is not private owned single-link regular metadata") }
}
