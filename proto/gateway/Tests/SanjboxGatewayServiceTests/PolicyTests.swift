import Foundation
import SanjboxGatewayService
import XCTest

final class PolicyTests: XCTestCase {
    func testDecodesDraftV1WithAllFourOperations() throws {
        let policy = try GatewayPolicy.decode(Data(Fixture.policyJSON.utf8))
        XCTAssertEqual(policy.schemaVersion, 1)
        XCTAssertEqual(policy.zoneID, zoneID)
        XCTAssertEqual(policy.auditCapacity, 256)
        XCTAssertEqual(policy.gateways.count, 4)
        XCTAssertEqual(policy.declaredMountsForTest, ["/git", "/model", "/npm", "/pypi"])
        XCTAssertEqual(policy.enabledRules.count, 4)
        XCTAssertEqual(policy.enabledRules.first?.mount, "/git")
        XCTAssertEqual(policy.rule(for: .model)?.isEnabled, true)
    }

    func testRejectsUnknownTopLevelField() throws {
        let text = Fixture.policyJSON.replacingOccurrences(
            of: "\"schemaVersion\": 1,", with: "\"schemaVersion\": 1,\n  \"extra\": true,")
        XCTAssertThrowsError(try GatewayPolicy.decode(Data(text.utf8))) { error in
            XCTAssertEqual(error as? PolicyError, .unknownField("policy.extra"))
        }
    }

    func testRejectsUnknownGatewayFieldDeterministically() throws {
        let text = Fixture.policyJSON.replacingOccurrences(
            of: "\"upstreamHostname\": \"registry.example\",",
            with: "\"upstreamHostname\": \"registry.example\",\n          \"zzz\": 1,\n          \"aaa\": 2,")
        XCTAssertThrowsError(try GatewayPolicy.decode(Data(text.utf8))) { error in
            // Seřazené klíče: rozhoduje "aaa", ne pořadí v dokumentu.
            XCTAssertEqual(error as? PolicyError, .unknownField("npm.aaa"))
        }
    }

    func testRejectsUnknownOperation() throws {
        let text = Fixture.policyJSON.replacingOccurrences(
            of: "\"operation\": \"npm\"", with: "\"operation\": \"homebrew\"")
        XCTAssertThrowsError(try GatewayPolicy.decode(Data(text.utf8))) { error in
            XCTAssertEqual(error as? PolicyError, .unknownOperation("homebrew"))
        }
    }

    func testRejectsUnsupportedSchemaVersion() throws {
        let text = Fixture.policyJSON.replacingOccurrences(
            of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2")
        XCTAssertThrowsError(try GatewayPolicy.decode(Data(text.utf8))) { error in
            XCTAssertEqual(error as? PolicyError, .unsupportedVersion(2))
        }
    }

    func testRejectsMissingField() throws {
        let text = Fixture.policyJSON.replacingOccurrences(of: "  \"auditCapacity\": 256,\n", with: "")
        XCTAssertThrowsError(try GatewayPolicy.decode(Data(text.utf8))) { error in
            XCTAssertEqual(error as? PolicyError, .missingField("auditCapacity"))
        }
    }

    func testRejectsUnknownFieldWhenTypeIsAlsoWrong() throws {
        let text = Fixture.policyJSON.replacingOccurrences(
            of: "\"auditCapacity\": 256", with: "\"auditCapacity\": 256, \"bogus\": []")
        XCTAssertThrowsError(try GatewayPolicy.decode(Data(text.utf8))) { error in
            XCTAssertEqual(error as? PolicyError, .unknownField("policy.bogus"))
        }
    }

    func testRejectsDuplicateOperation() {
        XCTAssertThrowsError(try Fixture.policy([Fixture.npm(), Fixture.npm(mount: "/npm2")])) { error in
            XCTAssertEqual(error as? PolicyError, .duplicateOperation(.npm))
        }
        // Duplicitní mount u různých operací je také odmítnutý.
        XCTAssertThrowsError(try Fixture.policy([Fixture.npm(), Fixture.pypi(mount: "/npm")])) { error in
            XCTAssertEqual(error as? PolicyError, .duplicateMount("/npm"))
        }
    }

    func testRejectsInvalidAndWildcardMounts() throws {
        for mount in ["/NPM", "/npm/", "/", "npm", "/*", "/np m"] {
            XCTAssertThrowsError(try Fixture.policy([Fixture.npm(mount: mount)]), mount) { error in
                XCTAssertEqual(error as? PolicyError, .invalidField("npm.mount"), mount)
            }
        }
    }

    func testRejectsInvalidPublicOrigin() {
        for origin in ["https://127.0.0.1:18765", "http://localhost:18765", "http://0.0.0.0:18765",
                       "http://127.0.0.1:0", "http://127.0.0.1:18765/"] {
            XCTAssertThrowsError(try GatewayPolicy(
                zoneID: zoneID,
                gateways: [.npm(NPMRule(publicOrigin: origin, cooldownSeconds: 3_600))]), origin) { error in
                XCTAssertEqual(error as? PolicyError, .invalidField("npm.publicOrigin"), origin)
            }
        }
    }

    func testRejectsOutOfRangeLimits() {
        for operations in [0, 17] {
            XCTAssertThrowsError(try RegistryRuleLimits(operations: operations)) { error in
                XCTAssertEqual(error as? PolicyError, .invalidField("limits.operations"))
            }
        }
        XCTAssertThrowsError(try RegistryRuleLimits(lifetimeSeconds: 121)) { error in
            XCTAssertEqual(error as? PolicyError, .invalidField("limits.lifetimeSeconds"))
        }
    }

    func testRejectsOutOfRangeLimitFromJSONWithPath() throws {
        let text = Fixture.policyJSON.replacingOccurrences(
            of: "\"operations\": 4,", with: "\"operations\": 0,")
        XCTAssertThrowsError(try GatewayPolicy.decode(Data(text.utf8))) { error in
            XCTAssertEqual(error as? PolicyError, .invalidField("npm.limits.operations"))
        }
    }

    func testRejectsModelMountThatHandlerCannotServe() {
        XCTAssertThrowsError(try Fixture.policy([
            .model(ModelRule(mount: "/models", allowedModels: ["fixture-model"], budgetUnits: 10)),
        ])) { error in
            XCTAssertEqual(error as? PolicyError, .invalidField("model.mount"))
        }
    }

    func testRejectsUnsupportedRepositoryPath() {
        XCTAssertThrowsError(try Fixture.policy([
            .git(GitRule(upstreamHostname: "github.example", repositoryPath: "/other.git")),
        ])) { error in
            XCTAssertEqual(error as? PolicyError, .invalidField("git.repositoryPath"))
        }
    }

    func testRejectsNegativeCooldown() {
        XCTAssertThrowsError(try Fixture.policy([Fixture.npm(cooldown: -1)])) { error in
            XCTAssertEqual(error as? PolicyError, .invalidField("npm.cooldownSeconds"))
        }
    }

    func testRejectsInvalidZoneIDAndEmptyPolicy() {
        for zone in ["", "zone/one", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try GatewayPolicy(zoneID: zone, gateways: [Fixture.npm()]), zone) { error in
                XCTAssertEqual(error as? PolicyError, .invalidField("zoneID"), zone)
            }
        }
        XCTAssertThrowsError(try GatewayPolicy(zoneID: zoneID, gateways: [])) { error in
            XCTAssertEqual(error as? PolicyError, .emptyGateways)
        }
    }

    func testRejectsTopLevelTypeMismatch() throws {
        let text = Fixture.policyJSON.replacingOccurrences(
            of: "\"auditCapacity\": 256", with: "\"auditCapacity\": \"many\"")
        XCTAssertThrowsError(try GatewayPolicy.decode(Data(text.utf8))) { error in
            XCTAssertEqual(error as? PolicyError, .invalidField("auditCapacity"))
        }
        XCTAssertThrowsError(try GatewayPolicy.decode(Data("{".utf8))) { error in
            XCTAssertEqual(error as? PolicyError, .malformed)
        }
    }

    func testEncodingRoundTripsAndIsStable() throws {
        let policy = try Fixture.allEnabled()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(policy)
        let second = try encoder.encode(policy)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try GatewayPolicy.decode(first), policy)
        // Kódování nesmí vyrobit pole, které by vlastní dekodér odmítl.
        XCTAssertNoThrow(try GatewayPolicy.decode(second))
    }

    func testPolicyErrorTextsAreStable() {
        XCTAssertEqual(PolicyError.unknownField("npm.aaa").description, "unknown field \"npm.aaa\"")
        XCTAssertEqual(PolicyError.unsupportedVersion(9).description, "policy.schemaVersion 9 is not supported")
        XCTAssertEqual(PolicyError.duplicateMount("/npm").description, "duplicate mount \"/npm\"")
    }
}

private extension GatewayPolicy {
    /// Pomocník jen pro test: mounty v pořadí dokumentu.
    var declaredMountsForTest: [String] { gateways.map(\.mount).sorted() }
}
