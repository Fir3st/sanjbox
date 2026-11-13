import Foundation
import SanjboxContracts

public struct MockProcess: Codable, Equatable, Sendable {
    public var kind: String
    public var frozen: Bool
}

public struct MockZoneSnapshot: Codable, Equatable, Sendable {
    public var uid: UInt32
    public var user = false
    public var volumes: [String] = []
    public var protections = false
    public var admissionBlocked = true
    public var networkIPCBlocked = true
    public var guiDomain = false
    public var userDomain = false
    public var scheduledJobs = false
    public var processes: [MockProcess] = []

    mutating func apply(_ step: MockStep, manifest: StateManifestDocument) throws {
        guard uid == manifest.zone.uid else { throw LifecycleFailure("backend UID mismatch") }
        func require(_ condition: Bool) throws {
            guard condition else { throw LifecycleFailure("mock precondition: \(step.rawValue)") }
        }
        switch step {
        case .createUser:
            try require(!user && admissionBlocked && processes.isEmpty); user = true
        case .createVolumes:
            try require(user && admissionBlocked); volumes = manifest.rollback.volumeIDs.sorted()
        case .armProtections:
            try require(user && volumes == manifest.rollback.volumeIDs.sorted())
            protections = true; networkIPCBlocked = false
        case .bootstrap:
            try require(user && protections && !networkIPCBlocked && admissionBlocked)
            guiDomain = true; userDomain = true; scheduledJobs = true
            processes = ["gui", "user-job", "cli", "detached", "stopped"].map { .init(kind: $0, frozen: $0 == "stopped") }
            admissionBlocked = false
        case .verifyRunning:
            try require(user && protections && !admissionBlocked && !networkIPCBlocked && guiDomain && userDomain && !processes.isEmpty)
        case .blockAdmission: admissionBlocked = true
        case .revokeNetworkIPC: networkIPCBlocked = true
        case .quiesceUID:
            try require(admissionBlocked && networkIPCBlocked)
            for index in processes.indices { processes[index].frozen = true }
        case .verifyPaused:
            try require(admissionBlocked && networkIPCBlocked && processes.allSatisfy(\.frozen))
        case .resumeUID:
            try require(protections && !networkIPCBlocked && admissionBlocked)
            for index in processes.indices { processes[index].frozen = false }
            admissionBlocked = false
        case .bootoutDomains:
            try require(admissionBlocked && networkIPCBlocked)
            guiDomain = false; userDomain = false
            processes.removeAll { $0.kind == "gui" || $0.kind == "user-job" }
        case .removeJobs:
            try require(admissionBlocked && networkIPCBlocked); scheduledJobs = false
        case .terminateUID:
            try require(admissionBlocked && networkIPCBlocked && !scheduledJobs && !guiDomain && !userDomain)
            processes = []
        case .verifyZeroProcesses:
            try require(admissionBlocked && networkIPCBlocked && processes.isEmpty)
        case .verifyRestartDenied:
            try require(admissionBlocked && networkIPCBlocked && !guiDomain && !userDomain && !scheduledJobs && processes.isEmpty)
        case .removeVolumes:
            try require(admissionBlocked && processes.isEmpty); volumes = []
        case .removeUser:
            try require(admissionBlocked && processes.isEmpty && volumes.isEmpty && !scheduledJobs)
            user = false; protections = false
        case .verifyCleanup:
            try require(!user && volumes.isEmpty && processes.isEmpty && admissionBlocked && networkIPCBlocked && !guiDomain && !userDomain && !scheduledJobs)
        }
    }
}

struct MockWorld: Codable, Equatable {
    var schema = "sanjbox.mock-lifecycle.world.v1"
    var zones: [String: MockZoneSnapshot] = [:]
}

/// Persists only inert JSON. It never resolves a UID, reads a manifest path, launches a job,
/// mounts a volume, sends a signal or changes network policy.
public final class FileBackedMock: MockLifecycleBackend {
    let store: LifecycleStore
    public var failBefore: MockStep?
    public var failAfter: MockStep?
    public init(store: LifecycleStore) { self.store = store }
    func world() throws -> MockWorld {
        let value = try decodeCanonical(MockWorld.self, store.read("world.json"))
        guard value.schema == "sanjbox.mock-lifecycle.world.v1" else { throw LifecycleFailure("unknown world schema") }
        return value
    }
    public func perform(_ step: MockStep, manifest: StateManifestDocument) throws {
        if failBefore == step { throw MockNoEffectFailure() }
        var world = try world()
        var zone = world.zones[manifest.zone.id] ?? MockZoneSnapshot(uid: manifest.zone.uid)
        try zone.apply(step, manifest: manifest)
        world.zones[manifest.zone.id] = zone
        try store.replace("world.json", data: canonical(world))
        if failAfter == step { throw LifecycleFailure("uncertain backend failure") }
    }
    public func validate(expected: [String: MockZoneSnapshot]) throws {
        guard try world().zones == expected else { throw LifecycleFailure("backend drift or incomplete effect; deny and preserve") }
    }
}
