import Foundation
import SanjboxProbeKit

enum BoundaryError: Error, CustomStringConvertible {
    case invalid(String), conflict(String), io(String)
    var description: String {
        switch self {
        case .invalid(let text), .conflict(let text), .io(let text): text
        }
    }
}

/// Only this scope exists. A self fixture is never an approved compartment or an S0 run.
struct BoundaryExpectation: Codable, Equatable {
    let schemaVersion: Int
    let scope: String
    let realUID: UInt32
    let effectiveUID: UInt32
    let realGID: UInt32
    let effectiveGID: UInt32
    let kernelGroups: [UInt32]
    let forbiddenGroups: [UInt32]
    let auditSessionID: Int32
    let auditUID: UInt32
    let launchdManagerName: String
    let launchdManagerUID: UInt32
    let window: WindowExpectation?
    let xpc: XPCFixtureExpectation?

    struct WindowExpectation: Codable, Equatable {
        let userID: UInt32
        let auditSessionID: Int32
        let onConsole: Bool
        let loginDone: Bool
    }

    static func parse(_ text: String) throws -> Self {
        let data = Data(text.utf8)
        try StrictJSON.validate(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).subtracting(["xpc"]) == Set([
                "schemaVersion", "scope", "realUID", "effectiveUID", "realGID", "effectiveGID",
                "kernelGroups", "forbiddenGroups", "auditSessionID", "auditUID",
                "launchdManagerName", "launchdManagerUID", "window",
              ]) else { throw BoundaryError.invalid("expectation: missing or unknown fields") }
        if !(object["window"] is NSNull) {
            guard let window = object["window"] as? [String: Any],
                  Set(window.keys) == Set(["userID", "auditSessionID", "onConsole", "loginDone"])
            else { throw BoundaryError.invalid("expectation: incomplete window context") }
        }
        if let xpc = object["xpc"] {
            guard let fields = xpc as? [String: Any], Set(fields.keys) == Set(["runID", "clientCodeHash", "serviceCodeHash"])
            else { throw BoundaryError.invalid("incomplete XPC preregistration") }
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.xpc?.validate()
        guard value.schemaVersion == 1, value.scope == "synthetic-self-fixture",
              value.realUID > 0, value.effectiveUID > 0,
              value.realUID != UInt32.max, value.effectiveUID != UInt32.max,
              value.realGID != UInt32.max, value.effectiveGID != UInt32.max,
              value.auditSessionID > 0, value.auditUID > 0, value.auditUID != UInt32.max,
              value.launchdManagerUID > 0, value.launchdManagerUID != UInt32.max,
              ["Aqua", "Background"].contains(value.launchdManagerName),
              !value.kernelGroups.isEmpty, value.kernelGroups.count <= 128,
              value.forbiddenGroups.count <= 128,
              Set(value.kernelGroups).count == value.kernelGroups.count,
              Set(value.forbiddenGroups).count == value.forbiddenGroups.count,
              !value.kernelGroups.contains(UInt32.max), !value.forbiddenGroups.contains(UInt32.max),
              Set(value.kernelGroups).isDisjoint(with: value.forbiddenGroups)
        else { throw BoundaryError.invalid("expectation: invalid identity, groups or scope") }
        if let window = value.window {
            guard window.userID > 0, window.userID != UInt32.max, window.auditSessionID > 0
            else { throw BoundaryError.invalid("expectation: invalid window identity") }
        }
        return value
    }

    var groupsOfInterest: Set<UInt32> { Set(kernelGroups + forbiddenGroups) }

    func mismatches(_ context: ProbeContext) -> [String] {
        let base = ProbeExpectation(
            effectiveUID: effectiveUID, realUID: realUID, effectiveGID: effectiveGID, realGID: realGID,
            requiredGroups: kernelGroups, forbiddenGroups: forbiddenGroups,
            launchdManagerName: launchdManagerName, launchdManagerUID: launchdManagerUID
        )
        var result = base.mismatches(in: context).map(\.field)
        if context.kernelGroups.sorted() != kernelGroups.sorted() { result.append("kernelGroups (exact)") }
        if context.audit?.sessionID != auditSessionID { result.append("auditSessionID (exact)") }
        if context.audit?.auditUID != auditUID { result.append("auditUID") }
        // Missing, duplicate or unresolved membership observations are not positive controls.
        if context.groupMembership.count != groupsOfInterest.count ||
            Set(context.groupMembership.map(\.gid)) != groupsOfInterest {
            result.append("groupMembership completeness")
        }
        if let expected = window {
            if context.windowSession?.userID != expected.userID { result.append("window.userID") }
            if context.windowSession?.auditSessionID != expected.auditSessionID { result.append("window.auditSessionID") }
            if context.windowSession?.onConsole != expected.onConsole { result.append("window.onConsole") }
            if context.windowSession?.loginDone != expected.loginDone { result.append("window.loginDone") }
        } else if context.windowSession != nil { result.append("window must be absent") }
        return result
    }
}

/// Small bounded syntax pass BEFORE Foundation decoding; Foundation alone silently accepts duplicate keys.
/// Strings use JSONDecoder so escaped keys ("a" / "\u0061") compare as decoded strings.
private struct StrictJSON {
    var bytes: [UInt8]
    var offset = 0
    var nodes = 0
    static func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 16_384 else { throw BoundaryError.invalid("expectation: size limit") }
        var parser = Self(bytes: Array(data))
        try parser.value(depth: 0)
        parser.whitespace()
        guard parser.offset == parser.bytes.count else { throw BoundaryError.invalid("expectation: trailing JSON") }
    }
    mutating func whitespace() { while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
    mutating func take(_ byte: UInt8) -> Bool {
        whitespace()
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }
    mutating func string() throws -> String {
        whitespace()
        let start = offset
        guard take(34) else { throw BoundaryError.invalid("expectation: JSON string required") }
        var escaped = false
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if byte == 34 && !escaped {
                guard offset - start <= 512 else { throw BoundaryError.invalid("expectation: string limit") }
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
            }
            escaped = byte == 92 && !escaped
        }
        throw BoundaryError.invalid("expectation: unterminated string")
    }
    mutating func value(depth: Int) throws {
        nodes += 1
        guard depth <= 4, nodes <= 512 else { throw BoundaryError.invalid("expectation: structure limit") }
        whitespace()
        if take(123) {
            var keys = Set<String>()
            if take(125) { return }
            repeat {
                let key = try string()
                guard keys.insert(key).inserted else { throw BoundaryError.invalid("expectation: duplicate JSON key") }
                guard take(58) else { throw BoundaryError.invalid("expectation: colon required") }
                try value(depth: depth + 1)
                if take(125) { return }
            } while take(44)
            throw BoundaryError.invalid("expectation: malformed object")
        }
        if take(91) {
            if take(93) { return }
            repeat {
                try value(depth: depth + 1)
                if take(93) { return }
            } while take(44)
            throw BoundaryError.invalid("expectation: malformed array")
        }
        if offset < bytes.count, bytes[offset] == 34 { _ = try string(); return }
        for literal in ["true", "false", "null"] {
            let token = Array(literal.utf8)
            if bytes[offset...].starts(with: token) { offset += token.count; return }
        }
        let start = offset
        while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
        guard offset > start, offset - start <= 10,
              offset - start == 1 || bytes[start] != 48
        else { throw BoundaryError.invalid("expectation: unsigned decimal integer required") }
    }
}
