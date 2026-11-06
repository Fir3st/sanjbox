import Foundation
import Testing
@testable import SanjboxGatewayCore

private struct D5ProcessResult: Sendable { let status: Int32; let output: Data; let error: Data }

/// Only generated inputs, empty profiles, explicit cwd and a fresh temporary
/// directory. No inherited environment, credentials, hooks, proxies or config.
private final class D5Workspace: @unchecked Sendable {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sanjbox-d5-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func cleanup() throws {
        let attributes = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink == false,
              root.lastPathComponent.hasPrefix("sanjbox-d5-fixture-") else { throw RegistryFailure.denied }
        try FileManager.default.removeItem(at: root)
    }
    var environment: [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path,
         "XDG_CONFIG_HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null",
         "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false",
         "SSH_ASKPASS": "/usr/bin/false", "GIT_ALLOW_PROTOCOL": "http",
         "GIT_AUTHOR_NAME": "Synthetic Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
         "GIT_COMMITTER_NAME": "Synthetic Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
         "GIT_AUTHOR_DATE": "2020-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2020-01-01T00:00:00Z",
         "PIP_CONFIG_FILE": "/dev/null", "PIP_DISABLE_PIP_VERSION_CHECK": "1", "PIP_NO_INPUT": "1"]
    }
    func process(_ executable: String, _ args: [String], body: Data = Data(), extra: [String: String] = [:]) throws -> (Process, URL, URL, [FileHandle]) {
        let id = UUID().uuidString
        let input = root.appendingPathComponent(id + ".input")
        let output = root.appendingPathComponent(id + ".out")
        let errors = root.appendingPathComponent(id + ".err")
        try body.write(to: input); try Data().write(to: output); try Data().write(to: errors)
        let handles = try [FileHandle(forReadingFrom: input), FileHandle(forWritingTo: output), FileHandle(forWritingTo: errors)]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = args; process.currentDirectoryURL = root
        process.environment = environment.merging(extra) { _, value in value }
        process.standardInput = handles[0]; process.standardOutput = handles[1]; process.standardError = handles[2]
        return (process, output, errors, handles)
    }
    func sync(_ args: [String], body: Data = Data(), extra: [String: String] = [:]) throws -> D5ProcessResult {
        try sync("/usr/bin/git", args, body: body, extra: extra)
    }
    func sync(_ executable: String, _ args: [String], body: Data = Data(), extra: [String: String] = [:]) throws -> D5ProcessResult {
        let (process, output, errors, handles) = try process(executable, args, body: body, extra: extra)
        defer { handles.forEach { try? $0.close() } }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timer)
        defer { timer.cancel() }
        try process.run(); Diag.blocking("D5.sync \(args.first ?? "")") { process.waitUntilExit() }
        return D5ProcessResult(status: process.terminationStatus, output: try Data(contentsOf: output), error: try Data(contentsOf: errors))
    }
    func async(_ executable: String, _ args: [String]) async throws -> D5ProcessResult {
        let (process, output, errors, handles) = try process(executable, args)
        defer { handles.forEach { try? $0.close() } }
        let timer = Task {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            if process.isRunning { process.terminate() }
        }
        defer { timer.cancel() }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        return D5ProcessResult(status: status, output: try Data(contentsOf: output), error: try Data(contentsOf: errors))
    }
    var gitOptions: [String] {
        ["-c", "core.hooksPath=/dev/null", "-c", "credential.helper=", "-c", "protocol.version=0",
         "-c", "http.followRedirects=false", "-c", "http.proxy=", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"]
    }
}

@Test @MainActor func gitCLICloneAndPushOnlyGeneratedProjectThroughRealLoopbackGateway() async throws {
    let workspace = try D5Workspace()
    defer { do { try workspace.cleanup() } catch { Issue.record("D5 fixture cleanup failed: \(error)") } }
    for args in [ ["init", "--bare", "--template=", "--initial-branch=main", "owner/fixture.git"],
                  ["--git-dir=owner/fixture.git", "config", "http.receivepack", "true"],
                  ["init", "--template=", "--initial-branch=main", "seed"] ] {
        #expect(try workspace.sync(args).status == 0)
    }
    try Data("only a generated fixture\n".utf8).write(to: workspace.root.appendingPathComponent("seed/canary.txt"))
    #expect(try workspace.sync(workspace.gitOptions + ["-C", "seed", "add", "canary.txt"]).status == 0)
    #expect(try workspace.sync(workspace.gitOptions + ["-C", "seed", "commit", "-m", "synthetic fixture"]).status == 0)
    #expect(try workspace.sync(workspace.gitOptions + ["-C", "seed", "push", "../owner/fixture.git", "main"], extra: ["GIT_ALLOW_PROTOCOL": "file"]).status == 0)
    let initial = try workspace.sync(["--git-dir=owner/fixture.git", "rev-parse", "main"]).output
    let backend = D5Backend { _, request, _ in
        let parts = request.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let result = try workspace.sync(workspace.gitOptions + ["http-backend"], body: request.body, extra: [
            "GIT_PROJECT_ROOT": workspace.root.path, "GIT_HTTP_EXPORT_ALL": "1",
            "PATH_INFO": String(parts[0]), "QUERY_STRING": parts.count == 2 ? String(parts[1]) : "",
            "REQUEST_METHOD": request.method, "CONTENT_TYPE": request.headers["content-type"] ?? "",
            "CONTENT_LENGTH": String(request.body.count), "SERVER_PROTOCOL": "HTTP/1.1", "REMOTE_ADDR": "127.0.0.1"])
        guard result.status == 0, let split = result.output.range(of: Data("\r\n\r\n".utf8)) else { throw RegistryFailure.metadata }
        let lines = String(decoding: result.output[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let type = lines.first { $0.lowercased().hasPrefix("content-type:") }?.dropFirst(13).trimmingCharacters(in: .whitespaces) ?? "application/octet-stream"
        let status = lines.first { $0.lowercased().hasPrefix("status:") }.flatMap { Int($0.split(separator: " ")[1]) } ?? 200
        return D5Wire(status: status, type: type, body: Data(result.output[split.upperBound...]))
    }
    let handler = GitGateway(configuration: try GitConfiguration(hostname: "git.example", repositoryPath: "/owner/fixture.git", allowPush: true), upstream: d5Client(backend))
    let server = GatewayServer(router: try TypedRouter(routes: [handler.route()]))
    let port = try await server.start()
    defer { server.stop() }
    let url = "http://127.0.0.1:\(port)/git/project.git"
    let clone = try await workspace.async("/usr/bin/git", workspace.gitOptions + ["clone", "--template=", url, "clone"])
    #expect(clone.status == 0, "clone: \(String(decoding: clone.error, as: UTF8.self))")
    guard clone.status == 0 else { return }
    #expect(try Data(contentsOf: workspace.root.appendingPathComponent("clone/canary.txt")) == Data("only a generated fixture\n".utf8))
    try Data("own synthetic change\n".utf8).write(to: workspace.root.appendingPathComponent("clone/canary.txt"))
    #expect(try workspace.sync(workspace.gitOptions + ["-C", "clone", "commit", "-am", "second synthetic fixture"]).status == 0)
    let push = try await workspace.async("/usr/bin/git", workspace.gitOptions + ["-C", "clone", "push", "origin", "HEAD:refs/heads/canary"])
    #expect(push.status == 0, "push: \(String(decoding: push.error, as: UTF8.self))")
    let local = try workspace.sync(["-C", "clone", "rev-parse", "HEAD"]).output
    #expect(try workspace.sync(["--git-dir=owner/fixture.git", "rev-parse", "refs/heads/canary"]).output == local)
    #expect(local != initial)
    let callsBefore = backend.calls.count
    let denied = try await workspace.async("/usr/bin/git", workspace.gitOptions + ["-C", "clone", "push", "http://127.0.0.1:\(port)/git/other.git", "HEAD:refs/heads/forbidden"])
    #expect(denied.status != 0 && backend.calls.count == callsBefore)
    #expect(backend.calls.allSatisfy { $0.0 == "git.example" && $0.1.target.hasPrefix("/owner/fixture.git/") })
    #expect(backend.calls.contains { $0.1.method == "POST" && $0.1.target.hasSuffix("/git-upload-pack") })
    #expect(backend.calls.contains { $0.1.method == "POST" && $0.1.target.hasSuffix("/git-receive-pack") })
    print("D5 local git client: " + String(decoding: try workspace.sync(["--version"]).output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

private actor D5PyPISlot {
    var handler: PyPIGateway?
    func install(_ handler: PyPIGateway) { self.handler = handler }
    func reply(_ request: HTTPRequest) async throws -> GatewayReply {
        guard let handler else { return .response(.error(503)) }
        return .response(try await handler.response(to: request))
    }
}

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3"),
               "Optional existing Python/pip client; never install it for this test"))
@MainActor func pypiPipDownloadsOnlySyntheticWheelThroughRealLoopbackGateway() async throws {
    let workspace = try D5Workspace()
    defer { do { try workspace.cleanup() } catch { Issue.record("D5 fixture cleanup failed: \(error)") } }
    let python = "/opt/homebrew/bin/python3"
    // The archive contains metadata only. No package code/build hooks are run.
    let script = """
    import zipfile
    with zipfile.ZipFile('fixture-1.0.0-py3-none-any.whl', 'w') as wheel:
        wheel.writestr('fixture-1.0.0.dist-info/METADATA', 'Metadata-Version: 2.1\\nName: fixture\\nVersion: 1.0.0\\n')
        wheel.writestr('fixture-1.0.0.dist-info/WHEEL', 'Wheel-Version: 1.0\\nGenerator: synthetic\\nRoot-Is-Purelib: true\\nTag: py3-none-any\\n')
        wheel.writestr('fixture-1.0.0.dist-info/RECORD', '')
    """
    #expect(try workspace.sync(python, ["-I", "-c", script]).status == 0)
    let bytes = try Data(contentsOf: workspace.root.appendingPathComponent(d5Filename))
    let metadata = try d5Index(files: [d5File(bytes: bytes)])
    let backend = D5Backend { _, request, _ in D5Wire(body: request.target.hasPrefix("/simple/") ? metadata : bytes) }
    let slot = D5PyPISlot()
    let server = GatewayServer(router: try TypedRouter(routes: [TypedRoute(mount: "/pypi", methods: ["GET"]) { try await slot.reply($0) }]))
    let port = try await server.start()
    defer { server.stop() }
    let config = try PyPIConfiguration(registryHostname: "index.example", artifactHostnames: ["files.example"], publicOrigin: "http://127.0.0.1:\(port)", cooldown: 3600)
    let handler = try d5PyPI(backend, configuration: config)
    await slot.install(handler)
    let result = try await workspace.async(python, ["-I", "-m", "pip", "download", "--no-deps", "--only-binary=:all:",
        "--no-cache-dir", "--disable-pip-version-check", "--no-input", "--retries", "0", "--timeout", "5",
        "--index-url", "http://127.0.0.1:\(port)/pypi/simple/", "--dest", "download", "fixture==1.0.0"])
    #expect(result.status == 0, "pip: \(String(decoding: result.error, as: UTF8.self))")
    guard result.status == 0 else { return }
    #expect(try Data(contentsOf: workspace.root.appendingPathComponent("download/" + d5Filename)) == bytes)
    #expect(await handler.downloadRecords().map(\.state) == [.transportAccepted])
    #expect(backend.calls.map { $0.1.target } == ["/simple/fixture/", "/simple/fixture/", "/packages/" + d5Filename, "/simple/fixture/"])
    print("D5 local pip client: " + String(decoding: try workspace.sync(python, ["-I", "-m", "pip", "--version"]).output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}
