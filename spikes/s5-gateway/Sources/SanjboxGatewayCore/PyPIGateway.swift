import Foundation

/// JSON Simple API only; file issuance always reauthorizes. No byte cache,
/// metadata cache, redirects, HEAD, ranges, wheel metadata sidecar or HTML fallback.
public actor PyPIGateway {
    public nonisolated let configuration: PyPIConfiguration
    private let upstream: UpstreamClient
    private let now: @Sendable () -> Date
    private var operations = 0
    private var records: [RegistryDownloadRecord] = []
    private enum Prepared: Sendable {
        case index(Data)
        case file(PyPIArtifact, Data, Date)
    }
    public init(configuration: PyPIConfiguration, upstream: UpstreamClient) {
        self.configuration = configuration; self.upstream = upstream; now = { Date() }
    }
    init(configuration: PyPIConfiguration, upstream: UpstreamClient, now: @escaping @Sendable () -> Date) {
        self.configuration = configuration; self.upstream = upstream; self.now = now
    }
    public nonisolated func route() -> TypedRoute {
        TypedRoute(mount: configuration.mount, methods: ["GET"]) { .response(try await self.response(to: $0)) }
    }
    public func downloadRecords() -> [RegistryDownloadRecord] { records }
    public func takeCompletedDownloadRecords() -> [RegistryDownloadRecord] {
        let complete = records.filter { $0.state != .prepared }
        records.removeAll { $0.state != .prepared }
        return complete
    }
    public func response(to request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        guard request.method == "GET", request.body.isEmpty, registryHeadersAllowed(request) else { return .error(403) }
        guard operations < configuration.limits.operations else { return .error(503, rejection: .capacity) }
        operations += 1
        defer { operations -= 1 }
        do {
            let target = try PyPITarget(request.target, mount: configuration.mount)
            let prepared = try await boundedOperation(timeout: configuration.limits.lifetime) { [self] in try await prepare(target) }
            try Task.checkCancellation()
            switch prepared {
            case .index(let data): return HTTPResponse(contentType: "application/vnd.pypi.simple.v1+json", body: data)
            case .file(let artifact, let data, let started):
                try clockCheck(started)
                guard artifact.eligible(now: now(), cooldown: configuration.cooldown) else { throw RegistryFailure.denied }
                guard records.count < configuration.limits.auditRecords else { throw RegistryFailure.busy }
                let record = RegistryDownloadRecord(id: UUID(), project: artifact.project.value, filename: artifact.filename,
                                                     version: artifact.version, sha256: artifact.sha256, source: artifact.source.absolute, uploadedAt: artifact.published,
                                                     bytes: data.count, preparedAt: now(), state: .prepared)
                records.append(record)
                return HTTPResponse(contentType: "application/octet-stream", body: data, completion: { [self] sent in
                    await finish(record.id, sent: sent)
                })
            }
        } catch is CancellationError { throw CancellationError() }
        catch { return registryError(error) }
    }
    private func prepare(_ target: PyPITarget) async throws -> Prepared {
        let started = now()
        try clockCheck(started)
        switch target {
        case .index(let project):
            let index = try await metadata(project)
            try clockCheck(started)
            return .index(try index.filtered(now: now()))
        case .file(let project, let filename):
            guard records.count < configuration.limits.auditRecords else { throw RegistryFailure.busy }
            let artifact = try await metadata(project).artifact(filename, now: now())
            let response = try await upstream.response(for: UpstreamRequest(hostname: artifact.source.hostname, target: artifact.source.path))
            // Every redirect is refused, including same-origin. No Location can
            // bypass the fresh metadata authorization or turn this into a proxy.
            guard response.head.status == 200, response.body.count == artifact.size,
                  registrySHA256(response.body) == artifact.sha256 else { throw RegistryFailure.denied }
            guard response.body.count <= configuration.limits.artifactBytes else { throw RegistryFailure.tooLarge }
            let fresh = try await metadata(project).artifact(filename, now: now())
            guard fresh == artifact else { throw RegistryFailure.changed }
            try clockCheck(started)
            try Task.checkCancellation()
            return .file(artifact, response.body, started)
        }
    }
    private func metadata(_ project: PyPIName) async throws -> PyPISimpleIndex {
        let response = try await upstream.response(for: UpstreamRequest(hostname: configuration.registryHostname,
            target: "/simple/" + project.value + "/", headers: ["Accept": "application/vnd.pypi.simple.v1+json", "Cache-Control": "no-cache"]))
        guard response.head.status == 200, registryMediaType(response.head) == "application/vnd.pypi.simple.v1+json" else { throw RegistryFailure.metadata }
        return try PyPISimpleIndex(data: response.body, project: project, configuration: configuration)
    }
    private func clockCheck(_ started: Date) throws {
        try Task.checkCancellation()
        let current = now()
        guard started.timeIntervalSince1970.isFinite, current.timeIntervalSince1970.isFinite, current >= started else { throw RegistryFailure.denied }
    }
    private func finish(_ id: UUID, sent: Bool) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].state == .prepared else { return }
        records[index].state = sent ? .transportAccepted : .sendFailed
    }
}
