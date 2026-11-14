import Foundation
import Security
import XPC

/// Verifier-owned inputs, never decoded from an XPC message. Provisioning an
/// independently trusted host policy is still a separate, unfinished A6 task.
/// An exact CDHash pins one executable build; an identifier or team name alone
/// is not a substitute. There is no default, self-discovery, or adoption path.
public struct NativeXPCPeerPolicy: Sendable {
    public let codeDirectoryHash: Data
    public let effectiveUID: UInt32
    public let effectiveGID: UInt32
    public let auditSessionID: Int32

    public init(codeDirectoryHash: Data, effectiveUID: UInt32, effectiveGID: UInt32,
                auditSessionID: Int32) throws {
        guard codeDirectoryHash.count == 20, codeDirectoryHash.contains(where: { $0 != 0 }),
              effectiveUID != 0, effectiveUID != UInt32.max, effectiveGID != UInt32.max,
              auditSessionID > 0 else {
            throw S8Error.refused("explicit non-root credentials, audit session and 20-byte code pin required")
        }
        self.codeDirectoryHash = codeDirectoryHash
        self.effectiveUID = effectiveUID; self.effectiveGID = effectiveGID
        self.auditSessionID = auditSessionID
    }

    /// Safe to give to xpc_connection_set_peer_code_signing_requirement exactly
    /// once before activating a new connection. No caller-supplied requirement DSL.
    public var codeSigningRequirement: String {
        "cdhash H\"" + codeDirectoryHash.map { String(format: "%02x", $0) }.joined() + "\""
    }
}

/// A read-only observation, deliberately not an authorization capability.
/// Connection credentials are OS values at connection establishment, not a claim
/// about every sender of a transferred Mach right. The code is message-bound.
public struct NativeXPCMessageIdentity: Equatable, Sendable {
    public let codeDirectoryHash: Data
    public let connectionEffectiveUID: UInt32
    public let connectionEffectiveGID: UInt32
    public let connectionAuditSessionID: Int32
    public let adHoc: Bool
    public let mutationAuthorized = false
}

/// The only identity input is a received XPC dictionary with OS transport
/// provenance. No PID lookup, wire audit-token decoding, bundle-path lookup,
/// cached admission, journal or UUID can substitute for that provenance.
public final class NativeXPCMessageVerifier: @unchecked Sendable {
    public let policy: NativeXPCPeerPolicy
    private let requirement: SecRequirement

    public init(policy: NativeXPCPeerPolicy) throws {
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(policy.codeSigningRequirement as CFString, [], &parsed) == errSecSuccess,
              let parsed else { throw S8Error.refused("native code pin requirement unavailable") }
        self.policy = policy; requirement = parsed
    }

    public func inspect(received message: xpc_object_t) throws -> NativeXPCMessageIdentity {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY,
              let connection = xpc_dictionary_get_remote_connection(message) else {
            throw S8Error.refused("received XPC message provenance required")
        }
        let uid = xpc_connection_get_euid(connection)
        let gid = xpc_connection_get_egid(connection)
        let session = xpc_connection_get_asid(connection)
        guard uid == policy.effectiveUID, gid == policy.effectiveGID, session == policy.auditSessionID else {
            throw S8Error.refused("OS connection credentials differ from verifier policy")
        }

        // Public Security API obtains the sender from this message's OS audit
        // token, including its process generation. A payload field is never read.
        var guest: SecCode?
        guard SecCodeCreateWithXPCMessage(message, [], &guest) == errSecSuccess, let guest else {
            throw S8Error.refused("OS message-bound code identity unavailable")
        }
        guard SecCodeCheckValidity(guest, .noNetworkAccess, requirement) == errSecSuccess else {
            throw S8Error.refused("message sender does not satisfy live code pin")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess, let staticCode else {
            throw S8Error.refused("message sender static code binding unavailable")
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let fields = info as? [String: Any],
              let hash = fields[kSecCodeInfoUnique as String] as? Data, hash == policy.codeDirectoryHash,
              let flags = (fields[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value,
              flags & SecCodeSignatureFlags.runtime.rawValue != 0 else {
            throw S8Error.refused("message sender hardened signature metadata unavailable or changed")
        }
        let entitlements = SignaturePolicy.entitlementState(
            dictionary: fields[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
            rawBlobPresent: fields[kSecCodeInfoEntitlements as String] != nil)
        guard entitlements.0 == .absent, entitlements.1 == false,
              SecCodeCheckValidity(guest, .noNetworkAccess, requirement) == errSecSuccess else {
            throw S8Error.refused("message sender entitlements or live validity refused")
        }
        return .init(codeDirectoryHash: hash, connectionEffectiveUID: uid,
                     connectionEffectiveGID: gid, connectionAuditSessionID: session,
                     adHoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0)
    }
}
