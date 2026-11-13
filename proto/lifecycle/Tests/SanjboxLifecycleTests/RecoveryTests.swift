import Foundation
import XCTest
import SanjboxContracts
@testable import SanjboxLifecycle

final class RecoveryTests: XCTestCase {
    private func crashMatrix(_ operation: LifecycleOperation) throws {
        for hook in operation.crashHooks {
            let fixture = try Fixture(); try fixture.prepare(for: operation)
            let process = Process()
            process.executableURL = try crashDriver()
            process.arguments = [fixture.path, "t001", operation.rawValue, hook]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 77, "\(operation):\(hook)")
            let store = try fixture.open(), c = LifecycleCoordinator(store: store)
            let before = try store.entries()
            let inspection = try c.inspect(zone: "t001")
            XCTAssertFalse(inspection.realStartAllowed)
            if hook.hasPrefix("afterIntent:") || hook.hasPrefix("afterEffect:") {
                XCTAssertTrue(inspection.requiresReview, hook)
                XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"))
                XCTAssertThrowsError(try c.recover(zone: "t001"))
                XCTAssertThrowsError(try c.execute(.start, zone: "t001"))
                XCTAssertThrowsError(try c.execute(.cleanup, zone: "t001"))
                XCTAssertEqual(try store.entries(), before)
            } else if hook == "beforeBegin" {
                try c.recover(zone: "t001")
                XCTAssertEqual(try store.entries(), before)
                try c.execute(operation, zone: "t001")
                XCTAssertEqual(try c.inspect(zone: "t001").state, resultState(operation))
            } else if hook == "afterFinish" {
                try c.recover(zone: "t001")
                XCTAssertEqual(try store.entries(), before)
                XCTAssertEqual(inspection.state, resultState(operation))
            } else if operation == .start && inspection.completedSteps < 3 {
                XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"))
                XCTAssertThrowsError(try c.execute(.start, zone: "t001"))
                try c.recover(zone: "t001")
                XCTAssertEqual(try c.inspect(zone: "t001").state, .stopped)
                XCTAssertEqual(try c.inspect(zone: "t001").reservedUID, 750)
            } else if [.start, .pause, .resume].contains(operation) {
                XCTAssertTrue(inspection.requiresReview)
                XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"))
                XCTAssertThrowsError(try c.recover(zone: "t001"))
                XCTAssertThrowsError(try c.execute(operation, zone: "t001"))
                XCTAssertEqual(try store.entries(), before)
            } else {
                try c.recover(zone: "t001")
                XCTAssertEqual(try c.inspect(zone: "t001").state, resultState(operation))
                let recovered = try store.entries()
                try c.recover(zone: "t001"); XCTAssertEqual(try store.entries(), recovered)
            }
        }
    }
    func testStartProcessDeathAtEveryBoundary() throws { try crashMatrix(.start) }
    func testPauseProcessDeathAtEveryBoundary() throws { try crashMatrix(.pause) }
    func testResumeProcessDeathAtEveryBoundary() throws { try crashMatrix(.resume) }
    func testStopProcessDeathAtEveryBoundary() throws { try crashMatrix(.stop) }
    func testCleanupProcessDeathAtEveryBoundary() throws { try crashMatrix(.cleanup) }

    func testKnownNoEffectFailureAtEveryStepRetriesWithoutDuplicateSuccessAudit() throws {
        for operation in LifecycleOperation.allCases {
            for step in operation.steps {
                let fixture = try Fixture(); try fixture.prepare(for: operation)
                let store = try fixture.open(), mock = FileBackedMock(store: store), c = LifecycleCoordinator(store: store, backend: mock)
                mock.failBefore = step
                XCTAssertThrowsError(try c.execute(operation, zone: "t001")) { XCTAssertTrue($0 is MockNoEffectFailure) }
                XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"))
                XCTAssertEqual(try c.inspect(zone: "t001").operation, operation)
                let failed = try AuditLog.decode(c.audit(zone: "t001"))
                XCTAssertEqual(failed.last?.outcome, .failed)
                mock.failBefore = nil
                try c.execute(operation, zone: "t001")
                XCTAssertEqual(try c.inspect(zone: "t001").state, resultState(operation))
                let audit = try AuditLog.decode(c.audit(zone: "t001"))
                XCTAssertEqual(audit.filter { $0.action == operation.action && $0.outcome == .allowed }.count, 1)
            }
        }
    }

    func testUncertainFailureAtEveryStepQuarantinesFreshCoordinator() throws {
        for operation in LifecycleOperation.allCases {
            for step in operation.steps {
                let fixture = try Fixture(); try fixture.prepare(for: operation)
                do {
                    let store = try fixture.open(), mock = FileBackedMock(store: store), c = LifecycleCoordinator(store: store, backend: mock)
                    mock.failAfter = step
                    XCTAssertThrowsError(try c.execute(operation, zone: "t001"))
                    XCTAssertTrue(try c.inspect(zone: "t001").requiresReview)
                }
                let store = try fixture.open(), c = LifecycleCoordinator(store: store)
                XCTAssertTrue(try c.inspect(zone: "t001").requiresReview)
                XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001"))
                XCTAssertThrowsError(try c.recover(zone: "t001"))
                XCTAssertThrowsError(try store.destroyCompletedFixture())
            }
        }
    }

    func testH1CrashPointCoverageAndRecoveryPolicy() throws {
        let mapping: [(ZoneCrashPoint, LifecycleOperation, String, ZoneRecoveryAction)] = [
            (.beforeIdentityCommit, .start, "beforeBegin", .refuseAndRollbackToCreated), (.afterIdentityCommit, .start, "afterBegin", .denyStartUntilCleanup),
            (.beforeProtectionsArmed, .start, "beforeIntent:armProtections", .denyStartUntilCleanup),
            (.afterProtectionsArmed, .start, "afterDone:armProtections", .denyStartAndRequireReview),
            (.duringPause, .pause, "afterDone:quiesceUID", .denyStartAndRequireReview),
            (.beforeQuiescence, .stop, "beforeIntent:terminateUID", .denyStartUntilCleanup),
            (.afterQuiescence, .stop, "afterDone:verifyZeroProcesses", .denyStartUntilCleanup),
            (.duringCleanup, .cleanup, "afterDone:removeVolumes", .resumeCleanup),
            (.afterCleanupCommit, .cleanup, "afterFinish", .identityReusable)
        ]
        XCTAssertEqual(Set(mapping.map(\.0)), Set(ZoneCrashPoint.allCases))
        for (point, operation, hook, expectedAction) in mapping {
            XCTAssertEqual(point.recoveryAction, expectedAction, "H1 recovery contract drift")
            let fixture = try Fixture(); try fixture.prepare(for: operation)
            do {
                let store = try fixture.open(), c = LifecycleCoordinator(store: store)
                c.hook = { if $0 == hook { throw InjectedCrash() } }
                XCTAssertThrowsError(try c.execute(operation, zone: "t001"))
            }
            let store = try fixture.open(), c = LifecycleCoordinator(store: store)
            let inspection = try c.inspect(zone: "t001")
            XCTAssertEqual(inspection.uidReusable, expectedAction.permitsUIDReuse, point.rawValue)
            if expectedAction == .denyStartAndRequireReview {
                XCTAssertTrue(inspection.requiresReview); XCTAssertThrowsError(try c.recover(zone: "t001"))
            }
            if !expectedAction.permitsStart {
                XCTAssertFalse(c.mockAdmissionAllowed(zone: "t001")); XCTAssertThrowsError(try c.execute(.start, zone: "t001"))
            }
            if point == .beforeIdentityCommit { XCTAssertNil(inspection.reservedUID); try c.execute(.start, zone: "t001") }
            if point == .duringCleanup { try c.recover(zone: "t001"); XCTAssertTrue(try c.inspect(zone: "t001").uidReusable) }
        }
    }

    func testCrossZoneReuseOnlyAfterCleanupFinishSurvivesRestart() throws {
        for hook in LifecycleOperation.cleanup.crashHooks {
            let fixture = try Fixture(); try fixture.prepare(for: .cleanup)
            do {
                let store = try fixture.open(), c = LifecycleCoordinator(store: store)
                try c.register(manifest: fixtureManifest("t002"))
                c.hook = { if $0 == hook { throw InjectedCrash() } }
                XCTAssertThrowsError(try c.execute(.cleanup, zone: "t001"))
            }
            let store = try fixture.open(), c = LifecycleCoordinator(store: store)
            if hook == "afterFinish" {
                try c.execute(.start, zone: "t002"); XCTAssertTrue(c.mockAdmissionAllowed(zone: "t002"))
            } else {
                XCTAssertThrowsError(try c.execute(.start, zone: "t002"), hook)
                XCTAssertFalse(try c.inspect(zone: "t001").uidReusable, hook)
            }
        }
    }
}
