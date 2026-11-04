import Foundation
import Security

/// Own executable only: no paths, signing identities, Keychain, or target-process lookup.
public struct ProbeSignature: Codable, Equatable, Sendable {
    public var hardenedRuntime: Bool
    public var forbiddenEntitlementPresent: Bool
    public var valid: Bool { hardenedRuntime && !forbiddenEntitlementPresent }
    static func metadata(_ dictionary: [String: Any]) throws -> ProbeSignature {
        guard let flags = dictionary[kSecCodeInfoFlags as String] as? NSNumber,
              CFGetTypeID(flags) != CFBooleanGetTypeID() else { throw InstrumentError("signing flags unavailable") }
        let keys: Set<String>
        if let value = dictionary[kSecCodeInfoEntitlementsDict as String] {
            guard let entitlements = value as? [String: Any] else { throw InstrumentError("malformed entitlements") }
            keys = Set(entitlements.keys)
        } else {
            try require(dictionary[kSecCodeInfoEntitlements as String] == nil, "undecoded entitlements")
            keys = []
        }
        return ProbeSignature(hardenedRuntime: flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0,
            forbiddenEntitlementPresent: !keys.isDisjoint(with: ["get-task-allow", "com.apple.security.get-task-allow"]))
    }
    public static func capture() throws -> ProbeSignature {
        var dynamic: SecCode?
        try require(SecCodeCopySelf([], &dynamic) == errSecSuccess && dynamic != nil, "own code unavailable")
        try require(SecCodeCheckValidity(dynamic!, .noNetworkAccess, nil) == errSecSuccess, "own running signature invalid")
        var code: SecStaticCode?
        try require(SecCodeCopyStaticCode(dynamic!, [], &code) == errSecSuccess && code != nil, "own static code unavailable")
        var info: CFDictionary?
        try require(SecCodeCopySigningInformation(code!, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            "own signing metadata unavailable")
        guard let dictionary = info as? [String: Any] else { throw InstrumentError("own signing metadata missing") }
        return try metadata(dictionary)
    }
    public static func requireSafe() throws {
        try require(try capture().valid, "invalidMeasurement: hardened runtime required; get-task-allow forbidden")
    }
}

extension StrictJSON {
    /// New schemas reject unknown keys recursively. Optional fields must be omitted, not null.
    public static func decodeExact<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        let value = try decode(type, from: data)
        let original = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let normalized = try JSONSerialization.jsonObject(with: encoded(value), options: [.fragmentsAllowed])
        try exactKeys(original, normalized)
        return value
    }
    private static func exactKeys(_ original: Any, _ normalized: Any) throws {
        if let object = original as? [String: Any], let other = normalized as? [String: Any] {
            try require(Set(object.keys).isSubset(of: Set(other.keys)), "unknown JSON field or null optional field")
            for (key, value) in object { try exactKeys(value, other[key]!) }
        } else if let array = original as? [Any], let other = normalized as? [Any] {
            try require(array.count == other.count, "JSON array shape changed")
            for (a, b) in zip(array, other) { try exactKeys(a, b) }
        }
    }
}

func digest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
func validateStamp(_ stamp: ClockStamp) throws {
    try require(boundedTime(stamp.monotonic) && stamp.utc.isFinite && stamp.utc > 0 && stamp.utc < 10_000_000_000 &&
        stamp.uncertainty.isFinite && (0...1).contains(stamp.uncertainty) && digest(stamp.bootIDHash), "invalid clock stamp")
}
func clockIssues(_ start: ClockStamp, _ end: ClockStamp) throws -> [String] {
    try validateStamp(start); try validateStamp(end)
    var issues: [String] = []
    if start.bootIDHash != end.bootIDHash { issues.append("different boot clock domains") }
    if end.monotonic < start.monotonic { issues.append("reversed monotonic timestamps") }
    if abs((end.utc - start.utc) - (end.monotonic - start.monotonic)) > 0.1 + start.uncertainty + end.uncertainty {
        issues.append("UTC/monotonic discontinuity")
    }
    return issues
}
