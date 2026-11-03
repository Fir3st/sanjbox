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

private struct NPMResult: Sendable { let status: Int32; let diagnostic: String }

private struct NPMRun: Sendable {
    let root: URL
    let project: URL
    let node: URL
    let cli: URL

    init() throws {
        let env = ProcessInfo.processInfo.environment
        guard let nodePath = env["SANJBOX_FIXTURE_NODE"], let cliPath = env["SANJBOX_FIXTURE_NPM_CLI"] else {
            throw XCTSkip("optional: supply inspected absolute SANJBOX_FIXTURE_NODE and SANJBOX_FIXTURE_NPM_CLI paths")
        }
        guard nodePath.hasPrefix("/"), cliPath.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: nodePath), FileManager.default.fileExists(atPath: cliPath) else {
            throw FixtureFailure.invalidInput
        }
        node = URL(fileURLWithPath: nodePath)
        cli = URL(fileURLWithPath: cliPath)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sanjbox-d4-npm-" + UUID().uuidString, isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for name in ["project", "home", "cache", "tmp", "prefix"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
            }
            for name in ["user.npmrc", "global.npmrc"] { try Data().write(to: root.appendingPathComponent(name)) }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
    func prepare(_ project: LockedProject) throws {
        try project.packageJSON.write(to: self.project.appendingPathComponent("package.json"))
        try project.lockfile.write(to: self.project.appendingPathComponent("package-lock.json"))
    }
    func installedManifest(_ key: PackageKey) throws -> Data {
        try Data(contentsOf: project.appendingPathComponent("node_modules/\(key.name)/package.json"))
    }
    func ci(origin: FixtureOrigin, offline: Bool = false) async throws -> NPMResult {
        try await invoke(["ci"] + (offline ? ["--offline"] : []), origin: origin)
    }
    func seedCache(_ artifact: SyntheticArtifact, origin: FixtureOrigin) async throws -> NPMResult {
        let file = root.appendingPathComponent("seed.tgz")
        try artifact.archive.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await invoke(["cache", "add", file.path, "--offline"], origin: origin)
    }
    private func invoke(_ arguments: [String], origin: FixtureOrigin) async throws -> NPMResult {
        // Complete replacement environment: no NODE_OPTIONS, proxies, ambient npm settings/auth.
        let environment = [
            "HOME": root.appendingPathComponent("home").path,
            "PATH": node.deletingLastPathComponent().path + ":/usr/bin:/bin",
            "TMPDIR": root.appendingPathComponent("tmp").path,
            "NPM_CONFIG_USERCONFIG": root.appendingPathComponent("user.npmrc").path,
            "NPM_CONFIG_GLOBALCONFIG": root.appendingPathComponent("global.npmrc").path,
            "NPM_CONFIG_CACHE": root.appendingPathComponent("cache").path,
            "NPM_CONFIG_PREFIX": root.appendingPathComponent("prefix").path,
            "NPM_CONFIG_REGISTRY": origin.value + "/npm/",
            "NPM_CONFIG_UPDATE_NOTIFIER": "false", "NPM_CONFIG_AUDIT": "false",
            "NPM_CONFIG_FUND": "false", "NPM_CONFIG_IGNORE_SCRIPTS": "true",
        ]
        let task = Task.detached { () throws -> NPMResult in
            let outputURL = root.appendingPathComponent("npm-output-" + UUID().uuidString + ".log")
            try Data().write(to: outputURL)
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
            let process = Process()
            process.executableURL = node
            process.arguments = [cli.path] + arguments + ["--ignore-scripts", "--no-audit", "--no-fund", "--loglevel=error",
                "--update-notifier=false", "--fetch-retries=0", "--fetch-timeout=5000", "--progress=false", "--logs-max=0"]
            process.currentDirectoryURL = project
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            try process.run()
            defer {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while process.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw FixtureFailure.incomplete }
                let size = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int ?? 0
                guard size <= 65_536 else { throw FixtureFailure.limit }
                usleep(20_000)
            }
            let reader = try FileHandle(forReadingFrom: outputURL)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536 else { throw FixtureFailure.limit }
            return NPMResult(status: process.terminationStatus, diagnostic: String(decoding: data, as: UTF8.self))
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func cleanup() {
        // Only the UUID directory created above; no input-specified deletion path.
        do { try FileManager.default.removeItem(at: root) }
        catch { XCTFail("Cannot clean own npm fixture directory: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
