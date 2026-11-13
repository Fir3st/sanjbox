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

    /// Pinned literal copy of the transition table. It is deliberately not derived from
    /// `ZoneStateMachine.allowedTransitions`: an accidental edit to the implementation must fail
    /// here, not update the expectation with it.
    private static let pinnedAllowed: [ZoneTransition] = [
        .init(from: .created, event: .start, to: .starting),
        .init(from: .starting, event: .launched, to: .running),
        .init(from: .starting, event: .stop, to: .stopping),
        .init(from: .running, event: .pause, to: .paused),
        .init(from: .running, event: .stop, to: .stopping),
        .init(from: .paused, event: .resume, to: .running),
        .init(from: .paused, event: .stop, to: .stopping),
        .init(from: .stopping, event: .quiesced, to: .stopped),
        .init(from: .stopped, event: .cleanup, to: .cleaning),
        .init(from: .cleaning, event: .cleaned, to: .cleaned),
    ]

    @Test func implementationMatchesThePinnedTransitionTable() {
        #expect(ZoneStateMachine.allowedTransitions == Self.pinnedAllowed)
        #expect(Self.pinnedAllowed.count == 10)
    }

    /// One negative test per forbidden (state, event) pair. The forbidden set is computed from the
    /// pinned literal table, not from `forbiddenTransitions`: 64 pairs, 10 allowed, 54 refused.
    @Test func everyForbiddenPairOutsideThePinnedTableIsRefused() throws {
        let allowedKeys = Set(Self.pinnedAllowed.map { "\($0.from.rawValue)/\($0.event.rawValue)" })
        let allPairs = ZoneState.allCases.flatMap { state in
            ZoneEvent.allCases.map { (state, $0) }
        }
        let forbidden = allPairs.filter {
            !allowedKeys.contains("\($0.0.rawValue)/\($0.1.rawValue)")
        }
        #expect(forbidden.count == 54)
        for (state, event) in forbidden {
            var machine = try machine(in: state)
            rejection("forbidden-transition") { try machine.apply(event) }
            #expect(machine.state == state, "a refused event must not change state")
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

    /// The refused start is the reachable case where the candidate target state (`starting`)
    /// violates the identity invariant. The machine must commit neither the state nor the identity
    /// before the invariant check passes.
    @Test func rejectedStartLeavesStateAndIdentityUntouched() throws {
        var machine = try ZoneStateMachine(zoneID: "a1b2")
        rejection("state-invariant") { try machine.apply(.start) }
        #expect(machine.state == .created)
        #expect(machine.uid == nil)
        #expect(machine.gid == nil)
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

    @Test func everyCrashPointIsReachableFromSomeEvent() {
        let reachable = Set(ZoneEvent.allCases.flatMap { $0.crashPoints })
        #expect(reachable == Set(ZoneCrashPoint.allCases))
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
