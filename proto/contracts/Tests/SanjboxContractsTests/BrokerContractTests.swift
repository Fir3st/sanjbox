import Foundation
import Testing
@testable import SanjboxContracts

@Suite("Narrow broker messages")
struct BrokerContractTests {
    let messages: [BrokerMessage] = [
        .frame(.init(zoneID: "a1b2", streamID: "window-1", sequence: 1, width: 640, height: 480)),
        .keyInput(.init(zoneID: "a1b2", streamID: "window-1", sequence: 1, keyCode: 0, action: .down)),
        .pointerInput(.init(zoneID: "a1b2", streamID: "window-1", sequence: 1, x: 639, y: 479, action: .move)),
    ]
    @Test func roundTripsEveryKind() throws {
        #expect(BrokerContract.protocolVersion == 1)
        #expect(Set(messages.map { $0.kind.rawValue }) == BrokerContract.acceptedKinds)
        for message in messages {
            let data = try message.encoded()
            #expect(try BrokerMessage.decode(data) == message)
            #expect(try BrokerMessage.decode(data).encoded() == data)
            #expect(try BrokerContract.decode(data).kind == message.kind.rawValue)
            var context = BrokerDeliveryContext(peerRole: message.requiredPeerRole, zoneID: "a1b2", streamID: "window-1",
                width: 640, height: 480, lastSequence: 0, surfaceAttachmentCount: message.requiredSurfaceAttachments)
            try message.validateDelivery(in: context)
            context.lastSequence = 1
            rejection("sequence-violation") { try message.validateDelivery(in: context) }
            context.lastSequence = UInt64.max
            rejection("sequence-violation") { try message.validateDelivery(in: context) }
        }
    }
    @Test func rejectsEnvelopeVersionFieldsAndPrivilegedKinds() throws {
        for version in [0, 2, 4294967295] {
            rejection("invalid-version") { _ = try BrokerContract.decode(envelopeJSON(kind: "zone.start", body: "{}", version: version)) }
        }
        for kind in ["", "broker.status", "zone.start", "zone.run", "policy.apply", "helper.reply"] {
            rejection("unknown-message-kind") { _ = try BrokerContract.decode(envelopeJSON(kind: kind, body: "{}")) }
        }
        rejection("unknown-field") { _ = try BrokerContract.decode(envelopeJSON(kind: "broker.frame", body: "{}", extra: "\"trace\":1")) }
        for text in ["", "no json", "{}", "{\"version\":1,\"version\":1,\"kind\":\"broker.frame\",\"body\":\"e30=\"}",
                     "{\"version\":1,\"kind\":\"broker.frame\",\"body\":\"!\"}"] {
            #expect(throws: ContractError.self) { _ = try BrokerContract.decode(Data(text.utf8)) }
        }
        rejection("input-too-large") { _ = try BrokerContract.decode(Data(repeating: 32, count: BrokerContract.maxBytes + 1)) }
    }
    @Test func validatesEveryBodyFieldAndRejectsExtraChannels() throws {
        for message in messages {
            let envelope = try BrokerContract.decode(message.encoded())
            let original = try #require(JSONSerialization.jsonObject(with: envelope.body) as? [String: Any])
            for field in original.keys {
                var missing = original; missing.removeValue(forKey: field)
                let body = String(decoding: try JSONSerialization.data(withJSONObject: missing), as: UTF8.self)
                rejection("missing-field") { _ = try BrokerMessage.decode(envelopeJSON(kind: message.kind.rawValue, body: body)) }
                var wrong = original; wrong[field] = ["injected"]
                #expect(throws: ContractError.self) {
                    _ = try BrokerMessage.decode(envelopeJSON(kind: message.kind.rawValue,
                        body: String(decoding: JSONSerialization.data(withJSONObject: wrong), as: UTF8.self)))
                }
            }
            for field in ["pid", "globalSurfaceID", "path", "auditToken", "uid", "command"] {
                var extra = original; extra[field] = 1
                let body = String(decoding: try JSONSerialization.data(withJSONObject: extra), as: UTF8.self)
                rejection("unknown-field") { _ = try BrokerMessage.decode(envelopeJSON(kind: message.kind.rawValue, body: body)) }
            }
            let body = String(decoding: envelope.body, as: UTF8.self)
            rejection("duplicate-key") { _ = try BrokerMessage.decode(envelopeJSON(kind: message.kind.rawValue,
                body: "{\"zoneID\":\"a1b2\"," + body.dropFirst())) }
            for zone in ["ABCD", "abc", "../a"] {
                var bad = original; bad["zoneID"] = zone
                rejection("invalid-identifier") { _ = try BrokerMessage.decode(envelopeJSON(kind: message.kind.rawValue,
                    body: String(decoding: JSONSerialization.data(withJSONObject: bad), as: UTF8.self))) }
            }
            var bad = original; bad["streamID"] = "../host"
            rejection("invalid-identifier") { _ = try BrokerMessage.decode(envelopeJSON(kind: message.kind.rawValue,
                body: String(decoding: JSONSerialization.data(withJSONObject: bad), as: UTF8.self))) }
            for number in ["0", "-1", "1.0", "1e0", "18446744073709551616"] {
                let raw = body.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":\(number)")
                rejection("invalid-range") { _ = try BrokerMessage.decode(envelopeJSON(kind: message.kind.rawValue, body: raw)) }
            }
        }
    }
    @Test func boundsAndSemanticRejectionsMatchOnEncodeAndDecode() throws {
        let bad: [BrokerMessage] = [
            .frame(.init(zoneID: "a1b2", streamID: "w", sequence: 1, width: 0, height: 1)),
            .frame(.init(zoneID: "a1b2", streamID: "w", sequence: 1, width: 1, height: 8193)),
            .frame(.init(zoneID: "a1b2", streamID: "w", sequence: 1, width: 1, height: 1, surfaceAttachmentIndex: 1)),
            .keyInput(.init(zoneID: "a1b2", streamID: "w", sequence: 1, keyCode: 128, action: .up)),
            .keyInput(.init(zoneID: "a1b2", streamID: "w", sequence: 1, keyCode: 0, action: .up, modifiers: 32)),
            .pointerInput(.init(zoneID: "a1b2", streamID: "w", sequence: 1, x: 8192, y: 0, action: .move)),
            .pointerInput(.init(zoneID: "a1b2", streamID: "w", sequence: 1, x: 0, y: 8192, action: .move)),
            .pointerInput(.init(zoneID: "a1b2", streamID: "w", sequence: 1, x: 0, y: 0, action: .down, button: 3)),
            .pointerInput(.init(zoneID: "a1b2", streamID: "w", sequence: 1, x: 0, y: 0, action: .down)),
            .pointerInput(.init(zoneID: "a1b2", streamID: "w", sequence: 1, x: 0, y: 0, action: .move, button: 1)),
        ]
        for message in bad {
            #expect(throws: ContractError.self) { _ = try message.encoded() }
            let body: Data
            switch message {
            case .frame(let r): body = try JSONEncoder().encode(r)
            case .keyInput(let r): body = try JSONEncoder().encode(r)
            case .pointerInput(let r): body = try JSONEncoder().encode(r)
            }
            let wire = try JSONEncoder().encode(BrokerEnvelope(kind: message.kind.rawValue, body: body))
            #expect(throws: ContractError.self) { _ = try BrokerMessage.decode(wire) }
        }
        let boundaries: [BrokerMessage] = [
            .frame(.init(zoneID: "a1b2", streamID: "w", sequence: UInt64.max, width: 8192, height: 8192)),
            .keyInput(.init(zoneID: "a1b2", streamID: "w", sequence: UInt64.max, keyCode: 127, action: .up, modifiers: 31)),
            .pointerInput(.init(zoneID: "a1b2", streamID: "w", sequence: UInt64.max, x: 8191, y: 8191, action: .up, button: 2)),
        ]
        for message in boundaries { #expect(try BrokerMessage.decode(message.encoded()) == message) }
        let frame = try BrokerContract.decode(messages[0].encoded())
        for size in [BrokerContract.maxBodyBytes - 1, BrokerContract.maxBodyBytes] {
            let padded = frame.body + Data(repeating: 32, count: size - frame.body.count)
            let envelope = BrokerEnvelope(kind: "broker.frame", body: padded)
            #expect(try BrokerMessage.decode(envelope.encoded()) == messages[0])
        }
        for size in [BrokerContract.maxBodyBytes, BrokerContract.maxBodyBytes + 1] {
            let data = envelopeJSON(kind: "broker.frame", body: String(repeating: " ", count: size))
            rejection(size == BrokerContract.maxBodyBytes ? "invalid-json" : "input-too-large") { _ = try BrokerContract.decode(data) }
        }
        for message in messages.dropFirst() {
            let envelope = try BrokerContract.decode(message.encoded())
            let body = String(decoding: envelope.body, as: UTF8.self)
                .replacingOccurrences(of: "\"down\"", with: "\"execute\"")
                .replacingOccurrences(of: "\"move\"", with: "\"execute\"")
            rejection("invalid-value") { _ = try BrokerMessage.decode(envelopeJSON(kind: message.kind.rawValue, body: body)) }
        }
        #expect(throws: ContractError.self) { _ = try BrokerEnvelope(kind: "broker.frame", body: Data("{}".utf8)).encoded() }
    }
    @Test func trustedContextCannotBeReplacedByPayloadClaims() throws {
        for message in messages {
            let context = BrokerDeliveryContext(peerRole: message.requiredPeerRole, zoneID: "a1b2", streamID: "window-1",
                width: 640, height: 480, lastSequence: 0, surfaceAttachmentCount: message.requiredSurfaceAttachments)
            var wrong = context; wrong.peerRole = context.peerRole == .hostController ? .sessionAgent : .hostController
            rejection("invalid-value") { try message.validateDelivery(in: wrong) }
            wrong = context; wrong.zoneID = "c3d4"
            rejection("invalid-value") { try message.validateDelivery(in: wrong) }
            wrong = context; wrong.streamID = "other"
            rejection("invalid-value") { try message.validateDelivery(in: wrong) }
            wrong = context; wrong.surfaceAttachmentCount += 1
            rejection("invalid-value") { try message.validateDelivery(in: wrong) }
            wrong = context; wrong.width = 0
            rejection("invalid-value") { try message.validateDelivery(in: wrong) }
            wrong = context; wrong.height = 8193
            rejection("invalid-value") { try message.validateDelivery(in: wrong) }
        }
        let frameContext = BrokerDeliveryContext(peerRole: .sessionAgent, zoneID: "a1b2", streamID: "window-1",
            width: 639, height: 480, lastSequence: 0, surfaceAttachmentCount: 1)
        rejection("invalid-value") { try messages[0].validateDelivery(in: frameContext) }
        let inputContext = BrokerDeliveryContext(peerRole: .hostController, zoneID: "a1b2", streamID: "window-1",
            width: 639, height: 479, lastSequence: 0, surfaceAttachmentCount: 0)
        rejection("invalid-range") { try messages[2].validateDelivery(in: inputContext) }
    }
}
