import Foundation
@testable import SanjboxGatewayFixtures
@testable import SanjboxGatewayCore
import XCTest

@MainActor final class NPMHandlerIntegrationTests: XCTestCase {
    func testDirectAndGatewayCacheMatricesExerciseSixteenActualHandlerScenarios() async throws {
        let scenarios = try ArtifactScenario.standard().filter { [.directURL, .gatewayCache].contains($0.input.access) }
        var receipts: [HandlerReceipt] = []
        let results = try await ArtifactHarness.run(scenarios) { input in
            let receipt = try await NPMHandlerAdapter.observe(input)
            receipts.append(receipt)
            return receipt.observation
        }
        XCTAssertEqual(scenarios.count, 16)
        XCTAssertEqual(results.filter { $0 == .matched }.count, 8)
        XCTAssertEqual(results.filter { $0 == .incomplete("denial reason not observable") }.count, 8)
        for (index, scenario) in scenarios.enumerated() {
            try assertReceipt(receipts[index], for: scenario, result: results[index])
        }
    }

    func testFixedClockAtCutoffAndOneSecondLaterChangesActualDecision() async throws {
        let scenario = try XCTUnwrap(ArtifactScenario.standard().first {
            $0.input.access == .directURL && $0.input.artifact.key.version == "1.2.0"
        })
        let before = try await NPMHandlerAdapter.observe(scenario.input)
        XCTAssertEqual(before.observation.exchanges.map(\.status), [403])
        let after = try await NPMHandlerAdapter.observe(ArtifactInput(artifact: scenario.input.artifact,
            access: .directURL, now: scenario.input.now + 1, cooldown: scenario.input.cooldown))
        XCTAssertEqual(after.observation.exchanges.map(\.status), [200])
        XCTAssertEqual(after.downloads.map(\.preparedAt), [Date(timeIntervalSince1970: Double(scenario.input.now + 1))])
        // The unchanged oracle catches a deliberately different observation. Neither the
        // adapter nor the handler is told that the original scenario expected refusal.
        XCTAssertEqual(ArtifactHarness.verify(scenario, after.observation), .mismatched("unexpected outcome"))
    }

    func testActualPackumentFiltersBothNamesAtDeterministicBoundary() async throws {
        let fixtures = try RegistryFixtures.standard()
        for name in ["fixture-bead", "@fixture/bead"] {
            let input = try XCTUnwrap(ArtifactScenario.standard().first { $0.input.artifact.key.name == name }).input
            let metadata = try fixtures.packument(name: name)
            let backend = HandlerBackend(artifact: input.artifact, metadata: metadata)
            let handler = try NPMHandlerAdapter.makeHandler(input: input, backend: backend, origin: .loopback(port: 12345))
            let response = try await handler.response(to: NPMHandlerAdapter.request(input.artifact.key.packumentTarget))
            XCTAssertEqual(response.status, 200)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            let versions = try XCTUnwrap(root["versions"] as? [String: [String: Any]])
            XCTAssertEqual(Set(versions.keys), ["1.0.0", "1.1.0"])
            XCTAssertEqual(root["dist-tags"] as? [String: String], [:], "latest points to unknown-date fixture and must disappear")
            for version in ["1.0.0", "1.1.0"] {
                let key = try PackageKey(name: name, version: version)
                let dist = try XCTUnwrap(versions[version]?["dist"] as? [String: String])
                XCTAssertEqual(dist["integrity"], try fixtures.artifact(key).integrity)
                XCTAssertEqual(dist["tarball"], "http://127.0.0.1:12345" + key.tarballTarget.replacingOccurrences(of: "@fixture/", with: "@fixture%2f"))
            }
            XCTAssertEqual(try backend.transcript().map { $0.request.target }, [input.artifact.key.upstreamPackumentTarget])
            let records = await handler.downloadRecords()
            XCTAssertTrue(records.isEmpty)
        }
    }

    func testMetadataChangeAfterFetchIsNotMistakenForExpectedDelivery() async throws {
        let scenario = try directScenario(version: "1.0.0")
        let changed = try SyntheticArtifact(key: scenario.input.artifact.key, publishedAt: scenario.input.now)
        let metadata = try RegistryFixtures(artifacts: [changed]).packument(name: changed.key.name)
        let receipt = try await NPMHandlerAdapter.observe(scenario.input, followingMetadata: metadata)
        XCTAssertEqual(receipt.observation.exchanges.map(\.status), [403])
        XCTAssertTrue(receipt.downloads.isEmpty)
        XCTAssertEqual(receipt.upstream.map { $0.request.target }, [changed.key.upstreamPackumentTarget, changed.key.upstreamTarballTarget, changed.key.upstreamPackumentTarget])
        XCTAssertEqual(try responseBody(receipt.upstream.last!), metadata)
        XCTAssertEqual(ArtifactHarness.verify(scenario, receipt.observation), .mismatched("unexpected outcome"))
    }

    func testCorruptArtifactAndTransportFailuresRemainCounterexamples() async throws {
        let delivery = try directScenario(version: "1.0.0")
        let corrupt = try await NPMHandlerAdapter.observe(delivery.input, fault: .corruptArtifact)
        XCTAssertEqual(corrupt.observation.exchanges.map(\.status), [403])
        XCTAssertTrue(corrupt.downloads.isEmpty)
        XCTAssertEqual(corrupt.upstream.count, 2)
        XCTAssertEqual(try responseBody(corrupt.upstream[1]), Data("synthetic corrupt archive".utf8))
        XCTAssertEqual(ArtifactHarness.verify(delivery, corrupt.observation), .mismatched("unexpected outcome"))
        for scenario in [delivery, try directScenario(version: "1.2.0")] {
            for fault: HandlerBackend.Fault in [.transport, .metadataHTTP] {
                let receipt = try await NPMHandlerAdapter.observe(scenario.input, fault: fault)
                XCTAssertEqual(receipt.observation.exchanges.map(\.status), [502])
                XCTAssertTrue(receipt.downloads.isEmpty)
                XCTAssertEqual(receipt.upstream.count, 1)
                if fault == .transport { XCTAssertEqual(receipt.upstream[0].failure, .scriptedFailure) }
                if case .mismatched = ArtifactHarness.verify(scenario, receipt.observation) {} else {
                    XCTFail("transport error must not turn into a matched or incomplete cooldown denial")
                }
            }
        }
    }

    func testAdapterPropagatesHandlerCancellation() async throws {
        let scenario = try directScenario(version: "1.0.0")
        do {
            _ = try await NPMHandlerAdapter.observe(scenario.input, fault: .cancel)
            XCTFail("cancelled actual handler was converted into an observation")
        } catch is CancellationError {} catch { XCTFail("wrong error: \(error)") }
    }

    func testGenericDenialNeverHidesLeakedBytesAuditOrBadStatus() async throws {
        for version in ["1.2.0", "1.3.0"] {
            let scenario = try directScenario(version: version)
            let actual = try await NPMHandlerAdapter.observe(scenario.input)
            XCTAssertEqual(ArtifactHarness.verify(scenario, actual.observation), .incomplete("denial reason not observable"))
            for (status, body, audits): (Int, Data, [PackageKey]) in [
                (403, Data(scenario.input.artifact.archive.prefix(1)), []),
                (403, scenario.input.artifact.archive, []),
                (403, actual.observation.exchanges[0].responseBody, [scenario.input.artifact.key]),
                (502, Data(), []),
            ] {
                let exchange = try ArtifactExchange(sequence: 0, method: "GET", target: scenario.input.artifact.key.tarballTarget,
                                                    status: status, responseBody: body)
                let observation = try ArtifactObservation(outcome: .denied(.other), exchanges: [exchange],
                    downloadAudits: audits, complete: true, accessEvidence: .directURL)
                XCTAssertEqual(ArtifactHarness.verify(scenario, observation), .mismatched("denial issued artifact or successful download audit"))
            }
        }
    }

    func testLocalProcessReceiptsRejectWrongManifestAndExit() throws {
        for access: ArtifactAccess in [.clientCache, .localImport] {
            let scenario = try XCTUnwrap(ArtifactScenario.standard().first { $0.input.access == access })
            for (manifest, status): (Data, Int32) in [(Data(), 0), (scenario.input.artifact.manifest, 1)] {
                let evidence: ArtifactAccessEvidence = access == .clientCache
                    ? .clientCacheInstallation(manifest: manifest, exitStatus: status)
                    : .localImportInstallation(manifest: manifest, exitStatus: status)
                let observation = try ArtifactObservation(outcome: .outsideNetworkControl, exchanges: [],
                    downloadAudits: [], complete: true, accessEvidence: evidence)
                XCTAssertEqual(ArtifactHarness.verify(scenario, observation), .mismatched("local installation receipt mismatch"))
            }
        }
    }

    /// Opt-in because this runs existing npm in isolated empty-config projects. All 40
    /// inputs use the same adapter; the 16 local/cache cases deliberately make no handler call.
    func testOptionalAllFortyScenariosWithActualNpmLockfileCacheAndImport() async throws {
        let availability = try NPMRun()
        availability.cleanup()
        let scenarios = try ArtifactScenario.standard()
        var receipts: [HandlerReceipt] = []
        let results = try await ArtifactHarness.run(scenarios) { input in
            let receipt = try await NPMHandlerAdapter.observe(input)
            receipts.append(receipt)
            return receipt.observation
        }
        XCTAssertEqual(results.count, 40)
        XCTAssertEqual(results.filter { $0 == .matched }.count, 28)
        XCTAssertEqual(results.filter { $0 == .incomplete("denial reason not observable") }.count, 12)
        XCTAssertEqual(results.filter { if case .mismatched = $0 { true } else { false } }.count, 0)
        for (index, scenario) in scenarios.enumerated() {
            try assertReceipt(receipts[index], for: scenario, result: results[index])
            print("D4_HANDLER_SCENARIO \(scenario.id) result=\(results[index]) handler_calls=\(receipts[index].handlerCalls) upstream_requests=\(receipts[index].upstream.count) audits=\(receipts[index].downloads.count)")
        }
    }

    private func directScenario(version: String) throws -> ArtifactScenario {
        try XCTUnwrap(ArtifactScenario.standard().first { $0.input.access == .directURL && $0.input.artifact.key.version == version })
    }

    private func responseBody(_ exchange: HandlerUpstreamExchange) throws -> Data {
        let wire = try XCTUnwrap(exchange.response)
        let end = try XCTUnwrap(wire.range(of: Data("\r\n\r\n".utf8)))
        return Data(wire[end.upperBound...])
    }

    private func assertReceipt(_ receipt: HandlerReceipt, for scenario: ArtifactScenario, result: ScenarioResult) throws {
        let input = scenario.input, key = input.artifact.key
        if [.clientCache, .localImport].contains(input.access) {
            XCTAssertEqual(result, .matched, scenario.id)
            XCTAssertEqual(receipt.process?.status, 0, receipt.process?.diagnostic ?? "missing process")
            XCTAssertEqual(receipt.installedManifest, input.artifact.manifest)
            XCTAssertEqual(receipt.handlerCalls, 0)
            XCTAssertTrue(receipt.upstream.isEmpty)
            XCTAssertTrue(receipt.downloads.isEmpty)
            XCTAssertTrue(receipt.observation.exchanges.isEmpty)
            return
        }
        let delivered = ["1.0.0", "1.1.0"].contains(key.version)
        XCTAssertEqual(result, delivered ? .matched : .incomplete("denial reason not observable"), scenario.id)
        XCTAssertEqual(receipt.handlerCalls, input.access == .gatewayCache ? 2 : 1)
        XCTAssertEqual(receipt.observation.exchanges.map(\.target), [key.tarballTarget])
        XCTAssertEqual(receipt.observation.exchanges.map(\.status), [delivered ? 200 : 403])
        XCTAssertEqual(receipt.observation.exchanges[0].responseBody,
                       delivered ? input.artifact.archive : Data("{\"error\":403}\n".utf8))
        let upstreamTargets: [String] = delivered
            ? (input.access == .gatewayCache ? [key.upstreamPackumentTarget, key.upstreamPackumentTarget]
                : [key.upstreamPackumentTarget, key.upstreamTarballTarget, key.upstreamPackumentTarget])
            : [key.upstreamPackumentTarget]
        XCTAssertEqual(receipt.upstream.map { $0.request.target }, upstreamTargets, scenario.id)
        let metadata = try RegistryFixtures(artifacts: [input.artifact]).packument(name: key.name)
        for exchange in receipt.upstream {
            XCTAssertEqual(exchange.hostname, "registry.fixture.invalid")
            XCTAssertEqual(exchange.request.method, "GET")
            XCTAssertNil(exchange.failure)
            if exchange.request.target == key.upstreamPackumentTarget {
                XCTAssertEqual(exchange.request.headers["cache-control"], "no-cache")
                XCTAssertEqual(exchange.request.headers["accept"], "application/json")
                XCTAssertEqual(try responseBody(exchange), metadata)
            } else { XCTAssertEqual(try responseBody(exchange), input.artifact.archive) }
        }
        XCTAssertEqual(receipt.downloads.count, delivered ? 1 : 0)
        if let record = receipt.downloads.first {
            XCTAssertEqual(record.package, key.name); XCTAssertEqual(record.version, key.version)
            XCTAssertEqual(record.integrity, input.artifact.integrity)
            XCTAssertEqual(record.source, FixtureOrigin.upstream.value + key.upstreamTarballTarget)
            XCTAssertEqual(record.bytes, input.artifact.archive.count)
            XCTAssertEqual(record.preparedAt, Date(timeIntervalSince1970: Double(input.now)))
            XCTAssertEqual(record.cached, input.access == .gatewayCache)
            XCTAssertEqual(record.state, input.access == .lockfileCI ? .transportAccepted : .prepared)
        }
        if input.access == .gatewayCache {
            let seed = try XCTUnwrap(receipt.seed)
            XCTAssertEqual(seed.exchange.status, 200)
            XCTAssertEqual(seed.exchange.responseBody, input.artifact.archive)
            XCTAssertEqual(seed.upstream.map { $0.request.target }, [key.upstreamPackumentTarget, key.upstreamTarballTarget, key.upstreamPackumentTarget])
            XCTAssertEqual(seed.downloads.count, 1)
            XCTAssertEqual(seed.downloads[0].state, .prepared)
            XCTAssertFalse(seed.downloads[0].cached)
            XCTAssertEqual(seed.downloads[0].integrity, input.artifact.integrity)
            let seedRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: seed.metadata) as? [String: Any])
            let dates = try XCTUnwrap(seedRoot["time"] as? [String: String])
            let date = try XCTUnwrap(ISO8601DateFormatter().date(from: try XCTUnwrap(dates[key.version])))
            XCTAssertLessThanOrEqual(date.timeIntervalSince1970, Double(input.now - input.cooldown))
            for exchange in seed.upstream where exchange.request.target == key.upstreamPackumentTarget {
                XCTAssertEqual(try responseBody(exchange), seed.metadata)
            }
            XCTAssertNotEqual(seed.downloads[0].id, receipt.downloads.first?.id)
        } else { XCTAssertNil(receipt.seed) }
        if input.access == .lockfileCI {
            XCTAssertEqual(receipt.process?.status == 0, delivered, receipt.process?.diagnostic ?? "missing process")
            XCTAssertEqual(receipt.installedManifest, delivered ? input.artifact.manifest : nil)
        }
    }
}
