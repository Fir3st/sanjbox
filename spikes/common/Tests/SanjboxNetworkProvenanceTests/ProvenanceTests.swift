import Foundation
import Security
import XCTest
@testable import SanjboxNetworkProvenance

final class ProvenanceTests: XCTestCase {
    func testPreparedFrameBindsRunFlowAndFreshChallenge() throws {
        let run = UUID()
        let a = try FlowChallenge.prepare(runID: run), b = try FlowChallenge.prepare(runID: run)
        try a.validate(); XCTAssertNotEqual(a.flowID, b.flowID); XCTAssertNotEqual(a.challenge, b.challenge)
        let claims = try XCTUnwrap(FlowChallenge.claims(a.bytes))
        XCTAssertEqual(claims.runID, run); XCTAssertEqual(claims.flowID, a.flowID); XCTAssertEqual(claims.challenge, a.challenge)
        XCTAssertNil(FlowChallenge.claims(a.bytes + Data([0])))
        XCTAssertNil(FlowChallenge.claims(Data(a.bytes.dropLast())))
        XCTAssertNil(FlowChallenge.claims(Data()))
    }
    func testExpiredFutureAndInvalidChallengeRejected() throws {
        var flow = try FlowChallenge.prepare(runID: UUID())
        XCTAssertThrowsError(try flow.validate(now: Date().addingTimeInterval(601)))
        XCTAssertThrowsError(try flow.validate(now: Date().addingTimeInterval(-2)))
        flow.challenge = String(repeating: "g", count: 64); XCTAssertThrowsError(try flow.validate())
    }
    func testExactEndpointsAndUnsupportedFamilies() throws {
        for address in ["127.0.0.1", "::1", "192.0.2.1", "2001:db8::1"] {
            try NetworkEndpoint(host: address, port: 12345).validate(allowZeroPort: false)
        }
        for address in ["0.0.0.0", "::", "::ffff:127.0.0.1", "::192.0.2.1", "fe80::1", "fe80::1%lo0", "224.0.0.1", "255.255.255.255", "169.254.1.2", "ff02::1", "localhost", "127.0.0.1\0evil", "127.00.0.1", "2001:DB8::1"] {
            XCTAssertThrowsError(try NetworkEndpoint(host: address, port: 12345).validate(allowZeroPort: false), address)
        }
        XCTAssertThrowsError(try NetworkEndpoint(host: "127.0.0.1", port: 0).validate(allowZeroPort: false))
        try NetworkEndpoint(host: "127.0.0.1", port: 0).validate(allowZeroPort: true)
    }
    func testStrictJSONRejectsUnknownEscapedDuplicateAndDepth() throws {
        struct Value: Decodable { var a: Int }
        let shape = Shape.object(["a": .scalar])
        XCTAssertEqual(try strictDecode(Value.self, data: Data("{\"a\":1}".utf8), shape: shape).a, 1)
        for text in [#"{"a":1,"a":2}"#, #"{"a":1,"\u0061":2}"#, #"{"a":1,"b":2}"#, #"{"a":1}{}"#, #"{"a":true}"#] {
            XCTAssertThrowsError(try strictDecode(Value.self, data: Data(text.utf8), shape: shape))
        }
        XCTAssertThrowsError(try strictDecode(Value.self, data: Data((String(repeating: "[", count: 25) + "0" + String(repeating: "]", count: 25)).utf8), shape: shape))
    }
    func testSignaturePolicyRejectsEvenFalseTaskAllowAndIncompleteMetadata() throws {
        var metadata: [String: Any] = [kSecCodeInfoFlags as String: NSNumber(value: 0x10000), kSecCodeInfoUnique as String: Data(repeating: 1, count: 20)]
        XCTAssertTrue(try OwnSignature.inspect(valid: true, metadata: metadata).permitsLive)
        XCTAssertFalse(try OwnSignature.inspect(valid: false, metadata: metadata).permitsLive)
        metadata[kSecCodeInfoEntitlementsDict as String] = ["com.apple.security.get-task-allow": false]
        XCTAssertFalse(try OwnSignature.inspect(valid: true, metadata: metadata).permitsLive)
        metadata[kSecCodeInfoEntitlementsDict as String] = nil
        metadata[kSecCodeInfoFlags as String] = true
        XCTAssertThrowsError(try OwnSignature.inspect(valid: true, metadata: metadata))
    }
    private func expectation() throws -> NetworkExpectation {
        let data = Data(#"{"schemaVersion":1,"scope":"testArea","identity":{"realUID":4501,"effectiveUID":4501,"realGID":4500,"effectiveGID":4500,"kernelGroups":[4500],"requiredGroups":[4500],"forbiddenGroups":[20,80],"auditSessionID":200,"auditUID":4501,"auditFlags":0,"managerName":"Aqua","managerUID":4501,"windowUID":4501,"windowAuditSessionID":200,"onConsole":false,"loginDone":true},"signature":{"valid":true,"hardenedRuntime":true,"getTaskAllowAbsent":true,"codeHash":"1111111111111111111111111111111111111111"},"forbiddenAuditSessionIDs":[100]}"#.utf8)
        return try NetworkExpectation.decode(data)
    }
    func testTestAreaRetainsStrictC1IdentityPolicy() throws {
        let original = try expectation()
        for index in 0..<9 {
            var value = original
            switch index {
            case 0: value.forbiddenAuditSessionIDs = []
            case 1: value.forbiddenAuditSessionIDs = [200]
            case 2: value.identity.onConsole = true
            case 3: value.identity.managerName = "Background"
            case 4: value.identity.forbiddenGroups = []
            case 5: value.identity.requiredGroups = []
            case 6: value.identity.windowAuditSessionID = 201
            case 7: value.identity.realUID = 501
            default: value.signature.hardenedRuntime = false
            }
            XCTAssertThrowsError(try value.validate(), "variant \(index)")
        }
    }
    func testRegistrationBoundsAndFreshness() throws {
        let flow = try FlowChallenge.prepare(runID: UUID())
        let value = NetworkRegistration(schemaVersion: 1, scope: .hostDiagnostic, flow: flow,
            transport: .tcp, endpoint: .init(host: "127.0.0.1", port: 12345), controlledTarget: true,
            durationMilliseconds: 1000, maximumContacts: 8)
        for index in 0..<5 {
            var changed = value
            switch index {
            case 0: changed.durationMilliseconds = 10001
            case 1: changed.durationMilliseconds = 99
            case 2: changed.maximumContacts = 17
            case 3: changed.controlledTarget = false
            default: changed.schemaVersion = 2
            }
            XCTAssertThrowsError(try changed.validate(receiver: false))
        }
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(try NetworkRegistration.decode(encoded, receiver: false).flow, flow)
    }

}
