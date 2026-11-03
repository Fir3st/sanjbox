import Darwin
import Foundation

/// Only generated names below the real /private/tmp. Each operation uses held directory FDs,
/// O_NOFOLLOW and create-exclusive files. No append, arbitrary input paths, delete or overwrite.
public final class Dataset {
    public let path: String
    private let fd: Int32
    private let device: dev_t
    private let inode: ino_t
    public init(runID: String, role: String) throws {
        try require(identifier(runID) && ["presentation", "ram", "report", "offscreen"].contains(role), "invalid dataset name")
        let name = "sanjbox-a2-\(runID)-uid\(geteuid())-\(role)"
        path = "/private/tmp/" + name
        let parent = open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try require(parent >= 0, "cannot open scratch parent")
        defer { close(parent) }
        try require(mkdirat(parent, name, 0o700) == 0, "dataset already exists or cannot be created; preserving conflict")
        fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try require(fd >= 0, "cannot open new dataset")
        var info = stat()
        guard fstat(fd, &info) == 0 && info.st_uid == geteuid() && info.st_mode & 0o777 == 0o700 else {
            close(fd); throw InstrumentError("dataset ownership/mode conflict")
        }
        device = info.st_dev; inode = info.st_ino
    }
    deinit { close(fd) }
    public func write<T: Encodable>(_ name: String, _ value: T) throws {
        try require(["intent.json", "recording.json", "report.json"].contains(name), "unsupported output name")
        var info = stat()
        try require(fstat(fd, &info) == 0 && info.st_dev == device && info.st_ino == inode && info.st_uid == geteuid() && info.st_mode & 0o777 == 0o700, "dataset changed; preserving conflict")
        let data = try encoded(value)
        try require(data.count <= 32 * 1024 * 1024, "output exceeds 32 MiB")
        let output = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try require(output >= 0, "output exists or cannot be created; preserving conflict")
        defer { close(output) }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(output, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0 && errno == EINTR { continue }
                try require(count > 0, "output write failed; partial output preserved")
                written += count
            }
        }
        try require(fsync(output) == 0, "output sync failed")
    }
    /// Explicitly staged own synthetic/recording JSON; never reads a caller-supplied path.
    public static func readFixture(name: String) throws -> Data {
        try require(identifier(name), "invalid fixture name")
        let parent = open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try require(parent >= 0, "cannot open scratch parent")
        defer { close(parent) }
        let input = openat(parent, "sanjbox-a2-fixture-\(geteuid())-\(name).json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        try require(input >= 0, "cannot open explicitly staged own fixture")
        defer { close(input) }
        var before = stat()
        try require(fstat(input, &before) == 0 && (before.st_mode & S_IFMT) == S_IFREG && before.st_uid == geteuid() && before.st_nlink == 1 &&
            before.st_size > 0 && before.st_size <= 32 * 1024 * 1024, "fixture type/owner/size/link conflict")
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(input, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            try require(count >= 0, "fixture read failed")
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            try require(data.count <= 32 * 1024 * 1024, "fixture exceeds bound")
        }
        var after = stat()
        try require(fstat(input, &after) == 0 && before.st_size == after.st_size && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec && data.count == before.st_size, "fixture changed while read")
        return data
    }
}
