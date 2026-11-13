import Foundation
import SanjboxContracts

public struct LifecycleFailure: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum LifecycleOperation: String, Codable, CaseIterable, Sendable {
    case start, pause, resume, stop, cleanup
    public var steps: [MockStep] {
        switch self {
        case .start: [.createUser, .createVolumes, .armProtections, .bootstrap, .verifyRunning]
        case .pause: [.blockAdmission, .revokeNetworkIPC, .quiesceUID, .verifyPaused]
        case .resume: [.armProtections, .resumeUID, .verifyRunning]
        case .stop: [.blockAdmission, .revokeNetworkIPC, .bootoutDomains, .removeJobs,
                     .terminateUID, .verifyZeroProcesses, .verifyRestartDenied]
        case .cleanup: [.verifyZeroProcesses, .verifyRestartDenied, .removeVolumes, .removeUser, .verifyCleanup]
        }
    }
    var beginEvent: ZoneEvent? {
        switch self { case .start: .start; case .stop: .stop; case .cleanup: .cleanup; default: nil }
    }
    var finishEvent: ZoneEvent {
        switch self { case .start: .launched; case .pause: .pause; case .resume: .resume; case .stop: .quiesced; case .cleanup: .cleaned }
    }
    var action: AuditAction {
        switch self { case .start: .zoneStarted; case .pause: .zonePaused; case .resume: .zoneResumed; case .stop: .zoneStopped; case .cleanup: .zoneCleaned }
    }
    public var crashHooks: [String] {
        ["beforeBegin", "afterBegin"] + steps.flatMap { step in
            ["beforeIntent", "afterIntent", "afterEffect", "afterDone"].map { "\($0):\(step.rawValue)" }
        } + ["beforeFinish", "afterFinish"]
    }
}

public enum MockStep: String, Codable, CaseIterable, Sendable {
    case createUser, createVolumes, armProtections, bootstrap, verifyRunning
    case blockAdmission, revokeNetworkIPC, quiesceUID, verifyPaused, resumeUID
    case bootoutDomains, removeJobs, terminateUID, verifyZeroProcesses, verifyRestartDenied
    case removeVolumes, removeUser, verifyCleanup
}

struct JournalEntry: Codable, Equatable {
    var schema = "sanjbox.mock-lifecycle.event.v1"
    var sequence: Int
    var previous: String
    var zoneID: String
    var kind: String
    var operation: LifecycleOperation?
    var step: MockStep?
    var manifest: StateManifestDocument?
    var audit: AuditRecord?
}

struct Progress: Equatable {
    var operation: LifecycleOperation
    var completed: Int = 0
    var pending = false
}

struct ZoneRecord {
    var manifest: StateManifestDocument
    var machine: ZoneStateMachine
    var progress: Progress?
    var audit: [AuditRecord]
}

public struct LifecycleInspection: Sendable {
    public let state: ZoneState
    public let reservedUID: UInt32?
    public let operation: LifecycleOperation?
    public let completedSteps: Int
    public let requiresReview: Bool
    public let mockAdmissionAllowed: Bool
    public let uidReusable: Bool
    public let realStartAllowed = false
    public let acceptanceStatus = "Neověřeno"
}

/// All physical operations are an explicitly synthetic interface. There is no native adapter.
/// A production implementation needs a host-owned, crash-persistent admission interlock and
/// evidence of whole-UID quiescence; this protocol does not supply either.
public protocol MockLifecycleBackend: AnyObject {
    func perform(_ step: MockStep, manifest: StateManifestDocument) throws
    func validate(expected: [String: MockZoneSnapshot]) throws
}

/// Only this error promises that no effect occurred. Every other error leaves a pending intent.
public struct MockNoEffectFailure: Error {
    public init() {}
}
