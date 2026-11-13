import Foundation

/// A capability report, NOT an artifact authorization. The inspected stock
/// formula API has no adopted per-bottle upload timestamp contract. Unknown
/// extension fields (including upload-time) never silently grant that capability.
public struct HomebrewMetadataAssessment: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case missingArtifactPublicationTime, unsupportedBottleIdentity }
    public let formula: String
    public let bottles: Int
    public let reason: Reason
    public var artifactCooldownSupported: Bool { false }
    public static func inspect(_ data: Data, formula: String, maximumBytes: Int = 4_194_304) throws -> Self {
        guard validFormula(formula) else { throw RegistryFailure.target }
        let root = try registryJSON(data, maximum: min(maximumBytes, 4_194_304))
        guard root["name"] as? String == formula, root["tap"] as? String == "homebrew/core",
              let bottle = root["bottle"] as? [String: Any], let stable = bottle["stable"] as? [String: Any],
              let files = stable["files"] as? [String: [String: Any]], files.count <= 128 else { throw RegistryFailure.metadata }
        let supportedIdentity = !files.isEmpty && files.values.allSatisfy { file in
            guard let digest = file["sha256"] as? String, registryValidDigest(digest),
                  let url = file["url"] as? String else { return false }
            // Digest URL on the configured stock bottle domain binds bytes but
            // carries no authenticated publication time. Formula @ is encoded as /.
            let name = formula.replacingOccurrences(of: "@", with: "/")
            return url == "https://ghcr.io/v2/homebrew/core/\(name)/blobs/sha256:\(digest)"
        }
        return Self(formula: formula, bottles: files.count,
                    reason: supportedIdentity ? .missingArtifactPublicationTime : .unsupportedBottleIdentity)
    }
    static func validFormula(_ name: String) -> Bool {
        name.utf8.count <= 128 && name.range(of: #"^[a-z0-9][a-z0-9+_.-]*(@[0-9]+(\.[0-9]+)*)?$"#, options: .regularExpression) != nil && !name.contains("..")
    }
}

/// Explicit deny integration point for HOMEBREW_API_DOMAIN=/brew/api and
/// HOMEBREW_BOTTLE_DOMAIN=/brew/bottles. It never serves install metadata or bytes.
/// This closes the handler, not Homebrew's fallback or the area's network boundary.
public actor HomebrewGateway {
    public nonisolated let mount: String
    private let registryHostname: String
    private let upstream: UpstreamClient
    private let limits: RegistryLimits
    private var operations = 0
    public init(registryHostname: String = "formulae.brew.sh", mount: String = "/brew", upstream: UpstreamClient,
                limits: RegistryLimits = try! RegistryLimits()) throws {
        self.registryHostname = try DestinationPolicy.validatedHostname(registryHostname)
        self.mount = try registryMount(mount); self.upstream = upstream; self.limits = limits
    }
    public nonisolated func route() -> TypedRoute {
        TypedRoute(mount: mount, methods: ["GET"]) { .response(try await self.response(to: $0)) }
    }
    public func response(to request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        guard request.method == "GET", request.body.isEmpty, registryHeadersAllowed(request) else { return .error(403) }
        // All bottles/manifests, JWS/catalogues, casks, taps and source builds deny
        // before upstream. Only a bounded single-formula diagnostic fetch exists.
        let prefix = mount + "/api/formula/"
        guard request.target.hasPrefix(prefix), request.target.hasSuffix(".json") else { return .error(403) }
        let formula = String(request.target.dropFirst(prefix.count).dropLast(5))
        guard HomebrewMetadataAssessment.validFormula(formula) else { return .error(400) }
        guard operations < limits.operations else { return .error(503, rejection: .capacity) }
        operations += 1
        defer { operations -= 1 }
        do {
            _ = try await boundedOperation(timeout: limits.lifetime) { [self] in
                let response = try await upstream.response(for: UpstreamRequest(hostname: registryHostname,
                    target: "/api/formula/\(formula).json", headers: ["Accept": "application/json", "Cache-Control": "no-cache"]))
                guard response.head.status == 200, registryMediaType(response.head) == "application/json" else { throw RegistryFailure.metadata }
                return try HomebrewMetadataAssessment.inspect(response.body, formula: formula, maximumBytes: limits.metadataBytes)
            }
            try Task.checkCancellation()
            return HTTPResponse(status: 403, body: Data(#"{"error":"artifact_publication_time_unverified","supported":false}"#.utf8))
        } catch is CancellationError { throw CancellationError() }
        catch { return registryError(error) }
    }
}
