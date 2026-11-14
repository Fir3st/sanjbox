import Foundation
import SanjboxContracts

/// Synthetic adapter output, never deserializable from a message. A native adapter must obtain
/// all fields from the connection audit token and dynamic code/session checks. These values
/// carry NO actual authorization, kernel identity, signature proof or admin approval.
public struct SyntheticServicePeer: Equatable, Sendable {
    public enum Role: Sendable { case hostController, area }
    public var role: Role
    public var uid: UInt32
    public var auditUID: UInt32
    public var auditSession: Int32
    public var processID: Int32
    public var processVersion: UInt64
    public var codeHash: String
    public var signatureMatches: Bool
    public init(role: Role, uid: UInt32, auditUID: UInt32, auditSession: Int32,
                processID: Int32, processVersion: UInt64, codeHash: String, signatureMatches: Bool) {
        self.role = role; self.uid = uid; self.auditUID = auditUID; self.auditSession = auditSession
        self.processID = processID; self.processVersion = processVersion
        self.codeHash = codeHash; self.signatureMatches = signatureMatches
    }
}

/// Pure daemon seam. Only records simulated effects; deliberately not wired to ServiceManagement
/// or S8LaunchDaemon. An approval is bound to one host process generation and one operation.
public struct SyntheticDaemonBoundary {
    private struct Approval {
        let peer: SyntheticServicePeer
        let action: FixtureAction
    }
    private let trustedHost: SyntheticServicePeer
    private var approvals: [UUID: Approval] = [:]
    private var revoked = false
    public private(set) var simulatedEffects = 0

    public init(trustedHost: SyntheticServicePeer) throws {
        guard trustedHost.role == .hostController, trustedHost.uid >= 501,
              trustedHost.auditUID == trustedHost.uid, trustedHost.auditSession > 0,
              trustedHost.processID > 0, trustedHost.processVersion > 0,
              trustedHost.signatureMatches, trustedHost.codeHash.count == 64,
              trustedHost.codeHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw S8Error.refused("invalid synthetic host baseline")
        }
        self.trustedHost = trustedHost
    }

    private func authorize(_ peer: SyntheticServicePeer) throws {
        guard !revoked, peer == trustedHost else { throw S8Error.refused("synthetic host binding mismatch/revoked") }
    }

    /// Called by the mock trusted approval authority, never by a wire request/UI flag.
    public mutating func approveForSimulation(_ action: FixtureAction, host: SyntheticServicePeer) throws -> UUID {
        try authorize(host)
        guard action != .status, approvals.count < 32 else { throw S8Error.refused("invalid approval or capacity") }
        let id = UUID(); approvals[id] = .init(peer: host, action: action); return id
    }

    public mutating func simulateDaemonMutation(_ action: FixtureAction, peer: SyntheticServicePeer, approvalID: UUID) throws {
        try authorize(peer)
        // Consume before comparing the action. A mistaken use never leaves a reusable capability.
        guard let approval = approvals.removeValue(forKey: approvalID), approval.peer == peer,
              approval.action == action, action != .status else { throw S8Error.refused("missing, replayed or mismatched approval") }
        simulatedEffects += 1
    }

    /// H1 itself does not authorize a peer. This seam checks host identity before decoding and
    /// never turns a valid request into a process, filesystem or service operation.
    public func inspectHelperRequest(_ wire: Data, peer: SyntheticServicePeer) throws -> HelperMessageKind {
        try authorize(peer)
        return try HelperMessage.decode(wire).kind
    }

    public mutating func revoke() { revoked = true; approvals.removeAll() }
}

public struct SyntheticRegistrationBinding: Equatable, Sendable {
    public var runID: UUID
    public var service: FixtureService
    public var ownerUID: UInt32
    public var signedInventorySHA256: String
    public init(runID: UUID, service: FixtureService, ownerUID: UInt32, signedInventorySHA256: String) {
        self.runID = runID; self.service = service; self.ownerUID = ownerUID
        self.signedInventorySHA256 = signedInventorySHA256
    }
}

/// A serial dry-run workflow only. A receipt is NOT native ownership proof: SMAppService status
/// does not identify a registration generation. Recovery therefore always requires explicit
/// independent user review, even if all recorded values match. No import/restore from disk and
/// no mutation adapter are provided; native artifact cleanup remains blocked after handoff.
public struct SyntheticRegistrationWorkflow {
    public enum Phase: String, Sendable {
        case pristine, registerIntent, registered, recoveryReview, unregisterIntent, verifyStopped, cleaned, conflict
    }
    public let binding: SyntheticRegistrationBinding
    public private(set) var phase: Phase = .pristine
    public private(set) var observations: [String] = []
    private var registeredStatus: Int?
    private var boot: String?
    private var session: Int32?

    public init(binding: SyntheticRegistrationBinding) throws {
        guard binding.ownerUID >= 501, binding.signedInventorySHA256.count == 64,
              binding.signedInventorySHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw S8Error.refused("invalid synthetic registration binding")
        }
        self.binding = binding
    }

    private mutating func require(_ condition: Bool, _ message: String) throws {
        guard condition else { phase = .conflict; throw S8Error.refused(message) }
    }

    public mutating func beginRegistration(status: Int, boot: String, session: Int32) throws {
        try require(phase == .pristine && status == 0 && !boot.isEmpty && boot.utf8.count <= 64 && session > 0,
                    "registration requires recorded absent baseline")
        self.boot = boot; self.session = session
        observations.append("original status=0; durable intent required before API")
        phase = .registerIntent
    }

    public mutating func registrationResult(succeeded: Bool, status: Int) throws {
        try require(phase == .registerIntent && succeeded && [1, 2].contains(status), "registration incomplete/uncertain")
        registeredStatus = status; phase = .registered
        observations.append("paired successful result; status=\(status)")
    }

    /// Simulates any UI/login/reboot restart. It does not infer a lifecycle cause from metadata.
    public mutating func restart() {
        if phase == .registered { phase = .recoveryReview }
        else if phase != .cleaned { phase = .conflict }
    }

    public mutating func reviewRecovery(current: SyntheticRegistrationBinding, status: Int,
                                        boot: String, session: Int32, userConfirmedExclusiveSlot: Bool) throws {
        try require(phase == .recoveryReview && current == binding && status == registeredStatus &&
                    [1, 2].contains(status) && !boot.isEmpty && boot.utf8.count <= 64 && session > 0 &&
                    userConfirmedExclusiveSlot, "recovery needs exact binding, status and independent user review")
        self.boot = boot; self.session = session; phase = .registered
        observations.append("manual recovery review recorded; same-status foreign change remains unobservable")
    }

    public mutating func beginUnregister(current: SyntheticRegistrationBinding, status: Int,
                                        boot: String, session: Int32) throws {
        try require(phase == .registered && current == binding && status == registeredStatus &&
                    self.boot == boot && self.session == session, "unregister binding/context drift")
        phase = .unregisterIntent
        observations.append("durable unregister intent required before API")
    }

    public mutating func unregisterResult(succeeded: Bool, status: Int) throws {
        try require(phase == .unregisterIntent && succeeded && status == 0, "unregister incomplete/uncertain")
        phase = .verifyStopped
    }

    public mutating func confirmStopped(ownHelpersRemaining: Int, relaunchObserved: Bool?, lifecycleCheckComplete: Bool) throws {
        try require(phase == .verifyStopped && ownHelpersRemaining == 0 && relaunchObserved == false &&
                    lifecycleCheckComplete, "missing independent process/relaunch cleanup oracle")
        phase = .cleaned
        observations.append("synthetic cleanup complete; does not unlock native artifact cleanup")
    }
}

public struct SyntheticServiceWorkflowReport: Encodable, Sendable {
    public let kind = "synthetic-registration-dry-run-no-system-effects"
    public let nativeRegistrationAllowed = false
    public let nativeArtifactCleanupAllowed = false
    public let signingProfile: String
    public let service: String
    public let phases: [String]
    public let observations: [String]
}

public enum SyntheticServiceWorkflows {
    /// Six fixed scenarios and one simulated UI/login/boot change; no filesystem or service API.
    public static func plans() throws -> [SyntheticServiceWorkflowReport] {
        try ["Personal Team (not verified)", "self-signed (conditional, not verified)"].flatMap { profile in
            try FixtureService.allCases.map { service in
                let binding = SyntheticRegistrationBinding(
                    runID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, service: service,
                    ownerUID: 501, signedInventorySHA256: String(repeating: "a", count: 64))
                var workflow = try SyntheticRegistrationWorkflow(binding: binding)
                var phases = [workflow.phase.rawValue]
                try workflow.beginRegistration(status: 0, boot: "synthetic-boot-1", session: 31)
                phases.append(workflow.phase.rawValue)
                try workflow.registrationResult(succeeded: true, status: 1)
                phases.append(workflow.phase.rawValue)
                workflow.restart(); phases.append(workflow.phase.rawValue)
                try workflow.reviewRecovery(current: binding, status: 1, boot: "synthetic-boot-2", session: 41,
                                            userConfirmedExclusiveSlot: true)
                phases.append(workflow.phase.rawValue)
                try workflow.beginUnregister(current: binding, status: 1, boot: "synthetic-boot-2", session: 41)
                phases.append(workflow.phase.rawValue)
                try workflow.unregisterResult(succeeded: true, status: 0)
                phases.append(workflow.phase.rawValue)
                try workflow.confirmStopped(ownHelpersRemaining: 0, relaunchObserved: false, lifecycleCheckComplete: true)
                phases.append(workflow.phase.rawValue)
                return .init(signingProfile: profile, service: service.rawValue, phases: phases, observations: workflow.observations)
            }
        }
    }
}
