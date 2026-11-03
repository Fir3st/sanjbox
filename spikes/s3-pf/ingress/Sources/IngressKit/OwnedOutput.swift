import CryptoKit
import Darwin
import Foundation

private struct OutputState: Codable {
    var schemaVersion = 1
    var runID: UUID
    var directoryDevice: UInt64
    var directoryInode: UInt64
    var reportDevice: UInt64
    var reportInode: UInt64
    var reportSize: Int
    var reportSHA256: String
    static let shape: Shape = .object(["schemaVersion": .scalar, "runID": .scalar, "directoryDevice": .scalar,
        "directoryInode": .scalar, "reportDevice": .scalar, "reportInode": .scalar, "reportSize": .scalar, "reportSHA256": .scalar])
}
public struct CleanupReport: Codable {
    public var runID: UUID
    public var status: String
    public var path: String
}
public enum OwnedOutput {
    public static func path(_ id: UUID) -> String { "/private/tmp/sanjbox-c3-run-" + id.uuidString.lowercased() }
    private static func root() throws -> Int32 {
        let fd = open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw IngressError("private tmp root unavailable") }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == 0, s.st_mode & S_IFMT == S_IFDIR, s.st_mode & S_ISVTX != 0 else {
            close(fd); throw IngressError("unexpected private tmp root metadata")
        }
        return fd
    }
    private static func name(_ id: UUID) -> String { "sanjbox-c3-run-" + id.uuidString.lowercased() }
    private static func metadata(_ fd: Int32, directory: Bool) throws -> stat {
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == geteuid(), s.st_gid == getegid(), s.st_flags == 0, s.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              s.st_mode & 0o777 == (directory ? 0o700 : 0o600), directory || s.st_nlink == 1 else {
            throw IngressError("output ownership/type/mode/link conflict")
        }
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            // Darwin reports ENOENT when this object has no extended ACL.
            guard errno == ENOENT else { throw IngressError("output ACL unavailable; preserved") }
            return s
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_valid(acl) == 0, acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL, entry == nil else { throw IngressError("output has extended ACL; preserved") }
        return s
    }
    private static func create(_ data: Data, _ file: String, directory: Int32) throws -> stat {
        let fd = openat(directory, file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw IngressError("create-new output refused") }
        defer { close(fd) }
        guard fchown(fd, uid_t.max, getegid()) == 0 else { throw IngressError("cannot set own output group") }
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw IngressError("output write failed; partial output preserved") }
            offset += n
        }
        guard fsync(fd) == 0 else { throw IngressError("output sync failed; output preserved") }
        return try metadata(fd, directory: false)
    }
    public static func save(_ report: SmokeReport) throws -> String {
        let parent = try root(); defer { close(parent) }
        guard mkdirat(parent, name(report.runID), 0o700) == 0 else { throw IngressError("run directory already exists/unavailable; no overwrite") }
        let fd = openat(parent, name(report.runID), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw IngressError("new output directory unavailable; preserved") }
        defer { close(fd) }
        guard fchown(fd, uid_t.max, getegid()) == 0 else { throw IngressError("cannot set own directory group") }
        let directory = try metadata(fd, directory: true)
        let data = try encodeJSON(report)
        let file = try create(data, "report.json", directory: fd)
        let state = OutputState(runID: report.runID, directoryDevice: UInt64(directory.st_dev), directoryInode: directory.st_ino,
            reportDevice: UInt64(file.st_dev), reportInode: file.st_ino, reportSize: data.count, reportSHA256: digest(data))
        _ = try create(encodeJSON(state), "state.json", directory: fd)
        return path(report.runID)
    }
    private static func readFile(_ file: String, directory: Int32, limit: Int) throws -> (Data, stat) {
        let fd = openat(directory, file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw IngressError("missing/conflicting output file") }
        defer { close(fd) }
        let original = try metadata(fd, directory: false)
        guard original.st_size >= 0, original.st_size <= limit else { throw IngressError("output size conflict") }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw IngressError("output read failure") }
            if n == 0 { break }
            result.append(contentsOf: buffer.prefix(n))
            guard result.count <= limit else { throw IngressError("output grew; preserved") }
        }
        let current = try metadata(fd, directory: false)
        guard original.st_size == result.count, original.st_size == current.st_size,
              original.st_mtimespec.tv_sec == current.st_mtimespec.tv_sec && original.st_mtimespec.tv_nsec == current.st_mtimespec.tv_nsec, original.st_ctimespec.tv_sec == current.st_ctimespec.tv_sec && original.st_ctimespec.tv_nsec == current.st_ctimespec.tv_nsec else { throw IngressError("output changed while reading; preserved") }
        return (result, current)
    }
    private static func unchanged(_ file: String, directory: Int32, previous: stat) -> Bool {
        var current = stat()
        return fstatat(directory, file, &current, AT_SYMLINK_NOFOLLOW) == 0 && current.st_dev == previous.st_dev &&
            current.st_ino == previous.st_ino && current.st_uid == previous.st_uid && current.st_gid == previous.st_gid && current.st_flags == previous.st_flags && current.st_mode == previous.st_mode &&
            current.st_nlink == previous.st_nlink && current.st_size == previous.st_size &&
            current.st_mtimespec.tv_sec == previous.st_mtimespec.tv_sec && current.st_mtimespec.tv_nsec == previous.st_mtimespec.tv_nsec && current.st_ctimespec.tv_sec == previous.st_ctimespec.tv_sec && current.st_ctimespec.tv_nsec == previous.st_ctimespec.tv_nsec
    }
    public static func cleanup(runID: UUID, apply: Bool) throws -> CleanupReport {
        let parent = try root(); defer { close(parent) }
        let fd = openat(parent, name(runID), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return .init(runID: runID, status: "alreadyAbsent", path: path(runID)) }
        guard fd >= 0 else { throw IngressError("output directory conflict; preserved") }
        defer { close(fd) }
        let directory = try metadata(fd, directory: true)
        let duplicate = dup(fd)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else { if duplicate >= 0 { close(duplicate) }; throw IngressError("cannot inspect output entries") }
        var entries = Set<String>()
        while let entry = readdir(stream) {
            let value = withUnsafePointer(to: &entry.pointee.d_name) { p in p.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            entries.insert(value)
            if entries.count > 4 { break }
        }
        closedir(stream)
        guard entries == [".", "..", "state.json", "report.json"] else { throw IngressError("extra/missing output entries; all conflicts preserved") }
        let (stateData, stateMetadata) = try readFile("state.json", directory: fd, limit: 4096)
        let state = try strictDecode(OutputState.self, data: stateData, shape: OutputState.shape)
        let (report, reportMetadata) = try readFile("report.json", directory: fd, limit: 1_048_576)
        guard state.schemaVersion == 1, state.runID == runID, state.directoryDevice == UInt64(directory.st_dev), state.directoryInode == directory.st_ino,
              state.reportDevice == UInt64(reportMetadata.st_dev), state.reportInode == reportMetadata.st_ino,
              state.reportSize == report.count, state.reportSHA256 == digest(report) else { throw IngressError("output manifest/hash/inode conflict; all files preserved") }
        guard unchanged(name(runID), directory: parent, previous: directory), unchanged("state.json", directory: fd, previous: stateMetadata),
              unchanged("report.json", directory: fd, previous: reportMetadata) else { throw IngressError("output changed; preserved") }
        // Recheck ACL/flags on all opened objects before the first unlink.
        _ = try metadata(fd, directory: true)
        _ = try readFile("state.json", directory: fd, limit: 4096)
        _ = try readFile("report.json", directory: fd, limit: 1_048_576)
        if apply {
            guard unlinkat(fd, "report.json", 0) == 0, unlinkat(fd, "state.json", 0) == 0,
                  unlinkat(parent, name(runID), AT_REMOVEDIR) == 0 else { throw IngressError("cleanup incomplete; inspect remaining own directory") }
        }
        return .init(runID: runID, status: apply ? "removedOwnFiles" : "dryRunVerifiedTwoOwnFiles", path: path(runID))
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
