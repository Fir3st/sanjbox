import CryptoKit
import Foundation
import SanjboxContracts

public struct H1FuzzReport: Encodable, Sendable {
    public let kind = "h1-wire-offline-not-XPC"
    public let corpusVersion = 1
    public let iterations: Int
    public let seed: UInt64
    public var positiveControls = 0
    public var expectedPositiveControls = 0
    public var negativeCases = 0
    public var unexpectedAccepts = 0
    public var rejectionCodes: [String: Int] = [:]
    public var coveredControls: [String] = []
    public var coveredMutations: [String] = []
    public var corpusSHA256 = ""
    public var failures: [String] = []
    public var succeeded: Bool {
        failures.isEmpty && unexpectedAccepts == 0 && positiveControls == expectedPositiveControls
    }
}

// Internal test injection is deliberately unavailable from the probe CLI.
struct H1FuzzInput {
    enum Receiver: String { case helper, reply, broker, brokerEnvelope }
    var receiver: Receiver
    var wire: Data
    var request: HelperMessage?
    var delivery: BrokerDeliveryContext?
    var control: String

    func validate() throws {
        switch receiver {
        case .helper: _ = try HelperMessage.decode(wire)
        case .reply:
            let reply = try HelperReply.decode(wire)
            guard let request else { throw S8Error.refused("missing harness correlation") }
            try reply.validate(for: request)
        case .broker:
            let message = try BrokerMessage.decode(wire)
            guard let delivery else { throw S8Error.refused("missing harness delivery") }
            try message.validateDelivery(in: delivery)
        case .brokerEnvelope: _ = try BrokerContract.decode(wire)
        }
    }

    var contextDescription: String {
        let reply = request.map { "\($0.kind.rawValue):\($0.zoneID ?? "nil")" } ?? "nil"
        guard let d = delivery else { return reply }
        return "\(reply)|\(d.peerRole.rawValue)|\(d.zoneID)|\(d.streamID)|\(d.width)|\(d.height)|\(d.lastSequence)|\(d.surfaceAttachmentCount)"
    }
}

/// Bounded deterministic structured mutation, not coverage-guided fuzzing or a native transport.
/// Raw positive JSON literals are independent of H1 encoders. No fixture creates processes,
/// services, Mach rights, signing identities or authorization evidence.
public enum H1Fuzzer {
    public static func run(iterations: Int, seed: UInt64 = 0x5338) throws -> H1FuzzReport {
        try run(iterations: iterations, seed: seed, evaluate: { try $0.validate() })
    }

    static func envelope(_ kind: String, _ body: String, version: String = "1") -> Data {
        Data("{\"version\":\(version),\"kind\":\"\(kind)\",\"body\":\"\(Data(body.utf8).base64EncodedString())\"}".utf8)
    }

    static func controls() throws -> [H1FuzzInput] {
        let z = #"{"zoneID":"a1b2"}"#
        let snap = #"{"zoneID":"a1b2","snapshotID":"snap-1","rollbackUnitID":"unit-1"}"#
        let helper: [(String, String)] = [
            ("helper.capabilities", "{}"), ("zone.create", #"{"zoneID":"a1b2","uid":601,"gid":601}"#),
            ("zone.start", z), ("zone.pause", z), ("zone.stop", z), ("zone.status", z), ("zone.resume", z),
            ("policy.apply", #"{"zoneID":"a1b2","policy":{"schema":"sanjbox.network-policy.v1","zoneID":"a1b2","defaultAction":"deny","gates":[]}}"#),
            ("zone.shell", #"{"zoneID":"a1b2","workingRootID":"work","workingDirectory":"."}"#),
            ("zone.run", #"{"zoneID":"a1b2","workingRootID":"work","workingDirectory":".","executableRootID":"public","executablePath":"bin/tool","arguments":[";literal","$(literal)"]}"#),
            ("zone.snapshot", snap), ("zone.rollback", snap)
        ]
        var inputs: [H1FuzzInput] = []
        for (kind, body) in helper {
            let wire = envelope(kind, body)
            let request = try HelperMessage.decode(wire)
            inputs.append(.init(receiver: .helper, wire: wire, control: kind))
            let zone = kind == "helper.capabilities" ? "" : #", "zoneID":"a1b2""#
            let launch = kind == "zone.run" || kind == "zone.shell"
            let success = launch ? #""accepted","executionID":"exec-1""# : #""completed""#
            let state = kind == "zone.status" ? #", "state":"running""# : ""
            inputs.append(.init(receiver: .reply,
                wire: envelope("helper.reply", "{\"requestKind\":\"\(kind)\"\(zone),\"outcome\":\(success)\(state)}"),
                request: request, control: "reply-success:" + kind))
            inputs.append(.init(receiver: .reply,
                wire: envelope("helper.reply", "{\"requestKind\":\"\(kind)\"\(zone),\"outcome\":\"failed\",\"errorCode\":\"unauthorized\"}"),
                request: request, control: "reply-failure:" + kind))
        }
        for (kind, fields, role, attachments) in [
            ("broker.frame", #""width":800,"height":600,"surfaceAttachmentIndex":0"#, BrokerPeerRole.sessionAgent, 1),
            ("broker.input.key", #""keyCode":127,"action":"down","modifiers":31"#, .hostController, 0),
            ("broker.input.pointer", #""x":799,"y":599,"action":"move","button":0"#, .hostController, 0)
        ] {
            inputs.append(.init(receiver: .broker,
                wire: envelope(kind, "{\"zoneID\":\"a1b2\",\"streamID\":\"screen-1\",\"sequence\":18446744073709551615,\(fields)}"),
                delivery: .init(peerRole: role, zoneID: "a1b2", streamID: "screen-1", width: 800,
                                height: 600, lastSequence: 0, surfaceAttachmentCount: attachments), control: kind))
        }
        // Independent receivers: rejection by one API cannot mask acceptance by the other.
        inputs += inputs.filter { $0.receiver == .broker }.map {
            var input = $0; input.receiver = .brokerEnvelope; input.delivery = nil
            input.control = "envelope:" + input.control; return input
        }
        return inputs
    }

    static let mutationNames = ["version", "unknown-header", "missing-header", "duplicate-header",
        "invalid-base64", "trailing", "invalid-utf8", "truncated", "envelope-limit", "body-limit",
        "receiver-kind", "unknown-body"]

    static func mutate(_ original: H1FuzzInput, variant: Int, random: UInt64) throws -> H1FuzzInput {
        var input = original
        var header = try JSONSerialization.jsonObject(with: input.wire) as! [String: Any]
        let raw = String(decoding: input.wire, as: UTF8.self)
        switch variant {
        case 0: header["version"] = 2 + random % 100
        case 1: header["callerUID"] = 0
        case 2: header.removeValue(forKey: "kind")
        case 3: input.wire = Data((String(raw.dropLast()) + #", "vers\u0069on":1}"#).utf8); return input
        case 4: header["body"] = "%%%"
        case 5: input.wire.append(Data("{}".utf8)); return input
        case 6: input.wire = Data([0xff, 0xfe, 0]); return input
        case 7: input.wire = input.wire.prefix(Int(random % UInt64(input.wire.count))); return input
        case 8:
            input.wire = Data(repeating: 0x20, count: ((input.receiver == .broker || input.receiver == .brokerEnvelope) ? BrokerContract.maxBytes : XPCEnvelope.maxBytes) + 1)
            return input
        case 9:
            header["body"] = Data(repeating: 0x20, count: ((input.receiver == .broker || input.receiver == .brokerEnvelope) ? BrokerContract.maxBodyBytes : XPCEnvelope.maxBodyBytes) + 1).base64EncodedString()
        case 10: header["kind"] = input.receiver == .helper ? "helper.reply" : "helper.capabilities"
        default:
            let body = Data(base64Encoded: header["body"] as! String)!
            let text = String(decoding: body, as: UTF8.self)
            let extra = text == "{}" ? #"{"callerUID":0}"# : String(text.dropLast()) + #", "callerUID":0}"#
            header["body"] = Data(extra.utf8).base64EncodedString()
        }
        input.wire = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys, .withoutEscapingSlashes])
        return input
    }

    static func semanticNegatives() throws -> [(String, H1FuzzInput)] {
        let positive = try controls()
        var out: [(String, H1FuzzInput)] = []
        func helper(_ name: String, _ kind: String, _ body: String) {
            out.append((name, .init(receiver: .helper, wire: envelope(kind, body), control: kind)))
        }
        for (name, uid) in [("uid-root", "0"), ("uid-exponent", "6.01e2"), ("uid-overflow", "4294967296"), ("uid-bool", "true")] {
            helper(name, "zone.create", "{\"zoneID\":\"a1b2\",\"uid\":\(uid),\"gid\":601}")
        }
        helper("duplicate-body", "zone.start", #"{"zoneID":"a1b2","zone\u0049D":"a1b2"}"#)
        helper("body-trailing", "zone.start", #"{"zoneID":"a1b2"}{}"#)
        helper("path-traversal", "zone.shell", #"{"zoneID":"a1b2","workingRootID":"work","workingDirectory":"../host"}"#)
        helper("absolute-path", "zone.shell", #"{"zoneID":"a1b2","workingRootID":"work","workingDirectory":"/host"}"#)
        helper("policy-zone", "policy.apply", #"{"zoneID":"a1b2","policy":{"schema":"sanjbox.network-policy.v1","zoneID":"c3d4","defaultAction":"deny","gates":[]}}"#)
        helper("argv-nul", "zone.run", #"{"zoneID":"a1b2","workingRootID":"work","workingDirectory":".","executableRootID":"public","executablePath":"bin/tool","arguments":["\u0000"]}"#)
        helper("nesting", "helper.capabilities", String(repeating: "[", count: 18) + "0" + String(repeating: "]", count: 18))
        helper("collection", "helper.capabilities", "[" + Array(repeating: "0", count: 129).joined(separator: ",") + "]")
        helper("string", "zone.start", "{\"zoneID\":\"" + String(repeating: "a", count: 4097) + "\"}")
        for original in positive where original.receiver == .reply {
            var i = original
            i.request = original.request?.kind == .capabilities ? .startZone(.init(zoneID: "a1b2")) : .capabilities
            out.append(("reply-kind-correlation", i))
            if original.request?.zoneID != nil {
                var header = try JSONSerialization.jsonObject(with: original.wire) as! [String: Any]
                let body = String(decoding: Data(base64Encoded: header["body"] as! String)!, as: UTF8.self)
                header["body"] = Data(body.replacingOccurrences(of: "a1b2", with: "c3d4").utf8).base64EncodedString()
                i = original; i.wire = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
                out.append(("reply-zone-correlation", i))
            }
        }
        for original in positive where original.receiver == .broker {
            for variant in 0..<7 {
                var i = original
                switch variant {
                case 0: i.delivery?.peerRole = original.delivery?.peerRole == .hostController ? .sessionAgent : .hostController
                case 1: i.delivery?.zoneID = "c3d4"
                case 2: i.delivery?.streamID = "screen-2"
                case 3: i.delivery?.surfaceAttachmentCount = 2
                case 4: i.delivery?.lastSequence = UInt64.max
                case 5: i.delivery?.width = 0
                default: i.delivery?.height = 0
                }
                out.append(("delivery-\(variant)", i))
            }
            if original.control != "broker.input.key" {
                var i = original; i.delivery?.width = 799
                out.append(("delivery-dimensions", i))
            }
        }
        let frame = positive.first { $0.control == "broker.frame" }!
        for (name, field) in [("global-surface", #""surfaceID":1"#), ("attachment-index", #""surfaceAttachmentIndex":1"#),
                               ("sequence-overflow", #""surfaceAttachmentIndex":0,"sequence":18446744073709551616"#)] {
            var i = frame
            let sequence = name == "sequence-overflow" ? "" : #""sequence":1,"#
            i.wire = envelope("broker.frame", "{\"zoneID\":\"a1b2\",\"streamID\":\"screen-1\",\(sequence)\"width\":800,\"height\":600,\(field)}")
            out.append((name, i))
        }
        for (control, name, body) in [
            ("reply-success:zone.run", "reply-missing-execution", #"{"requestKind":"zone.run","zoneID":"a1b2","outcome":"accepted"}"#),
            ("reply-success:zone.run", "reply-premature-completed", #"{"requestKind":"zone.run","zoneID":"a1b2","outcome":"completed","executionID":"exec-1"}"#),
            ("reply-success:zone.status", "reply-missing-state", #"{"requestKind":"zone.status","zoneID":"a1b2","outcome":"completed"}"#),
            ("reply-failure:zone.start", "reply-failure-success-data", #"{"requestKind":"zone.start","zoneID":"a1b2","outcome":"failed","errorCode":"unauthorized","state":"running"}"#),
            ("broker.input.key", "key-range", #"{"zoneID":"a1b2","streamID":"screen-1","sequence":1,"keyCode":128,"action":"down","modifiers":0}"#),
            ("broker.input.key", "modifier-range", #"{"zoneID":"a1b2","streamID":"screen-1","sequence":1,"keyCode":1,"action":"down","modifiers":32}"#),
            ("broker.input.pointer", "pointer-action-button", #"{"zoneID":"a1b2","streamID":"screen-1","sequence":1,"x":1,"y":1,"action":"move","button":1}"#)
        ] {
            var i = positive.first { $0.control == control }!
            i.wire = envelope(i.receiver == .reply ? "helper.reply" : control, body)
            out.append((name, i))
            if i.receiver == .broker {
                i.receiver = .brokerEnvelope; i.delivery = nil
                out.append((name, i))
            }
        }
        return out
    }

    static func run(iterations: Int, seed: UInt64, evaluate: (H1FuzzInput) throws -> Void) throws -> H1FuzzReport {
        guard (1...10_000).contains(iterations), seed != 0 else { throw S8Error.refused("fuzz bounds: 1...10000, nonzero seed") }
        let controls = try controls()
        var report = H1FuzzReport(iterations: iterations, seed: seed)
        report.expectedPositiveControls = controls.count * 2
        report.coveredControls = controls.map(\.control).sorted()
        var digest = SHA256(); var state = seed
        var classes: Set<String> = []
        func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
        func failure(_ message: String) { if report.failures.count < 16 { report.failures.append(message) } }
        func record(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { digest.update(data: Data($0)) }; digest.update(data: data)
        }
        func check(_ input: H1FuzzInput, positive: Bool, label: String) {
            record(Data("\(input.receiver.rawValue)|\(positive)|\(label)|\(input.control)|\(input.contextDescription)".utf8))
            record(input.wire)
            if !positive { report.negativeCases += 1; classes.insert(label) }
            do {
                try evaluate(input)
                if positive { report.positiveControls += 1 }
                else { report.unexpectedAccepts += 1; failure("accepted negative: \(input.control)/\(label)") }
            } catch let error as ContractError {
                if positive { failure("rejected control: \(input.control): \(error.code)") }
                else if ContractError.codes.contains(error.code) { report.rejectionCodes[error.code, default: 0] += 1 }
                else { failure("unknown contract rejection: \(error.code)") }
            } catch { failure("unexpected harness/decoder error: \(input.control)/\(label): \(error)") }
        }
        for input in controls { check(input, positive: true, label: "before") }
        // Every public message kind and mutation class is covered even for iterations=1.
        for input in controls {
            for variant in mutationNames.indices {
                check(try mutate(input, variant: variant, random: next()), positive: false, label: mutationNames[variant])
            }
        }
        for (name, input) in try semanticNegatives() { check(input, positive: false, label: name) }
        for _ in 0..<iterations {
            let input = controls[Int(next() % UInt64(controls.count))]
            let variant = Int(next() % UInt64(mutationNames.count))
            check(try mutate(input, variant: variant, random: next()), positive: false, label: mutationNames[variant])
        }
        for input in controls { check(input, positive: true, label: "after") }
        report.coveredMutations = classes.sorted()
        report.corpusSHA256 = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return report
    }
}
