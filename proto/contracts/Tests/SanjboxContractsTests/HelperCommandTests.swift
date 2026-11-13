import Foundation
import Testing
@testable import SanjboxContracts

@Suite("H3 command and reply contracts")
struct HelperCommandTests {
    let commands: [HelperMessage] = [
        .shell(.init(zoneID: "a1b2", workingRootID: "project")),
        .run(.init(zoneID: "a1b2", workingRootID: "project", executableRootID: "tools", executablePath: "bin/tool", arguments: ["--fixture", "literal; $(data)"])),
        .pauseZone(.init(zoneID: "a1b2")),
        .resumeZone(.init(zoneID: "a1b2")),
        .snapshot(.init(zoneID: "a1b2", snapshotID: "snap-1", rollbackUnitID: "whole-state")),
        .rollback(.init(zoneID: "a1b2", snapshotID: "snap-1", rollbackUnitID: "whole-state")),
    ]
    @Test func everyCLICommandRoundTripsWithCorrelatedSuccessAndFailure() throws {
        for command in commands {
            #expect(try HelperMessage.decode(command.encoded()) == command)
            let launch = command.kind == .shell || command.kind == .run
            let success = HelperReply(requestKind: command.kind, zoneID: command.zoneID,
                outcome: launch ? .accepted : .completed, executionID: launch ? "execution-1" : nil)
            let failure = HelperReply(requestKind: command.kind, zoneID: command.zoneID,
                outcome: .failed, errorCode: .invalidState)
            for reply in [success, failure] {
                try reply.validate(for: command)
                #expect(try HelperReply.decode(reply.encoded()) == reply)
                #expect(try HelperReply.decode(reply.encoded()).encoded() == reply.encoded())
            }
        }
        let allKinds = Set(commands.map(\.kind)).union([.capabilities, .createZone, .startZone, .stopZone, .zoneStatus, .applyNetworkPolicy])
        #expect(allKinds == Set(HelperMessageKind.allCases))
    }
    @Test func everyCommandFieldIsRequiredTypedAndClosed() throws {
        for command in commands {
            let envelope = try XPCEnvelope.decode(command.encoded())
            let fields = try #require(JSONSerialization.jsonObject(with: envelope.body) as? [String: Any])
            for key in fields.keys {
                var missing = fields; missing.removeValue(forKey: key)
                rejection("missing-field") { _ = try HelperMessage.decode(envelopeJSON(kind: command.kind.rawValue,
                    body: String(decoding: JSONSerialization.data(withJSONObject: missing), as: UTF8.self))) }
                var wrong = fields; wrong[key] = NSNull()
                #expect(throws: ContractError.self) { _ = try HelperMessage.decode(envelopeJSON(kind: command.kind.rawValue,
                    body: String(decoding: JSONSerialization.data(withJSONObject: wrong), as: UTF8.self))) }
            }
            for field in ["uid", "hostPath", "environment", "privileged", "partialRoots"] {
                var extra = fields; extra[field] = "forbidden"
                rejection("unknown-field") { _ = try HelperMessage.decode(envelopeJSON(kind: command.kind.rawValue,
                    body: String(decoding: JSONSerialization.data(withJSONObject: extra), as: UTF8.self))) }
            }
        }
    }
    @Test func rejectsPathsAndIdentifiersWithoutResolvingAnything() {
        for path in ["/host/path", "../escape", "a/../b", "a//b", "a/", "a\\b", "x\u{85}y", String(repeating: "x", count: 1025)] {
            rejection("invalid-value") { try ShellRequest(zoneID: "a1b2", workingRootID: "project", workingDirectory: path).validate() }
            rejection("invalid-value") { try RunRequest(zoneID: "a1b2", workingRootID: "project", executableRootID: "tools", executablePath: path).validate() }
        }
        rejection("invalid-value") { try RunRequest(zoneID: "a1b2", workingRootID: "project", executableRootID: "tools", executablePath: ".").validate() }
        for id in ["", "UPPER", "../../host", String(repeating: "a", count: 33)] {
            rejection("invalid-identifier") { try ShellRequest(zoneID: "a1b2", workingRootID: id).validate() }
            rejection("invalid-identifier") { try RunRequest(zoneID: "a1b2", workingRootID: "project", executableRootID: id, executablePath: "tool").validate() }
            rejection("invalid-identifier") { try SnapshotRequest(zoneID: "a1b2", snapshotID: id, rollbackUnitID: "unit").validate() }
            rejection("invalid-identifier") { try SnapshotRequest(zoneID: "a1b2", snapshotID: "snap", rollbackUnitID: id).validate() }
        }
        rejection("invalid-identifier") { try ShellRequest(zoneID: "BAD", workingRootID: "project").validate() }
        rejection("invalid-identifier") { try SnapshotRequest(zoneID: "BAD", snapshotID: "snap", rollbackUnitID: "unit").validate() }
    }
    @Test func argvBoundsAreCheckedOnBothWireAndTypedValues() throws {
        let base = RunRequest(zoneID: "a1b2", workingRootID: "project", executableRootID: "tools", executablePath: "tool")
        for args in [Array(repeating: "", count: 65), [String(repeating: "x", count: 1025)], ["a\0b"], Array(repeating: String(repeating: "x", count: 1024), count: 33)] {
            var invalid = base; invalid.arguments = args
            #expect(throws: ContractError.self) { _ = try HelperMessage.run(invalid).encoded() }
            let body = try JSONEncoder().encode(invalid)
            #expect(throws: ContractError.self) { _ = try HelperMessage.decode(XPCEnvelope(kind: "zone.run", body: body).encoded()) }
        }
        for args in [Array(repeating: "", count: 64), Array(repeating: String(repeating: "x", count: 1024), count: 32)] {
            var boundary = base; boundary.arguments = args
            #expect(try HelperMessage.decode(HelperMessage.run(boundary).encoded()) == .run(boundary))
        }
    }
    @Test func repliesRejectAmbiguousSuccessFailureAndMismatchedRequests() throws {
        let valid = HelperReply(requestKind: .run, zoneID: "a1b2", outcome: .accepted, executionID: "execution-1")
        var invalid = valid; invalid.zoneID = "c3d4"
        rejection("invalid-value") { try invalid.validate(for: commands[1]) }
        invalid = valid; invalid.requestKind = .shell
        rejection("invalid-value") { try invalid.validate(for: commands[1]) }
        invalid = valid; invalid.executionID = nil
        rejection("invalid-value") { try invalid.validate() }
        invalid = valid; invalid.executionID = "../host"
        rejection("invalid-value") { try invalid.validate() }
        invalid = valid; invalid.outcome = .completed
        rejection("invalid-value") { try invalid.validate() }
        invalid = valid; invalid.state = .running
        rejection("invalid-value") { try invalid.validate() }
        invalid = valid; invalid.errorCode = .operationFailed
        rejection("invalid-value") { try invalid.validate() }
        invalid = valid; invalid.outcome = .failed
        rejection("invalid-value") { try invalid.validate() }
        invalid = .init(requestKind: .pauseZone, zoneID: "a1b2", outcome: .accepted)
        rejection("invalid-value") { try invalid.validate() }
        invalid = .init(requestKind: .zoneStatus, zoneID: "a1b2", outcome: .completed)
        rejection("invalid-value") { try invalid.validate() }
        invalid = .init(requestKind: .capabilities, zoneID: "a1b2", outcome: .completed)
        rejection("invalid-identifier") { try invalid.validate() }
        invalid = .init(requestKind: .pauseZone, zoneID: nil, outcome: .completed)
        rejection("invalid-identifier") { try invalid.validate() }
        for kind in HelperMessageKind.allCases {
            let reply = HelperReply(requestKind: kind, zoneID: kind == .capabilities ? nil : "a1b2", outcome: .failed, errorCode: .unauthorized)
            #expect(try HelperReply.decode(reply.encoded()) == reply)
        }
        let status = HelperReply(requestKind: .zoneStatus, zoneID: "a1b2", outcome: .completed, state: .stopping)
        #expect(try HelperReply.decode(status.encoded()) == status)
        let body = String(decoding: try XPCEnvelope.decode(valid.encoded()).body, as: UTF8.self)
        for (old, new) in [("zone.run", "zone.unknown"), ("accepted", "unknown"), ("\"requestKind\":\"zone.run\",", "")] {
            #expect(throws: ContractError.self) { _ = try HelperReply.decode(envelopeJSON(kind: "helper.reply", body: body.replacingOccurrences(of: old, with: new))) }
        }
        for missing in ["requestKind", "outcome"] {
            var fields = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            fields.removeValue(forKey: missing)
            rejection("missing-field") { _ = try HelperReply.decode(envelopeJSON(kind: "helper.reply",
                body: String(decoding: JSONSerialization.data(withJSONObject: fields), as: UTF8.self))) }
        }
        for badBody in [
            "{\"requestKind\":\"zone.run\",\"zoneID\":\"a1b2\",\"outcome\":\"failed\",\"errorCode\":\"unknown\"}",
            "{\"requestKind\":\"zone.status\",\"zoneID\":\"a1b2\",\"outcome\":\"completed\",\"state\":\"unknown\"}",
        ] {
            rejection("invalid-value") { _ = try HelperReply.decode(envelopeJSON(kind: "helper.reply", body: badBody)) }
        }
        rejection("duplicate-key") { _ = try HelperReply.decode(envelopeJSON(kind: "helper.reply",
            body: "{\"zoneID\":\"a1b2\"," + body.dropFirst())) }
        rejection("unknown-field") { _ = try HelperReply.decode(envelopeJSON(kind: "helper.reply", body: "{\"pid\":1," + body.dropFirst())) }
        rejection("invalid-version") { _ = try HelperReply.decode(envelopeJSON(kind: "helper.reply", body: body, version: 2)) }
        rejection("unknown-message-kind") { _ = try HelperReply.decode(envelopeJSON(kind: "zone.run", body: body)) }
        rejection("unknown-message-kind") { _ = try HelperMessage.decode(valid.encoded()) }
    }
}
