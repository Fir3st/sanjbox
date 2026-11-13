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

    /// The body budget is declared on the *raw* body, not on its base64 wire text. A body one byte
    /// below and exactly at the declared limit must survive `decode(encode(x)) == x`.
    @Test func bodyBudgetBoundaryRoundTrips() throws {
        for size in [XPCEnvelope.maxBodyBytes - 1, XPCEnvelope.maxBodyBytes] {
            let envelope = XPCEnvelope(kind: "helper.capabilities",
                                       body: Data(repeating: 0x62, count: size))
            let wire = try envelope.encoded()
            #expect(wire.count <= XPCEnvelope.maxBytes, "body \(size) wire \(wire.count)")
            #expect(try XPCEnvelope.decode(wire) == envelope)
        }
    }

    @Test func bodyOneByteOverBudgetIsRejected() {
        let over = XPCEnvelope(kind: "helper.capabilities",
                               body: Data(repeating: 0x62, count: XPCEnvelope.maxBodyBytes + 1))
        rejection("input-too-large") { _ = try over.encoded() }
        rejection("input-too-large") {
            _ = try XPCEnvelope.decode(envelopeJSON(kind: "helper.capabilities",
                body: String(repeating: "b", count: XPCEnvelope.maxBodyBytes + 1)))
        }
    }

    @Test func slashHeavyBase64FitsTheWireBudget() throws {
        // Valid JSON with U+FFFF produces enough '/' in base64 to exceed maxBytes when JSON
        // escapes slashes. Exercise both documented raw-body boundaries, not only ASCII bodies.
        let json = Data(("{\"padding\":\"" + String(repeating: "\u{ffff}", count: 16_379) + "\"}").utf8)
        #expect(json.count == XPCEnvelope.maxBodyBytes - 1)
        for size in [XPCEnvelope.maxBodyBytes - 1, XPCEnvelope.maxBodyBytes] {
            let body = json + Data(repeating: 0x20, count: size - json.count)
            let envelope = XPCEnvelope(kind: "helper.capabilities", body: body)
            let wire = try envelope.encoded()
            #expect(wire.count <= XPCEnvelope.maxBytes)
            #expect(try XPCEnvelope.decode(wire) == envelope)
        }
    }

}
