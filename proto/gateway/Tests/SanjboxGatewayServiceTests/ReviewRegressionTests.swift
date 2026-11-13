import Foundation
import XCTest
@testable import SanjboxGatewayService

final class ReviewRegressionTests: XCTestCase {
    func testDuplicateDecodedPolicyKeysAreRejectedAtEveryNestingLevel() throws {
        for (old, new) in [
            ("\"schemaVersion\": 1", "\"schemaVersion\": 1, \"schemaVersion\": 2"),
            ("\"enabled\": true", "\"enabled\": true, \"enabled\": false"),
            ("\"enabled\": true", "\"enabled\": false, \"\\u0065nabled\": true"),
            ("\"mount\": \"/npm\"", "\"mount\": \"/npm\", \"mount\": \"/other\""),
            ("\"metadataBytes\": 4194304", "\"metadataBytes\": 4194304, \"metadataBytes\": 1"),
        ] {
            let document = Fixture.policyJSON.replacingOccurrences(of: old, with: new)
            XCTAssertNotEqual(document, Fixture.policyJSON)
            XCTAssertThrowsError(try GatewayPolicy.decode(Data(document.utf8))) {
                XCTAssertEqual($0 as? PolicyError, .malformed)
            }
        }
    }

    func testNumericPolicyTokensCannotRoundIntoPermissionsOrBudget() throws {
        for number in ["1.000000000000000000001", "1e0", "-0", "1.0"] {
            let document = Fixture.policyJSON.replacingOccurrences(of: "\"schemaVersion\": 1",
                                                                   with: "\"schemaVersion\": \(number)")
            XCTAssertThrowsError(try GatewayPolicy.decode(Data(document.utf8)))
        }
        let original = try GatewayPolicy.decode(Data(Fixture.policyJSON.utf8))
        XCTAssertEqual(try GatewayPolicy.decode(JSONEncoder().encode(original)), original)
    }

    func testPolicyPreflightRejectsOversizeDeepAndTrailingInput() throws {
        for data in [Data(repeating: 32, count: 65_537),
                     Data((String(repeating: "[", count: 20) + "0" + String(repeating: "]", count: 20)).utf8),
                     Data((Fixture.policyJSON + " true").utf8)] {
            XCTAssertThrowsError(try GatewayPolicy.decode(data))
        }
    }

    func testAuditParserRejectsNoncanonicalAmbiguousLines() {
        for line in ["01|npm|GET|/npm/x|routed||200", "1|npm|GET|/npm/%zz|routed||200",
                     "1|npm|GET|/npm/%41|routed||200", "1|npm|GET|/npm/x\n|routed||200"] {
            XCTAssertNil(AuditRecord.parse(line))
        }
    }

    func testFinalSSEChunkFailureDoesNotLeaveSuccessfulAudit() async throws {
        let wire = try modelStreamWire()
        let request = requestWire("POST", "/model/v1/messages", body: try encodeModelRequest())
        let successful = MockChannel(inbound: request)
        let first = try GatewayService(policy: Fixture.policy([Fixture.model()]),
                                       upstream: OfflineUpstream { _ in wire }.client)
        try await LoopbackConnection(channel: successful).serve(serving: first)
        XCTAssertTrue(String(decoding: successful.sent, as: UTF8.self).hasSuffix("0\r\n\r\n"))
        let failing = MockChannel(inbound: request, failSendAt: successful.sendCallCount)
        let second = try GatewayService(policy: Fixture.policy([Fixture.model()]),
                                        upstream: OfflineUpstream { _ in wire }.client)
        try await LoopbackConnection(channel: failing).serve(serving: second)
        let records = await second.auditRecords()
        XCTAssertEqual(records.map(\.decision), [.failed])
        XCTAssertEqual(records.map(\.reason), ["streamFailed"])
        XCTAssertFalse(String(decoding: failing.sent, as: UTF8.self).hasSuffix("0\r\n\r\n"))
        XCTAssertTrue(failing.isClosed)
    }

    func testDuplicateCLIOptionsCannotSilentlyChangePolicyOrListener() {
        for args in [["--policy", "a", "--policy", "b"],
                     ["--policy", "a", "--listen", "127.0.0.1:1", "--listen", "127.0.0.1:2"]] {
            XCTAssertThrowsError(try GatewayCommand.parse(args))
        }
    }
    func testNPMPackageVersionLimitIsActuallyPassedToTheHandler() async throws {
        let versions = ["1.0.0", "2.0.0"]
        let manifests = Dictionary(uniqueKeysWithValues: versions.map { version in
            (version, ["name": "fixture", "version": version, "dist": [
                "tarball": "https://registry.example/fixture/-/fixture-\(version).tgz",
                "integrity": "sha512-" + Data(repeating: 65, count: 64).base64EncodedString(),
            ]] as [String: Any])
        })
        let metadata = try JSONSerialization.data(withJSONObject: [
            "name": "fixture", "versions": manifests,
            "time": Dictionary(uniqueKeysWithValues: versions.map { ($0, "2020-01-01T00:00:00Z") }),
            "dist-tags": ["latest": "2.0.0"],
        ])
        for limit in [1, 2] {
            let policy = try Fixture.policy([.npm(NPMRule(publicOrigin: Fixture.origin,
                upstreamHostname: "registry.example", limits: RegistryRuleLimits(files: limit)))])
            let service = try GatewayService(policy: policy,
                upstream: OfflineUpstream { _ in responseWire(metadata) }.client)
            let reply = try await service.dispatch(request("GET", "/npm/fixture"))
            XCTAssertEqual(status(of: reply), limit == 1 ? 502 : 200)
        }
    }

}
