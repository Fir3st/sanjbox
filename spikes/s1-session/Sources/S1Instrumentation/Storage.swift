import Darwin
import Foundation

/// Only generated names below the real /private/tmp. Each operation uses held directory FDs,
/// O_NOFOLLOW and create-exclusive files. No arbitrary input paths, delete or overwrite.
/// Only the new held process-series journal FD appends during its own acquisition.
public final class Dataset {
    public let path: String
    private let fd: Int32
    private let device: dev_t
    private let inode: ino_t
    public init(runID: String, role: String) throws {
        try require(identifier(runID) && ["presentation", "ram", "report", "offscreen", "login-marker", "process-memory", "process-series", "descendant-memory"].contains(role), "invalid dataset name")
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
    public func write<T: Encodable>(_ name: String, _ value: T, compact: Bool = false) throws {
        try require(["intent.json", "recording.json", "report.json", "registry.json", "registry-1.json", "registry-2.json"].contains(name), "unsupported output name")
        var info = stat()
        try require(fstat(fd, &info) == 0 && info.st_dev == device && info.st_ino == inode && info.st_uid == geteuid() && info.st_mode & 0o777 == 0o700, "dataset changed; preserving conflict")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try compact ? encoder.encode(value) : encoded(value)
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
    /// A new in-progress journal only. Never open or append an existing path/run.
    /// The held FD belongs to this dataset; each acquired point is persisted before another read.
    func processSeriesJournal(runID: String) throws -> ProcessSeriesJournal {
        try require(identifier(runID), "invalid journal run ID")
        var info = stat()
        try require(fstat(fd, &info) == 0 && info.st_dev == device && info.st_ino == inode && info.st_uid == geteuid() && info.st_mode & 0o777 == 0o700, "dataset changed before journal creation")
        let output = openat(fd, "samples.jsonl", O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try require(output >= 0, "journal exists or cannot be created; preserving conflict")
        return ProcessSeriesJournal(fd: output, runID: runID)
    }
    func descendantJournal(runID: String) throws -> DescendantJournal {
        var info = stat()
        try require(fstat(fd, &info) == 0 && info.st_dev == device && info.st_ino == inode && info.st_uid == geteuid() && info.st_mode & 0o777 == 0o700, "dataset changed before journal creation")
        let output = openat(fd, "descendants.jsonl", O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try require(output >= 0, "descendant journal exists or cannot be created")
        return DescendantJournal(fd: output, runID: runID)
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

/// An append-only stream on a fresh held FD during acquisition, immutable after closure.
/// It is raw partial evidence, never a complete recording or an automatic recovery/verdict.
struct ProcessSeriesJournalEntry: Codable {
    var schemaVersion = 1
    var runID: String
    var sequence: Int
    var window: Window
    var point: ProcessSeriesPoint
}
final class ProcessSeriesJournal {
    private let fd: Int32
    private let runID: String
    private var count = 0
    private var bytesWritten = 0
    init(fd: Int32, runID: String) { self.fd = fd; self.runID = runID }
    deinit { close(fd) }
    func append(_ point: ProcessSeriesPoint, window: Window) throws {
        try require(count < 32 * 602, "process journal count bound")
        let entry = ProcessSeriesJournalEntry(runID: runID, sequence: count, window: window, point: point)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var bytes = try encoder.encode(entry); bytes.append(10)
        try require(bytes.count <= 4096 && bytesWritten + bytes.count <= 32 * 1024 * 1024, "process journal size bound")
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if result < 0 && errno == EINTR { continue }
                try require(result > 0, "process journal write failed; partial prefix retained")
                offset += result
            }
        }
        try require(fsync(fd) == 0, "process journal sync failed; partial evidence retained")
        bytesWritten += bytes.count
        count += 1
    }
}

/// Separate format: the fixed-registry journal inspector intentionally does not accept this stream.
final class DescendantJournal {
    private let fd: Int32
    private let runID: String
    private var count = 0, bytesWritten = 0
    init(fd: Int32, runID: String) { self.fd = fd; self.runID = runID }
    deinit { close(fd) }
    private struct Entry: Encodable {
        var schemaVersion = 1
        var mode = "descendant-memory"
        var runID: String
        var sequence: Int
        var observation: DescendantObservation
    }
    func append(_ point: DescendantObservation) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(Entry(runID: runID, sequence: count, observation: point)); data.append(10)
        try require(count < 180_000 && data.count <= 8192 && bytesWritten + data.count <= 32 * 1024 * 1024, "descendant journal resource bound")
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                try require(n > 0, "descendant journal write failed")
                offset += n
            }
        }
        try require(fsync(fd) == 0, "descendant journal sync failed")
        count += 1; bytesWritten += data.count
    }
}
