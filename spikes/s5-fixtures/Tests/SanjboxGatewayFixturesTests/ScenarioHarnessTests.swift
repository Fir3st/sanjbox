import Foundation
import SanjboxGatewayFixtures
import XCTest

@MainActor final class ScenarioHarnessTests: XCTestCase {
    func testScenarioInventoryIncludesExactBoundaryScopedAndLocalCases() throws {
        let scenarios = try ArtifactScenario.standard()
        XCTAssertEqual(scenarios.count, 40)
        XCTAssertEqual(Set(scenarios.map(\.id)).count, 40)
        XCTAssertEqual(scenarios.filter { $0.expected == .deliver }.count, 12)
        XCTAssertEqual(scenarios.filter { $0.expected == .denyCooldown }.count, 6)
        XCTAssertEqual(scenarios.filter { $0.expected == .denyUnknownDate }.count, 6)
        XCTAssertEqual(scenarios.filter { $0.expected == .outsideNetworkControl }.count, 16)
        for scenario in scenarios where scenario.input.artifact.key.version == "1.1.0" {
            XCTAssertEqual(scenario.input.artifact.publishedAt, scenario.input.now - scenario.input.cooldown)
        }
    }

    func testVerifierRequiresClosedObservationAndRequestProvenance() throws {
        let scenario = try ArtifactScenario.standard()[0]
        let body = scenario.input.artifact.archive, key = scenario.input.artifact.key
        let empty = try ArtifactObservation(outcome: .delivered(body), exchanges: [], downloadAudits: [key], complete: true, accessEvidence: .directURL)
        XCTAssertEqual(ArtifactHarness.verify(scenario, empty), .incomplete("exactly one observed artifact request required"))
        let unclosed = try ArtifactObservation(outcome: .delivered(body), exchanges: [], downloadAudits: [key], complete: false)
        XCTAssertEqual(ArtifactHarness.verify(scenario, unclosed), .incomplete("unclosed observation"))
        let wrong = try ArtifactExchange(sequence: 0, method: "GET", target: "/npm/other", status: 200, responseBody: body)
        let observation = try ArtifactObservation(outcome: .delivered(body), exchanges: [wrong], downloadAudits: [key], complete: true, accessEvidence: .directURL)
        XCTAssertEqual(ArtifactHarness.verify(scenario, observation), .mismatched("request provenance does not match artifact"))
    }

    func testVerifierDetectsWrongBytesAuditsSequenceAndAmbiguousDelivery() throws {
        let scenario = try ArtifactScenario.standard()[0]
        let key = scenario.input.artifact.key, body = scenario.input.artifact.archive
        func observation(_ bytes: Data, audits: [PackageKey], sequence: Int = 0, count: Int = 1) throws -> ArtifactObservation {
            let exchange = try ArtifactExchange(sequence: sequence, method: "GET", target: key.tarballTarget, status: 200, responseBody: bytes)
            return try ArtifactObservation(outcome: .delivered(bytes), exchanges: Array(repeating: exchange, count: count), downloadAudits: audits, complete: true, accessEvidence: .directURL)
        }
        XCTAssertEqual(ArtifactHarness.verify(scenario, try observation(body, audits: [key])), .matched)
        for value in [try observation(Data("wrong".utf8), audits: [key]),
                      try observation(body, audits: []), try observation(body, audits: [key, key])] {
            XCTAssertEqual(ArtifactHarness.verify(scenario, value), .mismatched("delivery bytes, status, or download audit mismatch"))
        }
        XCTAssertEqual(ArtifactHarness.verify(scenario, try observation(body, audits: [key], sequence: 1)), .incomplete("missing or duplicate sequence"))
        XCTAssertEqual(ArtifactHarness.verify(scenario, try observation(body, audits: [key], count: 2)), .incomplete("missing or duplicate sequence"))
    }

    func testDenialRejectsPartialArtifactLeakAndWrongReason() throws {
        let scenario = try XCTUnwrap(ArtifactScenario.standard().first { $0.expected == .denyCooldown })
        let key = scenario.input.artifact.key
        func value(_ data: Data, denial: ArtifactDenial = .cooldown) throws -> ArtifactObservation {
            try ArtifactObservation(outcome: .denied(denial), exchanges: [ArtifactExchange(sequence: 0, method: "GET", target: key.tarballTarget,
                status: 403, responseBody: data)], downloadAudits: [], complete: true, accessEvidence: .directURL)
        }
        XCTAssertEqual(ArtifactHarness.verify(scenario, try value(Data())), .matched)
        XCTAssertEqual(ArtifactHarness.verify(scenario, try value(scenario.input.artifact.archive.prefix(10))),
                       .mismatched("denial issued artifact or successful download audit"))
        XCTAssertEqual(ArtifactHarness.verify(scenario, try value(Data(), denial: .other)), .incomplete("denial reason not observable"))
        XCTAssertEqual(ArtifactHarness.verify(scenario, try value(Data(), denial: .unknownDate)), .mismatched("unexpected outcome"))
    }

    func testLocalCacheOutcomeNeverMeansGatewayEnforcement() throws {
        let scenario = try XCTUnwrap(ArtifactScenario.standard().first { $0.input.access == .clientCache })
        let local = try ArtifactObservation(outcome: .outsideNetworkControl, exchanges: [], downloadAudits: [], complete: true, accessEvidence: .clientCache)
        XCTAssertEqual(ArtifactHarness.verify(scenario, local), .matched)
        let claimedInstall = try ArtifactObservation(outcome: .delivered(scenario.input.artifact.archive), exchanges: [], downloadAudits: [], complete: true, accessEvidence: .clientCache)
        XCTAssertEqual(ArtifactHarness.verify(scenario, claimedInstall), .mismatched("network policy cannot attest local installation"))
    }

    func testRunnerCallsAdapterWithInputAndPreservesMismatch() async throws {
        let scenario = try ArtifactScenario.standard()[0]
        var calls = 0
        let results = try await ArtifactHarness.run([scenario]) { input in
            calls += 1
            XCTAssertEqual(input.artifact.key, scenario.input.artifact.key)
            return try ArtifactObservation(outcome: .denied(.other), exchanges: [], downloadAudits: [], complete: true, accessEvidence: .directURL)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(results, [.incomplete("exactly one observed artifact request required")])
        do { _ = try await ArtifactHarness.run([scenario, scenario]) { _ in XCTFail("duplicate executed"); throw FixtureFailure.invalidInput }; XCTFail() }
        catch { XCTAssertEqual(error as? FixtureFailure, .duplicate) }
    }

    func testObservationBounds() throws {
        XCTAssertThrowsError(try ArtifactExchange(sequence: 64, method: "GET", target: "/npm/a", status: 200, responseBody: Data()))
        XCTAssertThrowsError(try ArtifactExchange(sequence: 0, method: "GET", target: "/npm/a", status: 200, responseBody: Data(repeating: 1, count: 65_537)))
        XCTAssertThrowsError(try ArtifactObservation(outcome: .delivered(Data(repeating: 1, count: 65_537)), exchanges: [], downloadAudits: [], complete: true, accessEvidence: .directURL))
    }

    func testVerifierRejectsEveryAdditionalPackumentResponseIncludingArtifactLeak() throws {
        let scenario = try XCTUnwrap(ArtifactScenario.standard().first { $0.expected == .denyCooldown })
        let key = scenario.input.artifact.key
        for body in [scenario.input.artifact.archive, Data("{\"unexpected\":true}".utf8), Data()] {
            for status in [200, 403] {
                let exchanges = try [
                    ArtifactExchange(sequence: 0, method: "GET", target: key.packumentTarget, status: status, responseBody: body),
                    ArtifactExchange(sequence: 1, method: "GET", target: key.tarballTarget, status: 403, responseBody: Data()),
                ]
                let observation = try ArtifactObservation(outcome: .denied(.cooldown), exchanges: exchanges,
                    downloadAudits: [], complete: true, accessEvidence: .directURL)
                XCTAssertEqual(ArtifactHarness.verify(scenario, observation), .mismatched("request provenance does not match artifact"))
            }
        }
    }

    func testAccessPathCannotBeInferredFromTerminalHTTPTrace() throws {
        let scenarios = try ArtifactScenario.standard()
        let direct = scenarios[0], body = direct.input.artifact.archive, key = direct.input.artifact.key
        let cached = try XCTUnwrap(scenarios.first { $0.input.artifact.key == key && $0.input.access == .gatewayCache })
        let exchange = try ArtifactExchange(sequence: 0, method: "GET", target: key.tarballTarget, status: 200, responseBody: body)
        func observation(_ evidence: ArtifactAccessEvidence) throws -> ArtifactObservation {
            try ArtifactObservation(outcome: .delivered(body), exchanges: [exchange], downloadAudits: [key], complete: true, accessEvidence: evidence)
        }
        XCTAssertEqual(ArtifactHarness.verify(direct, try observation(.unverified)), .incomplete("access path unverified"))
        XCTAssertEqual(ArtifactHarness.verify(cached, try observation(.directURL)), .mismatched("wrong access path"))
        XCTAssertEqual(ArtifactHarness.verify(cached, try observation(.gatewayCache(seededArtifact: body, upstreamArtifactFetches: 0))), .matched)
        XCTAssertEqual(ArtifactHarness.verify(cached, try observation(.gatewayCache(seededArtifact: body, upstreamArtifactFetches: 1))), .mismatched("gateway cache provenance mismatch"))
        XCTAssertEqual(ArtifactHarness.verify(cached, try observation(.gatewayCache(seededArtifact: Data(), upstreamArtifactFetches: 0))), .mismatched("gateway cache provenance mismatch"))
    }

    func testLockfileEvidenceRequiresExactInputsAndExitOutcome() throws {
        let scenario = try XCTUnwrap(ArtifactScenario.standard().first { $0.input.access == .lockfileCI })
        let key = scenario.input.artifact.key, body = scenario.input.artifact.archive
        let origin = try FixtureOrigin.loopback(port: 12345)
        let project = try RegistryFixtures.standard().project(key: key, origin: origin)
        let exchange = try ArtifactExchange(sequence: 0, method: "GET", target: key.tarballTarget, status: 200, responseBody: body)
        func observation(_ evidence: ArtifactAccessEvidence) throws -> ArtifactObservation {
            try ArtifactObservation(outcome: .delivered(body), exchanges: [exchange], downloadAudits: [key], complete: true, accessEvidence: evidence)
        }
        XCTAssertEqual(ArtifactHarness.verify(scenario, try observation(.lockfileCI(manifest: project.packageJSON, lockfile: project.lockfile, origin: origin, exitStatus: 0))), .matched)
        XCTAssertEqual(ArtifactHarness.verify(scenario, try observation(.lockfileCI(manifest: project.packageJSON, lockfile: Data(), origin: origin, exitStatus: 0))), .mismatched("lockfile provenance mismatch"))
        XCTAssertEqual(ArtifactHarness.verify(scenario, try observation(.lockfileCI(manifest: project.packageJSON, lockfile: project.lockfile, origin: origin, exitStatus: 1))), .mismatched("npm exit mismatch"))
        XCTAssertEqual(ArtifactHarness.verify(scenario, try observation(.directURL)), .mismatched("wrong access path"))
    }

    func testOAuthMockScenarioMatrix() throws {
        let policy = try MockAuthorizationPolicy(expected: MockPrincipal(provider: "provider-a", account: "account-a", zone: "zone-a"), resource: "project-a")
        let scenarios = try OAuthScenario.standard()
        XCTAssertEqual(scenarios.count, 15)
        XCTAssertEqual(Set(scenarios.map(\.id)).count, 15)
        for scenario in scenarios { XCTAssertEqual(policy.evaluate(scenario.input), scenario.expected, scenario.id) }
    }

    func testOAuthSchemaRejectsDuplicatesUnknownScopesAndOversizedInputs() throws {
        XCTAssertThrowsError(try MockGrant(scopes: ["repo:read", "repo:read"], resources: [], expiresAt: 1))
        XCTAssertThrowsError(try MockGrant(scopes: ["repo:read"], resources: ["a", "a"], expiresAt: 1))
        XCTAssertThrowsError(try MockGrant(scopes: ["Repo:read"], resources: ["a"], expiresAt: 1))
        XCTAssertThrowsError(try MockGrant(scopes: [], resources: Array(repeating: "a", count: 17), expiresAt: 1))
        XCTAssertThrowsError(try MockPrincipal(provider: "provider-a", account: String(repeating: "a", count: 81), zone: "zone-a"))
    }
}
