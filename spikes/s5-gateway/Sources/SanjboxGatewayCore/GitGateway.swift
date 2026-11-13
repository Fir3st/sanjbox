import Foundation

public struct GitConfiguration: Sendable {
    public let hostname: String
    public let repositoryPath: String
    public let mount: String
    public let allowPush: Bool
    public let maximumRequestBytes: Int
    public let limits: RegistryLimits
    /// One exact upstream repository, bound by the trusted owner to one project.
    /// No credentials or real external identity are supported in this spike.
    public init(hostname: String, repositoryPath: String, mount: String = "/git", allowPush: Bool = false,
                maximumRequestBytes: Int = 1_048_576, limits: RegistryLimits = try! RegistryLimits()) throws {
        let parts = repositoryPath.split(separator: "/", omittingEmptySubsequences: false)
        guard repositoryPath.utf8.count <= 512, repositoryPath.hasSuffix(".git"), parts.count >= 2, parts[0].isEmpty,
              parts.dropFirst().allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.allSatisfy {
                      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || "-_.".utf8.contains($0)
                  }
              }), (1...1_048_576).contains(maximumRequestBytes) else { throw RegistryFailure.configuration }
        self.hostname = try DestinationPolicy.validatedHostname(hostname)
        self.repositoryPath = repositoryPath; self.mount = try registryMount(mount); self.allowPush = allowPush
        self.maximumRequestBytes = maximumRequestBytes; self.limits = limits
    }
}

/// Fixed-project Smart HTTP v0 transport. Pack data is opaque and bounded; the
/// trusted Git server validates refs/objects. No SSH, LFS, dumb HTTP, protocol v2,
/// redirect, gzip, arbitrary auth, upstream URL or secondary repo can be selected.
public actor GitGateway {
    public nonisolated let configuration: GitConfiguration
    private let upstream: UpstreamClient
    private var operations = 0
    public init(configuration: GitConfiguration, upstream: UpstreamClient) {
        self.configuration = configuration; self.upstream = upstream
    }
    public nonisolated func route() -> TypedRoute {
        TypedRoute(mount: configuration.mount, methods: ["GET", "POST"]) { .response(try await self.response(to: $0)) }
    }
    public func response(to request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        guard registryHeadersAllowed(request), !request.headers.keys.contains(where: { $0.lowercased() == "git-protocol" }) else { return .error(403) }
        guard operations < configuration.limits.operations else { return .error(503, rejection: .capacity) }
        operations += 1
        defer { operations -= 1 }
        do {
            let operation = try operation(request)
            return try await boundedOperation(timeout: configuration.limits.lifetime) { [self] in
                let response = try await upstream.response(for: UpstreamRequest(hostname: configuration.hostname,
                    method: request.method, target: configuration.repositoryPath + operation.suffix,
                    headers: operation.headers, body: request.body))
                guard response.head.status == 200, registryMediaType(response.head) == operation.responseType,
                      !response.body.isEmpty else { throw RegistryFailure.denied }
                guard response.body.count <= configuration.limits.artifactBytes else { throw RegistryFailure.tooLarge }
                try Task.checkCancellation()
                // No upstream headers, Location or WWW-Authenticate leave this handler.
                return HTTPResponse(contentType: operation.responseType, body: response.body)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { return registryError(error) }
    }
    private struct Operation { let suffix: String; let headers: [String: String]; let responseType: String }
    private func operation(_ request: HTTPRequest) throws -> Operation {
        let prefix = configuration.mount + "/project.git"
        for service in ["git-upload-pack", "git-receive-pack"] {
            if request.target == prefix + "/info/refs?service=" + service {
                guard request.method == "GET", request.body.isEmpty else { throw RegistryFailure.denied }
                guard service != "git-receive-pack" || configuration.allowPush else { throw RegistryFailure.denied }
                return Operation(suffix: "/info/refs?service=" + service,
                    headers: ["Accept": "application/x-\(service)-advertisement", "Cache-Control": "no-cache"],
                    responseType: "application/x-\(service)-advertisement")
            }
            if request.target == prefix + "/" + service {
                guard request.method == "POST", !request.body.isEmpty else { throw RegistryFailure.denied }
                guard service != "git-receive-pack" || configuration.allowPush else { throw RegistryFailure.denied }
                guard request.body.count <= configuration.maximumRequestBytes else { throw RegistryFailure.tooLarge }
                let types = request.headers.filter { $0.key.lowercased() == "content-type" }
                guard types.count == 1, types.first?.value == "application/x-\(service)-request" else { throw RegistryFailure.denied }
                return Operation(suffix: "/" + service,
                    headers: ["Content-Type": "application/x-\(service)-request", "Accept": "application/x-\(service)-result", "Cache-Control": "no-cache"],
                    responseType: "application/x-\(service)-result")
            }
        }
        throw RegistryFailure.target
    }
}
