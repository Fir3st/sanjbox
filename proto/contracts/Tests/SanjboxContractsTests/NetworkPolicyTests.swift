import Foundation
import Testing
@testable import SanjboxContracts

@Suite("Síťová politika a typované brány")
struct NetworkPolicyTests {
    private func gateJSON(id: String = "npm-edge", type: String = "npm", upstream: String = "registry.npmjs.org",
                          methods: String = "[]", request: String = "1048576",
                          response: String = "4194304") -> String {
        jsonObject([("id", "\"\(id)\""), ("type", "\"\(type)\""), ("upstream", "\"\(upstream)\""),
                    ("methods", methods), ("requestBytesLimit", request), ("responseBytesLimit", response)])
    }

    private func policyJSON(gates: String, zoneID: String? = "a1b2",
                            schema: String? = "sanjbox.network-policy.v1", action: String? = "deny",
                            extraField: String = "") -> Data {
        var parts = ["\"gates\":\(gates)"]
        if let schema { parts.insert("\"schema\":\"\(schema)\"", at: 0) }
        if let zoneID { parts.append("\"zoneID\":\"\(zoneID)\"") }
        if let action { parts.append("\"defaultAction\":\"\(action)\"") }
        if !extraField.isEmpty { parts.append(extraField) }
        return Data(("{" + parts.joined(separator: ",") + "}").utf8)
    }

    @Test func decodesAndReencodesCanonically() throws {
        let policy = validPolicy()
        let first = try policy.encoded()
        let decoded = try NetworkPolicy.decode(first)
        #expect(decoded == policy)
        #expect(try decoded.encoded() == first)
    }

    @Test func acceptsEmptyGateListAsDenyAll() throws {
        let decoded = try NetworkPolicy.decode(policyJSON(gates: "[]"))
        #expect(decoded.gates.isEmpty)
    }

    @Test func rejectsUnknownTopLevelField() {
        rejection("unknown-field") {
            _ = try NetworkPolicy.decode(policyJSON(gates: "[]", extraField: "\"allowAll\":true"))
        }
    }

    @Test func rejectsUnknownGateField() {
        let gate = jsonObject([("id", "\"npm-edge\""), ("type", "\"npm\""), ("upstream", "\"registry.npmjs.org\""),
                               ("methods", "[]"), ("requestBytesLimit", "1048576"),
                               ("responseBytesLimit", "4194304"), ("wildcard", "true")])
        rejection("unknown-field") {
            _ = try NetworkPolicy.decode(policyJSON(gates: "[\(gate)]"))
        }
    }

    @Test func rejectsMissingRequiredFields() {
        rejection("missing-field") { _ = try NetworkPolicy.decode(policyJSON(gates: "[]", schema: nil)) }
        rejection("missing-field") {
            _ = try NetworkPolicy.decode(Data("{\"schema\":\"sanjbox.network-policy.v1\",\"zoneID\":\"a1b2\"}".utf8))
        }
        rejection("missing-field") {
            let gate = jsonObject([("id", "\"npm-edge\""), ("type", "\"npm\""), ("upstream", "\"registry.npmjs.org\""),
                                   ("methods", "[]"), ("requestBytesLimit", "1048576")])
            _ = try NetworkPolicy.decode(policyJSON(gates: "[\(gate)]"))
        }
    }

    @Test func rejectsUnknownGateType() {
        rejection("invalid-value") {
            _ = try NetworkPolicy.decode(policyJSON(gates: "[\(gateJSON(type: "docker-hub"))]"))
        }
    }

    @Test func rejectsNonDenyDefaultAction() {
        rejection("invalid-policy") {
            _ = try NetworkPolicy.decode(policyJSON(gates: "[]", action: "allow"))
        }
    }

    @Test func rejectsWrongSchemaAndZone() {
        rejection("invalid-policy") {
            _ = try NetworkPolicy.decode(policyJSON(gates: "[]", schema: "sanjbox.network-policy.v0"))
        }
        rejection("invalid-identifier") {
            _ = try NetworkPolicy.decode(policyJSON(gates: "[]", zoneID: "a1b2c"))
        }
    }

    @Test func rejectsMalformedUpstream() {
        for upstream in ["registry.npmjs.org:443", "https://registry.npmjs.org", "registry.npmjs.org/path",
                          "*.npmjs.org", "localhost", "Registry.npmjs.org", "-bad.example.com"] {
            do {
                _ = try NetworkPolicy.decode(policyJSON(gates: "[\(gateJSON(upstream: upstream))]"))
                Issue.record("upstream '\(upstream)' must be rejected")
            } catch let error as ContractError {
                #expect(error.code == "invalid-policy", "upstream '\(upstream)': \(error)")
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test func rejectsDuplicateAndMalformedGateIDs() {
        let gate = gateJSON()
        rejection("invalid-policy") {
            _ = try NetworkPolicy.decode(policyJSON(gates: "[\(gate),\(gate)]"))
        }
        rejection("invalid-identifier") {
            _ = try NetworkPolicy.decode(policyJSON(gates: "[\(gateJSON(id: "NPM_Edge"))]"))
        }
    }

    @Test func rejectsMethodRules() {
        // methods only for model-api
        rejection("invalid-policy") {
            _ = try NetworkPolicy.decode(policyJSON(gates: "[\(gateJSON(methods: "[\"POST\"]"))]"))
        }
        // model-api requires at least one method
        rejection("invalid-policy") {
            _ = try NetworkPolicy.decode(policyJSON(gates: "[\(gateJSON(type: "model-api", methods: "[]"))]"))
        }
        // unknown method
        rejection("invalid-policy") {
            _ = try NetworkPolicy.decode(policyJSON(gates: "[\(gateJSON(type: "model-api", methods: "[\"PUT\"]"))]"))
        }
        // duplicate method
        rejection("invalid-policy") {
            _ = try NetworkPolicy.decode(policyJSON(gates: "[\(gateJSON(type: "model-api", methods: "[\"POST\",\"POST\"]"))]"))
        }
        // accepted: model-api with POST
        #expect(throws: Never.self) {
            _ = try NetworkPolicy.decode(policyJSON(gates: "[\(gateJSON(type: "model-api", methods: "[\"POST\"]"))]"))
        }
    }

    @Test func rejectsInvalidByteLimits() {
        rejection("invalid-range") {
            _ = try NetworkPolicy.decode(policyJSON(gates: "[\(gateJSON(request: "0"))]"))
        }
        rejection("invalid-range") {
            _ = try NetworkPolicy.decode(policyJSON(gates: "[\(gateJSON(response: "16777217"))]"))
        }
        rejection("invalid-range") {
            _ = try NetworkPolicy.decode(policyJSON(gates: "[\(gateJSON(request: "1048576.5"))]"))
        }
    }

    @Test func rejectsTooManyGates() {
        let gate = gateJSON()
        let gates = "[" + Array(repeating: gate, count: NetworkPolicy.maxGates + 1).joined(separator: ",") + "]"
        rejection("collection-limit") { _ = try NetworkPolicy.decode(policyJSON(gates: gates)) }
    }

    @Test func rejectsOversizedDocument() {
        let filler = String(repeating: "a", count: NetworkPolicy.maxBytes + 1)
        rejection("input-too-large") {
            _ = try NetworkPolicy.decode(policyJSON(gates: "[\(gateJSON(id: filler))]"))
        }
    }

    @Test func rejectsDuplicateKeys() {
        let body = "{\"schema\":\"sanjbox.network-policy.v1\",\"zoneID\":\"a1b2\",\"defaultAction\":\"deny\",\"defaultAction\":\"allow\",\"gates\":[]}"
        rejection("duplicate-key") { _ = try NetworkPolicy.decode(Data(body.utf8)) }
    }
}
