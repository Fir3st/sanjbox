import Darwin
import Foundation

private func recoveryACLIsEmpty(_ fd: Int32) -> Bool {
    guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var flagset: acl_flagset_t?
    guard acl_get_flagset_np(UnsafeMutableRawPointer(acl), &flagset) == 0, let flagset else { return false }
    for flag in [ACL_FLAG_DEFER_INHERIT, ACL_FLAG_NO_INHERIT, ACL_ENTRY_INHERITED, ACL_ENTRY_FILE_INHERIT,
                 ACL_ENTRY_DIRECTORY_INHERIT, ACL_ENTRY_LIMIT_INHERIT, ACL_ENTRY_ONLY_INHERIT] {
        guard acl_get_flag_np(flagset, flag) == 0 else { return false }
    }
    var entry: acl_entry_t?
    errno = 0
    return acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == -1 && errno == EINVAL
}

private func stamp(_ fd: Int32, directory: Bool) throws -> RecoveryStamp {
    var s = stat()
    guard fstat(fd, &s) == 0, s.st_uid == geteuid(), s.st_flags == 0,
          s.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
          s.st_mode & 0o7777 == (directory ? 0o700 : 0o600),
          directory || s.st_nlink == 1, recoveryACLIsEmpty(fd),
          directory || (s.st_size >= 0 && s.st_size <= 64 * 1024 + 1)
    else { throw RecoveryFailure("unsafe private mock object metadata") }
    return .init(device: s.st_dev, inode: s.st_ino, uid: s.st_uid, gid: s.st_gid, mode: s.st_mode,
                 birthSeconds: Int64(s.st_birthtimespec.tv_sec), birthNanos: Int64(s.st_birthtimespec.tv_nsec), generation: s.st_gen,
                 size: directory ? 0 : s.st_size, changeSeconds: directory ? 0 : Int64(s.st_ctimespec.tv_sec),
                 changeNanos: directory ? 0 : Int64(s.st_ctimespec.tv_nsec))
}

private func recoveryFlush(_ fd: Int32, directory: Int32, ancestors: [Int32] = [],
                           beforeStep: (String) throws -> Void = { _ in }) throws {
    try beforeStep("file-fsync")
    guard fsync(fd) == 0 else { throw RecoveryFailure("durable file fsync failed") }
    try beforeStep("file-fullfsync")
    guard fcntl(fd, F_FULLFSYNC) == 0 else { throw RecoveryFailure("durable file fullfsync failed") }
    try beforeStep("directory-fsync")
    guard fsync(directory) == 0 else { throw RecoveryFailure("durable directory fsync failed") }
    for (index, ancestor) in ancestors.enumerated() {
        try beforeStep("ancestor-\(index)-fsync")
        guard fsync(ancestor) == 0 else { throw RecoveryFailure("durable ancestor fsync failed") }
    }
    try beforeStep("final-fullfsync")
    guard fcntl(fd, F_FULLFSYNC) == 0 else { throw RecoveryFailure("durable final fullfsync failed") }
}

private func bootIdentity() throws -> String {
    var bytes = [CChar](repeating: 0, count: 128)
    var size = bytes.count
    guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0,
          let end = bytes.firstIndex(of: 0) else { throw RecoveryFailure("boot identity unavailable") }
    return String(decoding: bytes[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Only an exclusively created direct child of /private/tmp is supported. No arbitrary source tree
/// is opened, copied, mounted or restored. Root/control/state directories are pinned and revalidated.
final class RecoveryStore {
    let path: String
    let rootFD: Int32
    let controlFD: Int32
    let stateFD: Int32
    private let parentFD: Int32
    private let lockFD: Int32
    let identity: RecoveryIdentity
    let manifest: Manifest
    private let rootName: String
    private let identityReceipt: RecoveryReceipt
    private var durableReceipts: [String: RecoveryReceipt] = [:]
    private var failedDurability = false
    // Internal deterministic fault injection only; there is no production CLI fault switch.
    var beforeFlush: (String, String) throws -> Void = { _, _ in }

    static func create(manifest: Manifest) throws -> RecoveryStore {
        guard getuid() == geteuid(), geteuid() != 0, Validator().validate(manifest).consistentDesign else {
            throw RecoveryFailure("require non-root caller and valid B3 declaration")
        }
        var template = Array("/private/tmp/sanjbox-b4-mock.XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw RecoveryFailure("mock fixture creation failed") }
        let path = String(cString: created)
        // A partially initialized fixture is retained on failure, never guessed safe to remove.
        do { return try RecoveryStore(path: path, creating: manifest) }
        catch { throw RecoveryFailure("\(error); retained initialization fixture: \(path)") }
    }

    convenience init(reopening path: String) throws { try self.init(path: path, creating: nil) }

    private init(path: String, creating model: Manifest?) throws {
        let prefix = "/private/tmp/sanjbox-b4-mock."
        guard getuid() == geteuid(), geteuid() != 0, path.hasPrefix(prefix), path.utf8.count == prefix.utf8.count + 6,
              path.dropFirst(prefix.count).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw RecoveryFailure("only exact generated mock fixture paths are accepted")
        }
        self.path = path
        rootName = String(path.split(separator: "/").last!)
        var opened: [Int32] = []
        do {
            let parent = open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard parent >= 0 else { throw RecoveryFailure("temporary parent unavailable") }
            opened.append(parent)
            var parentInfo = stat()
            guard fstat(parent, &parentInfo) == 0, parentInfo.st_uid == 0,
                  parentInfo.st_mode & S_IFMT == S_IFDIR, parentInfo.st_mode & 0o1000 != 0 else {
                throw RecoveryFailure("temporary parent is not root-owned sticky directory")
            }
            let root = openat(parent, rootName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard root >= 0 else { throw RecoveryFailure("mock root unavailable") }
            opened.append(root)
            let rootStamp = try stamp(root, directory: true)
            if model != nil {
                guard mkdirat(root, "control", 0o700) == 0, mkdirat(root, "state", 0o700) == 0,
                      fsync(root) == 0, fsync(parent) == 0 else { throw RecoveryFailure("mock directories not persisted") }
            }
            let control = openat(root, "control", O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard control >= 0 else { throw RecoveryFailure("control directory unavailable") }
            opened.append(control)
            let state = openat(root, "state", O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard state >= 0 else { throw RecoveryFailure("state directory unavailable") }
            opened.append(state)
            let controlStamp = try stamp(control, directory: true), stateStamp = try stamp(state, directory: true)
            guard controlStamp.device == rootStamp.device, stateStamp.device == rootStamp.device else {
                throw RecoveryFailure("mock children must share the fixture filesystem")
            }
            let lock = openat(control, "lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK | (model == nil ? 0 : O_CREAT | O_EXCL), 0o600)
            guard lock >= 0 else { throw RecoveryFailure("mock lock unavailable") }
            opened.append(lock)
            guard try stamp(lock, directory: false).size == 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw RecoveryFailure("mock fixture busy") }
            if model != nil { try recoveryFlush(lock, directory: control) }
            let identity: RecoveryIdentity
            if let model {
                let manifestReceipt = try Self.write(model, area: "control", name: "manifest.json", fd: control)
                let policyReceipt = try Self.write(["schema": "sanjbox.mock-policy.v1", "policy": "host-policy-canary"], area: "control", name: "policy.json", fd: control)
                identity = .init(transaction: UUID().uuidString, ownerUID: geteuid(), bootSession: try bootIdentity(), rootPath: path,
                                 root: rootStamp, control: controlStamp, state: stateStamp, manifest: manifestReceipt, policy: policyReceipt)
                _ = try Self.write(identity, area: "control", name: "identity.json", fd: control)
            } else {
                identity = try recoveryDecode(RecoveryIdentity.self, Self.read(area: "control", name: "identity.json", fd: control).0)
            }
            let identityPair = try Self.read(area: "control", name: "identity.json", fd: control)
            guard identity.schema == "sanjbox.mock-recovery.identity.v1", UUID(uuidString: identity.transaction) != nil,
                  identity.ownerUID == geteuid(), identity.bootSession == (try bootIdentity()), identity.rootPath == path,
                  identity.root == rootStamp, identity.control == controlStamp, identity.state == stateStamp,
                  identity.manifest.area == "control", identity.manifest.name == "manifest.json",
                  identity.policy.area == "control", identity.policy.name == "policy.json" else { throw RecoveryFailure("mock identity changed or rebooted") }
            let manifestPair = try Self.read(area: "control", name: "manifest.json", fd: control)
            guard manifestPair.1 == identity.manifest, try Self.read(area: "control", name: "policy.json", fd: control).1 == identity.policy else { throw RecoveryFailure("manifest or policy drift") }
            let decoded = try recoveryDecode(Manifest.self, manifestPair.0)
            guard Validator().validate(decoded).consistentDesign else { throw RecoveryFailure("inconsistent stored manifest") }
            self.identity = identity
            self.manifest = decoded
            identityReceipt = identityPair.1
            parentFD = parent; rootFD = root; controlFD = control; stateFD = state; lockFD = lock
            // No throwing work after transfer: the catch below owns these descriptors until this point.
        } catch { for fd in opened { close(fd) }; throw error }
    }

    deinit { for fd in [lockFD, stateFD, controlFD, rootFD, parentFD] { close(fd) } }

    func verify() throws {
        guard !failedDurability else { throw RecoveryFailure("durability failure latched; deny start and reopen for explicit revalidation") }
        guard try stamp(rootFD, directory: true) == identity.root,
              try stamp(controlFD, directory: true) == identity.control,
              try stamp(stateFD, directory: true) == identity.state,
              try stamp(lockFD, directory: false).size == 0 else { throw RecoveryFailure("mock directory protection changed") }
        for (parent, name, fd) in [(parentFD, rootName, rootFD), (rootFD, "control", controlFD), (rootFD, "state", stateFD), (controlFD, "lock", lockFD)] {
            var named = stat(), pinned = stat()
            guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0, fstat(fd, &pinned) == 0,
                  named.st_dev == pinned.st_dev, named.st_ino == pinned.st_ino else { throw RecoveryFailure("mock directory or lock binding replaced") }
        }
        _ = try readDurable(area: "control", name: "lock")
        for expected in [identityReceipt, identity.manifest, identity.policy] {
            guard try readDurable(area: expected.area, name: expected.name).1 == expected else { throw RecoveryFailure("host control changed") }
        }
    }

    private func fd(_ area: String) throws -> Int32 {
        switch area { case "control": return controlFD; case "state": return stateFD; default: throw RecoveryFailure("unknown receipt area") }
    }
    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 96 && name != "." && name != ".." && name.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || [45, 46].contains($0) }
    }

    func read(_ receipt: RecoveryReceipt) throws -> Data {
        try verify()
        let pair = try readDurable(area: receipt.area, name: receipt.name)
        guard pair.1 == receipt else { throw RecoveryFailure("recorded object changed: \(receipt.name)") }
        return pair.0
    }
    func read(area: String, name: String) throws -> (Data, RecoveryReceipt) {
        try verify()
        return try readDurable(area: area, name: name)
    }
    func write<T: Encodable>(_ value: T, area: String, name: String) throws -> RecoveryReceipt {
        try verify()
        let receipt = try Self.write(value, area: area, name: name, fd: fd(area)) { descriptor, parent in
            try self.flush(descriptor, directory: parent, context: "write:\(area)/\(name)")
        }
        durableReceipts[area + "/" + name] = receipt
        try verify()
        return receipt
    }

    private func flush(_ descriptor: Int32, directory: Int32, context: String) throws {
        do {
            try recoveryFlush(descriptor, directory: directory, ancestors: [rootFD, parentFD]) {
                try self.beforeFlush(context, $0)
            }
        } catch {
            failedDurability = true
            throw error
        }
    }

    /// Complete canonical bytes are not evidence that an earlier writer's flush succeeded. A fresh
    /// session must flush each exact receipt, its directory and ancestor bindings before accepting it.
    /// Cache only the identity/content/ctime that was successfully flushed in this locked session.
    private func readDurable(area: String, name: String) throws -> (Data, RecoveryReceipt) {
        guard !failedDurability else { throw RecoveryFailure("durability failure latched; deny start") }
        let parent = try fd(area)
        let pair = try Self.read(area: area, name: name, fd: parent)
        let key = area + "/" + name
        if durableReceipts[key] == pair.1 { return pair }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw RecoveryFailure("revalidation descriptor unavailable") }
        defer { close(descriptor) }
        guard try stamp(descriptor, directory: false) == pair.1.stamp else { throw RecoveryFailure("record changed before durable revalidation") }
        try flush(descriptor, directory: parent, context: "revalidate:" + key)
        guard try Self.read(area: area, name: name, fd: parent).1 == pair.1 else {
            failedDurability = true
            throw RecoveryFailure("record changed across durable revalidation; deny start")
        }
        durableReceipts[key] = pair.1
        return pair
    }

    private static func read(area: String, name: String, fd parent: Int32) throws -> (Data, RecoveryReceipt) {
        guard validName(name) else { throw RecoveryFailure("invalid record filename") }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw RecoveryFailure("missing or unsafe record: \(name)") }
        defer { close(fd) }
        let before = try stamp(fd, directory: false)
        var data = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while data.count <= 64 * 1024 {
            let count = Darwin.read(fd, &bytes, min(bytes.count, 64 * 1024 + 1 - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw RecoveryFailure("record read failed") }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        let after = try stamp(fd, directory: false)
        var named = stat()
        guard before == after, data.count == before.size, data.count <= 64 * 1024,
              fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == after.device, named.st_ino == after.inode else { throw RecoveryFailure("record changed during read or exceeds bound") }
        return (data, .init(area: area, name: name, stamp: after, digest: recoveryHash(data)))
    }

    private static func write<T: Encodable>(_ value: T, area: String, name: String, fd parent: Int32,
                                            flush: (Int32, Int32) throws -> Void = { try recoveryFlush($0, directory: $1) }) throws -> RecoveryReceipt {
        guard validName(name) else { throw RecoveryFailure("invalid record filename") }
        let data = try recoveryEncode(value)
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW_ANY | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RecoveryFailure("record exists or cannot be created: \(name)") }
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw RecoveryFailure("partial journal write; deny start") }
                offset += n
            }
        }
        try flush(fd, parent)
        return try read(area: area, name: name, fd: parent).1
    }

    func names(area: String, maximum: Int = 128) throws -> Set<String> {
        try verify()
        let descriptor = openat(try fd(area), ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { throw RecoveryFailure("directory listing unavailable") }
        guard let stream = fdopendir(descriptor) else { close(descriptor); throw RecoveryFailure("directory listing unavailable") }
        defer { closedir(stream) }
        var names = Set<String>()
        while true {
            errno = 0
            guard let entry = readdir(stream) else { if errno != 0 { throw RecoveryFailure("directory listing failed") }; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard names.count < maximum else { throw RecoveryFailure("mock entry limit exceeded") }
            names.insert(name)
        }
        return names
    }

    /// Mock selector file replacement only, never an APFS mount or volume swap. Requires an exclusive
    /// trusted host namespace: Darwin has no rename-if-inode-matches CAS for this final check interval.
    func replaceBinding(before: RecoveryReceipt, prepared: RecoveryReceipt) throws -> RecoveryReceipt {
        guard before.area == "state", prepared.area == "state", before.name.hasPrefix("slot-"), prepared.name.hasPrefix("next-") else { throw RecoveryFailure("invalid mock selector switch") }
        _ = try read(before); _ = try read(prepared)
        guard renameat(stateFD, prepared.name, stateFD, before.name) == 0 else { throw RecoveryFailure("mock selector rename failed") }
        let fd = openat(stateFD, before.name, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw RecoveryFailure("switched selector unavailable") }
        defer { close(fd) }
        try flush(fd, directory: stateFD, context: "switch:state/" + before.name)
        let after = try read(area: "state", name: before.name).1
        guard after.stamp.inode == prepared.stamp.inode, after.stamp.device == prepared.stamp.device,
              after.digest == prepared.digest else { throw RecoveryFailure("unexpected selector after switch") }
        return after
    }

    /// Called only for this session's generated fixture after full identity checks. No generic tree removal.
    func cleanup() throws {
        var named = stat()
        errno = 0
        if fstatat(parentFD, rootName, &named, AT_SYMLINK_NOFOLLOW) == -1 {
            guard errno == ENOENT else { throw RecoveryFailure("mock teardown path unavailable") }
            return // Idempotent only for an absent exact generated root; a replacement is verified below.
        }
        try verify()
        guard try Set(FileManager.default.contentsOfDirectory(atPath: path)) == ["control", "state"] else { throw RecoveryFailure("unexpected mock root entry; retain fixture") }
        // All owned descendants must be flat private regular files; refuse links, directories, and mounts.
        for area in ["control", "state"] {
            for name in try names(area: area) {
                _ = try read(area: area, name: name)
            }
        }
        try verify()
        let teardown = try ["state", "control"].map { ($0, try names(area: $0)) }
        for (area, entries) in teardown {
            for name in entries {
                guard unlinkat(try fd(area), name, 0) == 0 else { throw RecoveryFailure("mock teardown failed") }
            }
            // Verification cannot be used after removing control identity; pinned descriptors remain owned.
            guard unlinkat(rootFD, area, AT_REMOVEDIR) == 0 else { throw RecoveryFailure("mock directory teardown failed") }
        }
        guard unlinkat(parentFD, rootName, AT_REMOVEDIR) == 0 else { throw RecoveryFailure("mock root teardown failed") }
    }
}
