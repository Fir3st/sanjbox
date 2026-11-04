import CryptoKit
import Foundation
import Network
import Testing
@testable import SanjboxGatewayCore

private let npmNow = Date(timeIntervalSince1970: 1_800_000_000)
private let npmBytes = Data("synthetic tarball bytes; never installed".utf8)
private func sri(_ data: Data) -> String { "sha512-" + Data(SHA512.hash(data: data)).base64EncodedString() }
private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

private func packument(name: String = "fixture", bytes: Data = npmBytes,
                       time: String? = iso(npmNow.addingTimeInterval(-3600)),
                       tarball: String? = nil, integrity: String? = nil,
                       extras: [String: Any] = [:]) throws -> Data {
    let base = String(name.split(separator: "/").last!)
    var manifest: [String: Any] = ["name": name, "version": "1.0.0",
        "dist": ["tarball": tarball ?? "https://registry.example/\(name)/-/\(base)-1.0.0.tgz", "integrity": integrity ?? sri(bytes)]]
    manifest.merge(extras) { _, new in new }
    return try JSONSerialization.data(withJSONObject: ["name": name, "versions": ["1.0.0": manifest],
        "time": time.map { ["1.0.0": $0] } ?? [:], "dist-tags": ["latest": "1.0.0"]], options: [.sortedKeys])
}

private struct NPMHosts: HostAddressProvider { func addresses() throws -> Set<SanjboxGatewayCore.IPAddress> { [] } }
private actor NPMDNS: DestinationResolver {
    private(set) var calls: [String] = []
    let answers: [String]
    init(_ answers: [String] = []) { self.answers = answers }
    func addresses(for hostname: String) async throws -> [SanjboxGatewayCore.IPAddress] {
        let index = calls.count
        calls.append(hostname)
        return [try SanjboxGatewayCore.IPAddress(index < answers.count ? answers[index] : "8.8.8.8")]
    }
}

private struct NPMWire: Sendable {
    var status = 200
    var headers: [String: String] = ["Content-Type": "application/json"]
    var body: Data
    var data: Data {
        var text = "HTTP/1.1 \(status) Fixture\r\nContent-Length: \(body.count)\r\n"
        for (key, value) in headers { text += "\(key): \(value)\r\n" }
        return Data((text + "\r\n").utf8) + body
    }
}
private final class NPMBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(String, String, String)] = []
    private var responder: @Sendable (String, String, Int) throws -> NPMWire
    var delay: Duration = .zero // configured before using fixture
    init(_ responder: @escaping @Sendable (String, String, Int) throws -> NPMWire) { self.responder = responder }
    func reply(host: String, wire: Data) throws -> Data {
        try lock.withLock {
            let text = String(decoding: wire, as: UTF8.self)
            let target = String(text.split(separator: " ")[1])
            requests.append((host, target, text))
            return try responder(host, target, requests.count).data
        }
    }
    var calls: [(String, String, String)] { lock.withLock { requests } }
}
private final class NPMConnection: UpstreamConnection, @unchecked Sendable {
    let backend: NPMBackend
    let host: String
    private let lock = NSLock()
    private var pending = Data()
    init(_ backend: NPMBackend, _ host: String) { self.backend = backend; self.host = host }
    func start(timeout: Duration) async throws { try Task.checkCancellation() }
    func send(_ data: Data, timeout: Duration) async throws {
        let reply = try backend.reply(host: host, wire: data)
        lock.withLock { pending = reply }
    }
    func receive(timeout: Duration) async throws -> ReceivedBytes {
        if backend.delay > .zero { try await Task.sleep(for: backend.delay) }
        try Task.checkCancellation()
        return lock.withLock {
            let part = Data(pending.prefix(16_384))
            pending = Data(pending.dropFirst(part.count))
            return ReceivedBytes(data: part, endOfStream: pending.isEmpty)
        }
    }
    func cancel() {}
}
private func gateway(_ backend: NPMBackend, config: NPMConfiguration? = nil,
                     dns: NPMDNS = NPMDNS(), now: @escaping @Sendable () -> Date = { npmNow }) throws -> NPMGateway {
    let client = UpstreamClient(resolver: dns, hostAddresses: NPMHosts(),
                               dialer: RecordingDialer { NPMConnection(backend, $0.hostname) })
    return NPMGateway(configuration: try config ?? NPMConfiguration(registryHostname: "registry.example", artifactHostnames: ["cdn.example"],
                                                                   publicOrigin: "http://127.0.0.1:8765", cooldown: 3600), upstream: client, now: now)
}
private func request(_ target: String = "/npm/fixture/-/fixture-1.0.0.tgz", method: String = "GET",
                     headers: [String: String] = [:], body: Data = Data()) -> HTTPRequest {
    HTTPRequest(method: method, target: target, headers: headers, body: body)
}
private func defaultBackend(metadata: Data? = nil) throws -> NPMBackend {
    let document = try metadata ?? packument()
    return NPMBackend { _, path, _ in NPMWire(body: path.contains("/-/") ? npmBytes : document) }
}

@Test func npmPackumentFiltersTimesTagsAndReconstructsOnlySafeFields() async throws {
    var root = try JSONSerialization.jsonObject(with: packument()) as! [String: Any]
    var versions = root["versions"] as! [String: Any]
    let old = versions["1.0.0"] as! [String: Any]
    var recent = old; recent["version"] = "2.0.0"
    versions["2.0.0"] = recent
    root["versions"] = versions
    root["time"] = ["1.0.0": iso(npmNow.addingTimeInterval(-3600)), "2.0.0": iso(npmNow.addingTimeInterval(-3599))]
    root["dist-tags"] = ["latest": "2.0.0", "stable": "1.0.0", "unknown": "3.0.0"]
    root["readme"] = "https://untrusted.example/secret"
    let backend = try defaultBackend(metadata: JSONSerialization.data(withJSONObject: root))
    let response = try await gateway(backend).response(to: request("/npm/fixture"))
    #expect(response.status == 200)
    let output = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
    #expect(Set(output.keys) == ["name", "versions", "time", "dist-tags"])
    #expect(output["dist-tags"] as? [String: String] == ["stable": "1.0.0"])
    let filtered = output["versions"] as! [String: [String: Any]]
    #expect(Set(filtered.keys) == ["1.0.0"])
    #expect((filtered["1.0.0"]!["dist"] as! [String: String])["tarball"] == "http://127.0.0.1:8765/npm/fixture/-/fixture-1.0.0.tgz")
    #expect(!String(decoding: response.body, as: UTF8.self).contains("https://"))
}

@Test func npmDirectLockfileTargetFetchesFreshMetadataAndAuditsOnlyTransportOutcome() async throws {
    let backend = try defaultBackend()
    let handler = try gateway(backend)
    let response = try await handler.response(to: request()) // no metadata visit first
    #expect(response.status == 200 && response.body == npmBytes)
    #expect(backend.calls.map(\.1) == ["/fixture", "/fixture/-/fixture-1.0.0.tgz", "/fixture"])
    #expect(await handler.downloadRecords().map(\.state) == [.prepared])
    #expect(await handler.takeCompletedDownloadRecords().isEmpty)
    await response.completion?(true)
    let records = await handler.takeCompletedDownloadRecords()
    #expect(records.count == 1 && records[0].state == .transportAccepted && !records[0].cached)
    #expect(records[0].integrity == sri(npmBytes) && records[0].bytes == npmBytes.count)
    #expect(await handler.downloadRecords().isEmpty)
}

@Test func npmCooldownUnknownFutureInvalidDatesAndUnsupportedSourcesDenyDirectRequests() async throws {
    for date in [nil, "invalid", "2027-02-31T00:00:00Z", iso(npmNow.addingTimeInterval(1)), iso(npmNow.addingTimeInterval(-3599))] {
        let backend = try defaultBackend(metadata: packument(time: date))
        let handler = try gateway(backend)
        #expect(try await handler.response(to: request()).status == 403)
        #expect(backend.calls.count == 1)
        #expect(await handler.downloadRecords().isEmpty)
    }
    for source in ["https://evil.example/a.tgz", "git+https://git.example/a", "file:../local", "npm:other@1", "../relative"] {
        let backend = try defaultBackend(metadata: packument(extras: ["dependencies": ["child": source]]))
        let handler = try gateway(backend)
        #expect(try await handler.response(to: request()).status == 403)
        #expect(backend.calls.count == 1)
    }
}

@Test func npmScopedPathsCanonicalizeAndAmbiguousTargetsNeverDial() async throws {
    let scoped = try packument(name: "@scope/fixture")
    let backend = try defaultBackend(metadata: scoped)
    let handler = try gateway(backend)
    let response = try await handler.response(to: request("/npm/@scope%2Ffixture"))
    #expect(response.status == 200)
    #expect(String(decoding: response.body, as: UTF8.self).contains("/npm/@scope%2ffixture/-/fixture-1.0.0.tgz"))
    #expect(try await handler.response(to: request("/npm/@scope/fixture/-/fixture-1.0.0.tgz")).status == 200)
    let initialCalls = backend.calls.count
    for target in ["/npm/fixture?auth=x", "/npm/fixture#x", "/npm/%66ixture", "/npm/@scope%252ffixture", "/npm/@scope%2ffixture%2fextra", "/npm/../fixture", "/npm//fixture", "/npm/fixture/-/other-1.0.0.tgz", "/npm/fixture/-/fixture-1.0.0.tgz?x", "/npm/fixture/-/fixture-%31.0.0.tgz", "/npm/https://evil.example"] {
        #expect(try await handler.response(to: request(target)).status == 400)
    }
    #expect(backend.calls.count == initialCalls)
}

@Test func npmBareFileDependencySpecsCannotLeavePackumentOrAuthorizeDirectTarball() async throws {
    for field in ["dependencies", "optionalDependencies", "peerDependencies"] {
        for spec in [".", "..", ".local", "payload.tgz", "payload.tar.gz", "payload.tar", "PAYLOAD.TGZ", " .local ", " payload.tar.gz "] {
            for target in ["/npm/fixture", "/npm/fixture/-/fixture-1.0.0.tgz"] {
                let backend = try defaultBackend(metadata: packument(extras: [field: ["child": spec]]))
                let handler = try gateway(backend)
                #expect(try await handler.response(to: request(target)).status == 403)
                #expect(backend.calls.map(\.1) == ["/fixture"])
                #expect(await handler.downloadRecords().isEmpty)
            }
        }
    }
}

@Test func npmMethodsCredentialsBodiesAndRangeAreRejectedBeforeUpstream() async throws {
    let backend = try defaultBackend(); let handler = try gateway(backend)
    let router = try TypedRouter(routes: [handler.route()])
    for method in ["PUT", "DELETE", "POST", "CONNECT"] {
        guard case .response(let response) = try await router.reply(to: request(method: method)) else { Issue.record("expected denial"); return }
        #expect(response.status == 403)
    }
    for header in ["authorization", "Authorization", "proxy-authorization", "cookie", "x-api-key", "api-key", "range", "Range"] {
        #expect(try await handler.response(to: request(headers: [header: "synthetic"])).status == 403)
    }
    #expect(try await handler.response(to: request(body: Data([1]))).status == 403)
    #expect(backend.calls.isEmpty)
}

@Test func npmCacheIsRevalidatedAndMetadataChangeAfterFetchNeverIssuesBytes() async throws {
    let good = try packument(); let young = try packument(time: iso(npmNow))
    let backend = NPMBackend { _, path, count in
        NPMWire(body: path.contains("/-/") ? npmBytes : (count <= 3 ? good : young))
    }
    let handler = try gateway(backend)
    #expect(try await handler.response(to: request()).status == 200)
    #expect(try await handler.response(to: request()).status == 403)
    #expect(backend.calls.filter { $0.1.contains("/-/") }.count == 1)
    #expect(await handler.downloadRecords().count == 1)
    for mutated in [try packument(time: iso(npmNow.addingTimeInterval(-7200))),
                    try packument(tarball: "https://cdn.example/new.tgz"),
                    try packument(bytes: Data("changed".utf8))] {
        let changing = NPMBackend { _, path, count in NPMWire(body: path.contains("/-/") ? npmBytes : (count == 1 ? good : mutated)) }
        let h = try gateway(changing)
        #expect(try await h.response(to: request()).status == 403)
        #expect(await h.downloadRecords().isEmpty)
    }
}

@Test func npmCacheHitRefetchesMetadataTwiceWithoutArtifactAndBoundedCacheEvicts() async throws {
    let backend = try defaultBackend(); let handler = try gateway(backend)
    let first = try await handler.response(to: request()); await first.completion?(true)
    let second = try await handler.response(to: request()); await second.completion?(false)
    #expect(second.body == npmBytes && second.status == 200)
    #expect(backend.calls.map(\.1) == ["/fixture", "/fixture/-/fixture-1.0.0.tgz", "/fixture", "/fixture", "/fixture"])
    #expect(await handler.downloadRecords().map(\.cached) == [false, true])
    #expect(await handler.downloadRecords().map(\.state) == [.transportAccepted, .sendFailed])
    let noCache = try NPMConfiguration(registryHostname: "registry.example", publicOrigin: "http://127.0.0.1:8765", cooldown: 3600, maximumCacheBytes: 1)
    let uncachedBackend = try defaultBackend(); let uncached = try gateway(uncachedBackend, config: noCache)
    for _ in 0..<2 { #expect(try await uncached.response(to: request()).status == 200) }
    #expect(uncachedBackend.calls.filter { $0.1.contains("/-/") }.count == 2)
}

@Test func npmRedirectReauthorizesMetadataAndEveryHopUsesFreshDNS() async throws {
    let metadata = try packument()
    let backend = NPMBackend { host, path, _ in
        if !path.contains("/-/") && host == "registry.example" { return NPMWire(body: metadata) }
        if host == "registry.example" { return NPMWire(status: 302, headers: ["Location": "https://cdn.example/file.tgz"], body: Data()) }
        return NPMWire(body: npmBytes)
    }
    let dns = NPMDNS(); let handler = try gateway(backend, dns: dns)
    #expect(try await handler.response(to: request(headers: ["x-untrusted-header": "do-not-forward"])).status == 200)
    #expect(backend.calls.map(\.0) == ["registry.example", "registry.example", "registry.example", "cdn.example", "registry.example"])
    #expect(await dns.calls == backend.calls.map(\.0))
    #expect(backend.calls.allSatisfy { !$0.2.contains("do-not-forward") && !$0.2.lowercased().contains("authorization:") })
    let rebinding = try gateway(backend, dns: NPMDNS(["8.8.8.8", "8.8.8.8", "8.8.8.8", "127.0.0.1"]))
    #expect(try await rebinding.response(to: request()).status == 502)
    #expect(await rebinding.downloadRecords().isEmpty)
}

@Test func npmRedirectUnapprovedOriginLoopChangedMetadataAndHashFailClosed() async throws {
    let metadata = try packument()
    for location in ["https://evil.example/file", "http://cdn.example/file", "https://cdn.example:443/file", "https://user@cdn.example/file", "https://cdn.example/file?q=x", "/relative", "https://cdn.example/%2e%2e/file"] {
        let backend = NPMBackend { _, path, _ in path.contains("/-/") ? NPMWire(status: 302, headers: ["Location": location], body: Data()) : NPMWire(body: metadata) }
        let handler = try gateway(backend)
        #expect(try await handler.response(to: request()).status == 403)
        #expect(backend.calls.count == 2)
        #expect(await handler.downloadRecords().isEmpty)
    }
    let changed = try packument(bytes: Data("changed".utf8))
    let mutation = NPMBackend { _, path, count in path.contains("/-/") ? NPMWire(status: 302, headers: ["Location": "https://cdn.example/file"], body: Data()) : NPMWire(body: count == 1 ? metadata : changed) }
    #expect(try await gateway(mutation).response(to: request()).status == 403)
    #expect(mutation.calls.count == 3)
    let corrupt = NPMBackend { _, path, _ in NPMWire(body: path.contains("/-/") ? Data("corrupt".utf8) : metadata) }
    #expect(try await gateway(corrupt).response(to: request()).status == 403)
    let loop = NPMBackend { _, path, _ in path.contains("/-/") ? NPMWire(status: 302, headers: ["Location": "https://registry.example/fixture/-/fixture-1.0.0.tgz"], body: Data()) : NPMWire(body: metadata) }
    #expect(try await gateway(loop).response(to: request()).status == 403)
}

@Test func npmIntegrityUsesStrongestAlgorithmAndRejectsBadOrMissingSRI() throws {
    let weak = "sha256-" + Data(SHA256.hash(data: npmBytes)).base64EncodedString()
    try NPMIntegrity(weak).verify(npmBytes)
    try NPMIntegrity("sha384-" + Data(SHA384.hash(data: npmBytes)).base64EncodedString()).verify(npmBytes)
    try NPMIntegrity(weak + " " + sri(npmBytes)).verify(npmBytes)
    #expect(throws: NPMFailure.integrity) { try NPMIntegrity(weak + " " + sri(Data("other".utf8))).verify(npmBytes) }
    for value in ["", "sha512-invalid", "sha1-" + Data(repeating: 0, count: 20).base64EncodedString(), sri(npmBytes) + "?option", "md5-abc"] {
        #expect(throws: NPMFailure.integrity) { _ = try NPMIntegrity(value) }
    }
}

@Test func npmMalformedDuplicateOrOversizedMetadataAndArtifactAreNeverPublished() async throws {
    let valid = try packument()
    for data in [Data("{}".utf8), Data("{\"name\":\"fixture\",\"name\":\"fixture\"}".utf8), Data((String(repeating: "[", count: 34) + "0" + String(repeating: "]", count: 34)).utf8)] {
        let handler = try gateway(defaultBackend(metadata: data))
        #expect(try await handler.response(to: request()).status != 200)
        #expect(await handler.downloadRecords().isEmpty)
    }
    let smallMetadata = try NPMConfiguration(registryHostname: "registry.example", publicOrigin: "http://127.0.0.1:8765", cooldown: 3600, maximumMetadataBytes: valid.count - 1)
    #expect(try await gateway(defaultBackend(), config: smallMetadata).response(to: request()).status == 413)
    let smallArtifact = try NPMConfiguration(registryHostname: "registry.example", publicOrigin: "http://127.0.0.1:8765", cooldown: 3600, maximumArtifactBytes: 1)
    #expect(try await gateway(defaultBackend(), config: smallArtifact).response(to: request()).status == 413)
    for status in [302, 304, 404] {
        let handler = try gateway(NPMBackend { _, _, _ in NPMWire(status: status, body: valid) })
        #expect(try await handler.response(to: request()).status == 502)
    }
}

@Test func npmAuditCapacityConcurrencyCancellationAndDeadlineAreBounded() async throws {
    let config = try NPMConfiguration(registryHostname: "registry.example", publicOrigin: "http://127.0.0.1:8765", cooldown: 3600, maximumAuditRecords: 1, maximumOperations: 1, lifetime: .seconds(2))
    let backend = try defaultBackend(); let handler = try gateway(backend, config: config)
    let first = try await handler.response(to: request())
    #expect(try await handler.response(to: request()).status == 503)
    await first.completion?(true)
    _ = await handler.takeCompletedDownloadRecords()
    #expect(try await handler.response(to: request()).status == 200)
    let slow = try defaultBackend(); slow.delay = .seconds(1)
    let limited = try gateway(slow, config: config)
    let task = Task { try await limited.response(to: request()) }
    while slow.calls.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(try await limited.response(to: request()).status == 503)
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(await limited.downloadRecords().isEmpty)
    let short = try NPMConfiguration(registryHostname: "registry.example", publicOrigin: "http://127.0.0.1:8765", cooldown: 3600, lifetime: .milliseconds(30))
    let timed = try gateway(slow, config: short)
    #expect(try await timed.response(to: request()).status == 502)
    #expect(await timed.downloadRecords().isEmpty)
}

private actor NPMRouteSlot {
    var handler: NPMGateway?
    func install(_ handler: NPMGateway) { self.handler = handler }
    func reply(_ request: HTTPRequest) async throws -> GatewayReply {
        guard let handler else { return .response(.error(503)) }
        return .response(try await handler.response(to: request))
    }
}

/// Pause the preparedAt clock read (the seventh read on a fresh tarball path)
/// after the child's last cancellation check. This reproduces a late child
/// result losing to the operation deadline/cancellation, without slow network I/O.
private final class NPMLateResultClock: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var blocked = false
    private let release = DispatchSemaphore(value: 0)
    var entered: Bool { lock.withLock { blocked } }
    func get() -> Date {
        let pause = lock.withLock {
            calls += 1
            if calls == 7 { blocked = true; return true }
            return false
        }
        if pause { _ = release.wait(timeout: .now() + 10) }
        return npmNow
    }
    func resume() { release.signal() }
}

@Test func npmDiscardedTimeoutOrCancelledChildCannotOrphanAuditCapacity() async throws {
    // The barrier must be reached before the operation deadline even on a loaded CI
    // runner; a 100 ms lifetime expired first there and the barrier was never hit.
    let lifetime = Duration.seconds(2)
    for cancel in [false, true] {
        let clock = NPMLateResultClock()
        let config = try NPMConfiguration(registryHostname: "registry.example", publicOrigin: "http://127.0.0.1:8765",
                                          cooldown: 3600, maximumAuditRecords: 1, lifetime: lifetime)
        let handler = try gateway(defaultBackend(), config: config, now: { clock.get() })
        let task = Task { try await handler.response(to: request()) }
        let until = ContinuousClock.now.advanced(by: lifetime)
        while !clock.entered && ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(1)) }
        guard clock.entered else {
            task.cancel(); clock.resume(); _ = try? await task.value
            Issue.record("did not reach the late-result clock barrier"); return
        }
        if cancel { task.cancel() }
        // The operation started before the barrier, so its deadline has passed.
        else { try await Task.sleep(for: lifetime + .milliseconds(100)) }
        clock.resume()
        if cancel { await #expect(throws: CancellationError.self) { _ = try await task.value } }
        else { #expect(try await task.value.status == 502) }
        #expect(await handler.downloadRecords().isEmpty)
        // Capacity one remains usable, including a possible validated cache hit.
        let next = try await handler.response(to: request())
        #expect(next.status == 200)
        await next.completion?(true)
        #expect(await handler.takeCompletedDownloadRecords().count == 1)
    }
}

/// Actual npm CLI, but ONLY a generated local archive and loopback registry.
/// Empty user/global config, new cache/cwd and an allowlisted environment prevent
/// reading ambient npm credentials or using proxy/configured registry settings.
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/npm"),
               "Optional local npm CLI is not installed; never download it for this test"))
@MainActor func npmCLIExactPinPacksOnlySyntheticArchiveThroughRealLoopbackGateway() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sanjbox-npm-fixture-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let package = folder.appendingPathComponent("package")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
    try Data("{\"name\":\"fixture\",\"version\":\"1.0.0\",\"main\":\"index.js\"}\n".utf8).write(to: package.appendingPathComponent("package.json"))
    try Data("module.exports = 1; // synthetic, never executed\n".utf8).write(to: package.appendingPathComponent("index.js"))
    let archive = folder.appendingPathComponent("upstream.tgz")
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-czf", archive.path, "-C", folder.path, "package"]
    tar.environment = ["PATH": "/usr/bin:/bin", "COPYFILE_DISABLE": "1"]
    try tar.run(); tar.waitUntilExit()
    #expect(tar.terminationStatus == 0)
    let bytes = try Data(contentsOf: archive)
    var document = try JSONSerialization.jsonObject(with: packument(bytes: bytes)) as! [String: Any]
    var versions = document["versions"] as! [String: [String: Any]]
    var young = versions["1.0.0"]!; young["version"] = "2.0.0"
    versions["2.0.0"] = young
    document["versions"] = versions
    document["time"] = ["1.0.0": iso(npmNow.addingTimeInterval(-3600)), "2.0.0": iso(npmNow)]
    document["dist-tags"] = ["latest": "2.0.0"] // absent after filtering; exact pin still works
    let metadata = try JSONSerialization.data(withJSONObject: document)
    let backend = NPMBackend { _, path, _ in NPMWire(body: path.contains("/-/") ? bytes : metadata) }
    let slot = NPMRouteSlot()
    let server = GatewayServer(router: try TypedRouter(routes: [TypedRoute(mount: "/npm", methods: ["GET"]) { try await slot.reply($0) }]))
    let port = try await server.start()
    defer { server.stop() }
    let config = try NPMConfiguration(registryHostname: "registry.example", publicOrigin: "http://127.0.0.1:\(port)", cooldown: 3600)
    let handler = try gateway(backend, config: config)
    await slot.install(handler)
    let working = folder.appendingPathComponent("working")
    try FileManager.default.createDirectory(at: working, withIntermediateDirectories: false)
    for name in ["user.npmrc", "global.npmrc", "stdout", "stderr"] { try Data().write(to: folder.appendingPathComponent(name)) }
    let output = try FileHandle(forWritingTo: folder.appendingPathComponent("stdout"))
    let errors = try FileHandle(forWritingTo: folder.appendingPathComponent("stderr"))
    defer { try? output.close(); try? errors.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/npm")
    process.arguments = ["pack", "fixture@1.0.0", "--registry=http://127.0.0.1:\(port)/npm/", "--ignore-scripts", "--json"]
    process.currentDirectoryURL = working
    process.environment = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "TMPDIR": folder.path,
        "npm_config_userconfig": folder.appendingPathComponent("user.npmrc").path,
        "npm_config_globalconfig": folder.appendingPathComponent("global.npmrc").path,
        "npm_config_cache": folder.appendingPathComponent("cache").path,
        "npm_config_fetch_retries": "0", "npm_config_update_notifier": "false", "npm_config_audit": "false",
        "npm_config_fund": "false", "npm_config_logs_max": "0", "npm_config_progress": "false"]
    process.standardOutput = output; process.standardError = errors
    let timeout = Task {
        do { try await Task.sleep(for: .seconds(15)) } catch { return }
        if process.isRunning { process.terminate() }
    }
    defer { timeout.cancel() }
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do { try process.run() } catch { continuation.resume(throwing: error) }
    }
    #expect(status == 0)
    guard status == 0 else { return }
    let packed = try Data(contentsOf: working.appendingPathComponent("fixture-1.0.0.tgz"))
    #expect(packed == bytes)
    let result = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("stdout"))) as! [[String: Any]]
    #expect(result.first?["integrity"] as? String == sri(bytes))
    let records = await handler.downloadRecords()
    #expect(records.count == 1 && records[0].state == .transportAccepted)
    #expect(backend.calls.allSatisfy { $0.0 == "registry.example" && ($0.1 == "/fixture" || $0.1 == "/fixture/-/fixture-1.0.0.tgz") })
}

@Test func npmCacheEntryAndByteBudgetsEvictRatherThanGrow() async throws {
    for (entries, budget) in [(1, npmBytes.count * 2), (2, npmBytes.count)] {
        let backend = NPMBackend { _, path, _ in
            NPMWire(body: path.contains("/-/") ? npmBytes : try packument(name: String(path.dropFirst())))
        }
        let config = try NPMConfiguration(registryHostname: "registry.example", publicOrigin: "http://127.0.0.1:8765", cooldown: 3600,
                                          maximumCacheBytes: budget, maximumCacheEntries: entries)
        let handler = try gateway(backend, config: config)
        for name in ["first", "second", "first"] {
            #expect(try await handler.response(to: request("/npm/\(name)/-/\(name)-1.0.0.tgz")).status == 200)
        }
        #expect(backend.calls.filter { $0.1.contains("/-/") }.count == 3)
        #expect(await handler.downloadRecords().allSatisfy { !$0.cached })
    }
}

@Test func npmCacheFinalCheckAndCDNHashMismatchRefuseRelease() async throws {
    let good = try packument(); let young = try packument(time: iso(npmNow))
    let changed = NPMBackend { _, path, count in NPMWire(body: path.contains("/-/") ? npmBytes : (count < 5 ? good : young)) }
    let handler = try gateway(changed)
    #expect(try await handler.response(to: request()).status == 200)
    #expect(try await handler.response(to: request()).status == 403) // cache hit, final metadata invalid
    #expect(await handler.downloadRecords().count == 1)
    let corruptCDN = NPMBackend { host, path, _ in
        if host == "cdn.example" { return NPMWire(body: Data("wrong CDN bytes".utf8)) }
        if path.contains("/-/") { return NPMWire(status: 307, headers: ["Location": "https://cdn.example/file.tgz"], body: Data()) }
        return NPMWire(body: good)
    }
    let redirected = try gateway(corruptCDN)
    #expect(try await redirected.response(to: request()).status == 403)
    #expect(await redirected.downloadRecords().isEmpty)
}

private final class NPMClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = npmNow
    func get() -> Date { lock.withLock { value } }
    func set(_ date: Date) { lock.withLock { value = date } }
}
@Test func npmClockRollbackIdentityMismatchAndMissingIntegrityCannotIssue() async throws {
    let metadata = try packument(time: iso(npmNow.addingTimeInterval(-7200)))
    let clock = NPMClock()
    let backend = NPMBackend { _, path, count in
        if count == 3 { clock.set(npmNow.addingTimeInterval(-1)) }
        return NPMWire(body: path.contains("/-/") ? npmBytes : metadata)
    }
    let handler = try gateway(backend, now: { clock.get() })
    #expect(try await handler.response(to: request()).status == 403)
    #expect(await handler.downloadRecords().isEmpty)
    for bad in [try packument(name: "different"), try packument(extras: ["name": "different"]),
                try packument(extras: ["version": "2.0.0"]),
                try packument(extras: ["dist": ["tarball": "https://registry.example/fixture/-/fixture-1.0.0.tgz", "shasum": "0"]]),
                try packument(extras: ["bundleDependencies": ["child"]])] {
        #expect(try await gateway(defaultBackend(metadata: bad)).response(to: request()).status != 200)
    }
}
