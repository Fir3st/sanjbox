import Foundation
import Security

enum SigningSelf {
    struct Observation: Equatable {
        let hardenedRuntime: Bool
        let forbiddenEntitlementPresent: Bool
        var policyMatches: Bool { hardenedRuntime && !forbiddenEntitlementPresent }
    }
    static func evaluate(flags: UInt32, entitlementKeys: Set<String>) -> Observation {
        Observation(
            hardenedRuntime: flags & SecCodeSignatureFlags.runtime.rawValue != 0,
            forbiddenEntitlementPresent: !entitlementKeys.isDisjoint(with: ["get-task-allow", "com.apple.security.get-task-allow"])
        )
    }
    static func evaluateMetadata(_ dictionary: [String: Any]) throws -> Observation {
        guard let flags = dictionary[kSecCodeInfoFlags as String] as? NSNumber,
              CFGetTypeID(flags) != CFBooleanGetTypeID()
        else { throw BoundaryError.invalid("own signing flags unavailable") }
        let keys: Set<String>
        if let value = dictionary[kSecCodeInfoEntitlementsDict as String] {
            guard let entitlements = value as? [String: Any] else { throw BoundaryError.invalid("own entitlement metadata malformed") }
            keys = Set(entitlements.keys)
        } else {
            guard dictionary[kSecCodeInfoEntitlements as String] == nil
            else { throw BoundaryError.invalid("raw entitlements present without decoded dictionary") }
            keys = []
        }
        return evaluate(flags: flags.uint32Value, entitlementKeys: keys)
    }
    /// Observe only our own running executable. No path argument, signing operation, Keychain,
    /// signing-identity enumeration, TCC database or certificate/TeamID output.
    static func observe() throws -> Observation {
        var dynamic: SecCode?
        guard SecCodeCopySelf([], &dynamic) == errSecSuccess, let dynamic,
              SecCodeCheckValidity(dynamic, .noNetworkAccess, nil) == errSecSuccess
        else { throw BoundaryError.invalid("own running signature could not be validated") }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamic, [], &code) == errSecSuccess, let code
        else { throw BoundaryError.invalid("own static code unavailable") }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any]
        else { throw BoundaryError.invalid("own signing metadata unavailable") }
        return try evaluateMetadata(dictionary)
    }
}
