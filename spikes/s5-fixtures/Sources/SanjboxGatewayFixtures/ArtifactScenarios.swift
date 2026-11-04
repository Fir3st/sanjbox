import CryptoKit
import Foundation

public enum ArtifactAccess: String, Sendable, CaseIterable {
    case directURL, lockfileCI, gatewayCache, clientCache, localImport
}
public enum ArtifactExpectation: Sendable, Equatable {
    case deliver, denyCooldown, denyUnknownDate, outsideNetworkControl
}
public struct ArtifactInput: Sendable {
    public let artifact: SyntheticArtifact
    public let access: ArtifactAccess
    public let now: Int64
    public let cooldown: Int64
}
public struct ArtifactScenario: Sendable {
    public let id: String
    public let input: ArtifactInput
    public let expected: ArtifactExpectation

    /// Expected values are literal test oracles, not an implementation of cooldown.
    public static func standard() throws -> [ArtifactScenario] {
        let fixtures = try RegistryFixtures.standard()
        var result: [ArtifactScenario] = []
        let expectations: [String: ArtifactExpectation] = [
            "1.0.0": .deliver, "1.1.0": .deliver, "1.2.0": .denyCooldown, "1.3.0": .denyUnknownDate,
        ]
        for artifact in fixtures.artifacts {
            guard let expected = expectations[artifact.key.version] else { continue }
            for access in ArtifactAccess.allCases {
                let outcome: ArtifactExpectation = [.clientCache, .localImport].contains(access) ? .outsideNetworkControl : expected
                result.append(ArtifactScenario(id: artifact.key.name + "@" + artifact.key.version + ":" + access.rawValue,
                    input: ArtifactInput(artifact: artifact, access: access, now: RegistryFixtures.now,
                                         cooldown: RegistryFixtures.cooldown), expected: outcome))
            }
        }
        return result
    }
}

/// Adapter supplies actual observations; it receives ArtifactInput only, never the expected result.
/// Evidence here remains self-reported test instrumentation, not an authenticated lab protocol.
public enum ArtifactOutcome: Sendable {
    case delivered(Data)
    case denied(ArtifactDenial)
    case outsideNetworkControl
}
public enum ArtifactDenial: Sendable { case cooldown, unknownDate, other }
/// Distinct evidence from adapter instrumentation; these are not authenticated assertions.
/// A terminal HTTP trace alone cannot demonstrate how npm or the gateway cache was used.
public enum ArtifactAccessEvidence: Sendable {
    case unverified
    case directURL
    case lockfileCI(manifest: Data, lockfile: Data, origin: FixtureOrigin, exitStatus: Int32)
    case gatewayCache(seededArtifact: Data, upstreamArtifactFetches: Int)
    case clientCache
    case localImport
}
public struct ArtifactExchange: Sendable {
    public let sequence: Int
    public let method: String
    public let target: String
    public let status: Int
    public let responseBody: Data
    public init(sequence: Int, method: String, target: String, status: Int, responseBody: Data) throws {
        try fixtureCheck((0..<64).contains(sequence) && method == "GET" && (200...599).contains(status))
        try fixtureCheck(target.utf8.count <= 512 && responseBody.count <= 65_536, .limit)
        self.sequence = sequence; self.method = method; self.target = target
        self.status = status; self.responseBody = responseBody
    }
}
public struct ArtifactObservation: Sendable {
    public let outcome: ArtifactOutcome
    public let exchanges: [ArtifactExchange]
    public let downloadAudits: [PackageKey]
    public let complete: Bool
    public let accessEvidence: ArtifactAccessEvidence
    public init(outcome: ArtifactOutcome, exchanges: [ArtifactExchange], downloadAudits: [PackageKey], complete: Bool,
                accessEvidence: ArtifactAccessEvidence = .unverified) throws {
        try fixtureCheck(exchanges.count <= 64 && downloadAudits.count <= 32, .limit)
        try fixtureCheck(exchanges.reduce(0) { $0 + $1.responseBody.count } <= 1_048_576, .limit)
        if case .delivered(let bytes) = outcome { try fixtureCheck(bytes.count <= 65_536, .limit) }
        switch accessEvidence {
        case .lockfileCI(let manifest, let lockfile, _, _):
            try fixtureCheck(manifest.count <= 65_536 && lockfile.count <= 65_536, .limit)
        case .gatewayCache(let bytes, let count):
            try fixtureCheck(bytes.count <= 65_536 && (0...64).contains(count), .limit)
        default: break
        }
        self.outcome = outcome; self.exchanges = exchanges; self.downloadAudits = downloadAudits; self.complete = complete
        self.accessEvidence = accessEvidence
    }
}
public enum ScenarioResult: Sendable, Equatable {
    case matched, mismatched(String), incomplete(String)
}

public enum ArtifactHarness {
    /// Sequential by design: deterministic ordering, no unbounded tasks. Adapters must bound their own I/O.
    public static func run(_ scenarios: [ArtifactScenario], isolation: isolated (any Actor)? = #isolation,
                           observe: (ArtifactInput) async throws -> ArtifactObservation) async throws -> [ScenarioResult] {
        try fixtureCheck(!scenarios.isEmpty && scenarios.count <= 128, .limit)
        try fixtureCheck(Set(scenarios.map(\.id)).count == scenarios.count, .duplicate)
        var results: [ScenarioResult] = []
        for scenario in scenarios {
            try Task.checkCancellation()
            results.append(verify(scenario, try await observe(scenario.input)))
        }
        return results
    }

    public static func verify(_ scenario: ArtifactScenario, _ observation: ArtifactObservation) -> ScenarioResult {
        guard observation.complete else { return .incomplete("unclosed observation") }
        let key = scenario.input.artifact.key
        for (index, exchange) in observation.exchanges.enumerated() {
            guard exchange.sequence == index else { return .incomplete("missing or duplicate sequence") }
            guard exchange.target == key.tarballTarget else {
                return .mismatched("request provenance does not match artifact")
            }
        }
        guard observation.downloadAudits.allSatisfy({ $0 == key }) else { return .mismatched("wrong audit identity") }
        if case .unverified = observation.accessEvidence { return .incomplete("access path unverified") }
        switch (scenario.input.access, observation.accessEvidence) {
        case (.directURL, .directURL), (.clientCache, .clientCache), (.localImport, .localImport): break
        case (.lockfileCI, .lockfileCI(let manifest, let lockfile, let origin, let status)):
            guard origin.mount == "/npm",
                  let fixtures = try? RegistryFixtures(artifacts: [scenario.input.artifact]),
                  let project = try? fixtures.project(key: key, origin: origin),
                  manifest == project.packageJSON, lockfile == project.lockfile else {
                return .mismatched("lockfile provenance mismatch")
            }
            guard (status == 0) == (scenario.expected == .deliver) else { return .mismatched("npm exit mismatch") }
        case (.gatewayCache, .gatewayCache(let seeded, let fetches)):
            guard seeded == scenario.input.artifact.archive, fetches == 0 else {
                return .mismatched("gateway cache provenance mismatch")
            }
        default: return .mismatched("wrong access path")
        }
        if scenario.expected == .outsideNetworkControl {
            guard observation.exchanges.isEmpty && observation.downloadAudits.isEmpty else {
                return .mismatched("local/cache boundary claimed with gateway activity")
            }
            if case .outsideNetworkControl = observation.outcome { return .matched }
            return .mismatched("network policy cannot attest local installation")
        }
        // Only one terminal client->gateway artifact exchange is supported by this oracle.
        // Metadata and other upstream exchanges need their own oracle: never ignore their bodies.
        guard observation.exchanges.count == 1 else { return .incomplete("exactly one observed artifact request required") }
        let response = observation.exchanges[0]
        switch (scenario.expected, observation.outcome) {
        case (.deliver, .delivered(let data)):
            guard response.status == 200, response.responseBody == data,
                  data == scenario.input.artifact.archive, observation.downloadAudits == [key] else {
                return .mismatched("delivery bytes, status, or download audit mismatch")
            }
            return .matched
        case (.denyCooldown, .denied(.cooldown)), (.denyUnknownDate, .denied(.unknownDate)):
            guard response.status == 403, observation.downloadAudits.isEmpty,
                  [Data(), Data("{\"error\":403}\n".utf8)].contains(response.responseBody) else {
                return .mismatched("denial issued artifact or successful download audit")
            }
            return .matched
        default: return .mismatched("unexpected outcome")
        }
    }
}
