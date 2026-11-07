import Foundation
import SanjboxGatewayCore
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

    /// MINOR: `rule(for:)` nesmí vrátit vypnuté pravidlo, aby se "deklarováno"
    /// nepletlo s "obsluhováno"; deklaraci vrací `declaredRule(for:)`.
    func testRuleLookupSeparatesDeclaredFromServed() throws {
        let policy = try Fixture.policy([Fixture.npm(enabled: false), Fixture.pypi()])
        XCTAssertNil(policy.rule(for: .npm))
        XCTAssertEqual(policy.declaredRule(for: .npm)?.isEnabled, false)
        XCTAssertEqual(policy.rule(for: .pypi)?.isEnabled, true)
        XCTAssertEqual(policy.declaredRule(for: .pypi)?.isEnabled, true)
        XCTAssertNil(policy.rule(for: .git))
        XCTAssertNil(policy.declaredRule(for: .git))
    }

    /// MINOR: rozsahy v `RegistryRuleLimits` jsou ručně zrcadlené z
    /// `RegistryLimits` (WP1.D5). Test bere rozsahy z handleru a porovnává je
    /// s politikou na hranicích; drift na kterékoli straně spadne.
    func testRegistryLimitRangesMatchHandlerContract() {
        let probes: [String: [Int]] = [
            "metadataBytes": [0, 1, 4_194_304, 4_194_305],
            "artifactBytes": [0, 1, 4_194_304, 4_194_305],
            "files": [0, 1, 10_000, 10_001],
            "operations": [0, 1, 16, 17],
            "auditRecords": [0, 1, 10_000, 10_001],
            "lifetimeSeconds": [0, 1, 120, 121],
        ]
        for (field, values) in probes {
            for value in values {
                let policyAccepted = (try? policyRegistryLimits(field, value)) != nil
                let handlerAccepted = (try? handlerRegistryLimits(field, value)) != nil
                XCTAssertEqual(policyAccepted, handlerAccepted,
                               "\(field)=\(value): policy=\(policyAccepted) handler=\(handlerAccepted)")
            }
        }
    }

    /// Stejná parita pro modelové API (`ModelRule` vs `ModelAPIConfiguration`).
    func testModelLimitRangesMatchHandlerContract() {
        let probes: [String: [Int]] = [
            "requestsPerWindow": [0, 1, 1_000, 1_001],
            "rateWindowSeconds": [0, 1, 86_400, 86_401],
            "maximumConcurrent": [0, 1, 32, 33],
            "maximumRecords": [0, 1, 10_000, 10_001],
            "maximumInputBytes": [0, 1, 65_536, 65_537],
            "maximumOutputTokens": [0, 1, 8_192, 8_193],
            "maximumOutputBytes": [0, 1, 1_048_576, 1_048_577],
            "maximumEvents": [0, 1, 16_384, 16_385],
            "lifetimeSeconds": [0, 1, 120, 121],
        ]
        for (field, values) in probes {
            for value in values {
                let policyAccepted = (try? Fixture.policy([.model(policyModelRule(field, value))])) != nil
                let handlerAccepted = (try? handlerModelConfiguration(field, value)) != nil
                XCTAssertEqual(policyAccepted, handlerAccepted,
                               "\(field)=\(value): policy=\(policyAccepted) handler=\(handlerAccepted)")
            }
        }
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

// MARK: - Parita rozsahů s handlery (WP1.D3/D5)

private func policyRegistryLimits(_ field: String, _ value: Int) throws -> RegistryRuleLimits {
    try RegistryRuleLimits(
        metadataBytes: field == "metadataBytes" ? value : 4_194_304,
        artifactBytes: field == "artifactBytes" ? value : 4_194_304,
        files: field == "files" ? value : 10_000,
        operations: field == "operations" ? value : 4,
        auditRecords: field == "auditRecords" ? value : 1_024,
        lifetimeSeconds: field == "lifetimeSeconds" ? value : 90)
}

private func handlerRegistryLimits(_ field: String, _ value: Int) throws {
    _ = try RegistryLimits(
        metadataBytes: field == "metadataBytes" ? value : 4_194_304,
        artifactBytes: field == "artifactBytes" ? value : 4_194_304,
        files: field == "files" ? value : 10_000,
        operations: field == "operations" ? value : 4,
        auditRecords: field == "auditRecords" ? value : 1_024,
        lifetime: .seconds(field == "lifetimeSeconds" ? value : 90))
}

private func policyModelRule(_ field: String, _ value: Int) -> ModelRule {
    ModelRule(
        allowedModels: ["fixture-model"], budgetUnits: 100,
        requestsPerWindow: field == "requestsPerWindow" ? value : 10,
        rateWindowSeconds: field == "rateWindowSeconds" ? value : 60,
        maximumConcurrent: field == "maximumConcurrent" ? value : 2,
        maximumRecords: field == "maximumRecords" ? value : 16,
        maximumInputBytes: field == "maximumInputBytes" ? value : 32_768,
        maximumOutputTokens: field == "maximumOutputTokens" ? value : 1_024,
        maximumOutputBytes: field == "maximumOutputBytes" ? value : 262_144,
        maximumEvents: field == "maximumEvents" ? value : 4_096,
        lifetimeSeconds: field == "lifetimeSeconds" ? value : 60)
}

private func handlerModelConfiguration(_ field: String, _ value: Int) throws {
    _ = try ModelAPIConfiguration(
        zoneID: zoneID, allowedModels: ["fixture-model"], budgetUnits: 100, chargePerRequest: 1,
        requestsPerWindow: field == "requestsPerWindow" ? value : 10,
        rateWindow: .seconds(field == "rateWindowSeconds" ? value : 60),
        maximumConcurrent: field == "maximumConcurrent" ? value : 2,
        maximumRecords: field == "maximumRecords" ? value : 16,
        maximumInputBytes: field == "maximumInputBytes" ? value : 32_768,
        maximumOutputTokens: field == "maximumOutputTokens" ? value : 1_024,
        maximumOutputBytes: field == "maximumOutputBytes" ? value : 262_144,
        maximumEvents: field == "maximumEvents" ? value : 4_096,
        lifetime: .seconds(field == "lifetimeSeconds" ? value : 60))
}
