import Foundation

/// Append-only recovery protocol. Incomplete or corrupt records never authorize start.
/// Durable completion checkpoints can resume. An intent without completion is deliberately ambiguous:
/// do not guess ownership from matching bytes and do not overwrite a possible later legitimate change.
final class RecoveryCoordinator {
    let store: RecoveryStore
    let backend: any RecoveryBackend
    var hook: (String) throws -> Void = { _ in }

    init(store: RecoveryStore, backend: any RecoveryBackend) { self.store = store; self.backend = backend }

    var steps: [RecoveryStep] {
        let volumes = backend.volumeIDs
        var result: [RecoveryStep] = [.init(phase: "begun")]
        for volume in volumes {
            result += [.init(phase: "snapshot-intent", volume: volume), .init(phase: "snapshot-done", volume: volume)]
        }
        result += [.init(phase: "snapshot-ready"), .init(phase: "restore-begun")]
        for phase in ["prepare", "switch"] {
            for volume in volumes {
                result += [.init(phase: phase + "-intent", volume: volume), .init(phase: phase + "-done", volume: volume)]
            }
        }
        result.append(.init(phase: "verified"))
        return result
    }
    private func eventName(_ index: Int) -> String { String(format: "%03d.json", index) }

    func events() throws -> [RecoveryEvent] {
        try store.verify()
        guard backend.volumeIDs == store.manifest.rollback.volumeIDs.sorted(), Set(backend.volumeIDs).count == backend.volumeIDs.count,
              (1...16).contains(backend.volumeIDs.count) else { throw RecoveryFailure("backend volume set differs from complete restore unit") }
        let stateNames = try store.names(area: "state")
        let allowedState = Set(backend.volumeIDs.flatMap { volume in
            ["live", "changed", "snapshot", "restored", "slot", "next", "next-workload"].map { "\($0)-\(volume).json" }
        })
        guard stateNames.isSubset(of: allowedState) else { throw RecoveryFailure("unexpected synthetic state entry") }
        let fixed: Set<String> = ["lock", "identity.json", "manifest.json", "policy.json"]
        let names = try store.names(area: "control")
        guard fixed.isSubset(of: names) else { throw RecoveryFailure("host control record missing") }
        let count = names.count - fixed.count
        guard count <= steps.count, names == fixed.union((0..<count).map(eventName)) else { throw RecoveryFailure("journal gaps, extra records, or excessive phases") }
        var result: [RecoveryEvent] = [], previous = store.identity.manifest.digest
        for index in 0..<count {
            let pair = try store.read(area: "control", name: eventName(index))
            let event = try recoveryDecode(RecoveryEvent.self, pair.0)
            guard event.schema == "sanjbox.mock-recovery.event.v1", event.sequence == index,
                  event.transaction == store.identity.transaction, event.manifestDigest == store.identity.manifest.digest,
                  event.previousDigest == previous, RecoveryStep(phase: event.phase, volume: event.volume) == steps[index] else { throw RecoveryFailure("journal chain, identity, or transition mismatch") }
            try validateShape(event)
            previous = pair.1.digest
            result.append(event)
        }
        if result.last?.phase == "verified", stateNames.contains(where: { $0.hasPrefix("next-") }) {
            throw RecoveryFailure("orphan prepared selector after completion")
        }
        return result
    }
    private func validateShape(_ event: RecoveryEvent) throws {
        let expectedCount: Int
        switch event.phase {
        case "begun", "restore-begun": expectedCount = backend.volumeIDs.count
        case "snapshot-done", "switch-done": expectedCount = 1
        case "prepare-done": expectedCount = 2
        default: expectedCount = 0
        }
        guard event.receipts.count == expectedCount, Set(event.receipts.map(\.name)).count == event.receipts.count,
              event.receipts.allSatisfy({ $0.area == "state" }) else { throw RecoveryFailure("journal receipt shape mismatch") }
        let names: [String]
        switch event.phase {
        case "begun", "restore-begun": names = backend.volumeIDs.map { "slot-\($0).json" }
        case "snapshot-done": names = ["snapshot-\(event.volume!).json"]
        case "prepare-done": names = ["restored-\(event.volume!).json", "next-\(event.volume!).json"]
        case "switch-done": names = ["slot-\(event.volume!).json"]
        default: names = []
        }
        guard event.receipts.map(\.name) == names else { throw RecoveryFailure("receipt filename does not match phase") }
    }

    private func append(_ step: RecoveryStep, receipts: [RecoveryReceipt] = []) throws {
        let prior = try events()
        guard prior.count < steps.count, steps[prior.count] == step else { throw RecoveryFailure("invalid next recovery step") }
        let previous = prior.isEmpty ? store.identity.manifest.digest : try store.read(area: "control", name: eventName(prior.count - 1)).1.digest
        let event = RecoveryEvent(sequence: prior.count, transaction: store.identity.transaction, manifestDigest: store.identity.manifest.digest,
                                  previousDigest: previous, phase: step.phase, volume: step.volume, receipts: receipts)
        try validateShape(event)
        _ = try store.write(event, area: "control", name: eventName(prior.count))
        try hook("after-" + step.phase + (step.volume.map { ":" + $0 } ?? ""))
    }

    private func find(_ phase: String, _ volume: String? = nil, in events: [RecoveryEvent]) throws -> RecoveryEvent {
        guard let value = events.first(where: { $0.phase == phase && $0.volume == volume }) else { throw RecoveryFailure("required checkpoint missing") }
        return value
    }

    /// Revalidates all durable artifacts and every selected volume, including volumes already switched.
    /// Preparations must be complete before the first switch. Host policy is checked by every store read.
    private func verifyCheckpoint(_ events: [RecoveryEvent]) throws {
        if events.isEmpty { return }
        if events.last!.phase.hasSuffix("-intent") { throw RecoveryFailure("ambiguous pending mutation; preserve journal and deny start for manual review") }
        let restoring = events.contains { $0.phase == "restore-begun" }
        let switched = Set(events.filter { $0.phase == "switch-done" }.compactMap(\.volume))
        for event in events where event.phase == "snapshot-done" { try backend.validate(event.receipts) }
        for event in events where event.phase == "prepare-done" {
            try backend.validate(switched.contains(event.volume!) ? [event.receipts[0]] : event.receipts)
        }
        // Snapshot-ready is the one point at which later workload changes are allowed, before rollback captures them.
        if events.last!.phase == "snapshot-ready" { return }
        let original = try find(restoring ? "restore-begun" : "begun", in: events).receipts
        let current = try backend.currentBindings()
        for (index, volume) in backend.volumeIDs.enumerated() {
            let expected = switched.contains(volume) ? try find("switch-done", volume, in: events).receipts[0] : original[index]
            guard current[index] == expected else { throw RecoveryFailure("later binding change or mixed unexpected state; refuse overwrite") }
            if switched.contains(volume) {
                try backend.verifyRestored(volume, snapshot: find("snapshot-done", volume, in: events).receipts[0],
                                           prepared: find("prepare-done", volume, in: events).receipts, binding: expected)
            }
        }
    }

    func inspect() -> RecoveryInspection {
        do {
            let records = try events()
            try verifyCheckpoint(records)
            let complete = records.last?.phase == "verified"
            if complete { _ = try backend.acquireQuiescence(restoring: true) }
            return .init(phase: records.last?.phase ?? "uninitialized", records: records.count, mockStartAllowed: complete,
                         reason: complete ? "All mock volumes and host policy reverified; real launch remains unsupported" : "Recovery incomplete; deny start")
        } catch {
            return .init(phase: "denied", records: 0, mockStartAllowed: false, reason: String(describing: error))
        }
    }

    func takeSnapshot() throws {
        var records = try events()
        try verifyCheckpoint(records)
        guard !records.contains(where: { $0.phase == "restore-begun" }) else { throw RecoveryFailure("rollback has already begun") }
        let witness = try backend.acquireQuiescence(restoring: false)
        if records.isEmpty {
            try hook("before-begun")
            try backend.validateQuiescence(witness, restoring: false)
            try append(.init(phase: "begun"), receipts: backend.currentBindings())
        }
        records = try events()
        while !records.contains(where: { $0.phase == "snapshot-ready" }) {
            try verifyCheckpoint(records)
            try backend.validateQuiescence(witness, restoring: false)
            let step = steps[records.count]
            if step.phase == "snapshot-ready" {
                try append(step)
            } else {
                let volume = step.volume!, index = backend.volumeIDs.firstIndex(of: volume)!
                let source = try find("begun", in: records).receipts[index]
                try append(step)
                try hook("before-snapshot-mutation:" + volume)
                try backend.validateQuiescence(witness, restoring: false)
                try backend.validate(try find("begun", in: records).receipts)
                let snapshot = try backend.snapshot(volume, source: source)
                try hook("after-snapshot-mutation:" + volume)
                try backend.validateQuiescence(witness, restoring: false)
                try append(.init(phase: "snapshot-done", volume: volume), receipts: [snapshot])
            }
            records = try events()
        }
    }

    func rollback() throws {
        var records = try events()
        try verifyCheckpoint(records)
        guard records.contains(where: { $0.phase == "snapshot-ready" }) else { throw RecoveryFailure("complete snapshot set required") }
        let witness = try backend.acquireQuiescence(restoring: true)
        if records.last?.phase == "verified" { return }
        if records.last?.phase == "snapshot-ready" {
            try hook("before-restore-begun")
            try backend.validateQuiescence(witness, restoring: true)
            try append(.init(phase: "restore-begun"), receipts: backend.currentBindings())
            records = try events()
        }
        while records.last?.phase != "verified" {
            try verifyCheckpoint(records)
            try backend.validateQuiescence(witness, restoring: true)
            let step = steps[records.count]
            if step.phase == "verified" {
                try hook("before-verified")
                try verifyCheckpoint(records)
                try backend.validateQuiescence(witness, restoring: true)
                try append(step)
            } else {
                let volume = step.volume!
                try append(step)
                try hook("before-" + step.phase.replacingOccurrences(of: "-intent", with: "-mutation") + ":" + volume)
                try backend.validateQuiescence(witness, restoring: true)
                // Validate the last completed checkpoint again after the fault/race hook, before mutation.
                try verifyCheckpoint(records)
                let receipts: [RecoveryReceipt]
                if step.phase == "prepare-intent" {
                    receipts = try backend.prepare(volume, snapshot: find("snapshot-done", volume, in: records).receipts[0])
                } else {
                    let index = backend.volumeIDs.firstIndex(of: volume)!
                    let before = try find("restore-begun", in: records).receipts[index]
                    receipts = [try backend.switchBinding(volume, before: before, prepared: find("prepare-done", volume, in: records).receipts)]
                }
                try hook("after-" + step.phase.replacingOccurrences(of: "-intent", with: "-mutation") + ":" + volume)
                try backend.validateQuiescence(witness, restoring: true)
                try append(.init(phase: step.phase.replacingOccurrences(of: "-intent", with: "-done"), volume: volume), receipts: receipts)
            }
            records = try events()
        }
        guard inspect().mockStartAllowed else { throw RecoveryFailure("post-completion verification failed; deny start") }
    }
}
