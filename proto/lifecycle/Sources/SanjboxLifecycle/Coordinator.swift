import Foundation
import SanjboxContracts

/// Serializes all mock operations under the store's exclusive lock. Every decision replays the
/// durable global ledger; no per-zone cache can bypass a different zone's UID reservation.
public final class LifecycleCoordinator {
    let store: LifecycleStore
    let backend: any MockLifecycleBackend
    private var locallyBegun = Set<String>()
    private var validatedManifests = Set<Data>()
    private var replayCache: ([JournalEntry], [String: ZoneRecord], [String: MockZoneSnapshot])?
    public var hook: (String) throws -> Void = { _ in }
    public var timestamp: () -> String = { "2026-11-13T00:00:00.000Z" }
    public init(store: LifecycleStore, backend: (any MockLifecycleBackend)? = nil) {
        self.store = store; self.backend = backend ?? FileBackedMock(store: store)
    }

    func records() throws -> [String: ZoneRecord] { try replay(store.entries()).0 }
    private func replay(_ entries: [JournalEntry]) throws -> ([String: ZoneRecord], [String: MockZoneSnapshot]) {
        if let cache = replayCache, cache.0 == entries { return (cache.1, cache.2) }
        var records: [String: ZoneRecord] = [:], world: [String: MockZoneSnapshot] = [:]
        for entry in entries {
            guard Identifier.isValidZoneID(entry.zoneID) else { throw LifecycleFailure("invalid journal zone") }
            if entry.kind == "register" {
                guard records[entry.zoneID] == nil, records.count < 64, entry.operation == nil, entry.step == nil,
                      let manifest = entry.manifest, manifest.zone.id == entry.zoneID else { throw LifecycleFailure("invalid registration") }
                let manifestBytes = try canonical(manifest)
                if !validatedManifests.contains(manifestBytes) {
                    _ = try StateManifestSchema.encode(manifest)
                    validatedManifests.insert(manifestBytes)
                }
                guard manifest.zone.uid >= CreateZoneRequest.minUID, manifest.zone.gid >= CreateZoneRequest.minUID else { throw LifecycleFailure("identity below H1 minimum") }
                let machine = try ZoneStateMachine(zoneID: entry.zoneID)
                var record = ZoneRecord(manifest: manifest, machine: machine, audit: [])
                try checkAudit(entry.audit, action: .zoneCreated, outcome: .allowed, record: &record)
                records[entry.zoneID] = record
                continue
            }
            guard var record = records[entry.zoneID], entry.manifest == nil, let operation = entry.operation else { throw LifecycleFailure("unknown zone or missing operation") }
            switch entry.kind {
            case "begin":
                let stoppingStart = operation == .stop && record.machine.state == .starting && record.progress?.operation == .start && record.progress?.pending == false
                guard entry.step == nil, entry.audit == nil, record.progress == nil || stoppingStart else { throw LifecycleFailure("overlapping operation") }
                if operation == .start {
                    guard !records.values.contains(where: { $0.machine.uid == record.manifest.zone.uid }) else { throw LifecycleFailure("UID reserved by another lifecycle") }
                    try record.machine.assignIdentity(uid: record.manifest.zone.uid, gid: record.manifest.zone.gid)
                }
                if let event = operation.beginEvent { try record.machine.apply(event) }
                else { guard record.machine.canApply(operation.finishEvent) else { throw LifecycleFailure("forbidden operation") } }
                record.progress = Progress(operation: operation)
            case "intent", "done", "retry":
                guard var progress = record.progress, progress.operation == operation, progress.completed < operation.steps.count,
                      entry.step == operation.steps[progress.completed] else { throw LifecycleFailure("out-of-order lifecycle step") }
                if entry.kind == "intent" {
                    guard !progress.pending, entry.audit == nil else { throw LifecycleFailure("duplicate intent") }
                    progress.pending = true
                } else {
                    guard progress.pending else { throw LifecycleFailure("completion without intent") }
                    if entry.kind == "done" {
                        guard entry.audit == nil else { throw LifecycleFailure("unexpected step audit") }
                        var snapshot = world[entry.zoneID] ?? MockZoneSnapshot(uid: record.manifest.zone.uid)
                        try snapshot.apply(operation.steps[progress.completed], manifest: record.manifest)
                        world[entry.zoneID] = snapshot
                        progress.completed += 1
                    } else { try checkAudit(entry.audit, action: operation.action, outcome: .failed, record: &record) }
                    progress.pending = false
                }
                record.progress = progress
            case "finish":
                guard let progress = record.progress, progress.operation == operation, !progress.pending,
                      progress.completed == operation.steps.count, entry.step == nil else { throw LifecycleFailure("premature finish or identity release") }
                try record.machine.apply(operation.finishEvent)
                try checkAudit(entry.audit, action: operation.action, outcome: .allowed, record: &record)
                record.progress = nil
            default: throw LifecycleFailure("unknown event kind")
            }
            try record.machine.assertInvariants()
            records[entry.zoneID] = record
        }
        replayCache = (entries, records, world)
        return (records, world)
    }
    private func checkAudit(_ audit: AuditRecord?, action: AuditAction, outcome: AuditOutcome, record: inout ZoneRecord) throws {
        guard let audit, audit.action == action, audit.outcome == outcome, audit.actorUID == 0,
              audit.zoneID == record.manifest.zone.id, audit.subjectID == nil,
              audit.detail == "synthetic lifecycle mock" else { throw LifecycleFailure("audit/event mismatch") }
        record.audit.append(audit)
        try AuditLog.validate(record.audit)
    }
    func checkpoint() throws -> [String: ZoneRecord] {
        let (records, world) = try replay(store.entries())
        guard !records.values.contains(where: { $0.progress?.pending == true }) else { throw LifecycleFailure("ambiguous pending intent; manual review required") }
        try backend.validate(expected: world)
        return records
    }
    private func append(zone: String, kind: String, operation: LifecycleOperation? = nil, step: MockStep? = nil,
                        manifest: StateManifestDocument? = nil, action: AuditAction? = nil, outcome: AuditOutcome = .allowed) throws {
        let entries = try store.entries()
        let records = try replay(entries).0
        let audit = action.map { AuditRecord(sequence: UInt64((records[zone]?.audit.count ?? 0) + 1), timestampUTC: timestamp(),
                                            zoneID: zone, actorUID: 0, action: $0, outcome: outcome, detail: "synthetic lifecycle mock") }
        let previous = try entries.last.map { digest(try canonical($0)) } ?? "genesis"
        let event = JournalEntry(sequence: entries.count, previous: previous,
                                 zoneID: zone, kind: kind, operation: operation, step: step, manifest: manifest, audit: audit)
        _ = try replay(entries + [event]) // Validate the candidate before any write, including typed inputs.
        try store.append(event)
    }
    public func register(manifest data: Data) throws {
        let manifest = try StateManifestSchema.decode(data)
        let records = try checkpoint()
        if let existing = records[manifest.zone.id] {
            guard existing.manifest == manifest else { throw LifecycleFailure("zone manifest conflict") }
            return
        }
        try append(zone: manifest.zone.id, kind: "register", manifest: manifest, action: .zoneCreated)
    }
    public func manifestReport(zone: String) throws -> ManifestValidationReport {
        guard let record = try records()[zone] else { throw LifecycleFailure("unknown zone") }
        return StateManifestSchema.report(record.manifest)
    }
    public func audit(zone: String) throws -> Data {
        guard let record = try records()[zone] else { throw LifecycleFailure("unknown zone") }
        return try AuditLog.encode(record.audit)
    }
    public func inspect(zone: String) throws -> LifecycleInspection {
        let all = try records()
        guard let record = all[zone] else { throw LifecycleFailure("unknown zone") }
        let pending = all.values.contains { $0.progress?.pending == true }
        let recoveryReview = record.progress.map { progress in
            !locallyBegun.contains(zone) && (progress.operation == .pause || progress.operation == .resume ||
                (progress.operation == .start && progress.completed >= 3))
        } ?? false
        var valid = !pending && !recoveryReview
        if valid { do { _ = try checkpoint() } catch { valid = false } }
        return .init(state: record.machine.state, reservedUID: record.machine.uid, operation: record.progress?.operation,
                     completedSteps: record.progress?.completed ?? 0, requiresReview: !valid,
                     mockAdmissionAllowed: valid && record.machine.state == .running && record.progress == nil,
                     uidReusable: valid && record.machine.uidAvailableForReuse)
    }
    /// Denial on any corruption, missing data, pause, stop, pending operation or backend drift.
    /// Represents all synthetic login/job/fork paths; it is not a transferable launch capability.
    public func mockAdmissionAllowed(zone: String) -> Bool { (try? inspect(zone: zone).mockAdmissionAllowed) ?? false }

    public func execute(_ operation: LifecycleOperation, zone: String) throws {
        let all = try checkpoint()
        guard var record = all[zone] else { throw LifecycleFailure("unknown zone") }
        let stoppingStart = operation == .stop && record.machine.state == .starting && record.progress?.operation == .start
        if let active = record.progress, !stoppingStart {
            guard active.operation == operation else { throw LifecycleFailure("another operation is incomplete") }
            if [.start, .pause, .resume].contains(operation), !locallyBegun.contains(zone) {
                throw LifecycleFailure("interrupted admission operation cannot resume; use conservative recovery")
            }
        } else {
            // Idempotence only for completed pause/stop/cleanup; start/resume must not silently
            // reinterpret a forbidden H1 transition as success.
            if (operation == .pause && record.machine.state == .paused) ||
                (operation == .stop && record.machine.state == .stopped) ||
                (operation == .cleanup && record.machine.state == .cleaned) { return }
            let event = operation.beginEvent ?? operation.finishEvent
            guard record.machine.canApply(event) else { throw LifecycleFailure("forbidden lifecycle transition") }
            if operation == .start, all.values.contains(where: { $0.machine.uid == record.manifest.zone.uid }) {
                throw LifecycleFailure("UID remains reserved until completed cleanup")
            }
            try hook("beforeBegin")
            try append(zone: zone, kind: "begin", operation: operation)
            locallyBegun.insert(zone)
            try hook("afterBegin")
            record = try checkpoint()[zone]!
        }
        while let progress = record.progress, progress.completed < operation.steps.count {
            let step = operation.steps[progress.completed]
            try hook("beforeIntent:\(step.rawValue)")
            _ = try checkpoint()
            try append(zone: zone, kind: "intent", operation: operation, step: step)
            try hook("afterIntent:\(step.rawValue)")
            // Recheck after the fault/race seam; never overwrite a later synthetic owner change.
            try backend.validate(expected: replay(store.entries()).1)
            do { try backend.perform(step, manifest: record.manifest) }
            catch is MockNoEffectFailure {
                // The mock promises no mutation. Verify that promise before clearing the intent.
                let expected = try replay(store.entries()).1
                try backend.validate(expected: expected)
                try append(zone: zone, kind: "retry", operation: operation, step: step, action: operation.action, outcome: .failed)
                throw MockNoEffectFailure()
            }
            try hook("afterEffect:\(step.rawValue)")
            try append(zone: zone, kind: "done", operation: operation, step: step)
            try hook("afterDone:\(step.rawValue)")
            record = try checkpoint()[zone]!
        }
        try hook("beforeFinish")
        _ = try checkpoint()
        try append(zone: zone, kind: "finish", operation: operation, action: operation.action)
        try hook("afterFinish")
        _ = try checkpoint()
    }
    /// Continue only a completed durable checkpoint. An intent without completion is quarantined.
    public func recover(zone: String) throws {
        guard let record = try checkpoint()[zone] else { throw LifecycleFailure("unknown zone") }
        if let progress = record.progress {
            switch progress.operation {
            case .start:
                guard progress.completed < 3 else { throw LifecycleFailure("H1 afterProtectionsArmed requires review") }
                try execute(.stop, zone: zone) // H1 afterIdentityCommit: drain, retain UID until cleanup.
            case .pause, .resume:
                throw LifecycleFailure("interrupted pause/resume requires review")
            case .stop, .cleanup: try execute(progress.operation, zone: zone)
            }
        }
    }
}
