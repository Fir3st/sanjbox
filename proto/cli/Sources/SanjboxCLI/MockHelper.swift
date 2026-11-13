import Foundation
import SanjboxContracts

public enum MockPhase: Sendable { case running, paused, stopped }

/// A closed synthetic fixture, never an OS adapter. All mutable state is protected by lock.
public final class MockHelper: @unchecked Sendable {
    static let roots: Set<String> = ["home", "project", "prefix", "tools", "cache", "tmp"]
    private let lock = NSLock()
    private var phase: MockPhase
    private var rootValues: [String: String] = Dictionary(uniqueKeysWithValues: roots.map { ($0, "baseline-\($0)") })
    private var snapshots: [String: [String: String]]
    private var handles: [String: HelperMessage] = [:]
    private var nextHandle = 1
    private var received: [HelperMessage] = []
    // Host control state is intentionally outside the restore unit.
    private var hostPolicy = "deny-default"

    public init(phase: MockPhase = .running) {
        self.phase = phase
        snapshots = ["baseline": Dictionary(uniqueKeysWithValues: Self.roots.map { ($0, "baseline-\($0)") })]
    }

    public func exchange(_ bytes: Data) throws -> Data {
        // Malformed messages never reach mutation, even when a caller bypasses the CLI parser.
        let request = try HelperMessage.decode(bytes)
        lock.lock(); defer { lock.unlock() }
        guard received.count < 128 else { return try failure(request, .unavailable).encoded() }
        received.append(request)
        guard request.zoneID == "a1b2" else { return try failure(request, .unauthorized).encoded() }
        let reply: HelperReply
        switch request {
        case .shell(let body):
            guard Self.roots.contains(body.workingRootID) else { return try failure(request, .invalidRequest).encoded() }
            reply = admit(request)
        case .run(let body):
            guard Self.roots.contains(body.workingRootID), Self.roots.contains(body.executableRootID)
            else { return try failure(request, .invalidRequest).encoded() }
            reply = admit(request)
        case .pauseZone:
            guard phase == .running else { return try failure(request, .invalidState).encoded() }
            phase = .paused
            reply = completed(request)
        case .snapshot(let body):
            guard body.rollbackUnitID == "full-state" else { return try failure(request, .invalidRequest).encoded() }
            guard phase == .paused || phase == .stopped else { return try failure(request, .invalidState).encoded() }
            guard snapshots[body.snapshotID] == nil, snapshots.count < 128 else { return try failure(request, .invalidState).encoded() }
            snapshots[body.snapshotID] = rootValues
            reply = completed(request)
        case .rollback(let body):
            guard body.rollbackUnitID == "full-state", let snapshot = snapshots[body.snapshotID]
            else { return try failure(request, .invalidRequest).encoded() }
            guard phase == .stopped else { return try failure(request, .invalidState).encoded() }
            rootValues = snapshot
            reply = completed(request)
        default: reply = failure(request, .invalidRequest)
        }
        try reply.validate(for: request)
        return try reply.encoded()
    }

    private func admit(_ request: HelperMessage) -> HelperReply {
        guard phase == .running else { return failure(request, .invalidState) }
        let handle = "mock-exec-\(nextHandle)"
        nextHandle += 1
        handles[handle] = request
        return HelperReply(requestKind: request.kind, zoneID: request.zoneID, outcome: .accepted, executionID: handle)
    }
    private func completed(_ request: HelperMessage) -> HelperReply {
        HelperReply(requestKind: request.kind, zoneID: request.zoneID, outcome: .completed)
    }
    private func failure(_ request: HelperMessage, _ code: HelperFailureCode) -> HelperReply {
        HelperReply(requestKind: request.kind, zoneID: request.zoneID, outcome: .failed, errorCode: code)
    }

    // Test observations and synthetic writes are not XPC operations or CLI escape hatches.
    struct Observation {
        let phase: MockPhase
        let rootValues: [String: String]
        let snapshots: [String: [String: String]]
        let handles: [String: HelperMessage]
        let received: [HelperMessage]
        let hostPolicy: String
    }
    func observe() -> Observation {
        lock.lock(); defer { lock.unlock() }
        return Observation(phase: phase, rootValues: rootValues, snapshots: snapshots,
                           handles: handles, received: received, hostPolicy: hostPolicy)
    }
    func mutateFixture() {
        lock.lock(); defer { lock.unlock() }
        for root in Self.roots { rootValues[root] = "changed-\(root)" }
        hostPolicy = "changed-host-policy"
    }
}
