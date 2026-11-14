import CryptoKit
import Darwin
import Foundation
import SanjboxProbeKit
import Security

// Native provenance, not a ServiceManagement registration generation. Reopening NEVER
// restores mutation authority. There is deliberately no journal reset/delete API.
private func requireJournal(_ condition: Bool, _ reason: String) throws {
    guard condition else { throw S8Error.refused("registration journal: " + reason) }
}
private func journalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
struct JournalFileIdentity: Codable, Equatable {
    let device: Int32, inode: UInt64, uid: UInt32, gid: UInt32, mode: UInt16, flags: UInt32
    init(_ s: stat) {
        device = s.st_dev; inode = s.st_ino; uid = s.st_uid; gid = s.st_gid; mode = s.st_mode; flags = s.st_flags
    }
}
private func journalDirectory(_ path: String) throws -> Int32 {
    try requireJournal(path.hasPrefix("/") && !path.hasSuffix("/") && path.utf8.count <= 4096, "absolute canonical path required")
    let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
    try requireJournal(!parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }, "invalid path component")
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    try requireJournal(fd >= 0, "cannot open filesystem root")
    do {
        for part in parts {
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try requireJournal(next >= 0, "directory missing, replaced or linked")
            close(fd); fd = next
        }
        return fd
    } catch { close(fd); throw error }
}
private func journalDirectoryIdentity(_ fd: Int32) throws -> JournalFileIdentity {
    var s = stat()
    try requireJournal(fstat(fd, &s) == 0 && s.st_mode & S_IFMT == S_IFDIR && s.st_uid == geteuid() &&
        s.st_mode & 0o7777 == 0o700 && s.st_flags == 0, "directory owner/mode/flags")
    try requireNoExtendedACL(fd: fd)
    return JournalFileIdentity(s)
}
private func journalNames(_ fd: Int32, maximum: Int) throws -> [String] {
    let copy = dup(fd)
    try requireJournal(copy >= 0, "directory descriptor unavailable")
    guard let directory = fdopendir(copy) else { close(copy); throw S8Error.refused("cannot enumerate journal") }
    defer { closedir(directory) }
    rewinddir(directory)
    var result: [String] = []
    while true {
        errno = 0
        guard let entry = readdir(directory) else { try requireJournal(errno == 0, "directory enumeration failed"); break }
        let name = withUnsafePointer(to: &entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) }
        }
        guard let name else { throw S8Error.refused("non-UTF8 journal name") }
        if name == "." || name == ".." { continue }
        try requireJournal(result.count < maximum && !name.contains("/"), "entry limit or invalid name")
        result.append(name)
    }
    return result.sorted()
}
private func journalRead(_ parent: Int32, _ name: String, maximum: Int) throws -> Data {
    let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    try requireJournal(fd >= 0, "record unavailable or linked")
    defer { close(fd) }
    var before = stat(); var after = stat(); var linked = stat()
    try requireJournal(fstat(fd, &before) == 0 && before.st_mode & S_IFMT == S_IFREG && before.st_mode & 0o7777 == 0o600 &&
        before.st_uid == geteuid() && before.st_nlink == 1 && before.st_flags == 0 && before.st_size >= 1 && before.st_size <= maximum,
        "record metadata or size")
    try requireNoExtendedACL(fd: fd)
    var data = Data(count: Int(before.st_size) + 1)
    let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
    try requireJournal(count == before.st_size, "short, extended or interrupted record read")
    data.count = count
    try requireJournal(fstat(fd, &after) == 0 && fstatat(parent, name, &linked, AT_SYMLINK_NOFOLLOW) == 0 &&
        JournalFileIdentity(before) == JournalFileIdentity(after) && JournalFileIdentity(after) == JournalFileIdentity(linked) &&
        before.st_size == after.st_size && after.st_nlink == 1 && sameTimes(before, after), "record changed during read")
    try requireNoExtendedACL(fd: fd)
    return data
}
private func sameTimes(_ a: stat, _ b: stat) -> Bool {
    a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
    a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
}

public struct NativeSignedAppInventory: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let path: String, identity: JournalFileIdentity, size: Int64?, sha256: String?
    }
    public let runID: String, appPath: String, ownerUID: UInt32, ownerGID: UInt32, hostCodeHash: String
    let entries: [Entry]

    /// Inspects only the actual own bundle: all nested signatures and all file bytes/metadata.
    /// Call after the host's independent expectation check. No caller's receipt supplies authority.
    public static func capture() throws -> Self {
        let run = try fixtureRunID(); let signing = fixtureSelfSigning()
        guard Bundle.main.bundleIdentifier == "org.sanjbox.s8.fixture.host", signing.issues.isEmpty, !signing.adHoc,
              let codeHash = fixtureCodeHash(), getuid() == geteuid(), geteuid() != 0, getgid() == getegid() else {
            throw S8Error.refused("native registration requires own non-ad-hoc signed host")
        }
        let path = Bundle.main.bundleURL.path
        let root = try journalDirectory(path); defer { close(root) }
        let inventory = try scan(root)
        let targets = ["", "/Contents/MacOS/S8LaunchAgent", "/Contents/MacOS/S8LaunchDaemon", "/Contents/Library/LoginItems/S8LoginItem.app"]
        let identifiers: [String?] = ["org.sanjbox.s8.fixture.host", nil, nil, "org.sanjbox.s8.fixture.loginItem"]
        for (suffix, identifier) in zip(targets, identifiers) {
            var code: SecStaticCode?; var raw: CFDictionary?
            try requireJournal(SecStaticCodeCreateWithPath(URL(fileURLWithPath: path + suffix) as CFURL, [], &code) == errSecSuccess && code != nil,
                               "nested static code unavailable")
            let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | SecCSFlags.noNetworkAccess.rawValue)
            try requireJournal(SecStaticCodeCheckValidity(code!, flags, nil) == errSecSuccess &&
                SecCodeCopySigningInformation(code!, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess, "nested signature invalid")
            let info = raw as? [String: Any]
            let signatureFlags = (info?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
            let entitlements = SignaturePolicy.entitlementState(dictionary: info?[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
                rawBlobPresent: info?[kSecCodeInfoEntitlements as String] != nil)
            try requireJournal(SignaturePolicy.issues(validity: errSecSuccess, information: errSecSuccess, flags: signatureFlags,
                identifier: info?[kSecCodeInfoIdentifier as String] as? String, entitlementState: entitlements.0,
                otherEntitlements: entitlements.1, requireAdHoc: false).isEmpty &&
                signatureFlags.map { $0 & SecCodeSignatureFlags.adhoc.rawValue == 0 } == true &&
                (identifier == nil || info?[kSecCodeInfoIdentifier as String] as? String == identifier), "nested signing profile/identifier")
            if suffix.isEmpty {
                let staticHash = (info?[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
                try requireJournal(staticHash == codeHash, "running host differs from signed app on disk")
            }
        }
        try requireJournal(try scan(root) == inventory, "app changed during signature checks")
        let linked = try journalDirectory(path); defer { close(linked) }
        var a = stat(); var b = stat()
        try requireJournal(fstat(root, &a) == 0 && fstat(linked, &b) == 0 && JournalFileIdentity(a) == JournalFileIdentity(b), "app root replaced")
        return .init(runID: run, appPath: path, ownerUID: geteuid(), ownerGID: getegid(), hostCodeHash: codeHash, entries: inventory)
    }

    // Shared native file hashing. Test fixtures are unsigned; production uses capture() above.
    static func scan(_ root: Int32) throws -> [Entry] {
        var result: [Entry] = []; var totalBytes: Int64 = 0
        func visit(_ fd: Int32, _ path: String, depth: Int) throws {
            var before = stat(); var after = stat()
            try requireJournal(result.count < 256 && depth <= 12 && fstat(fd, &before) == 0 && before.st_uid == geteuid() &&
                before.st_flags == 0 && before.st_mode & 0o7022 == 0, "app inventory metadata/budget")
            try requireNoExtendedACL(fd: fd)
            let type = before.st_mode & S_IFMT
            if type == S_IFREG {
                try requireJournal(before.st_nlink == 1 && before.st_size >= 0 && before.st_size <= 64 * 1024 * 1024, "app file link/size")
                totalBytes += before.st_size
                try requireJournal(totalBytes <= 256 * 1024 * 1024, "app byte budget")
                var digest = SHA256(); var bytes = [UInt8](repeating: 0, count: 65_536); var total: Int64 = 0
                while true {
                    let n = Darwin.read(fd, &bytes, bytes.count)
                    if n < 0 && errno == EINTR { continue }
                    try requireJournal(n >= 0, "app read failed")
                    if n == 0 { break }
                    total += Int64(n)
                    try requireJournal(total <= before.st_size, "app grew while hashing")
                    digest.update(data: Data(bytes.prefix(n)))
                }
                try requireJournal(total == before.st_size, "app shrank while hashing")
                result.append(.init(path: path, identity: .init(before), size: total,
                                    sha256: digest.finalize().map { String(format: "%02x", $0) }.joined()))
            } else if type == S_IFDIR {
                result.append(.init(path: path, identity: .init(before), size: nil, sha256: nil))
                let original = try journalNames(fd, maximum: 256)
                for name in original {
                    let child = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    try requireJournal(child >= 0, "app child missing/linked")
                    do {
                        try visit(child, path.isEmpty ? name : path + "/" + name, depth: depth + 1)
                        var actual = stat(); var linked = stat()
                        try requireJournal(fstat(child, &actual) == 0 && fstatat(fd, name, &linked, AT_SYMLINK_NOFOLLOW) == 0 &&
                            JournalFileIdentity(actual) == JournalFileIdentity(linked), "app child replaced")
                        close(child)
                    } catch { close(child); throw error }
                }
                try requireJournal(try journalNames(fd, maximum: 256) == original, "app directory changed")
            } else { throw S8Error.refused("app contains non-file") }
            try requireJournal(fstat(fd, &after) == 0 && JournalFileIdentity(before) == JournalFileIdentity(after) &&
                before.st_size == after.st_size && before.st_nlink == after.st_nlink && sameTimes(before, after), "app changed while hashing")
            try requireNoExtendedACL(fd: fd)
        }
        try visit(root, "", depth: 0)
        return result
    }
}

struct JournalProcess: Codable, Equatable {
    let pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64, bootSeconds: Int64, bootMicroseconds: Int32, auditUID: UInt32, auditSession: Int32
    static func capture() throws -> Self {
        var process = proc_bsdinfo(); var boot = timeval(); var size = MemoryLayout<timeval>.size; var audit = auditinfo_addr()
        try requireJournal(getuid() == geteuid() && geteuid() != 0 && getgid() == getegid() &&
            proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &process, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size &&
            process.pbi_pid == getpid() && process.pbi_uid == geteuid() && sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 &&
            getaudit_addr(&audit, Int32(MemoryLayout<auditinfo_addr>.size)) == 0 && audit.ai_asid > 0 && audit.ai_auid != UInt32.max,
            "own process/boot/audit identity unavailable")
        return .init(pid: getpid(), startSeconds: process.pbi_start_tvsec, startMicroseconds: process.pbi_start_tvusec,
            bootSeconds: Int64(boot.tv_sec), bootMicroseconds: Int32(boot.tv_usec), auditUID: audit.ai_auid, auditSession: audit.ai_asid)
    }
}
private struct JournalHeader: Codable, Equatable {
    let schema: Int, kind: String, root: JournalFileIdentity, inventory: NativeSignedAppInventory
}
private struct JournalRecord: Codable {
    let schema: Int, sequence: Int, previousSHA256: String, operationID: String, service: FixtureService, action: FixtureAction, phase: String, status: Int
    let succeeded: Bool?, errorDomain: String?, errorCode: Int?, process: JournalProcess, expectationSHA256: String
}
private enum NativeRegistrationState {
    case interrupted, registered, unregistered, conflict
    var description: String {
        switch self {
        case .interrupted: "interrupted; API outcome unknown"
        case .registered: "registered; continuity unproven after restart"
        case .unregistered: "unregister returned absent; process/relaunch oracle still required"
        case .conflict: "conflict; API failure or unexpected status"
        }
    }
}
public struct NativeRecoveryReport: Encodable {
    public let journalPath: String, runID: String, signedInventorySHA256: String, services: [String: String], records: Int
    public let mutationAuthorityRestored = false
    public let artifactCleanupAllowed = false
}

// A final device barrier must follow both file and directory fsync. The journal's
// creation ancestry and file are required to share a device before using this sequence.
enum JournalDurability {
    enum Step: Equatable { case fileContents, directoryEntry, deviceBarrier }
    static func commit(file: Int32, directory: Int32,
                       syscall: (Step, Int32) -> Int32 = native) throws {
        for step in [Step.fileContents, .directoryEntry, .deviceBarrier] {
            let descriptor = step == .directoryEntry ? directory : file
            try requireJournal(syscall(step, descriptor) == 0, "record durability failed; partial journal retained")
        }
    }
    private static func native(_ step: Step, _ fd: Int32) -> Int32 {
        step == .deviceBarrier ? fcntl(fd, F_FULLFSYNC) : fsync(fd)
    }
}

public final class NativeRegistrationJournal {
    public struct Operation {
        fileprivate let id: String, service: FixtureService, action: FixtureAction
    }
    public let path: String
    private let fd: Int32, header: JournalHeader, headerBytes: Data, process: JournalProcess
    private var live: [FixtureService: Int] = [:]
    private var pending: Operation?
    private var poisoned = false

    /// Fixed per sealed run and owning UID; no selectable path can bypass a pending result.
    /// Read-only mode never creates directories. This is user app state, not system registration.
    public static func open(inventory: NativeSignedAppInventory, create: Bool) throws -> NativeRegistrationJournal? {
        try requireJournal(UUID(uuidString: inventory.runID)?.uuidString == inventory.runID && inventory.ownerUID == geteuid() &&
                           inventory.ownerGID == getegid(), "run/owner mismatch")
        guard let home = getpwuid(geteuid()).map({ String(cString: $0.pointee.pw_dir) }) else { throw S8Error.refused("own home unavailable") }
        let parentPath = home + "/Library/Application Support"
        let parent = try journalDirectory(parentPath); defer { close(parent) }
        var parentStat = stat()
        try requireJournal(fstat(parent, &parentStat) == 0 && parentStat.st_uid == geteuid() && parentStat.st_mode & 0o022 == 0 &&
                           parentStat.st_flags == 0, "unsafe application support directory")
        try requireNoExtendedACL(fd: parent)
        let name = "org.sanjbox.s8.fixture-registration"
        if create {
            try requireJournal(mkdirat(parent, name, 0o700) == 0 || errno == EEXIST, "cannot create own journal parent")
            try requireJournal(fsync(parent) == 0, "journal parent sync failed")
        }
        let container = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if container < 0 && errno == ENOENT && !create { return nil }
        try requireJournal(container >= 0, "journal parent unavailable")
        defer { close(container) }
        let containerIdentity = try journalDirectoryIdentity(container)
        try requireJournal(containerIdentity.device == parentStat.st_dev, "journal parent changed filesystem")
        return try NativeRegistrationJournal(parent: container, name: inventory.runID,
            path: parentPath + "/" + name + "/" + inventory.runID, inventory: inventory, create: create)
    }

    // Internal only: native filesystem tests use their own disposable parent.
    init?(parent: Int32, name: String, path: String, inventory: NativeSignedAppInventory, create: Bool) throws {
        try requireJournal(name == inventory.runID && UUID(uuidString: name)?.uuidString == name && inventory.ownerUID == geteuid() &&
                           inventory.ownerGID == getegid(), "run/owner mismatch")
        let parentIdentity = try journalDirectoryIdentity(parent)
        var created = false
        if create {
            if mkdirat(parent, name, 0o700) == 0 { created = true }
            else { try requireJournal(errno == EEXIST, "cannot create run journal") }
            try requireJournal(fsync(parent) == 0, "run journal parent sync failed")
        }
        let opened = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if opened < 0 && errno == ENOENT && !create { return nil }
        try requireJournal(opened >= 0, "run journal unavailable")
        var transferred = false
        do {
            let identity = try journalDirectoryIdentity(opened)
            try requireJournal(identity.device == parentIdentity.device, "run journal changed filesystem")
            try requireJournal(flock(opened, LOCK_EX | LOCK_NB) == 0, "busy; another host owns this run")
            let expected = JournalHeader(schema: 1, kind: "s8-native-registration-journal", root: identity, inventory: inventory)
            let bytes = try journalJSON(expected)
            if created {
                try requireJournal(try journalNames(opened, maximum: 65).isEmpty, "new root is not empty")
                try Self.write(opened, name: "header.json", data: bytes)
            } else {
                let actual = try journalRead(opened, "header.json", maximum: 262_144)
                try requireJournal(actual == bytes, "inventory/run/app/UID/root drift or malformed header")
            }
            self.fd = opened; self.path = path; self.header = expected; self.headerBytes = bytes
            self.process = try JournalProcess.capture()
            // Swift runs deinit if a throw occurs after all stored properties initialize.
            // Before this point catch owns the fd; afterwards deinit owns it (including load failure).
            transferred = true
            _ = try load()
        } catch { if !transferred { close(opened) }; throw error }
    }
    deinit { close(fd) }

    private static func write(_ fd: Int32, name: String, data: Data) throws {
        try requireJournal(data.count <= 262_144, "record too large")
        let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try requireJournal(file >= 0, "record conflict")
        defer { close(file) }
        var s = stat()
        let directoryIdentity = try journalDirectoryIdentity(fd)
        try requireJournal(fstat(file, &s) == 0 && s.st_uid == geteuid() && s.st_mode & 0o7777 == 0o600 && s.st_nlink == 1 && s.st_flags == 0 && s.st_dev == directoryIdentity.device,
                           "new record metadata/device")
        try requireNoExtendedACL(fd: file)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                try requireJournal(n > 0, "record write failed; partial journal retained")
                offset += n
            }
        }
        try JournalDurability.commit(file: file, directory: fd)
        try requireJournal(try journalRead(fd, name, maximum: 262_144) == data, "record changed during commit")
    }
    private func verifyRoot() throws {
        try requireJournal(!poisoned && (try journalDirectoryIdentity(fd)) == header.root, "closed after failure or root metadata drift")
        let linked = try journalDirectory(path); defer { close(linked) }
        try requireJournal(try journalDirectoryIdentity(linked) == header.root, "root path replaced")
        try requireJournal(try journalRead(fd, "header.json", maximum: 262_144) == headerBytes, "header changed")
    }
    private func load() throws -> ([JournalRecord], [FixtureService: NativeRegistrationState]) {
        try verifyRoot()
        let files = try journalNames(fd, maximum: 65)
        try requireJournal(files.contains("header.json"), "header missing")
        let count = files.count - 1
        try requireJournal(count <= 64 && Set(files) == Set(["header.json"] + (0..<count).map { String(format: "%03d.json", $0 + 1) }),
                           "unexpected, missing or noncontiguous records")
        var records: [JournalRecord] = []; var states: [FixtureService: NativeRegistrationState] = [:]
        var previous = sha256(headerBytes); var unmatched: JournalRecord?
        var registrations: [FixtureService: JournalRecord] = [:]; var operationIDs: Set<String> = []
        for sequence in 1..<(count + 1) {
            let bytes = try journalRead(fd, String(format: "%03d.json", sequence), maximum: 16_384)
            let record = try JSONDecoder().decode(JournalRecord.self, from: bytes)
            try requireJournal(try journalJSON(record) == bytes, "noncanonical/unknown/duplicate record fields")
            try requireJournal(record.schema == 1 && record.sequence == sequence && record.previousSHA256 == previous &&
                UUID(uuidString: record.operationID)?.uuidString == record.operationID && record.service.permitsUserMutation && record.action != .status &&
                (0...3).contains(record.status) && record.process.pid > 0 && record.process.startSeconds > 0 && record.process.bootSeconds > 0 &&
                record.process.auditUID != UInt32.max && record.process.auditSession > 0 &&
                record.process.startMicroseconds < 1_000_000 && (0..<1_000_000).contains(record.process.bootMicroseconds) &&
                record.expectationSHA256.count == 64 &&
                record.expectationSHA256.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "invalid record identity/schema/hash chain")
            if record.phase == "intent" {
                try requireJournal(!operationIDs.contains(record.operationID) && !states.values.contains(.conflict) &&
                    unmatched == nil && record.succeeded == nil && record.errorDomain == nil && record.errorCode == nil &&
                    ((record.action == .register && states[record.service] == nil && record.status == 0) ||
                     (record.action == .unregister && states[record.service] == .registered && registrations[record.service]?.status == record.status &&
                      registrations[record.service]?.process == record.process && [1, 2].contains(record.status))),
                    "invalid intent transition")
                operationIDs.insert(record.operationID)
                unmatched = record; states[record.service] = .interrupted
            } else if record.phase == "result", let intent = unmatched {
                try requireJournal(record.operationID == intent.operationID && record.service == intent.service && record.action == intent.action &&
                    record.process == intent.process && record.expectationSHA256 == intent.expectationSHA256 && record.succeeded != nil &&
                    ((record.succeeded == true && record.errorDomain == nil && record.errorCode == nil) ||
                     (record.succeeded == false && record.errorDomain != nil && record.errorCode != nil)), "unpaired result")
                if record.succeeded == true && record.action == .register && [1, 2].contains(record.status) {
                    states[record.service] = .registered; registrations[record.service] = record
                } else if record.succeeded == true && record.action == .unregister && record.status == 0 {
                    states[record.service] = .unregistered
                } else { states[record.service] = .conflict }
                unmatched = nil
            } else { throw S8Error.refused("unexpected phase or result without intent") }
            previous = sha256(bytes); records.append(record)
        }
        return (records, states)
    }
    public func revokeLiveAuthority() { poisoned = true; live.removeAll() }

    public func recoveryReport(inventory: NativeSignedAppInventory) throws -> NativeRecoveryReport {
        try requireJournal(inventory == header.inventory, "recovery app inventory drift")
        let (records, states) = try load()
        return .init(journalPath: path, runID: header.inventory.runID, signedInventorySHA256: sha256(try journalJSON(header.inventory)),
            services: Dictionary(uniqueKeysWithValues: states.map { ($0.key.rawValue, $0.value.description) }), records: records.count)
    }
    public func begin(_ service: FixtureService, _ action: FixtureAction, status: Int,
                      inventory: NativeSignedAppInventory, expectation: S8Expectation) throws -> Operation {
        do {
            try requireJournal(inventory == header.inventory && (try JournalProcess.capture()) == process, "app or process/session drift")
            try requireJournal(expectation.configurationIssues().isEmpty && expectation.realUID == geteuid() &&
                expectation.effectiveUID == geteuid() && expectation.realGID == getgid() && expectation.effectiveGID == getegid() &&
                expectation.auditUID == process.auditUID && expectation.auditSessionID == process.auditSession,
                "expectation owner/audit identity changed")
            let (records, states) = try load()
            try requireJournal(pending == nil && records.count <= 62 && service.permitsUserMutation && action != .status &&
                !states.values.contains(where: { $0 == .interrupted || $0 == .conflict }), "pending/conflicting run or capacity")
            if action == .register {
                try requireJournal(status == 0 && states[service] == nil && live[service] == nil, "existing or previous registration cannot be adopted/repeated")
            } else {
                try requireJournal(live[service] == status && [1, 2].contains(status) &&
                    states[service] == .registered, "no live provenance; restart/status drift requires independent ownership oracle")
            }
            let operation = Operation(id: UUID().uuidString, service: service, action: action)
            let prior = records.isEmpty ? sha256(headerBytes) : sha256(try journalJSON(records.last!))
            let record = JournalRecord(schema: 1, sequence: records.count + 1, previousSHA256: prior, operationID: operation.id,
                service: service, action: action, phase: "intent", status: status, succeeded: nil, errorDomain: nil, errorCode: nil,
                process: process, expectationSHA256: sha256(try journalJSON(expectation)))
            live.removeValue(forKey: service)
            try Self.write(fd, name: String(format: "%03d.json", record.sequence), data: journalJSON(record))
            _ = try load(); pending = operation
            return operation
        } catch { poisoned = true; live.removeAll(); throw error }
    }
    public func finish(_ operation: Operation, status: Int, error: NSError?, inventory: NativeSignedAppInventory) throws {
        do {
            try requireJournal(inventory == header.inventory && (try JournalProcess.capture()) == process &&
                pending?.id == operation.id && (0...3).contains(status), "result binding/process/pending mismatch")
            let (records, _) = try load()
            guard let intent = records.last, intent.phase == "intent", intent.operationID == operation.id else { throw S8Error.refused("missing intent") }
            try requireJournal(error.map { !$0.domain.isEmpty && $0.domain.utf8.count <= 256 } ?? true, "error domain bound")
            let result = JournalRecord(schema: 1, sequence: records.count + 1, previousSHA256: sha256(try journalJSON(intent)), operationID: operation.id,
                service: operation.service, action: operation.action, phase: "result", status: status, succeeded: error == nil,
                errorDomain: error?.domain, errorCode: error?.code, process: process, expectationSHA256: intent.expectationSHA256)
            try Self.write(fd, name: String(format: "%03d.json", result.sequence), data: journalJSON(result))
            _ = try load(); pending = nil
            if error == nil && operation.action == .register && [1, 2].contains(status) { live[operation.service] = status }
        } catch { poisoned = true; live.removeAll(); throw error }
    }
}
