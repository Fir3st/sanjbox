import Foundation

/// Lifecycle state of one zone: created → starting → running → paused → stopping → stopped →
/// cleaning → cleaned. `cleaned` is terminal; a zone that needs to run again is a new zone.
///
/// The machine is a pure prototype of the admission rules from WP1.H2/WP2.2: it performs no system
/// operation, touches no user, volume or process, and its only evidence is its own tests.
public enum ZoneState: String, CaseIterable, Codable, Sendable {
    case created
    case starting
    case running
    case paused
    case stopping
    case stopped
    case cleaning
    case cleaned

    /// States in which a zone identity (UID/GID) must already be bound.
    public var requiresIdentity: Bool {
        [.starting, .running, .paused, .stopping, .stopped, .cleaning].contains(self)
    }
}

public enum ZoneEvent: String, CaseIterable, Sendable {
    case start
    case launched
    case pause
    case resume
    case stop
    case quiesced
    case cleanup
    case cleaned
}

public struct ZoneTransition: Equatable, Sendable {
    public let from: ZoneState
    public let event: ZoneEvent
    public let to: ZoneState

    public init(from: ZoneState, event: ZoneEvent, to: ZoneState) {
        self.from = from
        self.event = event
        self.to = to
    }
}

/// A (state, event) pair the machine must refuse.
public struct ForbiddenTransition: Equatable, Sendable {
    public let from: ZoneState
    public let event: ZoneEvent

    public init(from: ZoneState, event: ZoneEvent) {
        self.from = from
        self.event = event
    }
}

/// A point at which the controlling component may die. Each event names the points that can be
/// observed between "event recorded" and "effect durable".
public enum ZoneCrashPoint: String, CaseIterable, Sendable {
    case beforeIdentityCommit
    case afterIdentityCommit
    case beforeProtectionsArmed
    case afterProtectionsArmed
    case duringPause
    case beforeQuiescence
    case afterQuiescence
    case duringCleanup
    case afterCleanupCommit
}

/// What recovery must do after a crash. Only `identityReusable` may hand the UID out again
/// (LC-11); only it and `refuseAndRollbackToCreated` may lead to a start (LC-06).
public enum ZoneRecoveryAction: String, CaseIterable, Sendable {
    case refuseAndRollbackToCreated
    case denyStartUntilCleanup
    case denyStartAndRequireReview
    case resumeCleanup
    case identityReusable

    public var permitsStart: Bool {
        switch self {
        case .refuseAndRollbackToCreated, .identityReusable: true
        case .denyStartUntilCleanup, .denyStartAndRequireReview, .resumeCleanup: false
        }
    }

    public var permitsUIDReuse: Bool {
        self == .identityReusable
    }
}

public extension ZoneEvent {
    /// Crash points observable while this event is in flight.
    var crashPoints: [ZoneCrashPoint] {
        switch self {
        case .start: [.beforeIdentityCommit, .afterIdentityCommit]
        case .launched: [.beforeProtectionsArmed, .afterProtectionsArmed]
        case .pause: [.duringPause]
        case .resume: []
        case .stop, .quiesced: [.beforeQuiescence, .afterQuiescence]
        case .cleanup: [.duringCleanup]
        case .cleaned: [.afterCleanupCommit]
        }
    }
}

public extension ZoneCrashPoint {
    var recoveryAction: ZoneRecoveryAction {
        switch self {
        case .beforeIdentityCommit: .refuseAndRollbackToCreated
        case .afterIdentityCommit, .beforeProtectionsArmed, .beforeQuiescence, .afterQuiescence: .denyStartUntilCleanup
        case .afterProtectionsArmed, .duringPause: .denyStartAndRequireReview
        case .duringCleanup: .resumeCleanup
        case .afterCleanupCommit: .identityReusable
        }
    }
}

/// Zone lifecycle state machine with the explicit allowed/forbidden transition table.
public struct ZoneStateMachine: Equatable, Sendable {
    /// The complete allowed transition list; every (state, event) pair not named here is forbidden.
    public static let allowedTransitions: [ZoneTransition] = [
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

    /// Every (state, event) pair without an entry in `allowedTransitions`, in declaration order.
    public static var forbiddenTransitions: [ForbiddenTransition] {
        var result: [ForbiddenTransition] = []
        for state in ZoneState.allCases {
            for event in ZoneEvent.allCases where target(from: state, on: event) == nil {
                result.append(ForbiddenTransition(from: state, event: event))
            }
        }
        return result
    }

    public static func target(from state: ZoneState, on event: ZoneEvent) -> ZoneState? {
        allowedTransitions.first { $0.from == state && $0.event == event }?.to
    }

    public let zoneID: String
    public private(set) var state: ZoneState
    public private(set) var uid: UInt32?
    public private(set) var gid: UInt32?

    public init(zoneID: String) throws {
        guard Identifier.isValidZoneID(zoneID) else { throw ContractError.invalidIdentifier("zoneID") }
        self.zoneID = zoneID
        self.state = .created
        self.uid = nil
        self.gid = nil
    }

    public var uidAvailableForReuse: Bool {
        state == .cleaned && uid == nil
    }

    public func canApply(_ event: ZoneEvent) -> Bool {
        Self.target(from: state, on: event) != nil
    }

    /// Binds the design identity. Allowed exactly once, and only before the first start: a UID that
    /// a previous zone used must not be handed out before that zone finished cleanup (LC-11).
    public mutating func assignIdentity(uid: UInt32, gid: UInt32) throws {
        guard uid >= CreateZoneRequest.minUID, gid >= CreateZoneRequest.minUID else {
            throw ContractError.invalidRange("uid/gid below \(CreateZoneRequest.minUID)")
        }
        if state == .created {
            guard self.uid == nil else { throw ContractError("uid-already-assigned", "zone \(zoneID)") }
            self.uid = uid
            self.gid = gid
            return
        }
        switch state {
        case .stopped, .cleaning:
            throw ContractError("uid-reuse-before-cleanup", "zone \(zoneID) is \(state.rawValue)")
        default:
            throw ContractError("state-invariant", "cannot bind identity in \(state.rawValue)")
        }
    }

    public mutating func apply(_ event: ZoneEvent) throws {
        guard let target = Self.target(from: state, on: event) else {
            throw ContractError("forbidden-transition", "\(state.rawValue) --\(event.rawValue)-->")
        }
        switch event {
        case .start:
            // A start without a bound identity would arm protections for a UID that is not the
            // zone's; the contract refuses it instead of inventing one.
            guard uid != nil else { throw ContractError("state-invariant", "start without identity") }
        case .cleaned:
            // Release happens only here, at the end of cleanup, never on `stop`.
            guard state == .cleaning else { throw ContractError("state-invariant", "release before cleanup") }
            uid = nil
            gid = nil
        default:
            break
        }
        state = target
        try assertInvariants()
    }

    /// Invariants checked after every transition and available to callers/tests directly.
    public func assertInvariants() throws {
        if state.requiresIdentity, uid == nil {
            throw ContractError("state-invariant", "\(state.rawValue) requires a bound identity")
        }
        if state == .cleaned, uid != nil {
            throw ContractError("state-invariant", "cleaned zone still holds an identity")
        }
        if state == .created, uid != nil, gid == nil {
            throw ContractError("state-invariant", "identity without gid")
        }
    }
}
