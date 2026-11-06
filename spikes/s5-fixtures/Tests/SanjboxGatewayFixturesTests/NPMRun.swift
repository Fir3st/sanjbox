import Darwin
import Foundation
import SanjboxGatewayFixtures
import XCTest

struct NPMResult: Sendable { let status: Int32; let diagnostic: String }

struct NPMRun: Sendable {
    let root: URL
    let project: URL
    let node: URL
    let cli: URL

    init() throws {
        // Read only explicit opt-in selectors, never enumerate ambient configuration.
        guard let nodeValue = getenv("SANJBOX_FIXTURE_NODE"), let cliValue = getenv("SANJBOX_FIXTURE_NPM_CLI") else {
            throw XCTSkip("optional: supply inspected absolute SANJBOX_FIXTURE_NODE and SANJBOX_FIXTURE_NPM_CLI paths")
        }
        let nodePath = String(cString: nodeValue), cliPath = String(cString: cliValue)
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
    func localImport(_ artifact: SyntheticArtifact, origin: FixtureOrigin) async throws -> NPMResult {
        // A new project without registry dependencies. The only input is our inert archive.
        try Data("{\"name\":\"fixture-local-consumer\",\"version\":\"1.0.0\"}".utf8)
            .write(to: project.appendingPathComponent("package.json"))
        let file = root.appendingPathComponent("import.tgz")
        try artifact.archive.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await invoke(["install", "--offline", "--package-lock=false", file.path], origin: origin)
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
