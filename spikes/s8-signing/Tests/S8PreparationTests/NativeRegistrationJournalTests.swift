import Darwin
import Foundation
import Testing
import SanjboxProbeKit
@testable import S8Preparation

// Real filesystem, flock, fsync, process identity and hashes. App signatures and service
// statuses below are synthetic inputs; NO ServiceManagement API is imported or invoked.
private final class JournalFixture {
    let root = "/private/tmp/s8-native-journal-test-" + UUID().uuidString
    let run = UUID().uuidString
    let fd: Int32
    let app: String
    var journalPath: String { root + "/" + run }
    init() throws {
        app = root + "/synthetic.app"
        guard mkdir(root, 0o700) == 0 else { throw S8Error.refused("test root") }
        fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 && mkdir(app, 0o700) == 0 else { throw S8Error.refused("test app") }
        try Data("own synthetic code bytes".utf8).write(to: URL(fileURLWithPath: app + "/code"))
        chmod(app + "/code", 0o600)
    }
    deinit {
        close(fd)
        // Only the exact root allocated by this test; fixtures never register or execute helpers.
        try? FileManager.default.removeItem(atPath: root)
    }
    func inventory() throws -> NativeSignedAppInventory {
        let appFD = open(app, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { close(appFD) }
        return .init(runID: run, appPath: app, ownerUID: geteuid(), ownerGID: getegid(),
                     hostCodeHash: String(repeating: "a", count: 40), entries: try NativeSignedAppInventory.scan(appFD))
    }
    func openJournal(create: Bool = true, inventory: NativeSignedAppInventory? = nil) throws -> NativeRegistrationJournal? {
        try NativeRegistrationJournal(parent: fd, name: run, path: journalPath, inventory: inventory ?? self.inventory(), create: create)
    }
    func record(_ name: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: journalPath + "/" + name)) }
    func overwrite(_ name: String, _ bytes: Data) throws {
        try bytes.write(to: URL(fileURLWithPath: journalPath + "/" + name)); chmod(journalPath + "/" + name, 0o600)
    }
    func register(_ journal: NativeRegistrationJournal, service: FixtureService = .agent, status: Int = 1) throws {
        let inventory = try self.inventory()
        let operation = try journal.begin(service, .register, status: 0, inventory: inventory, expectation: expectation())
        try journal.finish(operation, status: status, error: nil, inventory: inventory)
    }
}
private func expectation() throws -> S8Expectation {
    let process = try JournalProcess.capture()
    func decode<T: Decodable>(_ type: T.Type, _ value: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
    let context = ProbeContext(pid: getpid(), parentPID: getppid(), realUID: getuid(), effectiveUID: geteuid(), realGID: getgid(),
        effectiveGID: getegid(), userName: "synthetic-test-owner", kernelGroups: [getgid()], groupMembership: [],
        audit: try decode(ProbeContext.AuditSession.self, ["sessionID": process.auditSession, "auditUID": process.auditUID, "flags": 0]),
        launchdManager: try decode(ProbeContext.LaunchdManager.self, ["name": "synthetic-test-manager", "uid": geteuid()]), windowSession: nil)
    return try .init(candidate: context)
}
private func changed<T: Codable>(_ value: T, field: String, replacement: Any) throws -> T {
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    object[field] = replacement
    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}

@Test func nativeJournalReadOnlyMissingRunCreatesNothing() throws {
    let f = try JournalFixture()
    #expect(try f.openJournal(create: false) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.root) == ["synthetic.app"])
}

@Test func nativeJournalCommitsBothUserServicePathsAndNeverAuthorizesArtifactDeletion() throws {
    let f = try JournalFixture(); let journal = try #require(try f.openJournal())
    for service in [FixtureService.agent, .loginItem] {
        try f.register(journal, service: service)
        let pending = try journal.begin(service, .unregister, status: 1, inventory: f.inventory(), expectation: expectation())
        try journal.finish(pending, status: 0, error: nil, inventory: f.inventory())
    }
    let report = try journal.recoveryReport(inventory: f.inventory())
    #expect(report.records == 8 && report.services.count == 2)
    #expect(report.services.values.allSatisfy { $0.hasPrefix("unregister returned absent") })
    #expect(!report.mutationAuthorityRestored && !report.artifactCleanupAllowed)
    let root = open(f.journalPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC); defer { close(root) }
    var s = stat(); #expect(fstat(root, &s) == 0 && s.st_mode & 0o7777 == 0o700)
    for name in try FileManager.default.contentsOfDirectory(atPath: f.journalPath) {
        #expect(fstatat(root, name, &s, AT_SYMLINK_NOFOLLOW) == 0 && s.st_mode & 0o7777 == 0o600 && s.st_nlink == 1)
    }
}

@Test func nativeJournalRecoveredRegistrationWithIdenticalStatusDoesNotRestoreAuthority() throws {
    let f = try JournalFixture()
    do { let journal = try #require(try f.openJournal()); try f.register(journal) }
    let reopened = try #require(try f.openJournal(create: false))
    #expect(try reopened.recoveryReport(inventory: f.inventory()).services["agent"] == "registered; continuity unproven after restart")
    // Even the same process and unchanged status cannot turn a disk receipt into authority.
    #expect(throws: (any Error).self) {
        try reopened.begin(.agent, .unregister, status: 1, inventory: f.inventory(), expectation: expectation())
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.journalPath).count == 3)
}

@Test func nativeJournalInterruptedIntentRefusesBothRetryAndOtherService() throws {
    for service in [FixtureService.agent, .loginItem] {
        let f = try JournalFixture()
        do {
            let journal = try #require(try f.openJournal())
            _ = try journal.begin(.agent, .register, status: 0, inventory: f.inventory(), expectation: expectation())
        }
        let reopened = try #require(try f.openJournal())
        #expect(try reopened.recoveryReport(inventory: f.inventory()).services["agent"] == "interrupted; API outcome unknown")
        #expect(throws: (any Error).self) {
            try reopened.begin(service, .register, status: 0, inventory: f.inventory(), expectation: expectation())
        }
    }
}

@Test func nativeJournalAPIFailureAndUnexpectedResultsRemainConflicts() throws {
    for status in [0, 1, 2, 3] {
        let f = try JournalFixture()
        do {
            let journal = try #require(try f.openJournal())
            let pending = try journal.begin(.agent, .register, status: 0, inventory: f.inventory(), expectation: expectation())
            try journal.finish(pending, status: status, error: NSError(domain: "synthetic-service-error", code: 7), inventory: f.inventory())
        }
        let recovered = try #require(try f.openJournal(create: false))
        #expect(try recovered.recoveryReport(inventory: f.inventory()).services["agent"]?.hasPrefix("conflict") == true)
        #expect(throws: (any Error).self) {
            try recovered.begin(.agent, .register, status: 0, inventory: f.inventory(), expectation: expectation())
        }
    }
    for status in [0, 3] {
        let f = try JournalFixture(); let journal = try #require(try f.openJournal())
        try f.register(journal, status: status)
        #expect(try journal.recoveryReport(inventory: f.inventory()).services["agent"]?.hasPrefix("conflict") == true)
    }
}

@Test func nativeJournalRejectsExistingStatusDaemonAndCompletedRunReuseBeforeIntent() throws {
    for (service, action, status) in [(FixtureService.daemon, FixtureAction.register, 0), (.agent, .register, 1),
                                      (.agent, .register, 2), (.agent, .register, 3), (.agent, .unregister, 1), (.agent, .status, 0)] {
        let f = try JournalFixture(); let journal = try #require(try f.openJournal())
        #expect(throws: (any Error).self) {
            try journal.begin(service, action, status: status, inventory: f.inventory(), expectation: expectation())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.journalPath) == ["header.json"])
    }
    let f = try JournalFixture(); let journal = try #require(try f.openJournal())
    try f.register(journal)
    let pending = try journal.begin(.agent, .unregister, status: 1, inventory: f.inventory(), expectation: expectation())
    try journal.finish(pending, status: 0, error: nil, inventory: f.inventory())
    #expect(throws: (any Error).self) { try journal.begin(.agent, .register, status: 0, inventory: f.inventory(), expectation: expectation()) }
}

@Test func nativeJournalStatusDriftAndDuplicateCompletionLoseLiveAuthority() throws {
    let f = try JournalFixture(); let journal = try #require(try f.openJournal())
    try f.register(journal)
    #expect(throws: (any Error).self) { try journal.begin(.agent, .unregister, status: 2, inventory: f.inventory(), expectation: expectation()) }
    #expect(throws: (any Error).self) { try journal.begin(.agent, .unregister, status: 1, inventory: f.inventory(), expectation: expectation()) }
    let g = try JournalFixture(); let second = try #require(try g.openJournal())
    let pending = try second.begin(.agent, .register, status: 0, inventory: g.inventory(), expectation: expectation())
    try second.finish(pending, status: 1, error: nil, inventory: g.inventory())
    #expect(throws: (any Error).self) { try second.finish(pending, status: 1, error: nil, inventory: g.inventory()) }
}

@Test func nativeJournalBindsRunAppOwnerGroupCodeHashAndExactInventory() throws {
    let f = try JournalFixture(); let baseline = try f.inventory()
    do { _ = try #require(try f.openJournal()) }
    for (field, replacement) in [("runID", UUID().uuidString as Any), ("appPath", f.app + "-moved"),
        ("ownerUID", UInt32.max), ("ownerGID", UInt32.max), ("hostCodeHash", String(repeating: "b", count: 40))] {
        #expect(throws: (any Error).self) { try f.openJournal(inventory: changed(baseline, field: field, replacement: replacement)) }
    }
    try Data("different synthetic bytes".utf8).write(to: URL(fileURLWithPath: f.app + "/code"))
    #expect(throws: (any Error).self) { try f.openJournal() }
    #expect(try f.record("header.json").count > 0)
}

@Test func nativeInventoryRejectsLinksModesACLAndDetectsReplacedInode() throws {
    for kind in ["symlink", "hardlink", "writable", "acl", "fifo"] {
        let f = try JournalFixture()
        if kind == "symlink" { #expect(symlink("code", f.app + "/linked") == 0) }
        if kind == "hardlink" { #expect(link(f.app + "/code", f.app + "/linked") == 0) }
        if kind == "writable" { #expect(chmod(f.app + "/code", 0o622) == 0) }
        if kind == "acl" { _ = try testTool("/bin/chmod", ["+a", "everyone allow read", f.app + "/code"], seconds: 3) }
        if kind == "fifo" { #expect(mkfifo(f.app + "/pipe", 0o600) == 0) }
        #expect(throws: (any Error).self) { try f.inventory() }
        if kind == "acl" { _ = try testTool("/bin/chmod", ["-N", f.app + "/code"], seconds: 3) }
    }
    let f = try JournalFixture(); let original = try f.inventory()
    #expect(rename(f.app + "/code", f.root + "/old-code") == 0)
    try Data("own synthetic code bytes".utf8).write(to: URL(fileURLWithPath: f.app + "/code")); chmod(f.app + "/code", 0o600)
    #expect(try f.inventory() != original)
}

@Test func nativeJournalRootReplacementSymlinkModeAndACLFailClosed() throws {
    for kind in ["replaced", "symlink", "mode", "acl"] {
        let f = try JournalFixture(); let journal = try #require(try f.openJournal())
        if kind == "replaced" || kind == "symlink" {
            #expect(rename(f.journalPath, f.root + "/old-journal") == 0)
            if kind == "replaced" { #expect(mkdir(f.journalPath, 0o700) == 0) }
            else { #expect(symlink("old-journal", f.journalPath) == 0) }
        }
        if kind == "mode" { #expect(chmod(f.journalPath, 0o750) == 0) }
        if kind == "acl" { _ = try testTool("/bin/chmod", ["+a", "everyone allow list", f.journalPath], seconds: 3) }
        #expect(throws: (any Error).self) { try journal.recoveryReport(inventory: f.inventory()) }
        if kind == "acl" { _ = try testTool("/bin/chmod", ["-N", f.journalPath], seconds: 3) }
    }
}

@Test func nativeJournalUnknownPartialTruncatedAndNoncanonicalRecordsArePreserved() throws {
    for kind in ["partial", "gap", "unknown", "duplicate-key", "symlink", "hardlink", "mode", "oversize", "header"] {
        let f = try JournalFixture()
        do { let journal = try #require(try f.openJournal()); try f.register(journal) }
        if kind == "partial" { try f.overwrite("002.json", Data("{".utf8)) }
        if kind == "gap" { #expect(unlink(f.journalPath + "/001.json") == 0) }
        if kind == "unknown" { try f.overwrite("extra.json", Data("{}".utf8)) }
        if kind == "duplicate-key" {
            let original = try f.record("002.json")
            try f.overwrite("002.json", Data("{\"schema\":1,".utf8) + original.dropFirst())
        }
        if kind == "symlink" {
            #expect(rename(f.journalPath + "/002.json", f.root + "/result") == 0)
            #expect(symlink("../result", f.journalPath + "/002.json") == 0)
        }
        if kind == "hardlink" { #expect(link(f.journalPath + "/002.json", f.root + "/result") == 0) }
        if kind == "mode" { #expect(chmod(f.journalPath + "/002.json", 0o640) == 0) }
        if kind == "oversize" { try f.overwrite("002.json", Data(repeating: 32, count: 16_385)) }
        if kind == "header" { try f.overwrite("header.json", Data("{}".utf8)) }
        let before = try FileManager.default.contentsOfDirectory(atPath: f.journalPath).sorted()
        #expect(throws: (any Error).self) { try f.openJournal(create: false) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.journalPath).sorted() == before)
    }
}

@Test func nativeJournalHashChainProcessSessionAndPairingCorruptionAreRefused() throws {
    for field in ["previousSHA256", "operationID", "pid", "startSeconds", "bootSeconds", "auditUID", "auditSession", "expectationSHA256", "phase", "service", "status", "action"] {
        let f = try JournalFixture()
        do { let journal = try #require(try f.openJournal()); try f.register(journal) }
        var object = try #require(try JSONSerialization.jsonObject(with: f.record("002.json")) as? [String: Any])
        switch field {
        case "previousSHA256", "expectationSHA256": object[field] = String(repeating: "f", count: 64)
        case "operationID": object[field] = UUID().uuidString
        case "pid", "startSeconds", "bootSeconds", "auditUID", "auditSession":
            var process = try #require(object["process"] as? [String: Any])
            process[field] = (process[field] as! Int) + 1; object["process"] = process
        case "phase": object[field] = "intent"
        case "service": object[field] = "loginItem"
        case "action": object[field] = "unregister"
        default: object[field] = 99
        }
        try f.overwrite("002.json", JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
        #expect(throws: (any Error).self) { try f.openJournal(create: false) }
    }
}

@Test func nativeJournalRealSeparateProcessLockAndCrashRelease() throws {
    let f = try JournalFixture()
    var journal = try f.openJournal()
    let python = "/usr/bin/python3"
    let blocked = "import os,fcntl,sys\nf=os.open(sys.argv[1],os.O_RDONLY|os.O_DIRECTORY)\ntry: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError: print('blocked');sys.exit(0)\nsys.exit(7)"
    #expect(try String(decoding: testTool(python, ["-I", "-B", "-c", blocked, f.journalPath], seconds: 3), as: UTF8.self).contains("blocked"))
    journal = nil
    let unlocked = "import os,fcntl,sys\nf=os.open(sys.argv[1],os.O_RDONLY|os.O_DIRECTORY)\nfcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nprint('available')"
    #expect(try String(decoding: testTool(python, ["-I", "-B", "-c", unlocked, f.journalPath], seconds: 3), as: UTF8.self).contains("available"))
    // Actual separate process takes the same inode lock, creates a partial next record and dies.
    let crash = "import os,fcntl,sys,signal\nf=os.open(sys.argv[1],os.O_RDONLY|os.O_DIRECTORY)\nfcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nr=os.open('001.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600,dir_fd=f)\nos.write(r,b'{')\nos.fsync(r)\nos.fsync(f)\nos.kill(os.getpid(),signal.SIGKILL)"
    #expect(throws: (any Error).self) { try testTool(python, ["-I", "-B", "-c", crash, f.journalPath], seconds: 3) }
    #expect(try f.record("001.json") == Data("{".utf8))
    #expect(try String(decoding: testTool(python, ["-I", "-B", "-c", unlocked, f.journalPath], seconds: 3), as: UTF8.self).contains("available"))
    #expect(throws: (any Error).self) { try f.openJournal() }
    withExtendedLifetime(journal) {}
}

@Test func nativeJournalLiveAppDriftLeavesDurableIntentAndRefusesResult() throws {
    let f = try JournalFixture(); let journal = try #require(try f.openJournal())
    let pending = try journal.begin(.agent, .register, status: 0, inventory: f.inventory(), expectation: expectation())
    try Data("drift after API".utf8).write(to: URL(fileURLWithPath: f.app + "/code"))
    #expect(throws: (any Error).self) { try journal.finish(pending, status: 1, error: nil, inventory: f.inventory()) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.journalPath).sorted() == ["001.json", "header.json"])
}

@Test func nativeInventoryCaptureRefusesUnsignedTestProcessBeforeAnyStateWrite() {
    #expect(throws: (any Error).self) { try NativeSignedAppInventory.capture() }
}

@Test func nativeJournalMalformedReopenReleasesEveryDescriptorAndLock() throws {
    let f = try JournalFixture()
    do { _ = try #require(try f.openJournal()) }
    try f.overwrite("001.json", Data("{".utf8))
    for _ in 0..<64 {
        #expect(throws: (any Error).self) { try f.openJournal(create: false) }
        let fd = open(f.journalPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        #expect(fd >= 0)
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC == FD_CLOEXEC)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        #expect(flock(fd, LOCK_UN) == 0)
        close(fd)
    }
}

@Test func nativeJournalExpectationUIDAndAuditDriftRefuseBeforeIntent() throws {
    let base = try expectation()
    for (field, value) in [("auditSessionID", Int(base.auditSessionID) + 1), ("auditUID", Int(base.auditUID) + 1),
                           ("realUID", Int(base.realUID) + 1), ("effectiveGID", Int(base.effectiveGID) + 1)] {
        let f = try JournalFixture(); let journal = try #require(try f.openJournal())
        #expect(throws: (any Error).self) {
            try journal.begin(.agent, .register, status: 0, inventory: f.inventory(),
                              expectation: changed(base, field: field, replacement: value))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.journalPath) == ["header.json"])
    }
}

// Fixed test-only tools; the production BoundedTool allowlist is intentionally unchanged.
private func testTool(_ executable: String, _ arguments: [String], seconds: Double) throws -> Data {
    guard ["/bin/chmod", "/usr/bin/python3"].contains(executable) else { throw S8Error.refused("test tool") }
    let process = Process(); let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = pipe
    process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
    try process.run(); try pipe.fileHandleForWriting.close()
    defer { try? pipe.fileHandleForReading.close() }
    let fd = pipe.fileHandleForReading.fileDescriptor
    guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
        kill(process.processIdentifier, SIGKILL); process.waitUntilExit(); throw S8Error.refused("test pipe")
    }
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    var bytes = [UInt8](repeating: 0, count: 4096); var output = Data()
    while true {
        let count = read(fd, &bytes, bytes.count)
        if count > 0 { output.append(contentsOf: bytes.prefix(count)) }
        if output.count > 8192 || ProcessInfo.processInfo.systemUptime > deadline {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit(); throw S8Error.refused("test child timeout/output bound")
        }
        if !process.isRunning && count <= 0 { break }
        if count < 0 && errno != EAGAIN && errno != EINTR {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit(); throw S8Error.refused("test child read")
        }
        usleep(2000)
    }
    process.waitUntilExit()
    guard process.terminationReason == .exit && process.terminationStatus == 0 else { throw S8Error.refused("test child nonzero/signal") }
    return output
}

@Test func nativeJournalRecoveryDetectsAppDriftEvenWhileHandleRemainsOpen() throws {
    let f = try JournalFixture(); let journal = try #require(try f.openJournal())
    try f.register(journal)
    try Data("different app bytes".utf8).write(to: URL(fileURLWithPath: f.app + "/code"))
    #expect(throws: (any Error).self) { try journal.recoveryReport(inventory: f.inventory()) }
}

@Test func nativeJournalDurabilityBarrierFollowsFileAndDirectorySyncAndStopsOnFailure() throws {
    var calls: [(JournalDurability.Step, Int32)] = []
    try JournalDurability.commit(file: 41, directory: 42) { step, fd in calls.append((step, fd)); return 0 }
    #expect(calls.map(\.0) == [.fileContents, .directoryEntry, .deviceBarrier])
    #expect(calls.map(\.1) == [41, 42, 41])
    for failedIndex in 0..<3 {
        var count = 0
        #expect(throws: (any Error).self) {
            try JournalDurability.commit(file: 41, directory: 42) { _, _ in
                let result: Int32 = count == failedIndex ? -1 : 0
                count += 1; return result
            }
        }
        #expect(count == failedIndex + 1)
    }
    // This verifies syscall order and refusal, not actual power-loss durability.
}

@Test func nativeJournalEnumerationDescriptorIsAtomicallyCloseOnExec() throws {
    let f = try JournalFixture()
    let duplicate = JournalDirectoryDescriptors.duplicateForEnumeration(f.fd)
    #expect(duplicate >= 0)
    defer { close(duplicate) }
    #expect(fcntl(duplicate, F_GETFD) & FD_CLOEXEC == FD_CLOEXEC)
    var original = stat(); var copied = stat()
    #expect(fstat(f.fd, &original) == 0 && fstat(duplicate, &copied) == 0)
    #expect(original.st_dev == copied.st_dev && original.st_ino == copied.st_ino)
}

@Test func nativeJournalOwnerReleaseUnlocksEvenWithInheritedDescriptionStillOpen() throws {
    let f = try JournalFixture()
    let owner = open(f.root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    try #require(owner >= 0)
    try #require(flock(owner, LOCK_EX | LOCK_NB) == 0)
    let inherited = JournalDirectoryDescriptors.duplicateForEnumeration(owner)
    try #require(inherited >= 0)
    defer { close(inherited) }
    let independent = open(f.root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    try #require(independent >= 0)
    defer { JournalDirectoryDescriptors.releaseLockOwner(independent) }
    #expect(flock(independent, LOCK_EX | LOCK_NB) == -1)
    JournalDirectoryDescriptors.releaseLockOwner(owner)
    // A forked pre-exec child retains this same open-file description even with CLOEXEC.
    #expect(fcntl(inherited, F_GETFD) >= 0)
    #expect(flock(independent, LOCK_EX | LOCK_NB) == 0)
}
