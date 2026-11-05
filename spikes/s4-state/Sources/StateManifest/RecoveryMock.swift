import Foundation

struct MockEntry: Codable, Equatable {
    var path: String
    var value: String
}
struct MockImage: Codable {
    var schema = "sanjbox.mock-image.v1"
    var transaction: String
    var volume: String
    var kind: String
    var sourceDigest: String?
    var entries: [MockEntry]
}
struct MockBinding: Codable {
    var schema = "sanjbox.mock-binding.v1"
    var transaction: String
    var volume: String
    var image: RecoveryReceipt
}

/// This adapter serializes tiny synthetic images as JSON. It is NOT a filesystem snapshot, clone,
/// APFS adapter, mount implementation, access boundary, or proof of actual whole-UID quiescence.
final class FileBackedRecoveryMock: RecoveryBackend {
    let store: RecoveryStore
    var volumeIDs: [String] { store.manifest.rollback.volumeIDs.sorted() }
    var wholeUID = true
    var admissionBlocked = true
    var networkBlocked = true
    var fullyOff = true
    var descriptorsClosed = true
    var mappingsClosed = true
    var leaseGeneration = UUID()

    init(store: RecoveryStore) { self.store = store }

    func initialize() throws {
        guard try store.names(area: "state").isEmpty else { throw RecoveryFailure("mock state already initialized") }
        for id in volumeIDs {
            let entries = store.manifest.roots.filter { $0.volumeID == id }.map {
                MockEntry(path: ($0.relativePath == "." ? "" : $0.relativePath + "/") + "synthetic-canary", value: "baseline-" + $0.role)
            }.sorted { $0.path < $1.path }
            let image = MockImage(transaction: store.identity.transaction, volume: id, kind: "live", entries: entries)
            let receipt = try store.write(image, area: "state", name: "live-\(id).json")
            _ = try store.write(MockBinding(transaction: store.identity.transaction, volume: id, image: receipt), area: "state", name: "slot-\(id).json")
        }
    }

    func acquireQuiescence(restoring: Bool) throws -> RecoveryQuiescence {
        let witness = RecoveryQuiescence(zoneUID: store.manifest.zone.uid, generation: leaseGeneration, wholeUID: wholeUID,
                                          admissionBlocked: admissionBlocked, networkBlocked: networkBlocked, fullyOff: fullyOff,
                                          descriptorsClosed: descriptorsClosed, mappingsClosed: mappingsClosed)
        try validateQuiescence(witness, restoring: restoring)
        return witness
    }
    func validateQuiescence(_ witness: RecoveryQuiescence, restoring: Bool) throws {
        try store.verify()
        guard witness.zoneUID == store.manifest.zone.uid, witness.generation == leaseGeneration,
              witness.wholeUID && wholeUID, witness.admissionBlocked && admissionBlocked,
              witness.networkBlocked && networkBlocked,
              !restoring || (witness.fullyOff && fullyOff && witness.descriptorsClosed && descriptorsClosed && witness.mappingsClosed && mappingsClosed)
        else { throw RecoveryFailure("whole-UID lifecycle interlock absent, stale, or insufficient") }
    }

    func currentBindings() throws -> [RecoveryReceipt] {
        try volumeIDs.map { id in
            let pair = try store.read(area: "state", name: "slot-\(id).json")
            _ = try binding(pair.1, volume: id)
            return pair.1
        }
    }
    func validate(_ receipts: [RecoveryReceipt]) throws {
        for receipt in receipts { _ = try store.read(receipt) }
    }
    func binding(_ receipt: RecoveryReceipt, volume: String) throws -> MockBinding {
        let value = try recoveryDecode(MockBinding.self, store.read(receipt))
        guard receipt.area == "state", value.schema == "sanjbox.mock-binding.v1", value.transaction == store.identity.transaction,
              value.volume == volume, value.image.area == "state", value.image.name != receipt.name else { throw RecoveryFailure("invalid mock binding identity") }
        _ = try image(value.image, volume: volume)
        return value
    }
    func image(_ receipt: RecoveryReceipt, volume: String) throws -> MockImage {
        let value = try recoveryDecode(MockImage.self, store.read(receipt))
        guard receipt.area == "state", value.schema == "sanjbox.mock-image.v1", value.transaction == store.identity.transaction,
              value.volume == volume, ["live", "changed", "snapshot", "restored"].contains(value.kind),
              (1...65).contains(value.entries.count), Set(value.entries.map(\.path)).count == value.entries.count,
              value.entries.allSatisfy({ $0.path.utf8.count <= 1024 && $0.value.utf8.count <= 256 }) else { throw RecoveryFailure("invalid mock image") }
        return value
    }

    func snapshot(_ volume: String, source: RecoveryReceipt) throws -> RecoveryReceipt {
        let binding = try binding(source, volume: volume)
        let original = try image(binding.image, volume: volume)
        let value = MockImage(transaction: store.identity.transaction, volume: volume, kind: "snapshot", sourceDigest: binding.image.digest, entries: original.entries)
        return try store.write(value, area: "state", name: "snapshot-\(volume).json")
    }
    func prepare(_ volume: String, snapshot: RecoveryReceipt) throws -> [RecoveryReceipt] {
        let original = try image(snapshot, volume: volume)
        guard original.kind == "snapshot" else { throw RecoveryFailure("restore source is not a mock snapshot") }
        let restored = MockImage(transaction: store.identity.transaction, volume: volume, kind: "restored", sourceDigest: snapshot.digest, entries: original.entries)
        let receipt = try store.write(restored, area: "state", name: "restored-\(volume).json")
        let selector = try store.write(MockBinding(transaction: store.identity.transaction, volume: volume, image: receipt), area: "state", name: "next-\(volume).json")
        // The restored artifact is a new independently writable JSON object; the snapshot is untouched.
        guard receipt.stamp.inode != snapshot.stamp.inode else { throw RecoveryFailure("restored object aliases snapshot") }
        return [receipt, selector]
    }
    func switchBinding(_ volume: String, before: RecoveryReceipt, prepared: [RecoveryReceipt]) throws -> RecoveryReceipt {
        guard prepared.count == 2, before.name == "slot-\(volume).json", prepared[1].name == "next-\(volume).json",
              try binding(prepared[1], volume: volume).image == prepared[0] else { throw RecoveryFailure("invalid prepared selector") }
        return try store.replaceBinding(before: before, prepared: prepared[1])
    }
    func verifyRestored(_ volume: String, snapshot: RecoveryReceipt, prepared: [RecoveryReceipt], binding selector: RecoveryReceipt) throws {
        guard prepared.count == 2 else { throw RecoveryFailure("incomplete prepared state") }
        let selected = try binding(selector, volume: volume), restored = try image(prepared[0], volume: volume), source = try image(snapshot, volume: volume)
        guard selected.image == prepared[0], restored.kind == "restored", source.kind == "snapshot",
              restored.sourceDigest == snapshot.digest, restored.entries == source.entries,
              selector.stamp.inode == prepared[1].stamp.inode, selector.digest == prepared[1].digest else {
            throw RecoveryFailure("restored mock state differs from selected complete snapshot")
        }
    }

    /// Test workload only: changes every declared role and adds an inert startup/job canary string.
    /// No startup file or job is installed. Call only between snapshot-ready and restore-begun.
    func simulateChanges() throws {
        for id in volumeIDs {
            let current = try store.read(area: "state", name: "slot-\(id).json").1
            let original = try image(binding(current, volume: id).image, volume: id)
            var entries = original.entries.map { MockEntry(path: $0.path, value: "changed-" + $0.value) }
            if let home = store.manifest.roots.first(where: { $0.volumeID == id && $0.role == "home" }) {
                entries.append(.init(path: home.relativePath + "/Library/LaunchAgents/synthetic-job", value: "inert-startup-canary"))
            }
            let changed = try store.write(MockImage(transaction: store.identity.transaction, volume: id, kind: "changed", entries: entries), area: "state", name: "changed-\(id).json")
            let next = try store.write(MockBinding(transaction: store.identity.transaction, volume: id, image: changed), area: "state", name: "next-workload-\(id).json")
            _ = try store.replaceBinding(before: current, prepared: next)
        }
    }
}
