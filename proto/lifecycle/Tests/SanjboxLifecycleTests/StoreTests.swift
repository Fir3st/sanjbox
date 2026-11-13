import Foundation
import XCTest
import Darwin
import SanjboxContracts
@testable import SanjboxLifecycle

final class StoreTests: XCTestCase {
    func testSecondWriterIsRejectedAndFreshReaderSucceedsAfterClose() throws {
        let fixture = try Fixture()
        do {
            let store = try fixture.open()
            XCTAssertThrowsError(try fixture.open())
            try LifecycleCoordinator(store: store).register(manifest: fixtureManifest())
        }
        let store = try fixture.open()
        XCTAssertEqual(try LifecycleCoordinator(store: store).inspect(zone: "t001").state, .created)
    }

    func testInvalidFixturePathsAndRootSymlinksAreRejected() throws {
        XCTAssertThrowsError(try LifecycleStore(path: "/private/tmp"))
        XCTAssertThrowsError(try LifecycleStore(path: LifecycleStore.prefix + "../other"))
        let fixture = try Fixture(), alias = LifecycleStore.prefix + UUID().uuidString
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: fixture.path)
        defer { try? FileManager.default.removeItem(atPath: alias) }
        XCTAssertThrowsError(try LifecycleStore(path: alias))
    }

    func testHeldDirectoryReplacementInvalidatesEveryDecision() throws {
        let fixture = try Fixture(), store = try fixture.open(), c = LifecycleCoordinator(store: store)
        try c.register(manifest: fixtureManifest()); try c.execute(.start, zone: "t001")
        let moved = fixture.path + "-moved"
        try FileManager.default.moveItem(atPath: fixture.path, toPath: moved)
        defer { try? FileManager.default.moveItem(atPath: moved, toPath: fixture.path) }
        XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"))
        XCTAssertThrowsError(try store.destroyCompletedFixture())
    }

    func testUnknownDuplicateTruncatedAndOversizedJSONFailClosed() throws {
        let mutations: [(Data) -> Data] = [
            { Data($0.dropLast()) },
            { Data($0.dropLast()) + Data(",\"unknown\":true}".utf8) },
            { Data($0.dropLast()) + Data(",\"count\":1}".utf8) },
            { _ in Data(repeating: 32, count: 1024 * 1024 + 1) },
            { $0 + Data("\n".utf8) }
        ]
        for mutation in mutations {
            let fixture = try Fixture(), store = try fixture.open(), c = LifecycleCoordinator(store: store)
            try c.register(manifest: fixtureManifest()); try c.execute(.start, zone: "t001")
            let path = fixture.path + "/head.json", data = try Data(contentsOf: URL(fileURLWithPath: path))
            try mutation(data).write(to: URL(fileURLWithPath: path))
            XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"))
            XCTAssertThrowsError(try c.recover(zone: "t001"))
        }
    }

    func testJournalGapOrphanRecordWrongHeadAndCorruptEventFailClosed() throws {
        for mutation in 0..<5 {
            let fixture = try Fixture(), store = try fixture.open(), c = LifecycleCoordinator(store: store)
            try c.register(manifest: fixtureManifest()); try c.execute(.start, zone: "t001")
            switch mutation {
            case 0: try FileManager.default.removeItem(atPath: fixture.path + "/000001.json")
            case 1: try Data("{}".utf8).write(to: URL(fileURLWithPath: fixture.path + "/unknown.json"))
            case 2: try Data("{}".utf8).write(to: URL(fileURLWithPath: fixture.path + "/999999.json"))
            case 3:
                var head = try decodeCanonical(Head.self, store.read("head.json")); head.digest = "wrong"
                try canonical(head).write(to: URL(fileURLWithPath: fixture.path + "/head.json"))
            default: try Data("{}".utf8).write(to: URL(fileURLWithPath: fixture.path + "/000000.json"))
            }
            XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"))
            XCTAssertThrowsError(try c.execute(.stop, zone: "t001"))
            XCTAssertThrowsError(try store.destroyCompletedFixture())
        }
    }

    func testCanonicalSemanticForgeriesCannotReleaseUID() throws {
        for kind in ["unknown", "finish", "done", "intent", "begin", "retry", "register"] {
            let fixture = try Fixture(), store = try fixture.open(), c = LifecycleCoordinator(store: store)
            try c.register(manifest: fixtureManifest()); try c.execute(.start, zone: "t001")
            let entries = try store.entries()
            let forged = JournalEntry(sequence: entries.count, previous: digest(try canonical(entries.last!)), zoneID: "t001", kind: kind,
                operation: .cleanup, step: kind == "done" || kind == "intent" || kind == "retry" ? .removeUser : nil)
            try store.append(forged)
            XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"))
            XCTAssertThrowsError(try c.inspect(zone: "t001"))
        }
    }

    func testReplayedCrossZoneCollisionCannotBeHiddenByValidHashChain() throws {
        let fixture = try Fixture(), store = try fixture.open(), c = LifecycleCoordinator(store: store)
        try c.register(manifest: fixtureManifest()); try c.register(manifest: fixtureManifest("t002"))
        try c.execute(.start, zone: "t001")
        let entries = try store.entries()
        try store.append(JournalEntry(sequence: entries.count, previous: digest(try canonical(entries.last!)), zoneID: "t002", kind: "begin", operation: .start))
        XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"))
        XCTAssertFalse(c.mockAdmissionAllowed(zone: "t002"))
        XCTAssertThrowsError(try c.inspect(zone: "t001"))
    }

    func testBackendDriftAndFalseZeroOrRestartWitnessPreventStoppedOrReuse() throws {
        for field in ["process", "admission", "network", "job", "volume", "uid"] {
            let fixture = try Fixture(); try fixture.prepare(for: .cleanup)
            let store = try fixture.open(), mock = FileBackedMock(store: store), c = LifecycleCoordinator(store: store)
            var world = try mock.world()
            switch field {
            case "process": world.zones["t001"]!.processes = [.init(kind: "detached", frozen: true)]
            case "admission": world.zones["t001"]!.admissionBlocked = false
            case "network": world.zones["t001"]!.networkIPCBlocked = false
            case "job": world.zones["t001"]!.scheduledJobs = true
            case "volume": world.zones["t001"]!.volumes = []
            default: world.zones["t001"]!.uid = 999
            }
            try store.replace("world.json", data: canonical(world))
            XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"))
            XCTAssertTrue(try c.inspect(zone: "t001").requiresReview)
            XCTAssertFalse(try c.inspect(zone: "t001").uidReusable)
            XCTAssertThrowsError(try c.execute(.cleanup, zone: "t001"))
            XCTAssertThrowsError(try store.destroyCompletedFixture())
        }
    }

    func testUnrelatedZoneDriftOrPendingIntentBlocksGlobalUIDAllocator() throws {
        let fixture = try Fixture(), store = try fixture.open(), c = LifecycleCoordinator(store: store)
        try c.register(manifest: fixtureManifest()); try c.register(manifest: fixtureManifest("t002", uid: 751))
        c.hook = { if $0 == "afterIntent:createUser" { throw InjectedCrash() } }
        XCTAssertThrowsError(try c.execute(.start, zone: "t001"))
        XCTAssertThrowsError(try c.execute(.start, zone: "t002"))
        XCTAssertTrue(try c.inspect(zone: "t002").requiresReview)
        XCTAssertThrowsError(try c.register(manifest: fixtureManifest("t003", uid: 752)))
    }

    func testSymlinkHardlinkFIFOAndPublicModeRecordsRefused() throws {
        for kind in ["symlink", "hardlink", "fifo", "mode"] {
            let fixture = try Fixture(), store = try fixture.open()
            let path = fixture.path + "/world.json", saved = fixture.path + "/saved.json"
            if kind == "mode" { XCTAssertEqual(chmod(path, 0o644), 0) }
            else {
                try FileManager.default.moveItem(atPath: path, toPath: saved)
                switch kind {
                case "symlink": XCTAssertEqual(symlink(saved, path), 0)
                case "hardlink": XCTAssertEqual(link(saved, path), 0)
                default: XCTAssertEqual(mkfifo(path, 0o600), 0)
                }
            }
            XCTAssertThrowsError(try store.read("world.json"), kind)
        }
    }

    func testWriteFlushAndHeadReplacementFailuresPoisonAndConservativelyReopen() throws {
        for hook in ["afterWrite:000000.json", "afterFlush:000000.json", "afterWrite:replacement.json", "afterFlush:replacement.json", "afterRename:head.json"] {
            let fixture = try Fixture()
            do {
                let store = try fixture.open(), c = LifecycleCoordinator(store: store)
                store.writeHook = { if $0 == hook { throw InjectedCrash() } }
                XCTAssertThrowsError(try c.register(manifest: fixtureManifest()))
                store.writeHook = nil
                XCTAssertThrowsError(try store.entries())
                XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"))
            }
            let store = try fixture.open(), c = LifecycleCoordinator(store: store)
            if hook == "afterRename:head.json" {
                XCTAssertEqual(try c.inspect(zone: "t001").state, .created) // reflush accepts complete checkpoint
                try c.execute(.start, zone: "t001")
            } else {
                XCTAssertThrowsError(try c.inspect(zone: "t001")) // preserve orphan/partial replacement
                XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"))
            }
        }
    }

    func testCleanupFinalCommitIOFailureNeverReusesUIDInPoisonedInstance() throws {
        let fixture = try Fixture(); try fixture.prepare(for: .cleanup)
        do {
            let store = try fixture.open(), c = LifecycleCoordinator(store: store)
            try c.register(manifest: fixtureManifest("t002"))
            c.hook = { if $0 == "beforeFinish" { store.writeHook = { if $0 == "afterRename:head.json" { throw InjectedCrash() } } } }
            XCTAssertThrowsError(try c.execute(.cleanup, zone: "t001"))
            XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"))
            XCTAssertThrowsError(try c.execute(.start, zone: "t002"))
        }
        let store = try fixture.open(), c = LifecycleCoordinator(store: store)
        XCTAssertTrue(try c.inspect(zone: "t001").uidReusable)
        try c.execute(.start, zone: "t002") // complete data is revalidated/reflushed by the fresh store
    }

    func testIncompleteFixtureIsNeverAutomaticallyDestroyed() throws {
        let fixture = try Fixture(), store = try fixture.open(), c = LifecycleCoordinator(store: store)
        try c.register(manifest: fixtureManifest())
        XCTAssertThrowsError(try store.destroyCompletedFixture())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path + "/head.json"))
    }

    func testInvalidAuditTimestampFailsBeforeRegistrationMutation() throws {
        let fixture = try Fixture(), store = try fixture.open(), c = LifecycleCoordinator(store: store)
        c.timestamp = { "bad timestamp" }
        XCTAssertThrowsError(try c.register(manifest: fixtureManifest()))
        XCTAssertTrue(try store.entries().isEmpty)
    }
}

private final class LyingNoEffectBackend: MockLifecycleBackend {
    let base: FileBackedMock
    init(store: LifecycleStore) { base = FileBackedMock(store: store) }
    func perform(_ step: MockStep, manifest: StateManifestDocument) throws {
        try base.perform(step, manifest: manifest)
        throw MockNoEffectFailure()
    }
    func validate(expected: [String: MockZoneSnapshot]) throws { try base.validate(expected: expected) }
}

extension StoreTests {
    func testFalseNoEffectPromiseDoesNotClearPendingIntent() throws {
        let fixture = try Fixture(), store = try fixture.open(), backend = LyingNoEffectBackend(store: store)
        let c = LifecycleCoordinator(store: store, backend: backend)
        try c.register(manifest: fixtureManifest())
        XCTAssertThrowsError(try c.execute(.start, zone: "t001"))
        XCTAssertEqual(try store.entries().last?.kind, "intent")
        XCTAssertTrue(try c.inspect(zone: "t001").requiresReview)
        XCTAssertThrowsError(try c.recover(zone: "t001"))
    }

    func testDriftAfterIntentDoesNotOverwriteLaterSyntheticChange() throws {
        let fixture = try Fixture(), store = try fixture.open(), c = LifecycleCoordinator(store: store)
        try c.register(manifest: fixtureManifest())
        var observed: Data?
        c.hook = { hook in
            if hook == "afterIntent:createVolumes" {
                var world = try FileBackedMock(store: store).world()
                world.zones["t001"]!.volumes = ["later-owner-change"]
                let bytes = try canonical(world)
                try store.replace("world.json", data: bytes)
                observed = bytes
            }
        }
        XCTAssertThrowsError(try c.execute(.start, zone: "t001"))
        XCTAssertEqual(try store.read("world.json"), observed)
        XCTAssertEqual(try store.entries().last?.kind, "intent")
        XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"))
    }
}


extension StoreTests {
    func testLockReplacementMissingLinksAndMetadataInvalidateLiveStoreAndExcludeSecondWriter() throws {
        for mutation in ["replacement", "missing", "symlink", "hardlink", "mode"] {
            let fixture = try Fixture()
            do {
                let store = try fixture.open(), c = LifecycleCoordinator(store: store)
                try c.register(manifest: fixtureManifest())
                try c.execute(.start, zone: "t001")
                XCTAssertTrue(c.mockAdmissionAllowed(zone: "t001"))
                let path = fixture.path + "/lock"
                switch mutation {
                case "replacement":
                    XCTAssertEqual(unlink(path), 0)
                    let fd = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
                    XCTAssertGreaterThanOrEqual(fd, 0); if fd >= 0 { close(fd) }
                case "missing": XCTAssertEqual(unlink(path), 0)
                case "symlink":
                    XCTAssertEqual(unlink(path), 0)
                    XCTAssertEqual(symlink("world.json", path), 0)
                case "hardlink": XCTAssertEqual(link(path, fixture.path + "/lock-alias"), 0)
                default: XCTAssertEqual(chmod(path, 0o644), 0)
                }
                XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"), mutation)
                XCTAssertThrowsError(try c.execute(.stop, zone: "t001"), mutation)
                XCTAssertThrowsError(try store.entries(), mutation)
                XCTAssertThrowsError(try fixture.open(), mutation) // directory inode flock remains held
            }
            if mutation == "replacement" {
                // Once the old descriptor closes, the valid replacement can acquire the same
                // directory lock; all durable records and the world are independently reverified.
                let reopened = try fixture.open(), c = LifecycleCoordinator(store: reopened)
                XCTAssertTrue(c.mockAdmissionAllowed(zone: "t001"))
                try c.execute(.stop, zone: "t001")
                try c.execute(.cleanup, zone: "t001")
                XCTAssertTrue(try c.inspect(zone: "t001").uidReusable)
            } else { XCTAssertThrowsError(try fixture.open(), mutation) }
        }
    }
}
