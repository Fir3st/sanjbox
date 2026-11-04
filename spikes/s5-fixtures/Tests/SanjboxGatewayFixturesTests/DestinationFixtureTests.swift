import Foundation
import SanjboxGatewayCore
import SanjboxGatewayFixtures
import XCTest

@MainActor final class DestinationFixtureTests: XCTestCase {
    func testRebindingFromPublicToLoopbackLANIPv6AndMixedAnswers() async throws {
        for answers in [["127.0.0.1"], ["192.168.1.2"], ["::1"], ["fd00::1"],
                        ["8.8.8.8", "10.1.2.3"], ["2606:4700:4700::1111", "fe80::1"]] {
            let resolver = try ScriptedResolver([
                DNSAnswer(hostname: "registry.fixture.invalid", addresses: ["8.8.8.8"]),
                DNSAnswer(hostname: "registry.fixture.invalid", addresses: answers),
            ])
            let host = try ScriptedHostAddresses([[], []])
            let policy = DestinationPolicy(hostAddressProvider: host)
            let approved = try await policy.approve(hostname: "registry.fixture.invalid", resolver: resolver)
            XCTAssertEqual(approved.addresses.map(\.text), ["8.8.8.8"])
            do {
                _ = try await policy.approve(hostname: "registry.fixture.invalid", resolver: resolver)
                XCTFail("rebound answer approved: \(answers)")
            } catch { XCTAssertEqual(error as? DestinationFailure, .prohibitedAddress) }
            try await resolver.assertConsumed()
            try host.assertConsumed()
        }
    }

    func testFreshHostSnapshotRejectsAddressThatBecameLocal() async throws {
        let resolver = try ScriptedResolver(Array(repeating:
            DNSAnswer(hostname: "registry.fixture.invalid", addresses: ["8.8.8.8"]), count: 2))
        let host = try ScriptedHostAddresses([[], ["8.8.8.8"]])
        let policy = DestinationPolicy(hostAddressProvider: host)
        _ = try await policy.approve(hostname: "registry.fixture.invalid", resolver: resolver)
        do { _ = try await policy.approve(hostname: "registry.fixture.invalid", resolver: resolver); XCTFail("stale host snapshot") }
        catch { XCTAssertEqual(error as? DestinationFailure, .prohibitedAddress) }
        try host.assertConsumed(); try await resolver.assertConsumed()
    }

    func testResolverAndSnapshotFailuresRemainFailures() async throws {
        let resolver = try ScriptedResolver([DNSAnswer(hostname: "registry.fixture.invalid", addresses: nil)])
        do { _ = try await DestinationPolicy(hostAddresses: []).approve(hostname: "registry.fixture.invalid", resolver: resolver); XCTFail() }
        catch { XCTAssertEqual(error as? FixtureFailure, .scriptedFailure) }
        let successfulDNS = try ScriptedResolver([DNSAnswer(hostname: "registry.fixture.invalid", addresses: ["8.8.8.8"])])
        let failedHost = try ScriptedHostAddresses([nil])
        do { _ = try await DestinationPolicy(hostAddressProvider: failedHost).approve(hostname: "registry.fixture.invalid", resolver: successfulDNS); XCTFail() }
        catch { XCTAssertEqual(error as? FixtureFailure, .scriptedFailure) }
    }

    func testScriptConsumptionHostnameAndLimits() async throws {
        XCTAssertThrowsError(try ScriptedResolver([]))
        XCTAssertThrowsError(try ScriptedHostAddresses([]))
        XCTAssertThrowsError(try DNSAnswer(hostname: "live.example", addresses: ["8.8.8.8"]))
        XCTAssertThrowsError(try DNSAnswer(hostname: "registry.fixture.invalid", addresses: Array(repeating: "8.8.8.8", count: 17)))
        let resolver = try ScriptedResolver([DNSAnswer(hostname: "registry.fixture.invalid", addresses: [])])
        do { try await resolver.assertConsumed(); XCTFail() } catch { XCTAssertEqual(error as? FixtureFailure, .incomplete) }
        do { _ = try await resolver.addresses(for: "cdn.fixture.invalid"); XCTFail() } catch { XCTAssertEqual(error as? FixtureFailure, .unexpectedRequest) }
        do { _ = try await resolver.addresses(for: "registry.fixture.invalid"); XCTFail() } catch { XCTAssertEqual(error as? FixtureFailure, .exhausted) }
        do { try await resolver.assertConsumed(); XCTFail("wrong/excess requests erased") } catch { XCTAssertEqual(error as? FixtureFailure, .incomplete) }
    }

    func testPublicUpstreamClientRejectsBeforeAnySocketCanBeCreated() async throws {
        let resolver = try ScriptedResolver([
            DNSAnswer(hostname: "registry.fixture.invalid", addresses: ["127.0.0.1"]),
            DNSAnswer(hostname: "registry.fixture.invalid", addresses: ["10.0.0.1"]),
        ])
        let host = try ScriptedHostAddresses([[], []])
        let client = UpstreamClient(resolver: resolver, hostAddresses: host)
        let request = try UpstreamRequest(hostname: "registry.fixture.invalid", target: "/fixture-bead")
        for _ in 0..<2 {
            do { _ = try await client.response(for: request); XCTFail("unsafe destination reached transport") }
            catch { XCTAssertEqual(error as? DestinationFailure, .prohibitedAddress) }
        }
        try await resolver.assertConsumed(); try host.assertConsumed()
    }

    func testRedirectFixturesDecodeAsMetadataOnlyAtEveryFragmentBoundary() throws {
        XCTAssertEqual(RedirectFixture.standard.count, 6)
        for fixture in RedirectFixture.standard {
            for split in 1..<fixture.response.count {
                var decoder = UpstreamResponseDecoder()
                _ = try decoder.append(fixture.response.prefix(split))
                _ = try decoder.append(fixture.response.dropFirst(split))
                try decoder.finish()
                XCTAssertEqual(decoder.head?.status, 302)
                XCTAssertEqual(decoder.head?.headers["location"], fixture.location)
            }
        }
        // Does NOT prove a D2 handler safely follows or rejects these redirects.
    }

    func testRedirectDestinationNeedsAnotherPolicyCheck() async throws {
        let resolver = try ScriptedResolver([
            DNSAnswer(hostname: "registry.fixture.invalid", addresses: ["8.8.8.8"]),
            DNSAnswer(hostname: "cdn.fixture.invalid", addresses: ["192.168.0.1"]),
        ])
        let policy = DestinationPolicy(hostAddresses: [])
        _ = try await policy.approve(hostname: "registry.fixture.invalid", resolver: resolver)
        do { _ = try await policy.approve(hostname: "cdn.fixture.invalid", resolver: resolver); XCTFail() }
        catch { XCTAssertEqual(error as? DestinationFailure, .prohibitedAddress) }
        try await resolver.assertConsumed()
    }

    func testPublicPolicyRejectsNonTLSLiteralAndECHWithoutResolverAccess() async throws {
        let resolver = try ScriptedResolver([DNSAnswer(hostname: "registry.fixture.invalid", addresses: ["8.8.8.8"])])
        let policy = DestinationPolicy(hostAddresses: [])
        for (scheme, host, ech, expected): (String, String, Bool, DestinationFailure) in [
            ("http", "registry.fixture.invalid", false, .nonTLS), ("https", "127.0.0.1", false, .ipLiteral),
            ("https", "registry.fixture.invalid", true, .encryptedClientHello),
        ] {
            do { _ = try await policy.approve(scheme: scheme, hostname: host, encryptedClientHello: ech, resolver: resolver); XCTFail() }
            catch { XCTAssertEqual(error as? DestinationFailure, expected) }
        }
        let requests = await resolver.requests
        XCTAssertTrue(requests.isEmpty)
    }
}
