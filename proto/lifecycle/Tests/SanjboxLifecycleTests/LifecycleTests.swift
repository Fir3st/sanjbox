import Foundation
import XCTest
import SanjboxContracts
@testable import SanjboxLifecycle

final class LifecycleTests: XCTestCase {
    func testWholeLifecycleUsesH1ManifestReportAndAudit() throws {
        let fixture = try Fixture(), store = try fixture.open(), c = LifecycleCoordinator(store: store)
        try c.register(manifest: fixtureManifest())
        let report = try c.manifestReport(zone: "t001")
        XCTAssertTrue(report.consistentDesign); XCTAssertTrue(report.requiredRolesDeclared)
        XCTAssertFalse(report.deploymentReady); XCTAssertEqual(report.acceptanceStatus, "Neověřeno")
        XCTAssertEqual(try c.inspect(zone: "t001").state, .created)
        for operation in LifecycleOperation.allCases {
            try c.execute(operation, zone: "t001")
            XCTAssertEqual(try c.inspect(zone: "t001").state, resultState(operation))
            XCTAssertFalse(try c.inspect(zone: "t001").realStartAllowed)
        }
        XCTAssertTrue(try c.inspect(zone: "t001").uidReusable)
        let audit = try AuditLog.decode(c.audit(zone: "t001"))
        XCTAssertEqual(audit.map(\.action), [.zoneCreated, .zoneStarted, .zonePaused, .zoneResumed, .zoneStopped, .zoneCleaned])
        XCTAssertTrue(audit.allSatisfy { $0.outcome == .allowed && $0.actorUID == 0 })
        try store.destroyCompletedFixture()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.path))
    }

    func testEveryForbiddenOperationLeavesLedgerUntouched() throws {
        let sequences: [[LifecycleOperation]] = [[], [.start], [.start, .pause], [.start, .stop], [.start, .stop, .cleanup]]
        for sequence in sequences {
            let fixture = try Fixture(), store = try fixture.open(), c = LifecycleCoordinator(store: store)
            try c.register(manifest: fixtureManifest())
            for operation in sequence { try c.execute(operation, zone: "t001") }
            let state = try c.inspect(zone: "t001").state
            for operation in LifecycleOperation.allCases {
                let noOp = (operation == .pause && state == .paused) || (operation == .stop && state == .stopped) || (operation == .cleanup && state == .cleaned)
                let event = operation.beginEvent ?? operation.finishEvent
                if ZoneStateMachine.target(from: state, on: event) == nil && !noOp {
                    let before = try store.entries()
                    XCTAssertThrowsError(try c.execute(operation, zone: "t001"), "\(state)/\(operation)")
                    XCTAssertEqual(try store.entries(), before)
                }
            }
        }
    }

    func testLC06AdmissionClosedAtEveryStopAndCleanupBoundary() throws {
        for operation in [LifecycleOperation.stop, .cleanup] {
            let fixture = try Fixture(); try fixture.prepare(for: operation)
            let store = try fixture.open(), c = LifecycleCoordinator(store: store)
            c.hook = { hook in
                if operation == .stop && hook == "beforeBegin" { return }
                XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"), hook)
                XCTAssertThrowsError(try c.execute(.start, zone: "t001"), hook)
                XCTAssertThrowsError(try c.execute(.resume, zone: "t001"), hook)
            }
            try c.execute(operation, zone: "t001")
            XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"))
            XCTAssertThrowsError(try c.execute(.start, zone: "t001"))
        }
    }

    func testLC11CrossZoneUIDReservationThroughAllStates() throws {
        let fixture = try Fixture(), store = try fixture.open(), c = LifecycleCoordinator(store: store)
        try c.register(manifest: fixtureManifest())
        try c.register(manifest: fixtureManifest("t002"))
        try c.register(manifest: fixtureManifest("t003", uid: 751))
        try c.execute(.start, zone: "t003") // independent UID positive control
        for operation in LifecycleOperation.allCases {
            c.hook = { hook in
                if operation == .start && hook == "beforeBegin" { return }
                if operation == .cleanup && hook == "afterFinish" { return }
                XCTAssertThrowsError(try c.execute(.start, zone: "t002"), "\(operation)/\(hook)")
            }
            try c.execute(operation, zone: "t001")
        }
        c.hook = { _ in }
        try c.execute(.start, zone: "t002")
        XCTAssertEqual(try c.inspect(zone: "t002").reservedUID, 750)
        XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"))
        XCTAssertTrue(c.mockAdmissionAllowed(zone: "t002"))
    }

    func testStopStartingAtEveryCompletedCheckpoint() throws {
        for hook in ["afterBegin"] + LifecycleOperation.start.steps.map({ "afterDone:\($0.rawValue)" }) {
            let fixture = try Fixture(); try fixture.prepare(for: .start)
            do {
                let store = try fixture.open(), c = LifecycleCoordinator(store: store)
                c.hook = { if $0 == hook { throw InjectedCrash() } }
                XCTAssertThrowsError(try c.execute(.start, zone: "t001"))
            }
            let store = try fixture.open(), c = LifecycleCoordinator(store: store)
            try c.execute(.stop, zone: "t001")
            XCTAssertEqual(try c.inspect(zone: "t001").state, .stopped)
            try c.execute(.cleanup, zone: "t001")
            XCTAssertTrue(try c.inspect(zone: "t001").uidReusable)
        }
    }

    func testStopIncludesDetachedStoppedAndUserDomainProcesses() throws {
        let fixture = try Fixture(); try fixture.prepare(for: .stop)
        let store = try fixture.open(), mock = FileBackedMock(store: store), c = LifecycleCoordinator(store: store, backend: mock)
        XCTAssertEqual(Set(try mock.world().zones["t001"]!.processes.map(\.kind)), Set(["gui", "user-job", "cli", "detached", "stopped"]))
        c.hook = { hook in
            if hook == "afterDone:bootoutDomains" {
                XCTAssertEqual(Set(try mock.world().zones["t001"]!.processes.map(\.kind)), Set(["cli", "detached", "stopped"]))
            }
            if hook == "afterDone:terminateUID" { XCTAssertTrue(try mock.world().zones["t001"]!.processes.isEmpty) }
        }
        try c.execute(.stop, zone: "t001")
        let world = try mock.world().zones["t001"]!
        XCTAssertFalse(world.guiDomain); XCTAssertFalse(world.userDomain); XCTAssertFalse(world.scheduledJobs)
        XCTAssertTrue(world.admissionBlocked); XCTAssertTrue(world.networkIPCBlocked)
    }

    func testPauseQuiescesEveryProcessAndResumeRestoresOnlyAfterProtection() throws {
        let fixture = try Fixture(); try fixture.prepare(for: .pause)
        let store = try fixture.open(), mock = FileBackedMock(store: store), c = LifecycleCoordinator(store: store, backend: mock)
        try c.execute(.pause, zone: "t001")
        XCTAssertTrue(try mock.world().zones["t001"]!.processes.allSatisfy(\.frozen))
        XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"))
        c.hook = { hook in
            if hook != "afterFinish" { XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"), hook) }
        }
        try c.execute(.resume, zone: "t001")
        XCTAssertTrue(c.mockAdmissionAllowed(zone: "t001"))
        XCTAssertTrue(try mock.world().zones["t001"]!.processes.allSatisfy { !$0.frozen })
    }

    func testIdempotentRegistrationPauseStopCleanupAndRecovery() throws {
        let fixture = try Fixture(), store = try fixture.open(), c = LifecycleCoordinator(store: store)
        try c.register(manifest: fixtureManifest())
        let registered = try store.entries()
        try c.register(manifest: fixtureManifest()); XCTAssertEqual(try store.entries(), registered)
        try c.execute(.start, zone: "t001")
        for operation in [LifecycleOperation.pause, .stop, .cleanup] {
            try c.execute(operation, zone: "t001")
            let before = try store.entries()
            try c.execute(operation, zone: "t001"); try c.recover(zone: "t001")
            XCTAssertEqual(try store.entries(), before)
        }
    }

    func testManifestConflictInvalidDesignAndUIDFloorRefusedBeforeMutation() throws {
        let fixture = try Fixture(), store = try fixture.open(), c = LifecycleCoordinator(store: store)
        try c.register(manifest: fixtureManifest())
        let before = try store.entries()
        XCTAssertThrowsError(try c.register(manifest: fixtureManifest(uid: 751)))
        var manifest = try StateManifestSchema.decode(fixtureManifest("t002"))
        manifest.roots.removeLast()
        XCTAssertThrowsError(try c.register(manifest: JSONEncoder().encode(manifest)))
        manifest = try StateManifestSchema.decode(fixtureManifest("t002"))
        manifest.zone.uid = 1; manifest.roots = manifest.roots.map { var r = $0; r.ownerUID = 1; return r }
        XCTAssertThrowsError(try c.register(manifest: JSONEncoder().encode(manifest)))
        XCTAssertEqual(try store.entries(), before)
    }

    func testUnknownZoneCannotAuthorizeAnything() throws {
        let fixture = try Fixture(), store = try fixture.open(), c = LifecycleCoordinator(store: store)
        XCTAssertFalse(c.mockAdmissionAllowed(zone: "t999"))
        XCTAssertThrowsError(try c.inspect(zone: "t999")); XCTAssertThrowsError(try c.recover(zone: "t999"))
        XCTAssertThrowsError(try c.audit(zone: "t999")); XCTAssertThrowsError(try c.execute(.start, zone: "t999"))
    }
    func testCleanedZoneInspectionCannotAdvertiseUIDAlreadyReboundElsewhere() throws {
        let fixture = try Fixture(), store = try fixture.open(), c = LifecycleCoordinator(store: store)
        try c.register(manifest: fixtureManifest())
        try c.register(manifest: fixtureManifest("t002"))
        try c.execute(.start, zone: "t001")
        try c.execute(.stop, zone: "t001")
        try c.execute(.cleanup, zone: "t001")
        XCTAssertTrue(try c.inspect(zone: "t001").uidReusable)
        try c.execute(.start, zone: "t002")
        XCTAssertFalse(try c.inspect(zone: "t001").uidReusable)
        XCTAssertEqual(try c.inspect(zone: "t002").reservedUID, 750)
        try c.execute(.stop, zone: "t002")
        try c.execute(.cleanup, zone: "t002")
        XCTAssertTrue(try c.inspect(zone: "t001").uidReusable)
    }

}
