import Foundation
import Testing
@testable import SanjboxContracts

// Helper message set: positive round trips plus one negative test per documented validation.
@Suite("Zprávy helperu")
struct HelperMessageTests {
    @Test func roundTripsEveryKindCanonically() throws {
        let messages: [HelperMessage] = [
            .capabilities,
            .createZone(CreateZoneRequest(zoneID: "a1b2", uid: 4501, gid: 4500)),
            .startZone(ZoneRef(zoneID: "a1b2")),
            .pauseZone(ZoneRef(zoneID: "a1b2")),
            .stopZone(ZoneRef(zoneID: "a1b2")),
            .zoneStatus(ZoneRef(zoneID: "a1b2")),
            .applyNetworkPolicy(ApplyNetworkPolicyRequest(zoneID: "a1b2", policy: validPolicy())),
        ]
        for message in messages {
            let first = try message.encoded()
            let decoded = try HelperMessage.decode(first)
            #expect(decoded == message)
            #expect(try decoded.encoded() == first, "encoder must be canonical for \(message.kind.rawValue)")
        }
    }

    @Test func rejectsUnknownMessageKind() {
        rejection("unknown-message-kind") {
            _ = try HelperMessage.decode(envelopeJSON(kind: "zone.teleport", body: "{}"))
        }
    }

    @Test func rejectsUnknownBodyField() {
        let body = jsonObject([("zoneID", "\"a1b2\""), ("force", "true")])
        rejection("unknown-field") {
            _ = try HelperMessage.decode(envelopeJSON(kind: "zone.start", body: body))
        }
    }

    @Test func rejectsFieldInBodylessKind() {
        rejection("unknown-field") {
            _ = try HelperMessage.decode(envelopeJSON(kind: "helper.capabilities", body: "{\"verbose\":true}"))
        }
    }

    @Test func rejectsMissingRequiredBodyField() {
        rejection("missing-field") {
            _ = try HelperMessage.decode(envelopeJSON(kind: "zone.start", body: "{}"))
        }
    }

    @Test func rejectsDuplicateBodyKey() {
        rejection("duplicate-key") {
            _ = try HelperMessage.decode(envelopeJSON(kind: "zone.start", body: "{\"zoneID\":\"a1b2\",\"zoneID\":\"a1b3\"}"))
        }
    }

    @Test func rejectsZoneIdentifierOfWrongShape() {
        for zoneID in ["abc", "abcde", "A1B2", "a1b-", ""] {
            do {
                _ = try HelperMessage.decode(envelopeJSON(kind: "zone.stop", body: zoneRefJSON(zoneID)))
                Issue.record("zone id '\(zoneID)' must be rejected")
            } catch let error as ContractError {
                #expect(error.code == "invalid-identifier", "zone id '\(zoneID)': \(error)")
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test func rejectsUIDAndGIDOverflow() {
        let body = jsonObject([("zoneID", "\"a1b2\""), ("uid", "4294967296"), ("gid", "4500")])
        rejection("invalid-range") {
            _ = try HelperMessage.decode(envelopeJSON(kind: "zone.create", body: body))
        }
        let negative = jsonObject([("zoneID", "\"a1b2\""), ("uid", "4501"), ("gid", "-1")])
        rejection("invalid-range") {
            _ = try HelperMessage.decode(envelopeJSON(kind: "zone.create", body: negative))
        }
    }

    @Test func rejectsUIDBelowDocumentedMinimum() {
        let body = jsonObject([("zoneID", "\"a1b2\""), ("uid", "501"), ("gid", "500")])
        rejection("invalid-range") {
            _ = try HelperMessage.decode(envelopeJSON(kind: "zone.create", body: body))
        }
    }

    @Test func rejectsFractionalUID() {
        let body = jsonObject([("zoneID", "\"a1b2\""), ("uid", "4501.5"), ("gid", "4500")])
        rejection("invalid-range") {
            _ = try HelperMessage.decode(envelopeJSON(kind: "zone.create", body: body))
        }
    }

    @Test func rejectsPolicyForAnotherZone() throws {
        let policy = try validPolicy(zoneID: "zz99").encoded()
        let request = ApplyNetworkPolicyRequest(zoneID: "a1b2", policy: try NetworkPolicy.decode(policy))
        rejection("invalid-policy") { try request.validate() }
    }

    @Test func rejectsInvalidPolicyInsideMessage() {
        // `defaultAction: allow` is not representable in v0; the nested shape is closed but the
        // semantic check still has to run before the message is accepted.
        var policy = validPolicy()
        policy.defaultAction = "allow"
        rejection("invalid-policy") {
            _ = try ApplyNetworkPolicyRequest(zoneID: "a1b2", policy: policy).validate()
        }
    }

    @Test func rejectsOversizedBody() throws {
        let filler = String(repeating: "x", count: XPCEnvelope.maxBodyBytes + 16)
        rejection("input-too-large") {
            _ = try HelperMessage.decode(envelopeJSON(kind: "zone.status", body: "{\"zoneID\":\"\(filler)\"}"))
        }
    }
}
