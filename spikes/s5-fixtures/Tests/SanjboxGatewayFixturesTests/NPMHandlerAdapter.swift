import Foundation
import SanjboxGatewayFixtures
@testable import SanjboxGatewayCore

// Test-only seam: fixed clock and in-memory upstream transport are internal D2/D1 APIs.
// The library and production gateway expose neither injection nor a policy bypass.
struct HandlerUpstreamExchange: Sendable {
    let hostname: String
    let request: HTTPRequest
    let response: Data?
    let failure: FixtureFailure?
}

struct HandlerSeedReceipt: Sendable {
    let metadata: Data
    let exchange: ArtifactExchange
    let upstream: [HandlerUpstreamExchange]
    let downloads: [NPMDownloadRecord]
}

struct HandlerReceipt: Sendable {
    let observation: ArtifactObservation
    let upstream: [HandlerUpstreamExchange]
    let downloads: [NPMDownloadRecord]
    let seed: HandlerSeedReceipt?
    let process: NPMResult?
    let installedManifest: Data?
    let handlerCalls: Int
}

/// Wire responses contain actual serialized fixture metadata/archives. The production
/// UpstreamClient encodes requests and parses these bytes, using its real destination policy.
final class HandlerBackend: @unchecked Sendable {
    enum Fault: Sendable { case none, transport, corruptArtifact, metadataHTTP, cancel }
    private let lock = NSLock()
    let artifact: SyntheticArtifact
    private var metadata: Data
    private var followingMetadata: Data?
    private let fault: Fault
    private var journal: [HandlerUpstreamExchange] = []
    private var overflow = false

    init(artifact: SyntheticArtifact, metadata: Data, fault: Fault = .none, followingMetadata: Data? = nil) {
        self.artifact = artifact; self.metadata = metadata; self.fault = fault
        self.followingMetadata = followingMetadata
    }

    func replaceMetadata(_ value: Data) { lock.withLock { metadata = value } }

    func transcript() throws -> [HandlerUpstreamExchange] {
        try lock.withLock {
            guard !overflow else { throw FixtureFailure.incomplete }
            return journal
        }
    }

    func reply(hostname: String, bytes: Data) throws -> Data {
        try lock.withLock {
            guard journal.count < 64 else { overflow = true; throw FixtureFailure.limit }
            var parser = HTTPRequestDecoder()
            guard let request = try parser.append(bytes) else { throw FixtureFailure.incomplete }
            do {
                guard hostname == "registry.fixture.invalid", request.method == "GET",
                      [artifact.key.upstreamPackumentTarget, artifact.key.upstreamTarballTarget].contains(request.target) else {
                    throw FixtureFailure.unexpectedRequest
                }
                if fault == .cancel { throw CancellationError() }
                if fault == .transport { throw FixtureFailure.scriptedFailure }
                let isMetadata = request.target == artifact.key.upstreamPackumentTarget
                let status = isMetadata && fault == .metadataHTTP ? 503 : 200
                let body: Data
                if isMetadata {
                    body = status == 200 ? metadata : Data("synthetic upstream unavailable".utf8)
                    if let next = followingMetadata { metadata = next; followingMetadata = nil }
                } else {
                    body = fault == .corruptArtifact ? Data("synthetic corrupt archive".utf8) : artifact.archive
                }
                let contentType = isMetadata ? "application/json" : "application/octet-stream"
                let wire = Data("HTTP/1.1 \(status) Fixture\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
                journal.append(HandlerUpstreamExchange(hostname: hostname, request: request, response: wire, failure: nil))
                return wire
            } catch {
                journal.append(HandlerUpstreamExchange(hostname: hostname, request: request, response: nil,
                                                       failure: error as? FixtureFailure))
                throw error
            }
        }
    }
}

private struct HandlerHosts: HostAddressProvider {
    func addresses() throws -> Set<SanjboxGatewayCore.IPAddress> { [] }
}
private struct HandlerDNS: DestinationResolver {
    func addresses(for hostname: String) async throws -> [SanjboxGatewayCore.IPAddress] {
        guard hostname == "registry.fixture.invalid" else { throw FixtureFailure.unexpectedRequest }
        // Policy-approved test address only. HandlerDialer never opens a socket.
        return [try SanjboxGatewayCore.IPAddress("8.8.8.8")]
    }
}
private struct HandlerDialer: UpstreamDialer {
    let backend: HandlerBackend
    func connection(to destination: ApprovedDestination) throws -> any UpstreamConnection {
        guard destination.hostname == "registry.fixture.invalid", destination.port == 443,
              destination.addresses.map(\.text) == ["8.8.8.8"] else { throw FixtureFailure.unexpectedRequest }
        return HandlerConnection(backend: backend, hostname: destination.hostname)
    }
}
private final class HandlerConnection: UpstreamConnection, @unchecked Sendable {
    let backend: HandlerBackend
    let hostname: String
    private let lock = NSLock()
    private var pending = Data()
    private var sent = false
    private var cancelled = false
    init(backend: HandlerBackend, hostname: String) { self.backend = backend; self.hostname = hostname }
    func start(timeout: Duration) async throws { try Task.checkCancellation() }
    func send(_ bytes: Data, timeout: Duration) async throws {
        try Task.checkCancellation()
        try lock.withLock {
            guard !sent, !cancelled else { throw FixtureFailure.unexpectedRequest }
            sent = true
            pending = try backend.reply(hostname: hostname, bytes: bytes)
        }
    }
    func receive(timeout: Duration) async throws -> ReceivedBytes {
        try Task.checkCancellation()
        return try lock.withLock {
            guard sent, !cancelled else { throw FixtureFailure.unexpectedRequest }
            // Multiple chunks exercise the real upstream framing/parser, not a canned HTTPResponse.
            let part = Data(pending.prefix(257))
            pending.removeFirst(part.count)
            return ReceivedBytes(data: part, endOfStream: pending.isEmpty)
        }
    }
    func cancel() { lock.withLock { cancelled = true } }
}

actor HandlerRecorder {
    private var handler: NPMGateway?
    private var journal: [ArtifactExchange] = []
    private var overflow = false
    func configure(_ handler: NPMGateway) throws {
        guard self.handler == nil else { throw FixtureFailure.invalidInput }
        self.handler = handler
    }
    nonisolated var route: TypedRoute {
        TypedRoute(mount: "/npm", methods: ["GET"]) { .response(try await self.response(to: $0)) }
    }
    func response(to request: HTTPRequest) async throws -> HTTPResponse {
        guard let handler else { throw FixtureFailure.incomplete }
        guard journal.count < 64 else { overflow = true; throw FixtureFailure.limit }
        let response = try await handler.response(to: request)
        journal.append(try ArtifactExchange(sequence: journal.count, method: request.method, target: request.target,
                                            status: response.status, responseBody: response.body))
        return response // preserve the original transport completion callback
    }
    func transcript() throws -> [ArtifactExchange] {
        guard !overflow else { throw FixtureFailure.incomplete }
        return journal
    }
}

@MainActor enum NPMHandlerAdapter {
    static func makeHandler(input: ArtifactInput, backend: HandlerBackend, origin: FixtureOrigin) throws -> NPMGateway {
        let upstream = UpstreamClient(resolver: HandlerDNS(), hostAddresses: HandlerHosts(),
                                      dialer: HandlerDialer(backend: backend),
                                      limits: UpstreamLimits(lifetime: .seconds(5)))
        return NPMGateway(configuration: try NPMConfiguration(registryHostname: "registry.fixture.invalid",
            publicOrigin: origin.value, cooldown: Double(input.cooldown), lifetime: .seconds(5)),
            upstream: upstream, now: { Date(timeIntervalSince1970: Double(input.now)) })
    }

    /// Receives no ArtifactScenario or expected outcome. Errors/cancellation propagate.
    /// Optional npm routes require the explicit installed-tool selectors in NPMRun.
    static func observe(_ input: ArtifactInput, fault: HandlerBackend.Fault = .none,
                        followingMetadata: Data? = nil) async throws -> HandlerReceipt {
        let artifact = input.artifact, key = artifact.key
        let metadata = try RegistryFixtures(artifacts: [artifact]).packument(name: key.name)
        let backend = HandlerBackend(artifact: artifact, metadata: metadata, fault: fault, followingMetadata: followingMetadata)
        let recorder = HandlerRecorder()
        let needsNPM = [.lockfileCI, .clientCache, .localImport].contains(input.access)
        let run = try needsNPM ? NPMRun() : nil
        defer { run?.cleanup() }
        let server = try needsNPM ? GatewayServer(router: TypedRouter(routes: [recorder.route])) : nil
        let port = try await server?.start() ?? 12345
        defer { server?.stop() }
        let origin = try FixtureOrigin.loopback(port: port)
        let handler = try makeHandler(input: input, backend: backend, origin: origin)
        try await recorder.configure(handler)

        var seed: HandlerSeedReceipt?
        if input.access == .gatewayCache {
            // Seed through a real successful handler call at the same fixed time. Keep an
            // already eligible date unchanged; otherwise use the exact eligible cutoff.
            // Then restore the scenario's authoritative metadata, including missing dates.
            let cutoff = input.now - input.cooldown
            let seedArtifact = try SyntheticArtifact(key: key, publishedAt: min(artifact.publishedAt ?? cutoff, cutoff))
            let seedMetadata = try RegistryFixtures(artifacts: [seedArtifact]).packument(name: key.name)
            backend.replaceMetadata(seedMetadata)
            let reply = try await recorder.response(to: request(key.tarballTarget))
            let seedExchanges = try await recorder.transcript(), seedDownloads = await handler.downloadRecords()
            guard reply.status == 200, reply.body == artifact.archive,
                  seedExchanges.count == 1, seedDownloads.count == 1, !seedDownloads[0].cached else {
                throw FixtureFailure.incomplete
            }
            seed = HandlerSeedReceipt(metadata: seedMetadata, exchange: seedExchanges[0],
                                      upstream: try backend.transcript(), downloads: seedDownloads)
            backend.replaceMetadata(metadata)
        }
        let exchangeStart = try await recorder.transcript().count
        let upstreamStart = try backend.transcript().count
        let auditStart = await handler.downloadRecords().count
        var process: NPMResult?
        var installed: Data?
        let evidence: ArtifactAccessEvidence
        switch input.access {
        case .directURL:
            _ = try await recorder.response(to: request(key.tarballTarget))
            evidence = .directURL
        case .gatewayCache:
            _ = try await recorder.response(to: request(key.tarballTarget))
            let newUpstream = Array(try backend.transcript().dropFirst(upstreamStart))
            guard let seed else { throw FixtureFailure.incomplete }
            evidence = .gatewayCache(seededArtifact: seed.exchange.responseBody,
                upstreamArtifactFetches: newUpstream.filter { $0.request.target == key.upstreamTarballTarget }.count)
        case .lockfileCI:
            guard let run else { throw FixtureFailure.incomplete }
            try run.prepare(RegistryFixtures(artifacts: [artifact]).project(key: key, origin: origin))
            process = try await run.ci(origin: origin)
            if FileManager.default.fileExists(atPath: run.project.appendingPathComponent("node_modules/\(key.name)/package.json").path) {
                installed = try run.installedManifest(key)
            }
            evidence = .lockfileCI(manifest: try Data(contentsOf: run.project.appendingPathComponent("package.json")),
                                  lockfile: try Data(contentsOf: run.project.appendingPathComponent("package-lock.json")),
                                  origin: origin, exitStatus: process!.status)
        case .clientCache:
            guard let run else { throw FixtureFailure.incomplete }
            try run.prepare(RegistryFixtures(artifacts: [artifact]).project(key: key, origin: origin))
            let cacheSeed = try await run.seedCache(artifact, origin: origin)
            guard cacheSeed.status == 0 else { throw FixtureFailure.incomplete }
            process = try await run.ci(origin: origin, offline: true)
            installed = try run.installedManifest(key)
            evidence = .clientCacheInstallation(manifest: installed!, exitStatus: process!.status)
        case .localImport:
            guard let run else { throw FixtureFailure.incomplete }
            process = try await run.localImport(artifact, origin: origin)
            installed = try run.installedManifest(key)
            evidence = .localImportInstallation(manifest: installed!, exitStatus: process!.status)
        }
        // On the socket path only, let GatewayServer record its real completion. Never
        // synthesize transportAccepted by calling a completion closure from this adapter.
        if needsNPM {
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while await handler.downloadRecords().contains(where: { $0.state == .prepared }) {
                guard ContinuousClock.now < deadline else { throw FixtureFailure.incomplete }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        let allExchanges = try await recorder.transcript()
        let exchanges = try allExchanges.dropFirst(exchangeStart).enumerated().map { index, value in
            try ArtifactExchange(sequence: index, method: value.method, target: value.target,
                                 status: value.status, responseBody: value.responseBody)
        }
        let downloads = Array(await handler.downloadRecords().dropFirst(auditStart))
        let upstream = Array(try backend.transcript().dropFirst(upstreamStart))
        let outcome: ArtifactOutcome
        switch input.access {
        case .clientCache, .localImport: outcome = .outsideNetworkControl
        default:
            guard let terminal = exchanges.last else { throw FixtureFailure.incomplete }
            // Generic 403 never tells us cooldown versus unknown date versus another cause.
            outcome = terminal.status == 200 ? .delivered(terminal.responseBody) : .denied(.other)
        }
        return HandlerReceipt(observation: try ArtifactObservation(outcome: outcome, exchanges: exchanges,
            downloadAudits: downloads.map { try PackageKey(name: $0.package, version: $0.version) },
            complete: true, accessEvidence: evidence), upstream: upstream, downloads: downloads,
            seed: seed, process: process, installedManifest: installed, handlerCalls: allExchanges.count)
    }

    static func request(_ target: String) -> HTTPRequest {
        HTTPRequest(method: "GET", target: target, headers: [:], body: Data())
    }
}
