import Foundation
import Testing
@testable import SanjboxContracts

// Broker v0: the message set is intentionally empty, so the only testable behaviour is the
// versioned envelope plus the refusal rules.
@Suite("Broker broker-v0")
struct BrokerContractTests {
    @Test func acceptedKindSetIsEmptyByDesign() {
        #expect(BrokerContract.acceptedKinds.isEmpty)
        #expect(BrokerContract.protocolVersion == 0)
    }

    @Test func rejectsEveryWellFormedKind() {
        for kind in ["broker.hello", "broker.status", "zone.start", "helper.capabilities"] {
            rejection("unknown-message-kind") {
                _ = try BrokerContract.decode(envelopeJSON(kind: kind, body: "{}", version: 0))
            }
        }
    }

    @Test func rejectsWrongVersion() {
        for version in [1, 2, 4294967295] {
            rejection("invalid-version") {
                _ = try BrokerContract.decode(envelopeJSON(kind: "broker.status", body: "{}", version: version))
            }
        }
    }

    @Test func reportsVersionBeforeKind() {
        // A message that is both wrong-version and unknown-kind must fail as a version error, so
        // that a version mismatch is never mistaken for an unimplemented message.
        rejection("invalid-version") {
            _ = try BrokerContract.decode(envelopeJSON(kind: "broker.teleport", body: "{}", version: 7))
        }
    }

    @Test func rejectsUnknownEnvelopeField() {
        rejection("unknown-field") {
            _ = try BrokerContract.decode(envelopeJSON(kind: "broker.status", body: "{}", version: 0, extra: "\"trace\":1"))
        }
    }

    @Test func rejectsOversizedEnvelope() {
        let body = String(repeating: "x", count: BrokerContract.maxBytes)
        rejection("input-too-large") {
            _ = try BrokerContract.decode(envelopeJSON(kind: "broker.status", body: body, version: 0))
        }
    }

    @Test func rejectsEmptyAndMalformedInput() {
        rejection("invalid-json") { _ = try BrokerContract.decode(Data()) }
        rejection("invalid-json") { _ = try BrokerContract.decode(Data("not json".utf8)) }
        rejection("unknown-message-kind") { _ = try BrokerContract.decode(envelopeJSON(kind: "", body: "{}", version: 0)) }
    }
}
