import Darwin
import Darwin.membership
import Foundation
import XCTest
import SanjboxProbeKit
@testable import HostAudit

/// Every mutation (including simulated hostile changes) stays inside this new synthetic tree.
final class HardenFixture: @unchecked Sendable {
    let path: String
    let identity: StatMetadata
    let context: ProbeContext
    init() throws {
        var template = Array("/private/tmp/sanjbox-b2-tests.XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw AuditFailure("fixture creation failed") }
        path = String(cString: created)
        var value = stat()
        guard lstat(path, &value) == 0 else { throw AuditFailure("fixture stat failed") }
        identity = metadata(value)
        context = ProbeContext.capture()
    }
    func at(_ name: String) -> String { path + "/" + name }
    var state: String { at("run/state") }
    func directory(_ name: String, mode: mode_t = 0o700) throws {
        guard mkdir(at(name), mode) == 0, chmod(at(name), mode) == 0 else { throw AuditFailure("fixture directory failed") }
    }
    func json<T: Encodable>(_ name: String, _ value: T) throws {
        let fd = open(at(name), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AuditFailure("fixture JSON failed") }
        defer { close(fd) }
        let data = try encode(value)
        try data.withUnsafeBytes { buffer in
            guard write(fd, buffer.baseAddress, buffer.count) == buffer.count else { throw AuditFailure("fixture write failed") }
        }
    }
    func setup(roots: [String] = ["target"], plan: HardeningPlan? = nil,
               prepare: (HardenFixture) throws -> Void = { _ in }) throws {
        try directory("run")
        for root in roots { try directory(root, mode: 0o755) }
        try prepare(self)
        let manager = try XCTUnwrap(context.launchdManager)
        let expectation = IdentityInput(expectation: .init(effectiveUID: context.effectiveUID, realUID: context.realUID,
            effectiveGID: context.effectiveGID, realGID: context.realGID, requiredGroups: [], forbiddenGroups: [],
            launchdManagerName: manager.name, launchdManagerUID: manager.uid), auditSessionID: try XCTUnwrap(context.audit?.sessionID))
        try json("run/run.s4-expect.json", expectation)
        try baseline(roots: roots)
        try json("run/run.s4-harden.json", plan ?? HardeningPlan(roots: roots.indices.map { "root-\($0)" }))
    }
    func baseline(roots: [String], name: String = "run/run.s4-report.json") throws {
        let config = Configuration(roots: roots.enumerated().map { .init(id: "root-\($0.offset)", path: at($0.element), purpose: "synthetic B2 fixture") }, limits: .init(maxDepth: 0, maxEntries: 16))
        let snapshot = Snapshot(generatedAt: "synthetic", identity: .init(context: context, mismatches: [], valid: true),
                                configuration: config, roots: Scanner(configuration: config).scan(), drift: .init(compared: false, events: []))
        try json(name, snapshot)
    }
    func args(_ operation: String, apply: Bool = false) -> [String] {
        var values = [operation, "--expect", at("run/run.s4-expect.json"), "--state", state]
        if operation == "harden" { values += ["--baseline", at("run/run.s4-report.json"), "--plan", at("run/run.s4-harden.json")] }
        if apply { values += ["--apply", "--acknowledge-quiescent"] }
        return values
    }
    func run(_ operation: String, apply: Bool = false, hooks: HardenHooks = .init()) throws -> CommandResult {
        try HostHardeningCommand.run(args(operation, apply: apply), capture: { _ in self.context }, hooks: hooks)
    }
    func mode(_ name: String = "target") throws -> UInt16 {
        var value = stat()
        guard lstat(at(name), &value) == 0 else { throw AuditFailure("fixture stat failed") }
        return value.st_mode & 0o7777
    }
    func cleanup() throws {
        var value = stat()
        guard path.hasPrefix("/private/tmp/sanjbox-b2-tests."), lstat(path, &value) == 0,
              value.st_uid == geteuid(), value.st_mode & S_IFMT == S_IFDIR, value.st_mode & 0o7777 == 0o700,
              value.st_dev == identity.device, value.st_ino == identity.inode else { throw AuditFailure("fixture cleanup identity mismatch") }
        try FileManager.default.removeItem(atPath: path)
    }
}

final class HostHardeningTests: XCTestCase {
    private func fixture(roots: [String] = ["target"]) throws -> HardenFixture {
        let f = try HardenFixture()
        addTeardownBlock { try f.cleanup() }
        try f.setup(roots: roots)
        return f
    }
    private func check(_ value: CommandResult, _ code: Int32, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value.exitCode, code, String(decoding: value.output, as: UTF8.self), file: file, line: line)
    }
    private func acl(_ path: String, add: Bool) throws {
        let acl = try XCTUnwrap(acl_init(add ? 1 : 0))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        if add {
            var mutable: acl_t? = acl, entry: acl_entry_t?
            XCTAssertEqual(acl_create_entry(&mutable, &entry), 0)
            let ace = try XCTUnwrap(entry)
            XCTAssertEqual(acl_set_tag_type(ace, ACL_EXTENDED_ALLOW), 0)
            var uuid = UUID().uuid
            XCTAssertEqual(mbr_uid_to_uuid(geteuid(), &uuid), 0)
            XCTAssertEqual(withUnsafePointer(to: &uuid) { acl_set_qualifier(ace, $0) }, 0)
            var permissions: acl_permset_t?
            XCTAssertEqual(acl_get_permset(ace, &permissions), 0)
            XCTAssertEqual(acl_add_perm(try XCTUnwrap(permissions), ACL_READ_DATA), 0)
        }
        XCTAssertEqual(acl_set_file(path, ACL_TYPE_EXTENDED, acl), 0)
    }

    func testDefaultDryRunIsExactAndDoesNotCreateJournal() throws {
        let f = try fixture()
        let before = try HardenPath(f.at("target")).requireTarget()
        let result = try f.run("harden")
        check(result, 0)
        let preview = try JSONDecoder().decode(HardenResult.self, from: result.output)
        XCTAssertTrue(preview.dryRun)
        XCTAssertEqual(preview.status, "would-apply")
        XCTAssertEqual(preview.changes.first?.before.stat.mode, 0o755)
        XCTAssertEqual(preview.changes.first?.mode, 0o700)
        XCTAssertEqual(try HardenPath(f.at("target")).requireTarget(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.state))
    }

    func testApplyDurableRecordsAndExclusiveJournalLock() throws {
        let f = try fixture()
        check(try f.run("harden", apply: true), 0)
        XCTAssertEqual(try f.mode(), 0o700)
        let journal = try HardenJournal(f.state, create: false)
        XCTAssertEqual(try journal.names(), ["lock", "manifest.json", "00-intent.json", "00-applied.json"])
        let manifest: HardenManifest = try journal.read("manifest.json")
        let applied: HardenEvent = try journal.read("00-applied.json")
        XCTAssertEqual(manifest.changes[0].before.stat.mode, 0o755)
        XCTAssertEqual(applied.after?.stat.mode, 0o700)
        // A live cooperating owner is an exclusive lock, including against dry-run uninstall.
        check(try f.run("uninstall"), 4)
        withExtendedLifetime(journal) {}
        // Restore in a separate scope after journal lock goes away.
    }

    func testRestoreRoundTripAndRetainedEvidence() throws {
        let f = try fixture()
        check(try f.run("harden", apply: true), 0)
        check(try f.run("uninstall"), 0)
        XCTAssertEqual(try f.mode(), 0o700)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.state + "/00-restore-intent.json"))
        check(try f.run("uninstall", apply: true), 0)
        XCTAssertEqual(try f.mode(), 0o755)
        check(try f.run("uninstall", apply: true), 0)
        XCTAssertEqual(try f.mode(), 0o755)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.state + "/00-restored.json"))
        XCTAssertEqual(chmod(f.at("target"), 0o750), 0)
        check(try f.run("uninstall", apply: true), 0)
        XCTAssertEqual(try f.mode(), 0o750, "later change after completed uninstall is never owned")
    }

    func testLegitimateModeAndSameModeCtimeChangesAreNotOverwritten() throws {
        let f = try fixture()
        check(try f.run("harden", apply: true), 0)
        XCTAssertEqual(chmod(f.at("target"), 0o750), 0)
        check(try f.run("uninstall", apply: true), 4)
        XCTAssertEqual(try f.mode(), 0o750)
        XCTAssertEqual(chmod(f.at("target"), 0o700), 0)
        check(try f.run("uninstall", apply: true), 4)
        XCTAssertEqual(try f.mode(), 0o700)
    }

    func testDirectoryContentsCtimeDriftConservativelyConflicts() throws {
        let f = try fixture()
        check(try f.run("harden", apply: true), 0)
        try f.directory("target/new-child")
        check(try f.run("uninstall", apply: true), 4)
        XCTAssertEqual(try f.mode(), 0o700)
    }

    func testReplacementInodeAndAncestorAreNeverRestored() throws {
        let f = try fixture()
        check(try f.run("harden", apply: true), 0)
        XCTAssertEqual(rename(f.at("target"), f.at("old-target")), 0)
        try f.directory("target", mode: 0o700)
        check(try f.run("uninstall", apply: true), 4)
        XCTAssertEqual(try f.mode(), 0o700)
        XCTAssertEqual(try f.mode("old-target"), 0o700)
        // The same original target inode under a replacement parent is still refused.
        let p = try HardenFixture()
        addTeardownBlock { try p.cleanup() }
        try p.directory("parent")
        try p.setup(roots: ["parent/target"])
        check(try p.run("harden", apply: true), 0)
        XCTAssertEqual(rename(p.at("parent"), p.at("old-parent")), 0)
        try p.directory("parent")
        XCTAssertEqual(rename(p.at("old-parent/target"), p.at("parent/target")), 0)
        check(try p.run("uninstall", apply: true), 4)
        XCTAssertEqual(try p.mode("parent/target"), 0o700)
    }

    func testExistingACLAndLaterACLRefusedWithoutACLMutation() throws {
        let f = try fixture()
        try acl(f.at("target"), add: true)
        defer { try? acl(f.at("target"), add: false) }
        check(try f.run("harden", apply: true), 4)
        XCTAssertEqual(try f.mode(), 0o755)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.state))
        let p = try fixture()
        check(try p.run("harden", apply: true), 0)
        try acl(p.at("target"), add: true)
        defer { try? acl(p.at("target"), add: false) }
        check(try p.run("uninstall", apply: true), 4)
        XCTAssertEqual(try p.mode(), 0o700)
        let fd = open(p.at("target"), O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        defer { close(fd) }
        XCTAssertEqual(readACL(fd).entries.count, 1)
    }

    func testRaceBeforeApplyAndRestoreFinalCheckRefused() throws {
        let f = try fixture()
        let race = HardenHooks(beforeFinalCheck: { _, _ in XCTAssertEqual(chmod(f.at("target"), 0o750), 0) })
        check(try f.run("harden", apply: true, hooks: race), 4)
        XCTAssertEqual(try f.mode(), 0o750)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.state + "/00-intent.json"))
        check(try f.run("uninstall", apply: true), 4)
        let p = try fixture()
        check(try p.run("harden", apply: true), 0)
        let race2 = HardenHooks(beforeFinalCheck: { _, _ in XCTAssertEqual(chmod(p.at("target"), 0o750), 0) })
        check(try p.run("uninstall", apply: true, hooks: race2), 4)
        XCTAssertEqual(try p.mode(), 0o750)
    }

    func testCrashAfterApplyBeforeCompletionJournalIsAmbiguous() throws {
        let f = try fixture()
        try crashChild(f, operation: "harden")
        XCTAssertEqual(try f.mode(), 0o700)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.state + "/00-intent.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.state + "/00-applied.json"))
        check(try f.run("uninstall", apply: true), 4)
        XCTAssertEqual(try f.mode(), 0o700)
    }

    func testCrashAfterRestoreBeforeCompletionJournalIsAmbiguous() throws {
        let f = try fixture()
        check(try f.run("harden", apply: true), 0)
        try crashChild(f, operation: "uninstall")
        XCTAssertEqual(try f.mode(), 0o755)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.state + "/00-restore-intent.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.state + "/00-restored.json"))
        check(try f.run("uninstall", apply: true), 4)
    }

    // Spawn xctest with only this harness selected; fault hooks exist only in test code.
    private func crashChild(_ fixture: HardenFixture, operation: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "HostAuditTests.HostHardeningTests/testCrashHarnessChild",
                             Bundle(for: HostHardeningTests.self).bundleURL.path]
        process.environment = ["PATH": "/usr/bin:/bin", "SANJBOX_B2_TEST_PATH": fixture.path,
                               "SANJBOX_B2_TEST_OPERATION": operation]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 77, "child must exit from the after-mutation test hook")
    }

    func testCrashHarnessChild() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SANJBOX_B2_TEST_PATH"], let operation = env["SANJBOX_B2_TEST_OPERATION"] else { return }
        guard path.hasPrefix("/private/tmp/sanjbox-b2-tests."), path.split(separator: "/").count == 3,
              ["harden", "uninstall"].contains(operation) else { _exit(91) }
        let pinned = try HardenPath(path)
        guard try pinned.requireTarget().stat.mode == 0o700 else { _exit(92) }
        var args = [operation, "--expect", path + "/run/run.s4-expect.json", "--state", path + "/run/state",
                    "--apply", "--acknowledge-quiescent"]
        if operation == "harden" { args += ["--baseline", path + "/run/run.s4-report.json", "--plan", path + "/run/run.s4-harden.json"] }
        _ = try HostHardeningCommand.run(args, capture: { ProbeContext.capture(groupsOfInterest: $0) },
                                         hooks: .init(afterMutation: { _, _ in _exit(77) }))
        _exit(93)
    }

    func testMultiRootPreflightFailureMakesNoChanges() throws {
        let f = try fixture(roots: ["target", "second"])
        XCTAssertEqual(chmod(f.at("second"), 0o750), 0)
        check(try f.run("harden", apply: true), 4)
        XCTAssertEqual(try f.mode(), 0o755)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.state))
        let p = try fixture(roots: ["target", "second"])
        check(try p.run("harden", apply: true), 0)
        XCTAssertEqual(chmod(p.at("second"), 0o750), 0)
        check(try p.run("uninstall", apply: true), 4)
        XCTAssertEqual(try p.mode(), 0o700)
        XCTAssertEqual(try p.mode("second"), 0o750)
    }

    func testSymlinkTargetAndParentAndSpecialNodeRefused() throws {
        let f = try fixture()
        XCTAssertEqual(rename(f.at("target"), f.at("real")), 0)
        XCTAssertEqual(symlink(f.at("real"), f.at("target")), 0)
        check(try f.run("harden", apply: true), 4)
        XCTAssertEqual(try f.mode("real"), 0o755)
        XCTAssertEqual(unlink(f.at("target")), 0)
        XCTAssertEqual(mkfifo(f.at("target"), 0o600), 0)
        check(try f.run("harden", apply: true), 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.state))
        XCTAssertThrowsError(try HardenPath(f.at("target/child")))
    }

    func testJournalCorruptionUnexpectedEntriesAndReusedStateRefused() throws {
        let f = try fixture()
        check(try f.run("harden", apply: true), 0)
        check(try f.run("harden", apply: true), 4)
        try f.json("run/state/unknown.json", ["synthetic": true])
        check(try f.run("uninstall", apply: true), 4)
        XCTAssertEqual(try f.mode(), 0o700)
        XCTAssertEqual(unlink(f.state + "/unknown.json"), 0)
        let fd = open(f.state + "/00-applied.json", O_WRONLY | O_TRUNC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(write(fd, "{", 1), 1)
        close(fd)
        check(try f.run("uninstall", apply: true), 4)
        XCTAssertEqual(try f.mode(), 0o700)
    }

    func testUnknownDuplicateAndNoncanonicalJournalKeysAreRefused() throws {
        for kind in ["unknown", "duplicate", "formatting"] {
            let f = try fixture()
            check(try f.run("harden", apply: true), 0)
            let path = f.state + "/00-applied.json"
            let data = try Data(contentsOf: URL(fileURLWithPath: path)) // own synthetic schema only
            var text = String(decoding: data, as: UTF8.self)
            if kind == "unknown" { text = "{\"unrecognized\":true," + text.dropFirst() }
            if kind == "duplicate" { text = "{\"index\":0," + text.dropFirst() }
            if kind == "formatting" { text = " " + text }
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
            check(try f.run("uninstall", apply: true), 4)
            XCTAssertEqual(try f.mode(), 0o700)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.state + "/00-restore-intent.json"))
        }
    }

    func testJournalBootIdentityAndPathReplacementRefused() throws {
        let f = try fixture()
        check(try f.run("harden", apply: true), 0)
        let path = f.state + "/manifest.json"
        var manifest = try JSONDecoder().decode(HardenManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        manifest.bootSession = UUID().uuidString
        try encode(manifest).write(to: URL(fileURLWithPath: path))
        check(try f.run("uninstall", apply: true), 4)
        XCTAssertEqual(try f.mode(), 0o700)
        let p = try fixture()
        check(try p.run("harden", apply: true), 0)
        XCTAssertEqual(rename(p.state, p.at("run/old-state")), 0)
        XCTAssertEqual(symlink(p.at("run/old-state"), p.state), 0)
        check(try p.run("uninstall", apply: true), 4)
        XCTAssertEqual(try p.mode(), 0o700)
    }

    func testRenameRaceAndPostMutationConflictPreserveOtherChanges() throws {
        let f = try fixture()
        let before = HardenHooks(beforeFinalCheck: { _, _ in
            XCTAssertEqual(rename(f.at("target"), f.at("moved")), 0)
            try f.directory("target", mode: 0o750)
        })
        check(try f.run("harden", apply: true, hooks: before), 4)
        XCTAssertEqual(try f.mode(), 0o750)
        XCTAssertEqual(try f.mode("moved"), 0o755)
        let p = try fixture()
        let after = HardenHooks(afterMutation: { _, _ in XCTAssertEqual(chmod(p.at("target"), 0o750), 0) })
        check(try p.run("harden", apply: true, hooks: after), 4)
        XCTAssertEqual(try p.mode(), 0o750)
        check(try p.run("uninstall", apply: true), 4)
        XCTAssertEqual(try p.mode(), 0o750)
    }

    func testIdentityMismatchStopsBeforeAnyPlanBaselineStateAccess() throws {
        let f = try fixture()
        var context = f.context
        context.effectiveUID += 1
        let result = try HostHardeningCommand.run(["harden", "--expect", f.at("run/run.s4-expect.json"),
            "--baseline", f.at("never.s4-report.json"), "--plan", f.at("never.s4-harden.json"), "--state", f.at("missing/state"),
            "--apply", "--acknowledge-quiescent"], capture: { _ in context })
        check(result, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.state))
        XCTAssertEqual(try f.mode(), 0o755)
    }

    func testStrictPlanFlagsAndPrivateStateParent() throws {
        let f = try fixture()
        XCTAssertThrowsError(try HostHardeningCommand.run(f.args("harden") + ["--apply"]))
        XCTAssertThrowsError(try HostHardeningCommand.run(f.args("harden", apply: true) + ["--dry-run"]))
        XCTAssertThrowsError(try HardeningPlan(roots: [], mode: 0o700).validate())
        XCTAssertThrowsError(try HardeningPlan(roots: ["a", "a"]).validate())
        XCTAssertThrowsError(try HardeningPlan(roots: ["a"], mode: 0o755).validate())
        XCTAssertEqual(chmod(f.at("run"), 0o755), 0)
        check(try f.run("harden", apply: true), 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.state))
        XCTAssertEqual(try f.mode(), 0o755)
    }

    func testActualReleaseCLIAndWrappers() throws {
        let f = try fixture()
        let binary = Bundle(for: HostHardeningTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("sanjbox-host-harden")
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (script, operation, apply) in [("harden-host.sh", "harden", false), ("harden-host.sh", "harden", true),
                                           ("uninstall.sh", "uninstall", false), ("uninstall.sh", "uninstall", true), ("uninstall.sh", "uninstall", true)] {
            let process = Process()
            process.executableURL = sourceRoot.appendingPathComponent(script)
            process.arguments = Array(f.args(operation, apply: apply).dropFirst())
            var environment = ProcessInfo.processInfo.environment
            environment["SANJBOX_HOST_HARDEN_BIN"] = binary.path
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.standardError
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
            XCTAssertNotNil(try? JSONDecoder().decode(HardenResult.self, from: data))
        }
        XCTAssertEqual(try f.mode(), 0o755)
    }
}
