import CryptoKit
import Foundation
@testable import SanjboxGatewayFixtures
@testable import SanjboxGatewayCore
import XCTest

@MainActor final class RedirectHandlerIntegrationTests: XCTestCase {
    private let registry = "registry.fixture.invalid"
    private let cdn = "cdn.fixture.invalid"

    func testSixExistingCorpusResponsesReachActualHandlerAndTraceEveryAttempt() async throws {
        let artifact = try fixture()
        XCTAssertEqual(RedirectFixture.standard.map(\.id),
                       ["cdn", "same-host-rebinding", "loopback", "downgrade", "userinfo", "unapproved-origin"])
        for redirect in RedirectFixture.standard {
            var steps = try prefix(artifact, redirect: redirect)
            var extraDNS: [DNSAnswer] = []
            let status: Int
            switch redirect.id {
            case "cdn":
                steps += try suffix(artifact, redirect: redirect)
                status = 200
            case "same-host-rebinding":
                steps += [try metadata(artifact)]
                extraDNS = [try DNSAnswer(hostname: registry, addresses: ["127.0.0.1"])]
                status = 502 // DestinationFailure is intentionally a generic upstream error in D2.
            default: status = 403
            }
            let dns = try answers(steps) + extraDNS
            let adapter = try session(steps, dns: dns)
            let receipt = try await adapter.request(artifact.key, headers: ["X-Untrusted-Fixture": "do-not-forward"])
            try await adapter.assertConsumed()
            try assertTrace(receipt, steps: steps, dns: dns, artifact: artifact)
            if status == 200 { try assertDelivery(receipt, artifact) }
            else { try assertRefusal(receipt, status: status) }
            print("D4_REDIRECT_CORPUS \(redirect.id) status=\(receipt.exchange.status) dns=\(dnsAttempts(receipt).count) dials=\(dialAttempts(receipt).count) audits=\(receipt.downloads.count) reason=unobserved")
            printObservedTrace(receipt, id: redirect.id)
        }
    }

    func testSameHostPositiveControlUsesFreshDNSAndHostSnapshotAtEachRequest() async throws {
        let artifact = try fixture(name: "@fixture/bead")
        let redirect = try corpus("same-host-rebinding")
        let steps = try prefix(artifact, redirect: redirect) + suffix(artifact, redirect: redirect)
        // Changing allowed addresses proves that each ApprovedDestination uses that attempt's answer.
        let dns = try steps.enumerated().map { index, step in
            try DNSAnswer(hostname: step.hostname, addresses: [index.isMultiple(of: 2) ? "8.8.8.8" : "1.1.1.1"])
        }
        let adapter = try session(steps, dns: dns)
        let receipt = try await adapter.request(artifact.key)
        try await adapter.assertConsumed()
        try assertTrace(receipt, steps: steps, dns: dns, artifact: artifact)
        try assertDelivery(receipt, artifact)
    }

    func testRebindingAndFreshHostInterfaceSnapshotPreventForbiddenTargetDial() async throws {
        let artifact = try fixture(), redirect = try corpus("same-host-rebinding")
        let steps = try prefix(artifact, redirect: redirect) + [metadata(artifact)]
        let deniedAnswers = [["127.0.0.1"], ["192.168.1.2"], ["::1"], ["fd00::1"],
                             ["8.8.8.8", "10.1.2.3"], ["2606:4700:4700::1111", "fe80::1"]]
        for denied in deniedAnswers {
            let dns = try answers(steps) + [DNSAnswer(hostname: registry, addresses: denied)]
            let adapter = try session(steps, dns: dns)
            let receipt = try await adapter.request(artifact.key)
            try await adapter.assertConsumed()
            try assertTrace(receipt, steps: steps, dns: dns, artifact: artifact)
            try assertRefusal(receipt, status: 502)
            XCTAssertEqual(dialAttempts(receipt).count, 3)
        }
        let dns = try answers(steps) + [DNSAnswer(hostname: registry, addresses: ["8.8.8.8"])]
        let snapshots: [[String]?] = [[], [], [], ["8.8.8.8"]]
        let adapter = try session(steps, dns: dns, hosts: snapshots)
        let receipt = try await adapter.request(artifact.key)
        try await adapter.assertConsumed()
        try assertTrace(receipt, steps: steps, dns: dns, hosts: snapshots, artifact: artifact)
        try assertRefusal(receipt, status: 502)
        XCTAssertEqual(dialAttempts(receipt).count, 3)
    }

    func testRedirectReauthorizationRejectsChangedDateSourceAndDigestBeforeTargetDial() async throws {
        let artifact = try fixture(), redirect = try corpus("cdn")
        for changed in try changedMetadata(artifact) {
            let steps = try prefix(artifact, redirect: redirect) + [metadata(artifact, body: changed)]
            let adapter = try session(steps)
            let receipt = try await adapter.request(artifact.key)
            try await adapter.assertConsumed()
            try assertTrace(receipt, steps: steps, artifact: artifact)
            try assertRefusal(receipt)
            XCTAssertFalse(dialAttempts(receipt).contains(cdn))
        }
    }

    func testFinalReauthorizationWithholdsFetchedRedirectArtifactWhenMetadataChanges() async throws {
        let artifact = try fixture(), redirect = try corpus("cdn")
        for changed in try changedMetadata(artifact) {
            var steps = try prefix(artifact, redirect: redirect) + suffix(artifact, redirect: redirect)
            steps[4] = try metadata(artifact, body: changed)
            let adapter = try session(steps)
            let receipt = try await adapter.request(artifact.key)
            try await adapter.assertConsumed()
            try assertTrace(receipt, steps: steps, artifact: artifact)
            try assertRefusal(receipt)
            XCTAssertEqual(dialAttempts(receipt).filter { $0 == cdn }.count, 1)
        }
    }

    func testCorruptRedirectBodyFailsDigestWithoutFinalMetadataOrAudit() async throws {
        let artifact = try fixture(), redirect = try corpus("cdn")
        var corrupt = artifact.archive
        corrupt[corrupt.count - 1] ^= 1
        let steps = try prefix(artifact, redirect: redirect) + [metadata(artifact), destination(redirect, body: corrupt)]
        let adapter = try session(steps)
        let receipt = try await adapter.request(artifact.key)
        try await adapter.assertConsumed()
        try assertTrace(receipt, steps: steps, artifact: artifact)
        try assertRefusal(receipt)
        let scenario = try XCTUnwrap(ArtifactScenario.standard().first {
            $0.input.artifact.key == artifact.key && $0.input.access == .directURL
        })
        XCTAssertEqual(try ArtifactHarness.verify(scenario, receipt.observation), .mismatched("unexpected outcome"))
    }

    func testRedirectSeedAndCacheHitKeepPreparedAuditAndReauthorizeTwice() async throws {
        let artifact = try fixture(), redirect = try corpus("cdn")
        let seed = try prefix(artifact, redirect: redirect) + suffix(artifact, redirect: redirect)
        let warm = try [metadata(artifact), metadata(artifact)]
        let adapter = try session(seed + warm)
        let first = try await adapter.request(artifact.key)
        let second = try await adapter.request(artifact.key)
        try await adapter.assertConsumed()
        try assertTrace(first, steps: seed, artifact: artifact)
        try assertTrace(second, steps: warm, artifact: artifact, firstID: 5)
        try assertDelivery(first, artifact)
        try assertDelivery(second, artifact, cached: true)
        XCTAssertNotEqual(first.downloads.first?.id, second.downloads.first?.id)
        let records = await adapter.handler.downloadRecords()
        XCTAssertEqual(records.map(\.state), [.prepared, .prepared])
    }

    func testRedirectedCacheRechecksCooldownAndUnknownDateAtBothAuthorizations() async throws {
        let artifact = try fixture(), redirect = try corpus("cdn")
        let seed = try prefix(artifact, redirect: redirect) + suffix(artifact, redirect: redirect)
        for changed in try Array(changedMetadata(artifact).prefix(2)) {
            for atFinal in [false, true] {
                let warm = try (atFinal ? [metadata(artifact)] : []) + [metadata(artifact, body: changed)]
                let adapter = try session(seed + warm)
                let first = try await adapter.request(artifact.key)
                let refused = try await adapter.request(artifact.key)
                try await adapter.assertConsumed()
                try assertDelivery(first, artifact)
                try assertTrace(refused, steps: warm, artifact: artifact, firstID: 5)
                try assertRefusal(refused)
                let records = await adapter.handler.downloadRecords()
                XCTAssertEqual(records, first.downloads, "refusal must not add or finish the seed's audit")
            }
        }
    }

    func testChangedCachedDigestForcesRefetchAndCannotReleaseOldRedirectBytes() async throws {
        let artifact = try fixture(), redirect = try corpus("cdn")
        let seed = try prefix(artifact, redirect: redirect) + suffix(artifact, redirect: redirect)
        let changed = try XCTUnwrap(changedMetadata(artifact).last)
        let fresh = try [metadata(artifact, body: changed), redirectStep(artifact, redirect),
                         metadata(artifact, body: changed), destination(redirect, body: artifact.archive)]
        let adapter = try session(seed + fresh)
        let first = try await adapter.request(artifact.key)
        let refused = try await adapter.request(artifact.key)
        try await adapter.assertConsumed()
        try assertDelivery(first, artifact)
        try assertTrace(refused, steps: fresh, artifact: artifact, firstID: 5)
        try assertRefusal(refused)
        XCTAssertEqual(dialAttempts(refused).filter { $0 == cdn }.count, 1, "changed digest must invalidate cache")
        let records = await adapter.handler.downloadRecords()
        XCTAssertEqual(records, first.downloads)
    }

    func testRedirectLoopStopsBeforeRedialAndHopLimitHasExactBoundary() async throws {
        let artifact = try fixture(), redirect = try corpus("cdn")
        let back = wireRedirect(FixtureOrigin.upstream.value + artifact.key.upstreamTarballTarget)
        let loop = try prefix(artifact, redirect: redirect) + [metadata(artifact),
            RedirectWireStep(hostname: cdn, target: "/fixture-bead-1.0.0.tgz", response: back), metadata(artifact)]
        let loopAdapter = try session(loop)
        let refused = try await loopAdapter.request(artifact.key)
        try await loopAdapter.assertConsumed()
        try assertTrace(refused, steps: loop, artifact: artifact)
        try assertRefusal(refused)
        for limit in [0, 1, 3] {
            for terminalSuccess in [false, true] {
                var steps = try [metadata(artifact)]
                for hop in 0...limit {
                    let hostname = hop == 0 ? registry : cdn
                    let target = hop == 0 ? artifact.key.upstreamTarballTarget : "/hop-\(hop).tgz"
                    let response = terminalSuccess && hop == limit ? wire(artifact.archive) :
                        wireRedirect("https://\(cdn)/hop-\(hop + 1).tgz")
                    steps.append(RedirectWireStep(hostname: hostname, target: target, response: response))
                    if hop < limit || terminalSuccess { steps.append(try metadata(artifact)) }
                }
                let adapter = try session(steps, limit: limit)
                let receipt = try await adapter.request(artifact.key)
                try await adapter.assertConsumed()
                try assertTrace(receipt, steps: steps, artifact: artifact)
                if terminalSuccess { try assertDelivery(receipt, artifact) }
                else { try assertRefusal(receipt) }
                XCTAssertEqual(dialAttempts(receipt).count, 2 * limit + (terminalSuccess ? 3 : 2))
            }
        }
    }

    func testClientCredentialsRejectedBeforeDNSAndOtherHeadersNeverCrossRedirect() async throws {
        let artifact = try fixture()
        for header in ["authorization", "Authorization", "proxy-authorization", "Cookie", "x-api-key", "api-key", "Range"] {
            let adapter = try session([])
            let receipt = try await adapter.request(artifact.key, headers: [header: "synthetic-untrusted"])
            try await adapter.assertConsumed()
            try assertRefusal(receipt)
            XCTAssertTrue(receipt.events.isEmpty)
        }
        let redirect = try corpus("cdn")
        let steps = try prefix(artifact, redirect: redirect) + suffix(artifact, redirect: redirect)
        let adapter = try session(steps)
        let receipt = try await adapter.request(artifact.key, headers: ["X-Untrusted-Fixture": "synthetic-untrusted",
            "Host": "other.fixture.invalid", "Accept": "text/plain", "Cache-Control": "only-if-cached"])
        try await adapter.assertConsumed()
        try assertTrace(receipt, steps: steps, artifact: artifact)
        try assertDelivery(receipt, artifact)
    }

    func testScriptLeftoversAndUnexpectedAttemptsCannotMasqueradeAsSafeRefusal() async throws {
        let artifact = try fixture(), redirect = try corpus("cdn")
        let full = try prefix(artifact, redirect: redirect) + suffix(artifact, redirect: redirect)
        // The first raw request is recorded even when a script contract is wrong.
        let wrong = [RedirectWireStep(hostname: registry, target: "/wrong", response: full[0].response)]
        let mismatch = try session(wrong)
        let failed = try await mismatch.request(artifact.key)
        XCTAssertEqual(failed.exchange.status, 502)
        XCTAssertEqual(failed.events.filter { if case .send = $0 { true } else { false } }.count, 1)
        do { try await mismatch.assertConsumed(); XCTFail("mismatched request accepted as complete") }
        catch { XCTAssertEqual(error as? FixtureFailure, .incomplete) }
        let leftover = try session(full)
        _ = try await leftover.request(artifact.key, headers: ["authorization": "synthetic"])
        do { try await leftover.assertConsumed(); XCTFail("unused script accepted as complete") }
        catch { XCTAssertEqual(error as? FixtureFailure, .incomplete) }
        // Supplying success bytes instead of the rejected Location changes actual output.
        // The adapter never receives the original fixture's reject expectation.
        let forbidden = try corpus("loopback")
        guard case .reject = forbidden.expectation else { return XCTFail("fixture oracle changed") }
        let replaced = try [metadata(artifact), RedirectWireStep(hostname: registry,
            target: artifact.key.upstreamTarballTarget, response: wire(artifact.archive)), metadata(artifact)]
        let positive = try session(replaced)
        let delivered = try await positive.request(artifact.key)
        try await positive.assertConsumed()
        try assertTrace(delivered, steps: replaced, artifact: artifact)
        try assertDelivery(delivered, artifact)
        XCTAssertNotEqual(delivered.exchange.status, 403)
    }

    private func fixture(name: String = "fixture-bead") throws -> SyntheticArtifact {
        try RegistryFixtures.standard().artifact(PackageKey(name: name, version: "1.0.0"))
    }
    private func corpus(_ id: String) throws -> RedirectFixture {
        try XCTUnwrap(RedirectFixture.standard.first { $0.id == id })
    }
    private func wire(_ body: Data, metadata: Bool = false) -> Data {
        Data("HTTP/1.1 200 Fixture\r\nContent-Type: \(metadata ? "application/json" : "application/octet-stream")\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
    }
    private func wireRedirect(_ location: String) -> Data {
        Data("HTTP/1.1 302 Fixture\r\nLocation: \(location)\r\nContent-Length: 0\r\n\r\n".utf8)
    }
    private func metadata(_ artifact: SyntheticArtifact, body: Data? = nil) throws -> RedirectWireStep {
        let bytes = try body ?? RegistryFixtures(artifacts: [artifact]).packument(name: artifact.key.name)
        return RedirectWireStep(hostname: registry, target: artifact.key.upstreamPackumentTarget, response: wire(bytes, metadata: true))
    }
    private func redirectStep(_ artifact: SyntheticArtifact, _ redirect: RedirectFixture) -> RedirectWireStep {
        RedirectWireStep(hostname: registry, target: artifact.key.upstreamTarballTarget, response: redirect.response)
    }
    private func prefix(_ artifact: SyntheticArtifact, redirect: RedirectFixture) throws -> [RedirectWireStep] {
        try [metadata(artifact), redirectStep(artifact, redirect)]
    }
    private func destination(_ redirect: RedirectFixture, body: Data) throws -> RedirectWireStep {
        let url = try XCTUnwrap(URLComponents(string: redirect.location))
        return RedirectWireStep(hostname: try XCTUnwrap(url.host), target: url.percentEncodedPath, response: wire(body))
    }
    private func suffix(_ artifact: SyntheticArtifact, redirect: RedirectFixture) throws -> [RedirectWireStep] {
        try [metadata(artifact), destination(redirect, body: artifact.archive), metadata(artifact)]
    }
    private func answers(_ steps: [RedirectWireStep]) throws -> [DNSAnswer] {
        try steps.map { try DNSAnswer(hostname: $0.hostname, addresses: ["8.8.8.8"]) }
    }
    private func session(_ steps: [RedirectWireStep], dns: [DNSAnswer]? = nil, hosts: [[String]?]? = nil,
                         limit: Int = 3) throws -> RedirectHandlerAdapter {
        let script = try dns ?? answers(steps)
        return try RedirectHandlerAdapter(steps: steps, dns: script,
            hostSnapshots: hosts ?? Array(repeating: [], count: script.count), maximumRedirects: limit)
    }
    private func changedMetadata(_ artifact: SyntheticArtifact) throws -> [Data] {
        var result: [Data] = []
        for date: Int64? in [RegistryFixtures.now - RegistryFixtures.cooldown + 1, nil,
                            RegistryFixtures.now - RegistryFixtures.cooldown - 2] {
            let changed = try SyntheticArtifact(key: artifact.key, publishedAt: date)
            result.append(try RegistryFixtures(artifacts: [changed]).packument(name: artifact.key.name))
        }
        result.append(try RegistryFixtures(artifacts: [artifact]).packument(name: artifact.key.name, origin: .cdn))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with:
            RegistryFixtures(artifacts: [artifact]).packument(name: artifact.key.name)) as? [String: Any])
        var versions = try XCTUnwrap(root["versions"] as? [String: [String: Any]])
        var version = try XCTUnwrap(versions[artifact.key.version])
        var dist = try XCTUnwrap(version["dist"] as? [String: String])
        dist["integrity"] = "sha512-" + Data(SHA512.hash(data: Data("different synthetic bytes".utf8))).base64EncodedString()
        version["dist"] = dist; versions[artifact.key.version] = version; root["versions"] = versions
        result.append(try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes]))
        return result
    }
    /// Persist compact observed traces. Request bytes are synthetic; response hashes
    /// are computed from received chunks, never from the planned WireStep responses.
    private func printObservedTrace(_ receipt: RedirectHandlerReceipt, id: String) {
        for (sequence, event) in receipt.events.enumerated() {
            let value: String
            switch event {
            case .dns(let host): value = "dns host=\(host)"
            case .answers(let host, let addresses): value = "answers host=\(host) addresses=\(addresses)"
            case .hostSnapshot(let addresses): value = "host-snapshot addresses=\(addresses)"
            case .dial(let connection, let host, let port, let addresses):
                value = "dial connection=\(connection) host=\(host) port=\(port) addresses=\(addresses)"
            case .start(let connection): value = "start connection=\(connection)"
            case .send(let connection, let bytes):
                value = "send connection=\(connection) request-base64=\(bytes.base64EncodedString())"
            case .receive(let connection, let bytes, let eof):
                let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                value = "receive connection=\(connection) bytes=\(bytes.count) sha256=\(hash) eof=\(eof)"
            case .cancel(let connection): value = "cancel connection=\(connection)"
            }
            print("D4_REDIRECT_TRACE \(id) sequence=\(sequence) \(value)")
        }
    }
    private func dnsAttempts(_ receipt: RedirectHandlerReceipt) -> [String] {
        receipt.events.compactMap { if case .dns(let host) = $0 { host } else { nil } }
    }
    private func dialAttempts(_ receipt: RedirectHandlerReceipt) -> [String] {
        receipt.events.compactMap { if case .dial(_, let host, _, _) = $0 { host } else { nil } }
    }
    private func assertDelivery(_ receipt: RedirectHandlerReceipt, _ artifact: SyntheticArtifact, cached: Bool = false,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(receipt.exchange.status, 200, file: file, line: line)
        XCTAssertEqual(receipt.exchange.responseBody, artifact.archive, file: file, line: line)
        XCTAssertEqual("sha512-" + Data(SHA512.hash(data: receipt.exchange.responseBody)).base64EncodedString(),
                       artifact.integrity, file: file, line: line)
        XCTAssertEqual(receipt.downloads.count, 1, file: file, line: line)
        let record = try XCTUnwrap(receipt.downloads.first, file: file, line: line)
        XCTAssertEqual(record.package, artifact.key.name, file: file, line: line)
        XCTAssertEqual(record.version, artifact.key.version, file: file, line: line)
        XCTAssertEqual(record.integrity, artifact.integrity, file: file, line: line)
        XCTAssertEqual(record.source, FixtureOrigin.upstream.value + artifact.key.upstreamTarballTarget, file: file, line: line)
        XCTAssertEqual(record.bytes, artifact.archive.count, file: file, line: line)
        XCTAssertEqual(record.cached, cached, file: file, line: line)
        XCTAssertEqual(record.preparedAt, Date(timeIntervalSince1970: Double(RegistryFixtures.now)), file: file, line: line)
        XCTAssertEqual(record.state, .prepared, file: file, line: line)
    }
    private func assertRefusal(_ receipt: RedirectHandlerReceipt, status: Int = 403,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(receipt.exchange.status, status, file: file, line: line)
        XCTAssertEqual(receipt.exchange.responseBody, Data("{\"error\":\(status)}\n".utf8), file: file, line: line)
        XCTAssertTrue(receipt.downloads.isEmpty, file: file, line: line)
        guard case .denied(.other) = try receipt.observation.outcome else {
            return XCTFail("no detailed denial reason is observable", file: file, line: line)
        }
    }
    /// Compare every observed boundary, raw request and returned byte chunk. Refusal DNS
    /// is the sole allowed suffix with no dial; excess/missing attempts fail this oracle.
    private func assertTrace(_ receipt: RedirectHandlerReceipt, steps: [RedirectWireStep], dns: [DNSAnswer]? = nil,
                             hosts: [[String]?]? = nil, artifact: SyntheticArtifact, firstID: Int = 0,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let dns = try dns ?? answers(steps)
        let hosts = hosts ?? Array(repeating: [], count: dns.count)
        var cursor = 0
        func next() throws -> RedirectEvent {
            guard cursor < receipt.events.count else { throw FixtureFailure.incomplete }
            defer { cursor += 1 }
            return receipt.events[cursor]
        }
        for (index, answer) in dns.enumerated() {
            let addresses = try XCTUnwrap(answer.addresses).map(\.text)
            XCTAssertEqual(try next(), .dns(answer.hostname), file: file, line: line)
            XCTAssertEqual(try next(), .answers(answer.hostname, addresses), file: file, line: line)
            XCTAssertEqual(try next(), .hostSnapshot(try XCTUnwrap(hosts[index]).sorted()), file: file, line: line)
            guard index < steps.count else { continue }
            let step = steps[index], id = firstID + index
            XCTAssertEqual(try next(), .dial(id, step.hostname, 443, addresses), file: file, line: line)
            XCTAssertEqual(try next(), .start(id), file: file, line: line)
            guard case .send(let sentID, let bytes) = try next() else { throw FixtureFailure.incomplete }
            XCTAssertEqual(sentID, id, file: file, line: line)
            var decoder = HTTPRequestDecoder()
            let request = try XCTUnwrap(decoder.append(bytes))
            XCTAssertEqual(request.method, "GET", file: file, line: line)
            XCTAssertEqual(request.target, step.target, file: file, line: line)
            XCTAssertTrue(request.body.isEmpty, file: file, line: line)
            var headers = ["host": step.hostname, "connection": "close", "accept-encoding": "identity", "content-length": "0"]
            if step.target == artifact.key.upstreamPackumentTarget {
                headers["accept"] = "application/json"; headers["cache-control"] = "no-cache"
            }
            XCTAssertEqual(request.headers, headers, "client headers must never be forwarded", file: file, line: line)
            var remaining = step.response
            while !remaining.isEmpty {
                let chunk = Data(remaining.prefix(257)); remaining.removeFirst(chunk.count)
                XCTAssertEqual(try next(), .receive(id, chunk, remaining.isEmpty), file: file, line: line)
            }
            XCTAssertEqual(try next(), .cancel(id), file: file, line: line)
        }
        XCTAssertEqual(cursor, receipt.events.count, "unexpected attempted transition", file: file, line: line)
        XCTAssertEqual(dialAttempts(receipt), steps.map(\.hostname), file: file, line: line)
    }
}
