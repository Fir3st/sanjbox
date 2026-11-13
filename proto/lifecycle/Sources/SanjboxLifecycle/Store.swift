import Foundation
import CryptoKit
import Darwin

func canonical<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(value)
    guard bytes.count <= 1024 * 1024 else { throw LifecycleFailure("record exceeds 1 MiB") }
    return bytes
}
func decodeCanonical<T: Codable>(_ type: T.Type, _ bytes: Data) throws -> T {
    guard bytes.count <= 1024 * 1024 else { throw LifecycleFailure("record exceeds 1 MiB") }
    let value = try JSONDecoder().decode(type, from: bytes)
    guard try canonical(value) == bytes else { throw LifecycleFailure("noncanonical, duplicate or unknown field") }
    return value
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

struct Head: Codable, Equatable { var schema = "sanjbox.mock-lifecycle.head.v1"; var count: Int; var digest: String }

/// Private, exclusively locked test fixture. Fsync is exercised, not a claim of power-loss safety.
/// Caller owns the namespace; no defense against its owner rolling back the entire fixture.
public final class LifecycleStore {
    public let path: String
    private let directory: Int32
    private let lock: Int32
    private var poisoned = false
    private var flushed: [String: String] = [:]
    private var decodedEvents: [String: (Data, JournalEntry, String)] = [:]
    private let device: dev_t
    private let inode: ino_t
    // Test fault seam; a thrown write/flush error poisons this instance, including post-write errors.
    public var writeHook: ((String) throws -> Void)?
    public static let prefix = "/private/tmp/sanjbox-h2-"
    static let maximumEvents = 2048

    public static func create() throws -> LifecycleStore {
        var template = Array((prefix + "XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw LifecycleFailure("mkdtemp failed") }
        let path = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LifecycleFailure("fixture open failed") }
        defer { close(fd) }
        let lock = openat(fd, "lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw LifecycleFailure("lock create failed") }
        close(lock)
        let store = try LifecycleStore(path: path)
        try store.writeNew("head.json", data: canonical(Head(count: 0, digest: "genesis")))
        try store.writeNew("world.json", data: canonical(MockWorld()))
        try store.flush(fd)
        return store
    }

    public init(path: String) throws {
        guard path.hasPrefix(Self.prefix), !path.dropFirst(Self.prefix.count).isEmpty,
              !path.dropFirst(Self.prefix.count).contains("/"), !path.contains("..") else {
            throw LifecycleFailure("only an owned H2 temporary fixture may be opened")
        }
        self.path = path
        directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw LifecycleFailure("fixture directory unavailable") }
        var st = stat()
        guard fstat(directory, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o777 == 0o700 else {
            close(directory); throw LifecycleFailure("fixture is not private and owned")
        }
        device = st.st_dev; inode = st.st_ino
        lock = openat(directory, "lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard lock >= 0 else { close(directory); throw LifecycleFailure("lock missing") }
        do { try checkFile(lock); guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw LifecycleFailure("fixture already locked") } }
        catch { close(lock); close(directory); throw error }
    }
    deinit { flock(lock, LOCK_UN); close(lock); close(directory) }

    private func checkFile(_ fd: Int32) throws {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
              st.st_mode & 0o777 == 0o600, st.st_nlink == 1, st.st_uid == getuid(),
              st.st_size >= 0, st.st_size <= 1024 * 1024 else { throw LifecycleFailure("invalid private record metadata") }
    }
    private func usable() throws {
        guard !poisoned else { throw LifecycleFailure("store poisoned by I/O failure; reopen for verification") }
        var current = stat()
        guard lstat(path, &current) == 0, current.st_mode & S_IFMT == S_IFDIR,
              current.st_dev == device, current.st_ino == inode, current.st_uid == getuid(),
              current.st_mode & 0o777 == 0o700 else { throw LifecycleFailure("fixture path identity changed") }
    }
    private func flush(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw LifecycleFailure("fsync failed") }
    }
    private func names() throws -> Set<String> {
        try usable()
        // Enumerate through the held descriptor, not a caller-controlled filename.
        let duplicate = dup(directory)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else { throw LifecycleFailure("directory enumeration failed") }
        defer { closedir(stream) }
        rewinddir(stream)
        var result = Set<String>()
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.insert(name) }
            guard result.count <= Self.maximumEvents + 3 else { throw LifecycleFailure("too many records") }
        }
        return result
    }
    func read(_ name: String) throws -> Data {
        try usable()
        let fd = openat(directory, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw LifecycleFailure("record missing or unreadable: \(name)") }
        defer { close(fd) }
        try checkFile(fd)
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw LifecycleFailure("record stat failed") }
        var buffer = [UInt8](repeating: 0, count: Int(before.st_size) + 1)
        var count = 0
        while count < buffer.count {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: count), $0.count - count) }
            if n < 0 { throw LifecycleFailure("record read failed") }
            if n == 0 { break }
            count += n
        }
        guard count <= 1024 * 1024 else { throw LifecycleFailure("record too large") }
        try checkFile(fd)
        var after = stat()
        guard fstat(fd, &after) == 0, stamp(before) == stamp(after) else { throw LifecycleFailure("record changed during read") }
        let bytes = Data(buffer.prefix(count)), receipt = stamp(after) + ":" + digest(bytes)
        // Cache only the exact metadata+bytes receipt flushed by this store instance.
        if flushed[name] != receipt {
            do { try flush(fd); try flush(directory) } catch { poisoned = true; throw error }
            flushed[name] = receipt
        }
        return bytes
    }
    private func stamp(_ value: stat) -> String {
        "\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    }
    private func writeNew(_ name: String, data: Data) throws {
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LifecycleFailure("exclusive record creation failed") }
        defer { close(fd) }
        var count = 0
        while count < data.count {
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: count), $0.count - count) }
            guard n > 0 else { throw LifecycleFailure("record write failed") }
            count += n
        }
        try writeHook?("afterWrite:\(name)")
        try flush(fd); try flush(directory)
        try writeHook?("afterFlush:\(name)")
    }
    func replace(_ name: String, data: Data) throws {
        try usable()
        do {
            // A surviving replacement is intentionally an incomplete transaction: never auto-delete.
            _ = try read(name)
            try writeNew("replacement.json", data: data)
            guard renameat(directory, "replacement.json", directory, name) == 0 else { throw LifecycleFailure("replacement failed") }
            try writeHook?("afterRename:\(name)")
            try flush(directory)
        } catch { poisoned = true; throw error }
    }
    func entries() throws -> [JournalEntry] {
        let head = try decodeCanonical(Head.self, read("head.json"))
        guard head.schema == "sanjbox.mock-lifecycle.head.v1", (0...Self.maximumEvents).contains(head.count) else { throw LifecycleFailure("invalid journal head") }
        let expected = Set(["head.json", "world.json", "lock"] + (0..<head.count).map(Self.eventName))
        guard try names() == expected else { throw LifecycleFailure("missing, orphan or unknown fixture entry") }
        var result: [JournalEntry] = [], previous = "genesis"
        for index in 0..<head.count {
            let name = Self.eventName(index), bytes = try read(name)
            let event: JournalEntry, hash: String
            if let cached = decodedEvents[name], cached.0 == bytes { event = cached.1; hash = cached.2 }
            else {
                event = try decodeCanonical(JournalEntry.self, bytes); hash = digest(bytes)
                decodedEvents[name] = (bytes, event, hash)
            }
            guard event.schema == "sanjbox.mock-lifecycle.event.v1", event.sequence == index,
                  event.previous == previous else { throw LifecycleFailure("journal chain mismatch") }
            result.append(event); previous = hash
        }
        guard previous == head.digest else { throw LifecycleFailure("head digest mismatch") }
        return result
    }
    static func eventName(_ index: Int) -> String { String(format: "%06d.json", index) }
    func append(_ event: JournalEntry) throws {
        try usable()
        do {
            let current = try entries()
            guard current.count < Self.maximumEvents, event.sequence == current.count else { throw LifecycleFailure("journal capacity/sequence") }
            let bytes = try canonical(event)
            try writeNew(Self.eventName(current.count), data: bytes)
            try replace("head.json", data: canonical(Head(count: current.count + 1, digest: digest(bytes))))
        } catch { poisoned = true; throw error }
    }
    /// Fixture cleanup is explicit and refuses pending operations, corruption and foreign entries.
    public func destroyCompletedFixture() throws {
        let records = try LifecycleCoordinator(store: self).checkpoint()
        guard records.values.allSatisfy({ $0.machine.state == .cleaned && $0.progress == nil }) else {
            throw LifecycleFailure("fixture still holds a zone; preserve for review")
        }
        let ownedNames = try names().subtracting(["lock"])
        for name in ownedNames { _ = try read(name) }
        try checkFile(lock)
        try usable()
        for name in ownedNames {
            guard unlinkat(directory, name, 0) == 0 else { throw LifecycleFailure("fixture unlink failed") }
        }
        guard unlinkat(directory, "lock", 0) == 0, rmdir(path) == 0 else { throw LifecycleFailure("fixture removal failed") }
        poisoned = true
    }
}
