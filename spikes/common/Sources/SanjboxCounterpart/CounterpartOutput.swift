import Darwin
import Foundation
import SanjboxProbeKit
import Synchronization

/// Output paths are resolved once. Renaming/replacing a pathname cannot redirect later writes.
/// This is descriptor ownership, not protection against a process that can mutate the same inode.
final class CounterpartOutput: Sendable {
    let raw: CounterpartOutputDirectory
    private let log: CounterpartOutputFile

    init(log logURL: URL, raw rawURL: URL) throws {
        let raw = try CounterpartOutputDirectory.open(rawURL, create: true, requireOwner: true)
        try raw.requireEmpty(path: rawURL.path)
        let parent = try CounterpartOutputDirectory.open(logURL.deletingLastPathComponent())
        guard try !raw.isSameDirectory(as: parent) else {
            throw CounterpartError.system("log must be outside raw directory", errno: EINVAL)
        }
        self.log = try parent.createFile(named: logURL.lastPathComponent)
        self.raw = raw
    }

    func record(_ event: CounterpartEvent) throws {
        var line = try JSONLines.makeEncoder().encode(event)
        line.append(0x0A)
        try log.write(line)
    }

    func close() {
        log.close()
        raw.close()
    }
}

/// The mutex serializes close against descriptor use, including capture creation on other threads.
final class CounterpartOutputDirectory: Sendable {
    private let descriptor: Mutex<Int32>

    private init(_ fd: Int32) { descriptor = Mutex(fd) }
    deinit { close() }

    static func open(_ url: URL, create: Bool = false, requireOwner: Bool = false) throws -> CounterpartOutputDirectory {
        guard url.isFileURL, !url.path.utf8.contains(0), url.path.hasPrefix("/") else {
            throw CounterpartError.system("invalid output directory", errno: EINVAL)
        }
        var parts = url.path.split(separator: "/").map(String.init)
        guard !parts.contains("..") else {
            throw CounterpartError.system("parent traversal in output directory", errno: EINVAL)
        }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CounterpartError.system("open output root", errno: errno) }
        do {
            // macOS exposes its temporary directories through these two root-owned aliases.
            // Validate their exact targets and expand them lexically; never resolve arbitrary links.
            if let first = parts.first, first == "tmp" || first == "var" {
                var info = stat()
                guard fstatat(fd, first, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw CounterpartError.system("inspect system directory alias", errno: errno)
                }
                if info.st_mode & S_IFMT == S_IFLNK {
                    var target = [UInt8](repeating: 0, count: 256)
                    let count = target.withUnsafeMutableBytes { readlinkat(fd, first, $0.baseAddress!, $0.count) }
                    let expected = "private/\(first)"
                    guard info.st_uid == 0, count > 0, count < target.count,
                          String(decoding: target.prefix(count), as: UTF8.self) == expected else {
                        throw CounterpartError.system("unexpected system directory alias", errno: EINVAL)
                    }
                    parts.insert("private", at: 0)
                }
            }
            for part in parts where part != "." {
                var child = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0, errno == ENOENT, create {
                    guard mkdirat(fd, part, 0o700) == 0 else {
                        throw CounterpartError.system("create output directory", errno: errno)
                    }
                    child = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else { throw CounterpartError.system("open output directory", errno: errno) }
                Darwin.close(fd)
                fd = child
                try validate(fd, requireOwner: false)
            }
            try validate(fd, requireOwner: requireOwner)
            return CounterpartOutputDirectory(fd)
        } catch {
            Darwin.close(fd)
            // No pathname rollback: keep created directories, even on failure.
            throw error
        }
    }

    private static func validate(_ fd: Int32, requireOwner: Bool) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw CounterpartError.system("inspect output directory", errno: errno) }
        let owned = info.st_uid == geteuid()
        let rootSticky = info.st_uid == 0 && info.st_mode & S_ISVTX != 0
        guard info.st_mode & S_IFMT == S_IFDIR, owned || (!requireOwner && info.st_uid == 0),
              info.st_mode & 0o022 == 0 || (!requireOwner && rootSticky) else {
            throw CounterpartError.system("unsafe output directory owner or mode", errno: EPERM)
        }
    }

    func isSameDirectory(as other: CounterpartOutputDirectory) throws -> Bool {
        func identity(_ directory: CounterpartOutputDirectory) throws -> (dev_t, ino_t) {
            try directory.descriptor.withLock { fd in
                var info = stat()
                guard fstat(fd, &info) == 0 else { throw CounterpartError.system("inspect output directory", errno: errno) }
                return (info.st_dev, info.st_ino)
            }
        }
        return try identity(self) == identity(other)
    }

    func requireEmpty(path: String) throws {
        try descriptor.withLock { fd in
            // openat(".") has an independent directory offset; fdopendir owns only this copy.
            let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard copy >= 0 else { throw CounterpartError.system("open raw directory listing", errno: errno) }
            guard let directory = fdopendir(copy) else {
                let code = errno
                Darwin.close(copy)
                throw CounterpartError.system("read raw directory", errno: code)
            }
            defer { closedir(directory) }
            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    guard errno == 0 else { throw CounterpartError.system("read raw directory", errno: errno) }
                    return
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                        String(cString: $0)
                    }
                }
                guard name == "." || name == ".." else { throw CounterpartError.rawDirectoryNotEmpty(path) }
            }
        }
    }

    func createFile(named name: String) throws -> CounterpartOutputFile {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw CounterpartError.system("invalid output file name", errno: EINVAL)
        }
        return try descriptor.withLock { fd in
            try Self.validate(fd, requireOwner: false)
            let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw CounterpartError.system("create output file \(name)", errno: errno) }
            return try CounterpartOutputFile(file)
        }
    }

    func close() {
        descriptor.withLock { fd in
            if fd >= 0 { Darwin.close(fd); fd = -1 }
        }
    }
}

/// An exclusive, newly created regular file. A failed write permanently closes this writer.
final class CounterpartOutputFile: Sendable {
    private let descriptor: Mutex<Int32>

    fileprivate init(_ fd: Int32) throws {
        descriptor = Mutex(fd)
        do { try Self.validate(fd) } catch {
            close()
            throw error
        }
    }
    deinit { close() }

    private static func validate(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw CounterpartError.system("inspect output file", errno: errno) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & 0o022 == 0 else {
            throw CounterpartError.system("unsafe output file owner, mode or link count", errno: EPERM)
        }
    }

    func write(_ data: Data) throws {
        try descriptor.withLock { fd in
            do {
                try Self.validate(fd)
                try Self.writeAll(data, to: fd)
            } catch {
                if fd >= 0 { Darwin.close(fd); fd = -1 }
                throw error
            }
        }
    }

    /// The injected call is only a unit-test seam for short writes, EINTR and terminal failures.
    static func writeAll(
        _ data: Data, to fd: Int32,
        call: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
    ) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = call(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0, count <= buffer.count - offset else {
                    throw CounterpartError.system("write output", errno: count < 0 ? errno : EIO)
                }
                offset += count
            }
        }
    }

    func close() {
        descriptor.withLock { fd in
            if fd >= 0 { Darwin.close(fd); fd = -1 }
        }
    }
}

/// Per-flow capture, lazily created in the retained directory. Empty contacts create no file.
struct RawCapture {
    private let directory: CounterpartOutputDirectory
    private let name: String
    private var file: CounterpartOutputFile?
    private var written = 0
    private(set) var truncated = false

    init(directory: CounterpartOutputDirectory, name: String) {
        self.directory = directory
        self.name = name
    }

    var fileName: String? { written > 0 ? name : nil }

    mutating func write(_ data: Data) {
        let kept = data.prefix(Counterpart.rawLimit - written)
        if kept.count < data.count { truncated = true }
        guard !kept.isEmpty else { return }
        do {
            if file == nil { file = try directory.createFile(named: name) }
            try file!.write(kept)
        } catch {
            fatalError("cannot write raw capture: \(error)")
        }
        written += kept.count
    }

    mutating func close() { file?.close() }
}
