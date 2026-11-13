import Foundation
import XCTest
import Darwin
import SanjboxContracts
@testable import SanjboxLifecycle

func fixtureManifest(_ id: String = "t001", uid: UInt32 = 750) throws -> Data {
    let value = StateManifestDocument(intent: "design-only", phase: "mvp", zone: .init(id: id, uid: uid, gid: 701),
        containers: [.init(id: "pool")],
        volumes: [
            .init(id: "state", containerID: "pool", mountPoint: "/Volumes/Sanjbox/\(id)/state", quota: .init(mode: "limited", limitBytes: 1000000, reserveBytes: 0)),
            .init(id: "tools", containerID: "pool", mountPoint: "/opt/snj/\(id)", quota: .init(mode: "limited", limitBytes: 1000000, reserveBytes: 0))
        ],
        roots: ["home", "project", "prefix", "cache", "tmp"].map {
            .init(id: $0, role: $0, volumeID: $0 == "prefix" ? "tools" : "state", relativePath: $0 == "prefix" ? "." : $0,
                  ownerUID: uid, purpose: "Synthetic \($0)")
        }, runtimePolicy: "deferred-f4", rollback: .init(unitID: "\(id)-full", volumeIDs: ["state", "tools"]),
        hostControl: .init(directoryPath: "/Library/Application Support/Sanjbox/control/\(id)", policyFile: "policy.json", recoveryFile: "recovery.json"),
        readOnlyInputs: [], outsideWrites: "forbidden-unverified", hostAccess: "controlled-export-only")
    return try StateManifestSchema.encode(value)
}

struct InjectedCrash: Error {}

final class Fixture {
    let path: String
    let device: dev_t
    let inode: ino_t
    init() throws {
        let store = try LifecycleStore.create(); path = store.path
        var value = stat()
        guard lstat(path, &value) == 0 else { throw LifecycleFailure("fixture stat failed") }
        device = value.st_dev; inode = value.st_ino
    }
    func open() throws -> LifecycleStore { try LifecycleStore(path: path) }
    // Test harness cleanup only: remove precisely this test-created flat namespace, including
    // deliberately damaged records. The production API refuses incomplete/ambiguous cleanup.
    deinit {
        var value = stat()
        guard lstat(path, &value) == 0, value.st_dev == device, value.st_ino == inode,
              value.st_mode & S_IFMT == S_IFDIR,
              let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return }
        defer { close(fd) }
        for name in names { _ = unlinkat(fd, name, 0) } // Flat unlink; never follows links or recurses.
        _ = rmdir(path)
    }
    func prepare(for operation: LifecycleOperation) throws {
        let store = try open(), coordinator = LifecycleCoordinator(store: store)
        try coordinator.register(manifest: fixtureManifest())
        if operation != .start { try coordinator.execute(.start, zone: "t001") }
        if operation == .resume { try coordinator.execute(.pause, zone: "t001") }
        if operation == .cleanup { try coordinator.execute(.stop, zone: "t001") }
    }
}

func resultState(_ operation: LifecycleOperation) -> ZoneState {
    switch operation { case .start, .resume: .running; case .pause: .paused; case .stop: .stopped; case .cleanup: .cleaned }
}

func crashDriver() throws -> URL {
    var directory = Bundle(for: LifecycleTests.self).bundleURL.deletingLastPathComponent()
    for _ in 0..<5 {
        let candidate = directory.appendingPathComponent("lifecycle-crash-driver")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        directory.deleteLastPathComponent()
    }
    throw LifecycleFailure("built lifecycle-crash-driver not found")
}
