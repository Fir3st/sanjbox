import Darwin
import Foundation
import SanjboxGatewayCore
import SanjboxGatewayFixtures
import XCTest

/// Optional real npm compatibility, with own inert tarball only. This is not D2 integration.
/// Run only when both absolute installed tool paths are explicitly supplied (see README).
@MainActor final class NPMCompatibilityTests: XCTestCase {
    func testNpmCIScopedLockfileFetchAndOfflineClientCacheBoundary() async throws {
        let run = try NPMRun()
        defer { run.cleanup() }
        let fixtures = try RegistryFixtures.standard()
        let key = try PackageKey(name: "@fixture/bead", version: "1.2.0") // newer than cooldown cutoff
        let mock = try RegistryMock(fixtures: fixtures)
        let server = GatewayServer(router: try TypedRouter(routes: [mock.route]))
        let port = try await server.start()
        defer { server.stop() }
        let origin = try FixtureOrigin.loopback(port: port)
        try await mock.configure(origin: origin)
        let project = try fixtures.project(key: key, origin: origin)
        try run.prepare(project)
        let cold = try await run.ci(origin: origin)
        XCTAssertEqual(cold.status, 0, cold.diagnostic)
        XCTAssertEqual(try run.installedManifest(key), try fixtures.artifact(key).manifest)
        XCTAssertEqual(try Data(contentsOf: run.project.appendingPathComponent("package-lock.json")), project.lockfile)
        let first = try await mock.transcript()
        XCTAssertEqual(first.map(\.target), [key.tarballTarget], "lockfile fetched directly without packument")
        XCTAssertEqual(first.map(\.status), [200])
        // D1 emits Cache-Control:no-store. Seed the npm content cache from our OWN local
        // archive explicitly; this models an imported/pre-existing cache, not a warm gateway cache.
        let seeded = try await run.seedCache(try fixtures.artifact(key), origin: origin)
        XCTAssertEqual(seeded.status, 0, seeded.diagnostic)
        // npm ci removes node_modules itself. The offline run can install this NEW artifact
        // from the seeded client cache even after the mock is configured to refuse it.
        try await mock.configure(origin: origin, refuse: [key])
        let cached = try await run.ci(origin: origin, offline: true)
        XCTAssertEqual(cached.status, 0, cached.diagnostic)
        XCTAssertEqual(try run.installedManifest(key), try fixtures.artifact(key).manifest)
        let second = try await mock.transcript()
        XCTAssertEqual(second, first, "offline cache run must make zero additional gateway requests")
    }

    func testNpmCIDirectLockfileRequestObservesMock403() async throws {
        let run = try NPMRun()
        defer { run.cleanup() }
        let fixtures = try RegistryFixtures.standard(), key = try PackageKey(name: "fixture-bead", version: "1.2.0")
        let mock = try RegistryMock(fixtures: fixtures)
        let server = GatewayServer(router: try TypedRouter(routes: [mock.route]))
        let port = try await server.start()
        defer { server.stop() }
        let origin = try FixtureOrigin.loopback(port: port)
        try await mock.configure(origin: origin, refuse: [key])
        let project = try fixtures.project(key: key, origin: origin)
        try run.prepare(project)
        let status = try await run.ci(origin: origin)
        XCTAssertNotEqual(status.status, 0, status.diagnostic)
        let requests = try await mock.transcript()
        XCTAssertFalse(requests.isEmpty)
        XCTAssertTrue(requests.allSatisfy { $0.target == key.tarballTarget && $0.status == 403 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.project.appendingPathComponent("node_modules/\(key.name)/package.json").path))
        XCTAssertEqual(try Data(contentsOf: run.project.appendingPathComponent("package-lock.json")), project.lockfile)
        // Refusal is explicitly scripted, NOT a tested implementation of cooldown.
    }

    func testNpmCIRejectsManifestLockfileMismatchWithoutArtifactIssuance() async throws {
        let run = try NPMRun()
        defer { run.cleanup() }
        let fixtures = try RegistryFixtures.standard(), key = try PackageKey(name: "fixture-bead", version: "1.0.0")
        let mock = try RegistryMock(fixtures: fixtures)
        let server = GatewayServer(router: try TypedRouter(routes: [mock.route]))
        let port = try await server.start()
        defer { server.stop() }
        let origin = try FixtureOrigin.loopback(port: port)
        try await mock.configure(origin: origin)
        try run.prepare(fixtures.project(key: key, origin: origin))
        // npm may consult metadata while validating a mismatched dependency version.
        // Both 1.0.0 and 1.1.0 exist. Require the explicit lock synchronization error,
        // rather than treating an unavailable version or broken transport as this result.
        try Data("{\"name\":\"fixture-consumer\",\"version\":\"1.0.0\",\"dependencies\":{\"fixture-bead\":\"1.1.0\"}}".utf8)
            .write(to: run.project.appendingPathComponent("package.json"))
        let status = try await run.ci(origin: origin)
        XCTAssertNotEqual(status.status, 0, status.diagnostic)
        XCTAssertTrue(status.diagnostic.contains("Invalid: lock file's fixture-bead@1.0.0 does not satisfy fixture-bead@1.1.0"), status.diagnostic)
        let requests = try await mock.transcript()
        XCTAssertTrue(requests.allSatisfy { $0.target == key.packumentTarget })
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.project.appendingPathComponent("node_modules/\(key.name)/package.json").path))
    }
}
