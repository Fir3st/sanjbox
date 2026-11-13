import Foundation

public struct NPMDownloadRecord: Sendable, Codable, Equatable {
    public enum State: String, Sendable, Codable { case prepared, transportAccepted, sendFailed }
    public let id: UUID
    public let package: String
    public let version: String
    public let integrity: String
    public let source: String
    public let bytes: Int
    public let cached: Bool
    public let preparedAt: Date
    public var state: State
}

/// Read-only npm subset. All I/O uses the shared D1 client; no client URL/auth,
/// URLSession, metadata cache, automatic redirects, or unverified streaming.
public actor NPMGateway {
    public nonisolated let configuration: NPMConfiguration
    private let upstream: UpstreamClient
    private let now: @Sendable () -> Date
    private var operations = 0
    private struct CacheEntry { let artifact: NPMArtifact; let bytes: Data }
    private var cache: [String: CacheEntry] = [:]
    private var insertionOrder: [String] = []
    private var cacheBytes = 0
    private var downloads: [NPMDownloadRecord] = []
    private enum PreparedResponse: Sendable {
        case metadata(HTTPResponse)
        case tarball(HTTPResponse, NPMDownloadRecord, NPMArtifact, Date)
    }

    public init(configuration: NPMConfiguration, upstream: UpstreamClient) {
        self.configuration = configuration
        self.upstream = upstream
        now = { Date() }
    }

    init(configuration: NPMConfiguration, upstream: UpstreamClient, now: @escaping @Sendable () -> Date) {
        self.configuration = configuration
        self.upstream = upstream
        self.now = now
    }

    public nonisolated func route() -> TypedRoute {
        TypedRoute(mount: configuration.mount, methods: ["GET"]) { request in
            .response(try await self.response(to: request))
        }
    }

    public func downloadRecords() -> [NPMDownloadRecord] { downloads }

    /// Trusted owner exports these records; pending sends remain in the actor.
    /// Capacity exhaustion refuses another download rather than losing history.
    public func takeCompletedDownloadRecords() -> [NPMDownloadRecord] {
        let complete = downloads.filter { $0.state != .prepared }
        downloads.removeAll { $0.state != .prepared }
        return complete
    }

    public func response(to request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let forbidden: Set<String> = ["authorization", "proxy-authorization", "cookie", "x-api-key", "api-key", "range"]
        guard request.method == "GET", request.body.isEmpty,
              request.headers.keys.allSatisfy({ !forbidden.contains($0.lowercased()) }) else { return .error(403) }
        guard operations < configuration.maximumOperations else { return .error(503, rejection: .capacity) }
        operations += 1
        defer { operations -= 1 }
        do {
            let target = try NPMTarget(request.target, mount: configuration.mount)
            let prepared = try await boundedOperation(timeout: configuration.lifetime) { [self] in
                try await perform(target)
            }
            try Task.checkCancellation()
            switch prepared {
            case .metadata(let response): return response
            case .tarball(let response, let record, let artifact, let started):
                try checkClock(started)
                guard artifact.eligible(now: now(), cooldown: configuration.cooldown) else { throw NPMFailure.ineligible }
                // Publish only after the timeout child has successfully returned.
                // A discarded child result must not leave an orphan prepared
                // record that permanently consumes the bounded audit capacity.
                guard downloads.count < configuration.maximumAuditRecords else { throw NPMFailure.busy }
                try Task.checkCancellation()
                downloads.append(record)
                return HTTPResponse(contentType: response.contentType, body: response.body, completion: { [self] sent in
                    await finish(record.id, sent: sent)
                })
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as NPMFailure {
            switch error {
            case .target: return .error(400)
            case .tooLarge: return .error(413)
            case .busy: return .error(503, rejection: .capacity)
            case .metadata: return .error(502)
            default: return .error(403)
            }
        } catch { return .error(502) }
    }

    private func perform(_ target: NPMTarget) async throws -> PreparedResponse {
        let started = now()
        switch target {
        case .packument(let name):
            let body = try await metadata(name)
            try checkClock(started)
            return .metadata(HTTPResponse(body: try NPMPackument(data: body, expectedName: name, configuration: configuration).filtered(now: now())))
        case .tarball(let name, let version):
            // Reserve bounded operation memory, but do not audit until the bytes
            // are validated and ready. Actor reentrancy is checked again at issue.
            guard downloads.count < configuration.maximumAuditRecords else { throw NPMFailure.busy }
            let artifact = try await authorize(name, version: version)
            let key = name.value + "@" + version
            let bytes: Data
            let cached: Bool
            if let entry = cache[key], entry.artifact == artifact {
                bytes = entry.bytes
                cached = true
            } else {
                removeCache(key)
                bytes = try await download(artifact)
                cached = false
            }
            try Task.checkCancellation()
            // Fresh authoritative metadata after the asynchronous fetch/cache
            // lookup, and immediately before releasing any bytes to the client.
            let final = try await authorize(name, version: version)
            guard final == artifact else { removeCache(key); throw NPMFailure.changed }
            try checkClock(started)
            guard artifact.eligible(now: now(), cooldown: configuration.cooldown) else { throw NPMFailure.ineligible }
            try artifact.integrity.verify(bytes)
            try Task.checkCancellation()
            guard downloads.count < configuration.maximumAuditRecords else { throw NPMFailure.busy }
            if !cached { insertCache(key, artifact: artifact, bytes: bytes) }
            let draft = NPMDownloadRecord(id: UUID(), package: name.value, version: version,
                                          integrity: artifact.integrity.text, source: artifact.source.absolute,
                                          bytes: bytes.count, cached: cached, preparedAt: now(), state: .prepared)
            return .tarball(HTTPResponse(contentType: "application/octet-stream", body: bytes), draft, artifact, started)
        }
    }

    private func checkClock(_ started: Date) throws {
        try Task.checkCancellation()
        guard now().timeIntervalSince1970.isFinite, now() >= started else { throw NPMFailure.ineligible }
    }

    private func metadata(_ name: NPMName) async throws -> Data {
        let request = try UpstreamRequest(hostname: configuration.registryHostname, target: "/" + name.encoded,
                                          headers: ["Accept": "application/json", "Cache-Control": "no-cache"])
        let result = try await upstream.response(for: request)
        try Task.checkCancellation()
        // No abbreviated install-v1 metadata (it lacks authoritative time), no
        // redirect or 304 using an old decision, no content sniffing.
        guard result.head.status == 200,
              result.head.headers["content-type"]?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/json" else { throw NPMFailure.metadata }
        guard result.body.count <= configuration.maximumMetadataBytes else { throw NPMFailure.tooLarge }
        return result.body
    }

    private func authorize(_ name: NPMName, version: String) async throws -> NPMArtifact {
        let body = try await metadata(name)
        return try NPMPackument(data: body, expectedName: name, configuration: configuration).artifact(version: version, now: now())
    }

    private func download(_ artifact: NPMArtifact) async throws -> Data {
        var location = artifact.source
        var visited = Set<NPMArtifactURL>()
        for hop in 0...configuration.maximumRedirects {
            try Task.checkCancellation()
            guard visited.insert(location).inserted else { throw NPMFailure.redirect }
            let result = try await upstream.response(for: UpstreamRequest(hostname: location.hostname, target: location.path))
            if [301, 302, 303, 307, 308].contains(result.head.status) {
                guard hop < configuration.maximumRedirects, let raw = result.head.headers["location"] else { throw NPMFailure.redirect }
                let next = try NPMArtifactURL(raw, allowedHosts: configuration.artifactHostnames)
                let fresh = try await authorize(artifact.name, version: artifact.version)
                guard fresh == artifact else { throw NPMFailure.changed }
                location = next
                // The next request resolves/validates/dials anew, even same host.
                continue
            }
            guard result.head.status == 200, !result.body.isEmpty else { throw NPMFailure.ineligible }
            guard result.body.count <= configuration.maximumArtifactBytes else { throw NPMFailure.tooLarge }
            try artifact.integrity.verify(result.body)
            return result.body
        }
        throw NPMFailure.redirect
    }

    private func finish(_ id: UUID, sent: Bool) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[index].state = sent ? .transportAccepted : .sendFailed
    }
    private func removeCache(_ key: String) {
        if let old = cache.removeValue(forKey: key) { cacheBytes -= old.bytes.count }
        insertionOrder.removeAll { $0 == key }
    }
    private func insertCache(_ key: String, artifact: NPMArtifact, bytes: Data) {
        guard configuration.maximumCacheEntries > 0, bytes.count <= configuration.maximumCacheBytes else { return }
        removeCache(key)
        while cache.count >= configuration.maximumCacheEntries || cacheBytes > configuration.maximumCacheBytes - bytes.count {
            guard let oldest = insertionOrder.first else { return }
            removeCache(oldest)
        }
        cache[key] = CacheEntry(artifact: artifact, bytes: bytes)
        insertionOrder.append(key)
        cacheBytes += bytes.count
    }
}
