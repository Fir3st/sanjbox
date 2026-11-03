import Darwin
import Foundation
import Security
import Testing
import SanjboxProbeKit
@testable import S8Preparation

private func context() throws -> ProbeContext {
    try JSONDecoder().decode(ProbeContext.self, from: Data("""
    {"pid":100,"parentPID":99,"realUID":601,"effectiveUID":601,"realGID":601,"effectiveGID":601,
     "userName":"synthetic","kernelGroups":[601],"groupMembership":[{"gid":601,"isMember":true},{"gid":80,"isMember":false}],
     "audit":{"sessionID":41,"auditUID":601,"flags":0},"launchdManager":{"name":"Aqua","uid":601},
     "windowSession":{"userID":601,"userName":"synthetic","auditSessionID":41,"onConsole":false,"loginDone":true}}
    """.utf8))
}

@Test func completeIdentityAcceptsOnlyExactContext() throws {
    let c = try context(); let expected = try S8Expectation(candidate: c)
    #expect(expected.mismatches(in: c).isEmpty)
    var changed = c; changed.audit?.sessionID = 42
    #expect(expected.mismatches(in: changed).contains("auditSessionID"))
    changed = c; changed.audit = nil
    #expect(expected.mismatches(in: changed).contains("auditSessionID"))
    changed = c; changed.launchdManager = nil
    #expect(!expected.mismatches(in: changed).isEmpty)
}

@Test func identityRejectsCredentialsAndSupplementaryGroupDrift() throws {
    let c = try context(); let expected = try S8Expectation(candidate: c)
    var changed = c; changed.realUID = 602; changed.effectiveGID = 602
    #expect(expected.mismatches(in: changed).contains("realUID"))
    #expect(expected.mismatches(in: changed).contains("effectiveGID"))
    changed = c; changed.kernelGroups += [80]
    #expect(expected.mismatches(in: changed).contains("kernelGroups"))
}

@Test func missingOrUnresolvedMembershipIsNotAnAbsence() throws {
    var c = try context(); var expected = try S8Expectation(candidate: c)
    expected.requiredGroups = [601]; expected.forbiddenGroups = [80]
    #expect(expected.mismatches(in: c).isEmpty)
    c.groupMembership[1].isMember = nil
    #expect(!expected.mismatches(in: c).isEmpty)
    c.groupMembership = []
    #expect(!expected.mismatches(in: c).isEmpty)
}

@Test func expectationRequiresCompleteWindowAndNonRoot() throws {
    let c = try context(); var expected = try S8Expectation(candidate: c)
    expected.windowSession?.auditSessionID = nil
    #expect(!expected.configurationIssues().isEmpty)
    expected = try S8Expectation(candidate: c); expected.realUID = 0; expected.effectiveUID = 0
    #expect(!expected.configurationIssues().isEmpty)
    expected = try S8Expectation(candidate: c); expected.auditSessionID = 0
    #expect(!expected.configurationIssues().isEmpty)
}

@Test func missingMandatoryExpectationFieldsCannotDecode() {
    #expect(throws: (any Error).self) { try JSONDecoder().decode(S8Expectation.self, from: Data("{\"effectiveUID\":601}".utf8)) }
}

@Test func strictExpectationRejectsDuplicateEscapedUnknownAndWrongTypeFields() throws {
    let expected = try S8Expectation(candidate: context())
    let data = try JSONEncoder().encode(expected)
    #expect(try decodeExpectation(data) == expected)
    let json = String(decoding: data, as: UTF8.self)
    for suffix in [",\"auditSessionID\":42}", ",\"auditSession\\u0049D\":42}", ",\"unexpected\":true}"] {
        #expect(throws: (any Error).self) { try decodeExpectation(Data((String(json.dropLast()) + suffix).utf8)) }
    }
    for bad in ["true", "601.0", "6.01e2", "\"601\""] {
        let wrong = json.replacingOccurrences(of: "\"realUID\":601", with: "\"realUID\":" + bad)
        #expect(throws: (any Error).self) { try decodeExpectation(Data(wrong.utf8)) }
    }
    #expect(throws: (any Error).self) { try decodeExpectation(Data("[[[[[[[]]]]]]]".utf8)) }
    #expect(throws: (any Error).self) { try decodeExpectation(data + Data("{}".utf8)) }
}

@Test func expectationPathRejectsUnscopedContentBeforeOpening() {
    for path in ["/private/tmp/s8-expectation.json", "/Users/example/Library/Keychains/s8-expectation.json", "/private/tmp/credentials.json"] {
        #expect(throws: (any Error).self) { try readExpectation(path) }
    }
}

@Test func staticSignaturePolicyHasExplicitPositiveControl() {
    #expect(SignaturePolicy.issues(validity: 0, information: 0, flags: 0x10002, identifier: "synthetic", entitlementState: .absent, otherEntitlements: false).isEmpty)
}

@Test func unknownAndWeakSignaturesFailClosed() {
    for flags: UInt32? in [nil, 0, 2, 0x10000] {
        #expect(!SignaturePolicy.issues(validity: 0, information: 0, flags: flags, identifier: "synthetic", entitlementState: .absent, otherEntitlements: false).isEmpty)
    }
    #expect(!SignaturePolicy.issues(validity: -1, information: 0, flags: 0x10002, identifier: "synthetic", entitlementState: .absent, otherEntitlements: false).isEmpty)
    #expect(!SignaturePolicy.issues(validity: 0, information: -1, flags: 0x10002, identifier: nil, entitlementState: .absent, otherEntitlements: false).isEmpty)
}

@Test func absentDictionaryWithRawEntitlementsIsUnknown() {
    #expect(SignaturePolicy.entitlementState(dictionary: nil, rawBlobPresent: true).0 == .unknown)
    #expect(SignaturePolicy.entitlementState(dictionary: nil, rawBlobPresent: false).0 == .absent)
}

@Test func getTaskAllowFalseAndMalformedValuesAreStillProhibited() {
    for value: Any in [true, false, "false", 0] {
        #expect(SignaturePolicy.entitlementState(dictionary: ["com.apple.security.get-task-allow": value], rawBlobPresent: true).0 == .present)
        #expect(SignaturePolicy.entitlementState(dictionary: ["get-task-allow": value], rawBlobPresent: true).0 == .present)
    }
}

@Test func otherEntitlementsAreNotSilentlyAccepted() {
    let state = SignaturePolicy.entitlementState(dictionary: ["com.apple.security.cs.disable-library-validation": true], rawBlobPresent: true)
    #expect(state.0 == .absent && state.1 == true)
    #expect(!SignaturePolicy.issues(validity: 0, information: 0, flags: 0x10002, identifier: "synthetic", entitlementState: state.0, otherEntitlements: state.1).isEmpty)
}

@Test func mockFrameAndInputHaveIndependentRoleChecks() {
    var broker = MockBroker()
    #expect(broker.evaluate(MockWire.request(), peer: MockPeer(), right: MockRight()) == .accepted)
    #expect(broker.evaluate(MockWire.request(opcode: 2, sequence: 2), peer: MockPeer(), right: nil) == .identity)
    var host = MockPeer(); host.uid = 501; host.auditSessionID = 31; host.role = .hostProxy
    #expect(broker.evaluate(MockWire.request(opcode: 2, sequence: 2), peer: host, right: nil) == .accepted)
}

@Test func replayAndCapacityAreBoundedWithoutSideEffectsOnRejection() {
    var broker = MockBroker()
    for sequence in 1...64 {
        #expect(broker.evaluate(MockWire.request(sequence: UInt64(sequence)), peer: MockPeer(), right: MockRight()) == .accepted)
    }
    #expect(broker.evaluate(MockWire.request(sequence: 64), peer: MockPeer(), right: MockRight()) == .replay)
    #expect(broker.evaluate(MockWire.request(sequence: 65), peer: MockPeer(), right: MockRight()) == .exhausted)
    #expect(broker.accepted == 64 && broker.lastSequence == 64)
}

@Test func sizeGlobalIDAndPathInputsAreRejected() {
    var broker = MockBroker()
    for data in [Data(), Data(repeating: 0, count: 41), Data("../../outside".utf8), MockWire.request() + Data([0])] {
        #expect(broker.evaluate(data, peer: MockPeer(), right: MockRight()) == .malformed)
    }
    var globalID = MockWire.request(); globalID[31] = 1
    #expect(broker.evaluate(globalID, peer: MockPeer(), right: MockRight()) == .malformed)
    #expect(broker.accepted == 0)
}

@Test func rightAndSessionMismatchesRejectKnownGoodWire() {
    var broker = MockBroker(); var peer = MockPeer()
    peer.auditSessionID = nil
    #expect(broker.evaluate(MockWire.request(), peer: peer, right: MockRight()) == .identity)
    peer = MockPeer(); peer.uid = 602
    #expect(broker.evaluate(MockWire.request(), peer: peer, right: MockRight()) == .identity)
    #expect(broker.evaluate(MockWire.request(), peer: MockPeer(), right: nil) == .capability)
    var right = MockRight(); right.generation = 2
    #expect(broker.evaluate(MockWire.request(), peer: MockPeer(), right: right) == .capability)
}

@Test func exhaustiveShortLengthsCannotSatisfyWire() {
    for length in 0..<32 {
        var broker = MockBroker()
        #expect(broker.evaluate(Data(repeating: 0, count: length), peer: MockPeer(), right: MockRight()) == .malformed)
    }
}

@Test func deterministicBoundedFuzzHasPositiveControls() throws {
    let a = try MockFuzzer.run(iterations: 1000)
    let b = try MockFuzzer.run(iterations: 1000)
    #expect(a.corpusSHA256 == b.corpusSHA256)
    #expect(a.positiveControls == 4 && a.negativeCases == 1000 && a.unexpectedAccepts == 0 && a.failures.isEmpty)
    #expect(throws: (any Error).self) { try MockFuzzer.run(iterations: 10_001) }
    #expect(throws: (any Error).self) { try MockFuzzer.run(iterations: 0) }
    #expect(throws: (any Error).self) { try MockFuzzer.run(iterations: 1, seed: 0) }
}

@Test func distinctServiceAndSigningExperimentsArePrepared() {
    let plans = ServiceExperiments.plans()
    #expect(plans.count == 6)
    #expect(plans.filter { $0.service == "LaunchDaemon" }.count == 2)
    #expect(plans.filter { $0.service == "LoginItem" }.count == 2)
    #expect(plans.filter { $0.service == "LaunchAgent" }.count == 2)
}

@Test func serviceStaticLayoutRejectsDangerousExtraKeysAndWrongTypes() {
    for daemon in [false, true] {
        let plist = ServiceExperiments.plist(daemon: daemon)
        #expect(ServiceExperiments.validate(plist, daemon: daemon))
        var changed = plist; changed["ProgramArguments"] = ["/bin/sh", "-c", "unexpected"]
        #expect(!ServiceExperiments.validate(changed, daemon: daemon))
        changed = plist; changed["RunAtLoad"] = 1
        #expect(!ServiceExperiments.validate(changed, daemon: daemon))
        changed = plist; changed["BundleProgram"] = "../../outside"
        #expect(!ServiceExperiments.validate(changed, daemon: daemon))
    }
}

@Test func selectedFileReaderRejectsLinksAndOversize() throws {
    let root = "/private/tmp/s8-a6-unit-\(UUID().uuidString)"
    #expect(mkdir(root, 0o700) == 0)
    let path = root + "/synthetic.json"; let link = root + "/linked.json"
    defer { _ = unlink(link); _ = unlink(path); _ = rmdir(root) }
    try Data("{}".utf8).write(to: URL(fileURLWithPath: path))
    #expect(try readOwnedFile(path, maximum: 2) == Data("{}".utf8))
    #expect(throws: (any Error).self) { try readOwnedFile(path, maximum: 1) }
    #expect(symlink(path, link) == 0)
    #expect(throws: (any Error).self) { try readOwnedFile(link, maximum: 2) }
    #expect(unlink(link) == 0)
    #expect(Darwin.link(path, link) == 0)
    #expect(throws: (any Error).self) { try readOwnedFile(path, maximum: 2) }
}

@Test func fixtureScopeRefusesArbitraryOrTraversingPaths() {
    for path in ["/private/tmp", "/Applications", "/private/tmp/sanjbox-s8-fixtures-invalid", "/private/tmp/sanjbox-s8-fixtures-00000000-0000-0000-0000-000000000000/../outside"] {
        #expect(throws: (any Error).self) { try SyntheticFixtures.verifyRoot(path) }
        #expect(throws: (any Error).self) { try SyntheticFixtures.cleanup(root: path) }
    }
}

@Test func cleanupOfAbsentValidRootIsIdempotent() throws {
    let path = "/private/tmp/sanjbox-s8-fixtures-\(UUID().uuidString.lowercased())"
    try SyntheticFixtures.cleanup(root: path); try SyntheticFixtures.cleanup(root: path)
}

@Test func absentWindowSessionRoundTripsAsExplicitNull() throws {
    var c = try context(); c.windowSession = nil
    let expected = try S8Expectation(candidate: c)
    let data = try JSONEncoder().encode(expected)
    #expect(String(decoding: data, as: UTF8.self).contains("\"windowSession\":null"))
    #expect(try decodeExpectation(data) == expected)
    #expect(expected.mismatches(in: c).isEmpty)
}

/// Only own mock bytes, not signed programs; exercises cleanup separately from compilation.
private func cleanupFixture() throws -> String {
    let root = "/private/tmp/sanjbox-s8-fixtures-\(UUID().uuidString.lowercased())"
    guard mkdir(root, 0o700) == 0 else { throw S8Error.refused("test mkdir") }
    let bytes = Data("own synthetic cleanup fixture".utf8)
    for name in SyntheticFixtures.names {
        try bytes.write(to: URL(fileURLWithPath: root + "/" + name)); _ = chmod(root + "/" + name, 0o500)
    }
    try Data(SyntheticFixtures.source.utf8).write(to: URL(fileURLWithPath: root + "/fixture.c"))
    _ = chmod(root + "/fixture.c", 0o600)
    var st = stat(); _ = lstat(root, &st)
    let manifest = FixtureManifest(ownerUID: geteuid(), ownerGID: st.st_gid, sourceSHA256: sha256(Data(SyntheticFixtures.source.utf8)),
                                   hashes: Dictionary(uniqueKeysWithValues: SyntheticFixtures.names.map { ($0, sha256(bytes)) }))
    try JSONEncoder().encode(manifest).write(to: URL(fileURLWithPath: root + "/manifest.json"))
    _ = chmod(root + "/manifest.json", 0o400)
    return root
}

@Test func cleanupRefusesLaterModeChangeBeforeDeletingAnyFile() throws {
    let root = try cleanupFixture()
    defer { _ = chmod(root + "/hardened", 0o500); try? SyntheticFixtures.cleanup(root: root) }
    #expect(chmod(root + "/hardened", 0o400) == 0)
    #expect(throws: (any Error).self) { try SyntheticFixtures.cleanup(root: root) }
    #expect(FileManager.default.fileExists(atPath: root + "/plain"))
}

@Test func cleanupRefusesLaterImmutableFlagBeforeDeletingAnyFile() throws {
    let root = try cleanupFixture()
    defer { _ = chflags(root + "/hardened", 0); try? SyntheticFixtures.cleanup(root: root) }
    #expect(chflags(root + "/hardened", UInt32(UF_IMMUTABLE)) == 0)
    #expect(throws: (any Error).self) { try SyntheticFixtures.cleanup(root: root) }
    #expect(FileManager.default.fileExists(atPath: root + "/plain"))
}

@Test func cleanupCanResumeAfterAnOwnedPartialUnlink() throws {
    let root = try cleanupFixture()
    defer { try? SyntheticFixtures.cleanup(root: root) }
    #expect(unlink(root + "/plain") == 0)
    #expect(throws: (any Error).self) { try SyntheticFixtures.verifyRoot(root) }
    try SyntheticFixtures.cleanup(root: root)
    #expect(!FileManager.default.fileExists(atPath: root))
}

@Test func cleanupCanFinishEmptyOwnedRootAndDryRunDoesNotRemoveIt() throws {
    let root = "/private/tmp/sanjbox-s8-fixtures-\(UUID().uuidString.lowercased())"
    #expect(mkdir(root, 0o700) == 0)
    defer { _ = rmdir(root) }
    try SyntheticFixtures.cleanup(root: root, apply: false)
    #expect(FileManager.default.fileExists(atPath: root))
    try SyntheticFixtures.cleanup(root: root)
    #expect(!FileManager.default.fileExists(atPath: root))
}
