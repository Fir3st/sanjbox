import Foundation
import Darwin
import SanjboxProbeKit
import Testing
@testable import C1ProbeKit

private func input(_ replacement: String = "") throws -> ProbeInput {
    let text = #"{"caseID":"NET-05","address":"192.0.2.10","port":18080,"transport":"tcp","canary":"SANJBOX-CANARY-c1-fixture-00000000000000000000000000000000","sendCount":8,"intervalMilliseconds":500,"controlledTarget":true}"#
    return try JSONDecoder().decode(ProbeInput.self, from: Data((replacement.isEmpty ? text : replacement).utf8))
}
private func expectation() -> C1Expectation {
    C1Expectation(identity: ProbeExpectation(effectiveUID: 4501, realUID: 4501, effectiveGID: 4500, realGID: 4500,
                     requiredGroups: [4500], forbiddenGroups: [20, 80], launchdManagerName: "Aqua",
                     launchdManagerUID: 4501, windowSessionUID: 4501, onConsole: false, forbiddenAuditSessionIDs: [100]), auditSessionID: 200)
}
private func context() -> ProbeContext {
    let json = #"{"pid":123,"parentPID":12,"realUID":4501,"effectiveUID":4501,"realGID":4500,"effectiveGID":4500,"userName":"snjt1","kernelGroups":[4500],"groupMembership":[{"gid":4500,"isMember":true},{"gid":20,"isMember":false},{"gid":80,"isMember":false}],"audit":{"sessionID":200,"auditUID":4501,"flags":0},"launchdManager":{"name":"Aqua","uid":4501},"windowSession":{"userID":4501,"userName":"snjt1","auditSessionID":200,"onConsole":false,"loginDone":true}}"#
    return try! JSONDecoder().decode(ProbeContext.self, from: Data(json.utf8))
}

@Test func mockIdentityMismatchNeverReachesTransport() throws {
    let value = try input()
    let expected = expectation()
    for index in 0..<5 {
        var actual = context()
        switch index {
        case 0: actual.realUID = 501
        case 1: actual.effectiveUID = 501
        case 2: actual.audit = nil
        case 3: actual.launchdManager = nil
        default: actual.groupMembership = []
        }
        var called = false
        #expect(throws: (any Error).self) {
            try C1Probe.run(input: value, expectation: expected, context: actual) { _ in called = true; return 0 }
        }
        #expect(!called)
    }
}

@Test func mockValidIdentityAllowsOnlyInjectedTransport() throws {
    var called = false
    let count = try C1Probe.run(input: input(), expectation: expectation(), context: context()) { _ in called = true; return 7 }
    #expect(called && count == 7) // MOCK: no sockets, no assertion about a PF verdict.
}

@Test func rejectWeakExpectationAndUnboundedInput() throws {
    var expected = expectation()
    expected.identity.forbiddenAuditSessionIDs = []
    #expect(throws: (any Error).self) { try C1Probe.validateExpectation(expected) }
    var value = try input()
    value.sendCount = 33
    #expect(throws: (any Error).self) { try value.validate() }
    value = try input(); value.address = "example.com"
    #expect(throws: (any Error).self) { try value.validate() }
    value = try input(); value.canary = "arbitrary data"
    #expect(throws: (any Error).self) { try value.validate() }
}

@Test func wrongSameUIDAuditSessionCannotReadProbeInput() throws {
    let actual = context()
    var expected = expectation()
    expected.auditSessionID = 201
    var read = false
    #expect(throws: (any Error).self) {
        try C1Probe.validatedInput(expectation: expected, context: actual) {
            read = true
            return try input()
        }
    }
    #expect(!read)
}

@Test func ownSchemaFilesRefuseSymlinksFIFOHardlinksAndSecretPaths() throws {
    let manager = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("c1-input-" + UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? manager.removeItem(at: root) }
    let file = root.appendingPathComponent("probe.json")
    try Data("{}".utf8).write(to: file)
    #expect(try InputFile.read(file.path, kind: "probe") == Data("{}".utf8))
    let symlink = root.appendingPathComponent("probe-link.json")
    try manager.createSymbolicLink(at: symlink, withDestinationURL: file)
    #expect(throws: (any Error).self) { try InputFile.read(symlink.path, kind: "probe") }
    let alias = root.appendingPathComponent("alias")
    try manager.createSymbolicLink(at: alias, withDestinationURL: root)
    #expect(throws: (any Error).self) { try InputFile.read(alias.appendingPathComponent("probe.json").path, kind: "probe") }
    let fifo = root.appendingPathComponent("probe-fifo.json")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(throws: (any Error).self) { try InputFile.read(fifo.path, kind: "probe") }
    let hardlink = root.appendingPathComponent("probe-hard.json")
    #expect(link(file.path, hardlink.path) == 0)
    #expect(throws: (any Error).self) { try InputFile.read(hardlink.path, kind: "probe") }
    try manager.removeItem(at: hardlink)
    #expect(chmod(file.path, 0o666) == 0)
    #expect(throws: (any Error).self) { try InputFile.read(file.path, kind: "probe") }
    for path in [root.path + "/.env", root.path + "/.ssh/probe.json", root.path + "/credentials/probe.json", root.path + "/Library/Keychains/probe.json"] {
        #expect(throws: (any Error).self) { try InputFile.read(path, kind: "probe") }
    }
}

@Test func embeddedNULFamilyConfusionRejectedBeforeMockSend() throws {
    var value = try input()
    value.address = "192.0.2.10\0:ignored"
    var sent = false
    #expect(throws: (any Error).self) {
        try C1Probe.run(input: value, expectation: expectation(), context: context()) { _ in
            sent = true
            return 1
        }
    }
    #expect(!sent)
}
