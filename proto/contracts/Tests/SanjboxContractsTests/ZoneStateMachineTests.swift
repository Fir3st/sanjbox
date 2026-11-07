import Foundation
import Testing
@testable import SanjboxContracts

@Suite("Stavový automat oblasti")
struct ZoneStateMachineTests {
    /// Walks created → starting → running and returns the machine with an identity bound.
    private func runningZone() throws -> ZoneStateMachine {
        var machine = try ZoneStateMachine(zoneID: "a1b2")
        try machine.assignIdentity(uid: 4501, gid: 4500)
        try machine.apply(.start)
        try machine.apply(.launched)
        return machine
    }

    @Test func allowedTableIsExplicitAndExhaustive() {
        #expect(ZoneStateMachine.allowedTransitions.count == 10)
        #expect(ZoneStateMachine.forbiddenTransitions.count
            == ZoneState.allCases.count * ZoneEvent.allCases.count - ZoneStateMachine.allowedTransitions.count)
        for transition in ZoneStateMachine.allowedTransitions {
            #expect(ZoneStateMachine.target(from: transition.from, on: transition.event) == transition.to)
        }
    }

    /// One negative test per forbidden (state, event) pair: 64 pairs, 10 allowed, 54 refused.
    @Test func everyForbiddenTransitionIsRefused() throws {
        #expect(ZoneStateMachine.forbiddenTransitions.count == 54)
        for forbidden in ZoneStateMachine.forbiddenTransitions {
            var machine = try machine(in: forbidden.from)
            rejection("forbidden-transition") { try machine.apply(forbidden.event) }
            #expect(machine.state == forbidden.from, "a refused event must not change state")
        }
    }

    @Test func LC06StartDuringStoppingAndAfterStopIsRefused() throws {
        var stopping = try runningZone()
        try stopping.apply(.stop)
        #expect(stopping.state == .stopping)
        rejection("forbidden-transition") { try stopping.apply(.start) }

        var stopped = try runningZone()
        try stopped.apply(.stop)
        try stopped.apply(.quiesced)
        #expect(stopped.state == .stopped)
        rejection("forbidden-transition") { try stopped.apply(.start) }
        // and the state is still `stopped`, not silently reset
        #expect(stopped.state == .stopped)
    }

    @Test func LC11IdentityIsReleasedOnlyAfterCleanup() throws {
        var machine = try runningZone()
        try machine.apply(.stop)
        try machine.apply(.quiesced)
        // still bound while stopped
        #expect(machine.uid == 4501)
        #expect(!machine.uidAvailableForReuse)
        try machine.apply(.cleanup)
        #expect(machine.state == .cleaning)
        #expect(machine.uid == 4501)
        #expect(!machine.uidAvailableForReuse)
        rejection("uid-reuse-before-cleanup") { try machine.assignIdentity(uid: 4502, gid: 4500) }
        try machine.apply(.cleaned)
        #expect(machine.state == .cleaned)
        #expect(machine.uid == nil)
        #expect(machine.uidAvailableForReuse)
        // cleaned is terminal: the same zone cannot restart and cannot be re-identified
        rejection("forbidden-transition") { try machine.apply(.start) }
        rejection("state-invariant") { try machine.assignIdentity(uid: 4502, gid: 4500) }
    }

    @Test func identityIsBoundAtMostOnceAndOnlyBeforeStart() throws {
        var machine = try ZoneStateMachine(zoneID: "a1b2")
        try machine.assignIdentity(uid: 4501, gid: 4500)
        rejection("uid-already-assigned") { try machine.assignIdentity(uid: 4501, gid: 4500) }
        try machine.apply(.start)
        rejection("state-invariant") { try machine.assignIdentity(uid: 4502, gid: 4500) }
    }

    @Test func startWithoutIdentityIsRefused() throws {
        var machine = try ZoneStateMachine(zoneID: "a1b2")
        rejection("state-invariant") { try machine.apply(.start) }
        #expect(machine.state == .created)
    }

    @Test func cleanupIsOnlyReachableFromStopped() throws {
        var machine = try ZoneStateMachine(zoneID: "a1b2")
        try machine.assignIdentity(uid: 4501, gid: 4500)
        rejection("forbidden-transition") { try machine.apply(.cleanup) }
        try machine.apply(.start)
        rejection("forbidden-transition") { try machine.apply(.cleanup) }
    }

    @Test func identityBelowMinimumIsRefused() throws {
        var machine = try ZoneStateMachine(zoneID: "a1b2")
        rejection("invalid-range") { try machine.assignIdentity(uid: 500, gid: 4500) }
        rejection("invalid-identifier") { _ = try ZoneStateMachine(zoneID: "A1B2") }
    }

    @Test func invariantsHoldAlongTheHappyPath() throws {
        var machine = try runningZone()
        try machine.assertInvariants()
        try machine.apply(.pause)
        #expect(machine.state == .paused)
        try machine.apply(.resume)
        #expect(machine.state == .running)
        try machine.apply(.stop)
        try machine.apply(.quiesced)
        try machine.apply(.cleanup)
        try machine.apply(.cleaned)
        try machine.assertInvariants()
    }

    @Test func everyCrashPointMapsToAnAdmissionDecision() {
        for point in ZoneCrashPoint.allCases {
            let action = point.recoveryAction
            // LC-06: only a clean rollback or a completed cleanup may precede a start.
            #expect(action.permitsStart == ["refuseAndRollbackToCreated", "identityReusable"].contains(action.rawValue),
                    "\(point.rawValue) permitsStart")
            // LC-11: the UID is reusable only after the cleanup commit is durable.
            #expect(action.permitsUIDReuse == (point == .afterCleanupCommit), "\(point.rawValue) permitsUIDReuse")
        }
    }

    @Test func everyEventDeclaresItsCrashPoints() {
        for event in ZoneEvent.allCases {
            if event == .resume {
                #expect(event.crashPoints.isEmpty)
                continue
            }
            #expect(!event.crashPoints.isEmpty, "\(event.rawValue) has no crash point")
        }
        // A crash in flight may admit a start only where no identity was committed yet. The
        // cleanup commit is the other exception: it is observable only after cleanup finished.
        let startPermitting = ZoneCrashPoint.allCases.filter { $0.recoveryAction.permitsStart }
        #expect(startPermitting == [.beforeIdentityCommit, .afterCleanupCommit])
        #expect(ZoneEvent.start.crashPoints == [.beforeIdentityCommit, .afterIdentityCommit])
        #expect(ZoneEvent.launched.crashPoints == [.beforeProtectionsArmed, .afterProtectionsArmed])
        #expect(ZoneEvent.cleaned.crashPoints == [.afterCleanupCommit])
    }

    /// Replays `target` reachable states by walking allowed transitions from `created`.
    private func machine(in target: ZoneState) throws -> ZoneStateMachine {
        guard target != .created else {
            var fresh = try ZoneStateMachine(zoneID: "a1b2")
            try fresh.assertInvariants()
            return fresh
        }
        var machine = try ZoneStateMachine(zoneID: "a1b2")
        try machine.assignIdentity(uid: 4501, gid: 4500)
        switch target {
        case .created:
            break
        case .starting:
            try machine.apply(.start)
        case .running:
            try machine.apply(.start)
            try machine.apply(.launched)
        case .paused:
            try machine.apply(.start)
            try machine.apply(.launched)
            try machine.apply(.pause)
        case .stopping:
            try machine.apply(.start)
            try machine.apply(.launched)
            try machine.apply(.stop)
        case .stopped:
            try machine.apply(.start)
            try machine.apply(.launched)
            try machine.apply(.stop)
            try machine.apply(.quiesced)
        case .cleaning:
            try machine.apply(.start)
            try machine.apply(.launched)
            try machine.apply(.stop)
            try machine.apply(.quiesced)
            try machine.apply(.cleanup)
        case .cleaned:
            try machine.apply(.start)
            try machine.apply(.launched)
            try machine.apply(.stop)
            try machine.apply(.quiesced)
            try machine.apply(.cleanup)
            try machine.apply(.cleaned)
        }
        #expect(machine.state == target)
        return machine
    }
}
