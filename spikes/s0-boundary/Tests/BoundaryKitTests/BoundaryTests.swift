import Darwin
import Foundation
import SanjboxProbeKit
import Security
import XCTest
@testable import BoundaryKit

final class BoundaryTests: XCTestCase {
    private func expectationObject() -> [String: Any] {
        ["schemaVersion": 1, "scope": "synthetic-self-fixture", "realUID": 450, "effectiveUID": 450,
         "realGID": 701, "effectiveGID": 701, "kernelGroups": [701], "forbiddenGroups": [20, 80],
         "auditSessionID": 12345, "auditUID": 450, "launchdManagerName": "Aqua", "launchdManagerUID": 450,
         "window": ["userID": 450, "auditSessionID": 12345, "onConsole": false, "loginDone": true]]
    }
    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    private func contextObject() -> [String: Any] {
        ["pid": 123, "parentPID": 122, "realUID": 450, "effectiveUID": 450, "realGID": 701, "effectiveGID": 701,
         "kernelGroups": [701], "groupMembership": [["gid": 701, "isMember": true], ["gid": 20, "isMember": false], ["gid": 80, "isMember": false]],
         "audit": ["sessionID": 12345, "auditUID": 450, "flags": 0],
         "launchdManager": ["name": "Aqua", "uid": 450],
         "windowSession": ["userID": 450, "auditSessionID": 12345, "onConsole": false, "loginDone": true]]
    }
    private func context(_ object: [String: Any]? = nil) throws -> ProbeContext {
        try JSONDecoder().decode(ProbeContext.self, from: JSONSerialization.data(withJSONObject: object ?? contextObject()))
    }
    func testExactIdentityAcceptsCompletePreRegisteredContext() throws {
        let expected = try BoundaryExpectation.parse(json(expectationObject()))
        XCTAssertEqual(expected.mismatches(try context()), [])
    }
    func testEveryMandatoryIdentityFieldRejectsMismatch() throws {
        let expected = try BoundaryExpectation.parse(json(expectationObject()))
        for field in ["realUID", "effectiveUID", "realGID", "effectiveGID"] {
            var object = contextObject(); object[field] = 999
            XCTAssertFalse(expected.mismatches(try context(object)).isEmpty, field)
        }
        for (section, field, value) in [("audit", "sessionID", 9 as Any), ("audit", "auditUID", 9),
                                       ("launchdManager", "name", "Background"), ("launchdManager", "uid", 9),
                                       ("windowSession", "userID", 9), ("windowSession", "auditSessionID", 9),
                                       ("windowSession", "onConsole", true), ("windowSession", "loginDone", false)] {
            var object = contextObject(), nested = object[section] as! [String: Any]
            nested[field] = value; object[section] = nested
            XCTAssertFalse(expected.mismatches(try context(object)).isEmpty, section + "." + field)
        }
    }
    func testExtraMissingDuplicateAndUnresolvedGroupsAreInvalid() throws {
        let expected = try BoundaryExpectation.parse(json(expectationObject()))
        for groups in [[701, 20], [], [701, 701]] {
            var object = contextObject(); object["kernelGroups"] = groups
            XCTAssertFalse(expected.mismatches(try context(object)).isEmpty)
        }
        for observations: [[String: Any]] in [[], [["gid": 701, "isMember": NSNull()]],
                                               [["gid": 701, "isMember": true], ["gid": 701, "isMember": true], ["gid": 20, "isMember": false]]] {
            var object = contextObject(); object["groupMembership"] = observations
            XCTAssertFalse(expected.mismatches(try context(object)).isEmpty)
        }
    }
    func testAbsentWindowIsExplicitAndExact() throws {
        var expectedObject = expectationObject(); expectedObject["window"] = NSNull()
        let expected = try BoundaryExpectation.parse(json(expectedObject))
        XCTAssertFalse(expected.mismatches(try context()).isEmpty)
        var object = contextObject(); object["windowSession"] = NSNull()
        XCTAssertEqual(expected.mismatches(try context(object)), [])
    }
    func testMissingAuditManagerAndWindowCannotPass() throws {
        let expected = try BoundaryExpectation.parse(json(expectationObject()))
        for section in ["audit", "launchdManager", "windowSession"] {
            var object = contextObject(); object.removeValue(forKey: section)
            XCTAssertFalse(expected.mismatches(try context(object)).isEmpty)
        }
    }
    func testSchemaRejectsEveryMissingTopLevelFieldAndUnknownFields() throws {
        for key in expectationObject().keys {
            var object = expectationObject(); object.removeValue(forKey: key)
            XCTAssertThrowsError(try BoundaryExpectation.parse(json(object)), key)
        }
        var object = expectationObject(); object["allowHost"] = true
        XCTAssertThrowsError(try BoundaryExpectation.parse(json(object)))
    }
    func testDuplicateEscapedAndNestedKeysAreRejected() throws {
        let valid = try json(expectationObject())
        for suffix in [#", "realUID":450}"#, #", "\u0072ealUID":450}"#] {
            XCTAssertThrowsError(try BoundaryExpectation.parse(String(valid.dropLast()) + suffix))
        }
        let nested = valid.replacingOccurrences(of: #""loginDone":true"#, with: #""loginDone":true,"loginDone":true"#)
        XCTAssertNotEqual(nested, valid)
        XCTAssertThrowsError(try BoundaryExpectation.parse(nested))
    }
    func testInvalidASIDsGroupsRootAndScopeAreRejected() throws {
        for (key, value) in [("auditSessionID", 0 as Any), ("auditSessionID", -1), ("auditUID", 4294967295 as UInt64),
                             ("realUID", 0), ("effectiveUID", 0), ("scope", "approved-host"), ("kernelGroups", []),
                             ("kernelGroups", [701, 701]), ("forbiddenGroups", [701])] {
            var object = expectationObject(); object[key] = value
            XCTAssertThrowsError(try BoundaryExpectation.parse(json(object)), key)
        }
    }
    func testBoundedJSONRejectsOversizeDepthFloatsTrailingDataAndInvalidUTF8Escapes() throws {
        let valid = try json(expectationObject())
        for text in [String(repeating: " ", count: 16_385), "[[[[[[0]]]]]]", valid + "{}",
                     valid.replacingOccurrences(of: "12345", with: "1.2345e4"), #"{"a":"\uD800"}"#] {
            XCTAssertThrowsError(try BoundaryExpectation.parse(text))
        }
    }
    func testDryRunOfAllSevenProbesDoesNotCollectOrInteract() {
        for probe in BoundaryProbe.allCases {
            let result = BoundaryCLI.evaluate(probe: probe, arguments: [], capture: { _ in XCTFail("capture in dry run"); throw BoundaryError.invalid("test") },
                                              perform: { _ in XCTFail("interaction in dry run"); throw BoundaryError.invalid("test") })
            XCTAssertEqual(result.status, .dryRun)
            XCTAssertFalse(result.acceptanceEvidence)
            XCTAssertFalse(result.details.isEmpty)
        }
    }
    func testMalformedExpectationIsInvalidBeforeCaptureOrInteraction() {
        let result = BoundaryCLI.evaluate(probe: .hostRead, arguments: ["--apply", "--expect-json", "{}"],
                                          capture: { _ in XCTFail("capture for malformed expectation"); throw BoundaryError.invalid("test") },
                                          perform: { _ in XCTFail("interaction before identity"); throw BoundaryError.invalid("test") })
        XCTAssertEqual(result.status, .invalidMeasurement)
        XCTAssertEqual(result.status.exitCode, 3)
    }
    func testMismatchPreventsEveryProbeInteraction() throws {
        for probe in BoundaryProbe.allCases {
            var wrong = try context(); wrong.realUID += 1
            let result = BoundaryCLI.evaluate(probe: probe, arguments: ["--apply", "--expect-json", try json(expectationObject())],
                                              capture: { _ in wrong }, perform: { _ in XCTFail("interaction before identity"); throw BoundaryError.invalid("test") })
            XCTAssertEqual(result.status, .invalidMeasurement)
        }
    }
    func testPositiveIdentityInvokesOnlyRequestedProbeOnce() throws {
        var calls = 0
        let result = BoundaryCLI.evaluate(probe: .hostRead, arguments: ["--apply", "--expect-json", try json(expectationObject())],
                                          capture: { _ in try self.context() }, validateSignature: { true }, perform: { probe in
            calls += 1; XCTAssertEqual(probe, .hostRead); return (.fixturePassed, ["test": "MOCK operation"])
        })
        XCTAssertEqual(calls, 1); XCTAssertEqual(result.status, .fixturePassed); XCTAssertFalse(result.acceptanceEvidence)
    }
    func testSignaturePrerequisiteBlocksEveryImplementedInteraction() throws {
        for probe in [BoundaryProbe.hostRead, .xpc, .ingress, .lifecycle] {
            let result = BoundaryCLI.evaluate(probe: probe, arguments: ["--apply", "--expect-json", try json(expectationObject())],
                                              capture: { _ in try self.context() }, validateSignature: { false }, perform: { _ in
                XCTFail("interaction before signing prerequisite"); throw BoundaryError.invalid("test")
            })
            XCTAssertEqual(result.status, .invalidMeasurement)
        }
    }
    func testUnavailableProbesCannotReportPass() throws {
        for probe in [BoundaryProbe.tcc, .capture] {
            let result = BoundaryCLI.evaluate(probe: probe, arguments: ["--apply", "--expect-json", try json(expectationObject())], capture: { _ in try self.context() })
            XCTAssertEqual(result.status, .notImplemented); XCTAssertEqual(result.status.exitCode, 5)
        }
    }
    func testArbitraryPathPIDServiceAndDuplicateFlagsRejected() {
        for arguments in [["--apply"], ["--expect-json", "{}"], ["--path", "/private/tmp"], ["--pid", "1"],
                          ["--service", "example"], ["--dry-run", "--dry-run"], ["--apply", "--expect-json", "{}", "--apply"]] {
            XCTAssertEqual(BoundaryCLI.evaluate(probe: .xpc, arguments: arguments).status, .usageError)
        }
    }
    func testSigningPolicyMockAcceptsRuntimeAndRejectsEitherEntitlementSpelling() {
        XCTAssertTrue(SigningSelf.evaluate(flags: 0x10000, entitlementKeys: []).policyMatches)
        XCTAssertFalse(SigningSelf.evaluate(flags: 0, entitlementKeys: []).policyMatches)
        for key in ["get-task-allow", "com.apple.security.get-task-allow"] {
            XCTAssertFalse(SigningSelf.evaluate(flags: 0x10000, entitlementKeys: [key]).policyMatches)
        }
    }
    func testRawUndecodableEntitlementsAreInvalidNotAnEmptyGrantSet() throws {
        let flags = kSecCodeInfoFlags as String, raw = kSecCodeInfoEntitlements as String
        let decoded = kSecCodeInfoEntitlementsDict as String
        XCTAssertTrue(try SigningSelf.evaluateMetadata([flags: NSNumber(value: 0x10000)]).policyMatches)
        XCTAssertThrowsError(try SigningSelf.evaluateMetadata([flags: NSNumber(value: 0x10000), raw: Data([0])]))
        XCTAssertThrowsError(try SigningSelf.evaluateMetadata([flags: NSNumber(value: 0x10000), decoded: "invalid"]))
        XCTAssertFalse(try SigningSelf.evaluateMetadata([flags: NSNumber(value: 0x10000), decoded: ["get-task-allow": false]]).policyMatches)
    }
    func testXPCPreregistrationRequiresCompleteCanonicalFields() throws {
        var object = expectationObject()
        let fields = ["runID": "6FD11621-FAD4-4E67-A170-51B66D311E71", "clientCodeHash": String(repeating: "a", count: 40),
                      "serviceCodeHash": String(repeating: "b", count: 40)]
        object["xpc"] = fields
        XCTAssertEqual(try BoundaryExpectation.parse(json(object)).xpc?.runID, fields["runID"])
        for key in fields.keys {
            var missing = fields; missing.removeValue(forKey: key); object["xpc"] = missing
            XCTAssertThrowsError(try BoundaryExpectation.parse(json(object)))
        }
        object["xpc"] = NSNull(); XCTAssertThrowsError(try BoundaryExpectation.parse(json(object)))
        object["xpc"] = fields.merging(["claimedUID": "501"]) { _, new in new }
        XCTAssertThrowsError(try BoundaryExpectation.parse(json(object)))
    }
    func testActualOwnedLoopbackRoundTrip() throws {
        XCTAssertEqual(try LoopbackFixture.run()["acknowledgedByClient"], "true")
    }
    func testActualOwnedChildEchoAndReap() throws {
        let canary = Data("synthetic-child-canary".utf8)
        let result = try FixedChild.run(.echo, input: canary)
        XCTAssertEqual(result.data, canary); XCTAssertEqual(result.status, 0)
        XCTAssertThrowsError(try FixedChild.run(.echo, input: Data(repeating: 0, count: 257)))
    }
    func testChildDispositionPrerequisiteRejectsAutoReapingOrCustomHandler() {
        let standard = unsafeBitCast(SIG_DFL, to: UInt.self)
        XCTAssertTrue(FixedChild.permitsExclusiveReap(handlerAddress: standard, flags: 0))
        XCTAssertFalse(FixedChild.permitsExclusiveReap(handlerAddress: unsafeBitCast(SIG_IGN, to: UInt.self), flags: 0))
        XCTAssertFalse(FixedChild.permitsExclusiveReap(handlerAddress: standard, flags: SA_NOCLDWAIT))
        XCTAssertFalse(FixedChild.permitsExclusiveReap(handlerAddress: UInt.max, flags: 0))
    }
    func testActualOwnChildTimeoutTerminatesAndReapsOnlyItsChild() throws {
        var child: pid_t = 0
        XCTAssertThrowsError(try FixedChild.run(.echo, input: Data("synthetic-timeout".utf8),
                                               testFault: .holdEchoInputOpen, onSpawn: { child = $0 })) { error in
            XCTAssertEqual(String(describing: error), "child deadline exceeded")
        }
        XCTAssertGreaterThan(child, 0)
        if child > 0 {
            var status: Int32 = 0
            errno = 0
            XCTAssertEqual(waitpid(child, &status, WNOHANG), -1)
            XCTAssertEqual(errno, ECHILD)
        }
    }
}
