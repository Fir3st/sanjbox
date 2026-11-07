import Foundation
import Testing
@testable import SanjboxContracts

// Wire/decoder negatives. Each test pins one documented rejection so a relaxed decoder fails.
@Suite("Envelope a striktní dekódování")
struct EnvelopeTests {
    @Test func acceptsWellFormedEnvelope() throws {
        let data = envelopeJSON(kind: "helper.capabilities", body: "{}")
        let envelope = try XPCEnvelope.decode(data)
        #expect(envelope.version == 1)
        #expect(envelope.kind == "helper.capabilities")
        #expect(try HelperMessage.decode(data) == .capabilities)
    }

    @Test func rejectsOversizedMessage() {
        let huge = String(repeating: " ", count: XPCEnvelope.maxBytes + 1)
        rejection("input-too-large") { _ = try XPCEnvelope.decode(Data(huge.utf8)) }
    }

    @Test func rejectsEmptyMessage() {
        rejection("invalid-json") { _ = try XPCEnvelope.decode(Data()) }
    }

    @Test func rejectsUnknownTopLevelField() {
        rejection("unknown-field") {
            _ = try XPCEnvelope.decode(envelopeJSON(kind: "helper.capabilities", body: "{}", extra: "\"debug\":true"))
        }
    }

    @Test func rejectsMissingRequiredField() {
        rejection("missing-field") {
            _ = try XPCEnvelope.decode(Data("{\"version\":1,\"kind\":\"helper.capabilities\"}".utf8))
        }
    }

    @Test func rejectsDuplicateKey() {
        let data = Data("{\"version\":1,\"version\":1,\"kind\":\"helper.capabilities\",\"body\":\"e30=\"}".utf8)
        rejection("duplicate-key") { _ = try XPCEnvelope.decode(data) }
    }

    @Test func rejectsTrailingBytes() {
        rejection("trailing-input") {
            _ = try XPCEnvelope.decode(envelopeJSON(kind: "helper.capabilities", body: "{}") + Data("{}".utf8))
        }
    }

    @Test func rejectsOtherProtocolVersions() {
        for version in [0, 2, 99] {
            rejection("invalid-version") {
                _ = try XPCEnvelope.decode(envelopeJSON(kind: "helper.capabilities", body: "{}", version: version))
            }
        }
    }

    @Test func rejectsMalformedKindText() {
        rejection("unknown-message-kind") {
            _ = try XPCEnvelope.decode(envelopeJSON(kind: "helper capabilities/../x", body: "{}"))
        }
    }

    @Test func rejectsVersionOverflow() {
        rejection("invalid-range") {
            _ = try XPCEnvelope.decode(Data("{\"version\":4294967296,\"kind\":\"helper.capabilities\",\"body\":\"e30=\"}".utf8))
        }
    }

    @Test func rejectsDeepNesting() {
        let nested = Data((String(repeating: "[", count: 24) + String(repeating: "]", count: 24)).utf8)
        rejection("nesting-limit") {
            var preflight = try JSONPreflight(nested, limit: 4096)
            try preflight.check()
        }
    }

    @Test func rejectsOverlongStringField() {
        let longKind = String(repeating: "a", count: 65)
        rejection("string-limit") {
            _ = try XPCEnvelope.decode(envelopeJSON(kind: longKind, body: "{}"))
        }
    }
}
