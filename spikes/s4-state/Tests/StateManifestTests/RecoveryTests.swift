import Darwin
import Foundation
import SanjboxProbeKit
import XCTest
@testable import StateManifest

private final class RecoveryFixture: @unchecked Sendable {
    let path: String
    let device: dev_t
    let inode: ino_t
    init(manifest: Manifest) throws {
        let store = try RecoveryStore.create(manifest: manifest)
        path = store.path
        device = store.identity.root.device
        inode = store.identity.root.inode
        try FileBackedRecoveryMock(store: store).initialize()
    }
    func open() throws -> (RecoveryStore, FileBackedRecoveryMock, RecoveryCoordinator) {
        let store = try RecoveryStore(reopening: path)
        let backend = FileBackedRecoveryMock(store: store)
        return (store, backend, RecoveryCoordinator(store: store, backend: backend))
    }
    // Test-only teardown also handles deliberately corrupted own fixtures, never production journals.
    func clean() throws {
        var s = stat()
        guard path.hasPrefix("/private/tmp/sanjbox-b4-mock."), path.split(separator: "/").count == 3,
              lstat(path, &s) == 0, s.st_dev == device, s.st_ino == inode, s.st_uid == geteuid(),
              s.st_mode & S_IFMT == S_IFDIR, s.st_mode & 0o7777 == 0o700 else { throw RecoveryFailure("test teardown identity mismatch") }
        try FileManager.default.removeItem(atPath: path)
    }
    func replace(_ relative: String, data: Data) throws {
        let fd = Darwin.open(path + "/" + relative, O_WRONLY | O_TRUNC | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw RecoveryFailure("test corruption target unavailable") }
        defer { close(fd) }
        guard data.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == data.count else { throw RecoveryFailure("test corruption write failed") }
    }
}

private final class WrongVolumeBackend: RecoveryBackend {
    var volumeIDs = ["state"]
    func acquireQuiescence(restoring: Bool) throws -> RecoveryQuiescence { throw RecoveryFailure("unexpected backend call") }
    func validateQuiescence(_ witness: RecoveryQuiescence, restoring: Bool) throws { throw RecoveryFailure("unexpected backend call") }
    func currentBindings() throws -> [RecoveryReceipt] { throw RecoveryFailure("unexpected backend call") }
    func validate(_ receipts: [RecoveryReceipt]) throws { throw RecoveryFailure("unexpected backend call") }
    func snapshot(_ volume: String, source: RecoveryReceipt) throws -> RecoveryReceipt { throw RecoveryFailure("unexpected backend call") }
    func prepare(_ volume: String, snapshot: RecoveryReceipt) throws -> [RecoveryReceipt] { throw RecoveryFailure("unexpected backend call") }
    func switchBinding(_ volume: String, before: RecoveryReceipt, prepared: [RecoveryReceipt]) throws -> RecoveryReceipt { throw RecoveryFailure("unexpected backend call") }
    func verifyRestored(_ volume: String, snapshot: RecoveryReceipt, prepared: [RecoveryReceipt], binding: RecoveryReceipt) throws { throw RecoveryFailure("unexpected backend call") }
}

final class RecoveryTests: XCTestCase {
    private var package: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func example() throws -> Manifest {
        try decodeManifest(Data(contentsOf: package.appendingPathComponent("examples/mvp.state-manifest.json")))
    }
    private func fixture() throws -> RecoveryFixture {
        let f = try RecoveryFixture(manifest: example())
        addTeardownBlock { try f.clean() }
        return f
    }
    private func expected(_ context: ProbeContext) throws -> ExpectedContext {
        let manager = try XCTUnwrap(context.launchdManager)
        return .init(schema: "sanjbox.state-expect.v1", expectation: .init(effectiveUID: context.effectiveUID, realUID: context.realUID,
                     effectiveGID: context.effectiveGID, realGID: context.realGID, requiredGroups: [], forbiddenGroups: [],
                     launchdManagerName: manager.name, launchdManagerUID: manager.uid), auditSessionID: try XCTUnwrap(context.audit?.sessionID))
    }
    private func stop(_ point: String, coordinator: RecoveryCoordinator) {
        coordinator.hook = { if $0 == point { throw RecoveryFailure("injected interruption") } }
    }

    func testFullMockRollbackRestoresAllRolesAndInertStartupCanaryWithoutPolicyChange() throws {
        let f = try fixture(), (store, backend, engine) = try f.open()
        XCTAssertFalse(engine.inspect().mockStartAllowed)
        let policy = try store.read(store.identity.policy)
        try engine.takeSnapshot()
        XCTAssertFalse(engine.inspect().mockStartAllowed)
        try backend.simulateChanges()
        let changed = try backend.currentBindings()
        XCTAssertTrue(try backend.image(backend.binding(changed[0], volume: "state").image, volume: "state").entries.contains { $0.value == "inert-startup-canary" })
        try engine.rollback()
        let result = engine.inspect()
        XCTAssertTrue(result.mockStartAllowed)
        XCTAssertFalse(result.realStartAllowed)
        XCTAssertEqual(result.records, 16)
        XCTAssertEqual(try store.read(store.identity.policy), policy)
        for id in backend.volumeIDs {
            let snapshot = try store.read(area: "state", name: "snapshot-\(id).json").1
            let selected = try store.read(area: "state", name: "slot-\(id).json").1
            let image = try backend.binding(selected, volume: id).image
            XCTAssertNotEqual(snapshot.stamp.inode, image.stamp.inode)
            XCTAssertEqual(try backend.image(snapshot, volume: id).entries, try backend.image(image, volume: id).entries)
            XCTAssertFalse(try backend.image(image, volume: id).entries.contains { $0.value == "inert-startup-canary" })
        }
        let before = try store.names(area: "control")
        try engine.rollback() // idempotent completed checkpoint, still verifies current identity/state
        XCTAssertEqual(try store.names(area: "control"), before)
    }

    func testMissingWholeUIDOrAdmissionOrNetworkBlocksBeforeSnapshotIntent() throws {
        for kind in ["uid", "admission", "network"] {
            let f = try fixture(), (_, backend, engine) = try f.open()
            if kind == "uid" { backend.wholeUID = false }
            if kind == "admission" { backend.admissionBlocked = false }
            if kind == "network" { backend.networkBlocked = false }
            XCTAssertThrowsError(try engine.takeSnapshot())
            XCTAssertTrue(try engine.events().isEmpty)
            XCTAssertFalse(engine.inspect().mockStartAllowed)
        }
    }
    func testRestoreRequiresFullyOffClosedDescriptorsAndMappings() throws {
        for kind in ["off", "fd", "mapping"] {
            let f = try fixture(), (_, backend, engine) = try f.open()
            try engine.takeSnapshot()
            if kind == "off" { backend.fullyOff = false }
            if kind == "fd" { backend.descriptorsClosed = false }
            if kind == "mapping" { backend.mappingsClosed = false }
            XCTAssertThrowsError(try engine.rollback())
            XCTAssertEqual(try engine.events().last?.phase, "snapshot-ready")
        }
    }
    func testLostLeaseAfterIntentLeavesDenyWithoutMutation() throws {
        let f = try fixture(), (store, backend, engine) = try f.open()
        engine.hook = { if $0 == "before-snapshot-mutation:state" { backend.leaseGeneration = UUID() } }
        XCTAssertThrowsError(try engine.takeSnapshot())
        XCTAssertFalse(try store.names(area: "state").contains("snapshot-state.json"))
        XCTAssertFalse(engine.inspect().mockStartAllowed)
        XCTAssertThrowsError(try engine.takeSnapshot())
    }
    func testPrepareAllVolumesBeforeSwitchAndMixedStateNeverStarts() throws {
        let f = try fixture(), (store, backend, engine) = try f.open()
        try engine.takeSnapshot(); try backend.simulateChanges()
        stop("after-switch-done:state", coordinator: engine)
        XCTAssertThrowsError(try engine.rollback())
        let names = try store.names(area: "state")
        XCTAssertTrue(names.contains("restored-tools.json"))
        XCTAssertTrue(names.contains("next-tools.json"))
        XCTAssertFalse(engine.inspect().mockStartAllowed)
        XCTAssertEqual(try backend.binding(store.read(area: "state", name: "slot-state.json").1, volume: "state").image.name, "restored-state.json")
        XCTAssertEqual(try backend.binding(store.read(area: "state", name: "slot-tools.json").1, volume: "tools").image.name, "changed-tools.json")
        engine.hook = { _ in }
        try engine.rollback()
        XCTAssertTrue(engine.inspect().mockStartAllowed)
    }
    func testLaterBindingChangeAndABARefusedWithoutOverwrite() throws {
        for aba in [false, true] {
            let f = try fixture(), (store, backend, engine) = try f.open()
            try engine.takeSnapshot(); try backend.simulateChanges()
            stop("after-prepare-done:tools", coordinator: engine)
            XCTAssertThrowsError(try engine.rollback())
            let original = try store.read(area: "state", name: "slot-state.json").0
            try f.replace("state/slot-state.json", data: Data("later-change".utf8))
            if aba { try f.replace("state/slot-state.json", data: original) }
            engine.hook = { _ in }
            XCTAssertThrowsError(try engine.rollback())
            XCTAssertEqual(try store.read(area: "state", name: "slot-state.json").0, aba ? original : Data("later-change".utf8))
            XCTAssertFalse(engine.inspect().mockStartAllowed)
        }
    }
    func testConflictInjectedImmediatelyBeforeSwitchIsRefused() throws {
        let f = try fixture(), (_, backend, engine) = try f.open()
        try engine.takeSnapshot(); try backend.simulateChanges()
        engine.hook = { if $0 == "before-switch-mutation:state" { try f.replace("state/slot-tools.json", data: Data("later".utf8)) } }
        XCTAssertThrowsError(try engine.rollback())
        XCTAssertEqual(try engine.events().last?.phase, "switch-intent")
        XCTAssertFalse(engine.inspect().mockStartAllowed)
    }
    func testPolicyDriftAndSnapshotDriftDenyStart() throws {
        for name in ["control/policy.json", "state/snapshot-state.json", "state/restored-state.json"] {
            let f = try fixture(), (_, backend, engine) = try f.open()
            try engine.takeSnapshot(); try backend.simulateChanges(); try engine.rollback()
            try f.replace(name, data: Data("{}\n".utf8))
            XCTAssertFalse(engine.inspect().mockStartAllowed)
            XCTAssertThrowsError(try engine.rollback())
        }
    }
    func testExactRecordByteLimitRoundTripsThroughStoreAndOverflowCreatesNoFile() throws {
        let f = try fixture(), (store, _, _) = try f.open()
        var chunks = Array(repeating: String(repeating: "a", count: 4000), count: 16) + [""]
        let overhead = try recoveryEncode(["chunks": chunks]).count
        chunks[16] = String(repeating: "b", count: 64 * 1024 - overhead)
        let payload = ["chunks": chunks]
        let receipt = try store.write(payload, area: "state", name: "boundary.json")
        let data = try store.read(receipt)
        XCTAssertEqual(data.count, 64 * 1024)
        XCTAssertEqual(try recoveryDecode([String: [String]].self, data), payload)
        chunks[16].append("c")
        XCTAssertThrowsError(try store.write(["chunks": chunks], area: "state", name: "overflow.json"))
        XCTAssertFalse(try store.names(area: "state").contains("overflow.json"))
    }

    func testMissingTruncatedUnknownDuplicateOversizeAndDeepJournalDeny() throws {
        for kind in ["missing", "truncated", "unknown", "duplicate", "oversize", "deep", "chain", "transition"] {
            let f = try fixture(), (store, _, engine) = try f.open()
            try engine.takeSnapshot()
            let pair = try store.read(area: "control", name: "000.json")
            let text = String(decoding: pair.0, as: UTF8.self)
            if kind == "missing" { XCTAssertEqual(unlink(f.path + "/control/000.json"), 0) }
            else {
                var data = Data("{".utf8)
                if kind == "unknown" { data = Data(("{\"unknown\":true," + text.dropFirst()).utf8) }
                if kind == "duplicate" { data = Data(("{\"sequence\":0," + text.dropFirst()).utf8) }
                if kind == "oversize" { data = Data(repeating: 32, count: 65537) }
                if kind == "deep" { data = Data((String(repeating: "[", count: 18) + "0" + String(repeating: "]", count: 18)).utf8) }
                if kind == "chain" || kind == "transition" {
                    var event = try recoveryDecode(RecoveryEvent.self, pair.0)
                    if kind == "chain" { event.previousDigest = String(repeating: "0", count: 64) }
                    else { event.phase = "verified" }
                    data = try recoveryEncode(event)
                }
                try f.replace("control/000.json", data: data)
            }
            XCTAssertFalse(engine.inspect().mockStartAllowed)
            XCTAssertThrowsError(try engine.rollback())
        }
    }
    func testLockJournalSymlinkHardlinkAndDirectoryReplacementRefused() throws {
        let f = try fixture(), (store, _, engine) = try f.open()
        XCTAssertThrowsError(try RecoveryStore(reopening: f.path))
        try engine.takeSnapshot()
        XCTAssertEqual(link(f.path + "/control/000.json", f.path + "/control/extra.json"), 0)
        XCTAssertFalse(engine.inspect().mockStartAllowed)
        XCTAssertEqual(unlink(f.path + "/control/extra.json"), 0)
        XCTAssertEqual(rename(f.path + "/state", f.path + "/old-state"), 0)
        XCTAssertEqual(mkdir(f.path + "/state", 0o700), 0)
        XCTAssertThrowsError(try store.verify())
        XCTAssertFalse(engine.inspect().mockStartAllowed)
    }
    func testSymlinkAndFIFOJournalDoNotBlockReader() throws {
        for kind in ["symlink", "fifo"] {
            let f = try fixture(), (_, _, engine) = try f.open()
            try engine.takeSnapshot()
            XCTAssertEqual(unlink(f.path + "/control/000.json"), 0)
            if kind == "symlink" { XCTAssertEqual(symlink("policy.json", f.path + "/control/000.json"), 0) }
            else { XCTAssertEqual(mkfifo(f.path + "/control/000.json", 0o600), 0) }
            XCTAssertFalse(engine.inspect().mockStartAllowed)
        }
    }
    func testProtectedMetadataAndHostControlOutsideRestoreUnit() throws {
        let f = try fixture(), (store, _, engine) = try f.open()
        XCTAssertNotEqual(store.identity.control.inode, store.identity.state.inode)
        XCTAssertEqual(store.identity.policy.area, "control")
        XCTAssertEqual(store.identity.manifest.area, "control")
        XCTAssertEqual(chmod(f.path + "/control", 0o750), 0)
        XCTAssertThrowsError(try engine.takeSnapshot())
        XCTAssertEqual(chmod(f.path + "/control", 0o700), 0)
        XCTAssertThrowsError(try RecoveryStore(reopening: "/private/tmp/foreign"))
    }

    func testDriftOfAlreadySwitchedVolumeBeforeFinalVerificationIsDenied() throws {
        let f = try fixture(), (_, backend, engine) = try f.open()
        try engine.takeSnapshot(); try backend.simulateChanges()
        engine.hook = { if $0 == "before-verified" { try f.replace("state/restored-state.json", data: Data("later-user-change".utf8)) } }
        XCTAssertThrowsError(try engine.rollback())
        XCTAssertEqual(try engine.events().last?.phase, "switch-done")
        XCTAssertFalse(engine.inspect().mockStartAllowed)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: f.path + "/state/restored-state.json")), Data("later-user-change".utf8))
    }
    func testBackendSetMismatchRefusedBeforeAnyJournalOrBackendCall() throws {
        let f = try fixture(), (store, _, _) = try f.open()
        let backend = WrongVolumeBackend()
        for ids in [["state"], ["state", "state"], ["state", "tools", "foreign"]] {
            backend.volumeIDs = ids
            let engine = RecoveryCoordinator(store: store, backend: backend)
            XCTAssertThrowsError(try engine.takeSnapshot())
            XCTAssertFalse(engine.inspect().mockStartAllowed)
        }
        XCTAssertEqual(try store.names(area: "control").count, 4)
    }
    func testChangesOutsideSnapshotReadyAndUnknownStateEntriesDenied() throws {
        let f = try fixture(), (store, backend, engine) = try f.open()
        stop("after-snapshot-done:state", coordinator: engine)
        XCTAssertThrowsError(try engine.takeSnapshot())
        try backend.simulateChanges() // deliberately violate the permitted workload boundary
        engine.hook = { _ in }
        XCTAssertThrowsError(try engine.takeSnapshot())
        XCTAssertFalse(engine.inspect().mockStartAllowed)
        XCTAssertFalse(try store.names(area: "state").contains("snapshot-tools.json"))
        let g = try fixture(), (other, _, otherEngine) = try g.open()
        _ = try other.write(["synthetic": "foreign-entry"], area: "state", name: "foreign.json")
        XCTAssertThrowsError(try otherEngine.takeSnapshot())
        XCTAssertFalse(otherEngine.inspect().mockStartAllowed)
    }

    func testCrashEveryPhaseAndMutationWindowThenFreshProcessRecovery() throws {
        var points = ["before-begun", "after-begun", "after-snapshot-ready", "before-restore-begun", "after-restore-begun", "before-verified", "after-verified"]
        for phase in ["snapshot", "prepare", "switch"] {
            for volume in ["state", "tools"] {
                points += ["after-\(phase)-intent:\(volume)", "before-\(phase)-mutation:\(volume)", "after-\(phase)-mutation:\(volume)", "after-\(phase)-done:\(volume)"]
            }
        }
        for point in points {
            let f = try fixture()
            try child(f, point: point, mode: "crash", expected: 77)
            // New helper processes inspect and recover from disk. No in-memory coordinator state survives.
            try child(f, point: point, mode: "recover", expected: 0)
        }
    }
    private func child(_ f: RecoveryFixture, point: String, mode: String, expected: Int32) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "StateManifestTests.RecoveryTests/testCrashHarnessChild", Bundle(for: RecoveryTests.self).bundleURL.path]
        process.environment = ["PATH": "/usr/bin:/bin", "SANJBOX_B4_TEST_PATH": f.path, "SANJBOX_B4_TEST_POINT": point, "SANJBOX_B4_TEST_MODE": mode]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, expected, "\(mode) \(point)")
    }
    func testCrashHarnessChild() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SANJBOX_B4_TEST_PATH"], let point = env["SANJBOX_B4_TEST_POINT"], let mode = env["SANJBOX_B4_TEST_MODE"] else { return }
        let store = try RecoveryStore(reopening: path), backend = FileBackedRecoveryMock(store: store)
        let engine = RecoveryCoordinator(store: store, backend: backend)
        if mode == "crash" {
            engine.hook = { if $0 == point { _exit(77) } }
            try engine.takeSnapshot()
            try backend.simulateChanges()
            try engine.rollback()
            _exit(91)
        }
        let report = engine.inspect()
        XCTAssertEqual(report.mockStartAllowed, point == "after-verified", point)
        XCTAssertFalse(report.realStartAllowed)
        let records = try engine.events()
        if records.last?.phase.hasSuffix("-intent") == true {
            XCTAssertThrowsError(try engine.takeSnapshot())
            XCTAssertThrowsError(try engine.rollback())
            XCTAssertFalse(engine.inspect().mockStartAllowed)
        } else {
            if !records.contains(where: { $0.phase == "snapshot-ready" }) { try engine.takeSnapshot() }
            try engine.rollback()
            XCTAssertTrue(engine.inspect().mockStartAllowed, point)
        }
    }

    func testCLIWrapperDefaultDryRunApplyAndIdentityFirst() throws {
        let f = try fixture()
        let context = ProbeContext.capture()
        let expectation = try expected(context)
        // CLI input files are in this known synthetic fixture root, not in control/state.
        let expectationPath = f.path + "/run.state-expect.json", manifestPath = f.path + "/run.state-manifest.json"
        try JSONEncoder().encode(expectation).write(to: URL(fileURLWithPath: expectationPath))
        try JSONEncoder().encode(example()).write(to: URL(fileURLWithPath: manifestPath))
        let binary = Bundle(for: RecoveryTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("sanjbox-state-recovery")
        for switches in [[], ["--apply"]] {
            let process = Process()
            process.executableURL = package.appendingPathComponent("recovery-mock.sh")
            process.arguments = ["mock-demo", "--expect", expectationPath, "--manifest", manifestPath] + switches
            var env = ProcessInfo.processInfo.environment
            env["SANJBOX_STATE_RECOVERY_BIN"] = binary.path
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe; process.standardError = FileHandle.standardError
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
            let result = try JSONDecoder().decode(RecoveryInspection.self, from: data)
            XCTAssertEqual(result.phase, switches.isEmpty ? "dry-run" : "verified")
            XCTAssertFalse(result.realStartAllowed)
        }
        var wrong = expectation
        wrong.expectation.effectiveUID = context.effectiveUID + 1
        try JSONEncoder().encode(wrong).write(to: URL(fileURLWithPath: expectationPath))
        let result = try StateRecoveryCommand.run(["mock-demo", "--expect", expectationPath, "--manifest", "/not-read.state-manifest.json", "--apply"], capture: { _ in context })
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertThrowsError(try StateRecoveryCommand.run(["apfs", "--apply"]))
        XCTAssertThrowsError(try StateRecoveryCommand.run(["mock-demo", "--dry-run", "--apply"]))
    }
    func testOwnedCleanupRemovesCompletedMockAndRejectsUnexpectedRootEntry() throws {
        let store = try RecoveryStore.create(manifest: example())
        let backend = FileBackedRecoveryMock(store: store), engine = RecoveryCoordinator(store: store, backend: backend)
        try backend.initialize(); try engine.takeSnapshot(); try engine.rollback()
        let path = store.path
        try store.cleanup()
        try store.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let f = try fixture(), (other, _, _) = try f.open()
        try Data("own-test-extra".utf8).write(to: URL(fileURLWithPath: f.path + "/extra"))
        XCTAssertThrowsError(try other.cleanup())
    }
}
