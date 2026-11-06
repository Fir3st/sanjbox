import CryptoKit
import Darwin
import Foundation
import Security

public enum ProvenanceScope: String, Codable, Sendable { case hostDiagnostic, testArea }
public enum NetworkTransport: String, Codable, Sendable { case tcp, udp }

public struct OwnSignature: Codable, Equatable, Sendable {
    public var valid: Bool
    public var hardenedRuntime: Bool
    public var getTaskAllowAbsent: Bool
    public var codeHash: String
    static let shape: Shape = .object(["valid": .scalar, "hardenedRuntime": .scalar,
        "getTaskAllowAbsent": .scalar, "codeHash": .scalar])
    public var permitsLive: Bool { valid && hardenedRuntime && getTaskAllowAbsent && codeHash.count == 40 }
    static func inspect(valid: Bool, metadata: [String: Any]) throws -> Self {
        guard let flags = metadata[kSecCodeInfoFlags as String] as? NSNumber,
              CFGetTypeID(flags) != CFBooleanGetTypeID(),
              let hash = metadata[kSecCodeInfoUnique as String] as? Data, hash.count == 20
        else { throw ProvenanceError("own signature metadata incomplete") }
        let entitlements: [String: Any]
        if let raw = metadata[kSecCodeInfoEntitlementsDict as String] {
            guard let decoded = raw as? [String: Any] else { throw ProvenanceError("malformed own entitlements") }
            entitlements = decoded
        } else {
            guard metadata[kSecCodeInfoEntitlements as String] == nil else { throw ProvenanceError("undecoded own entitlements") }
            entitlements = [:]
        }
        return .init(valid: valid, hardenedRuntime: flags.uint32Value & 0x10000 != 0,
            getTaskAllowAbsent: entitlements["get-task-allow"] == nil && entitlements["com.apple.security.get-task-allow"] == nil,
            codeHash: hash.map { String(format: "%02x", $0) }.joined())
    }
    public static func capture() throws -> Self {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw ProvenanceError("own code unavailable") }
        let valid = SecCodeCheckValidity(code, .noNetworkAccess, nil) == errSecSuccess
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { throw ProvenanceError("own static code unavailable") }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let metadata = info as? [String: Any] else { throw ProvenanceError("own signing information unavailable") }
        return try inspect(valid: valid, metadata: metadata)
    }
}

public struct NetworkExpectation: Codable, Sendable {
    public var schemaVersion: Int
    public var scope: ProvenanceScope
    public var identity: NetworkIdentity
    public var signature: OwnSignature
    public var forbiddenAuditSessionIDs: [Int32]
    static let shape: Shape = .object(["schemaVersion": .scalar, "scope": .scalar,
        "identity": NetworkIdentity.shape, "signature": OwnSignature.shape, "forbiddenAuditSessionIDs": .array(.scalar)])
    public static func decode(_ data: Data) throws -> Self {
        let value = try strictDecode(Self.self, data: data, shape: shape)
        try value.validate(); return value
    }
    public func validate() throws {
        try identity.validate()
        guard forbiddenAuditSessionIDs.count <= 64, forbiddenAuditSessionIDs == forbiddenAuditSessionIDs.sorted(),
              Set(forbiddenAuditSessionIDs).count == forbiddenAuditSessionIDs.count, forbiddenAuditSessionIDs.allSatisfy({ $0 >= 0 }),
              !forbiddenAuditSessionIDs.contains(identity.auditSessionID) else { throw ProvenanceError("invalid forbidden audit sessions") }
        guard schemaVersion == 1, signature.permitsLive,
              signature.codeHash.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil else { throw ProvenanceError("weak signature expectation") }
        if scope == .testArea {
            // The legacy C1 non-console policy remains mandatory for area measurements.
            guard !forbiddenAuditSessionIDs.isEmpty, (400...60000).contains(identity.effectiveUID), identity.realUID == identity.effectiveUID,
                  identity.realGID == identity.effectiveGID, !identity.requiredGroups.isEmpty,
                  Set(identity.forbiddenGroups).isSuperset(of: [20, 80]), identity.managerName == "Aqua",
                  identity.managerUID == identity.effectiveUID, identity.windowUID == identity.effectiveUID,
                  identity.windowAuditSessionID == identity.auditSessionID, identity.onConsole == false,
                  identity.loginDone == true else { throw ProvenanceError("weak testArea identity expectation") }
        }
    }
    public func preflight() throws -> NetworkIdentity {
        try validate()
        let actual = try OwnNetworkIdentity.capture(expected: identity)
        guard !forbiddenAuditSessionIDs.contains(actual.auditSessionID) else { throw ProvenanceError("forbidden actual audit session") }
        let signature = try OwnSignature.capture()
        guard signature.permitsLive, signature == self.signature else { throw ProvenanceError("own signature mismatch; target unread, no sockets") }
        return actual
    }
}

/// Prepared before either endpoint opens a socket; synthetic correlation, never authentication.
public struct FlowChallenge: Codable, Equatable, Sendable {
    public var runID: UUID
    public var flowID: UUID
    public var challenge: String
    public var preparedAtUTC: String
    static let shape: Shape = .object(["runID": .scalar, "flowID": .scalar, "challenge": .scalar, "preparedAtUTC": .scalar])
    public static func prepare(runID: UUID) throws -> Self {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ProvenanceError("random generation failed") }
        return .init(runID: runID, flowID: UUID(), challenge: bytes.map { String(format: "%02x", $0) }.joined(), preparedAtUTC: Timestamp.now().utc)
    }
    public func validate(now: Date = Date()) throws {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard challenge.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let date = formatter.date(from: preparedAtUTC), formatter.string(from: date) == preparedAtUTC,
              now.timeIntervalSince(date) >= -1, now.timeIntervalSince(date) <= 600,
              runID != UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
              flowID != UUID(uuidString: "00000000-0000-0000-0000-000000000000")
        else { throw ProvenanceError("invalid or expired preregistered flow (10 minute limit)") }
    }
    public var bytes: Data { Data("SANJBOX-NETWORK-PROVENANCE-V1|\(runID.uuidString)|\(flowID.uuidString)|\(challenge)\n".utf8) }
    /// Parse only exact canonical wire bytes. Arbitrary traffic remains in independent raw files.
    static func claims(_ data: Data) -> PayloadClaims? {
        guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\n") else { return nil }
        let fields = text.dropLast().split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == "SANJBOX-NETWORK-PROVENANCE-V1",
              let run = UUID(uuidString: String(fields[1])), run.uuidString == fields[1],
              let flow = UUID(uuidString: String(fields[2])), flow.uuidString == fields[2],
              fields[3].range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return nil }
        return .init(runID: run, flowID: flow, challenge: String(fields[3]))
    }
}
public struct PayloadClaims: Codable, Equatable, Sendable {
    public var runID: UUID
    public var flowID: UUID
    public var challenge: String
}
public struct NetworkEndpoint: Codable, Equatable, Sendable {
    public var host: String
    public var port: UInt16
    static let shape: Shape = .object(["host": .scalar, "port": .scalar])
    public init(host: String, port: UInt16) { self.host = host; self.port = port }
    public var family: String { host.contains(":") ? "ipv6" : "ipv4" }
    public func validate(allowZeroPort: Bool) throws {
        guard (allowZeroPort && port == 0) || port >= 1024 else { throw ProvenanceError("port must be 1024…65535, or receiver ephemeral 0") }
        var v4 = in_addr(), v6 = in6_addr()
        guard host.utf8.count <= 45, !host.contains("\0") else { throw ProvenanceError("invalid numeric address") }
        if inet_pton(AF_INET, host, &v4) == 1 {
            let number = UInt32(bigEndian: v4.s_addr)
            // Reject unspecified, multicast, reserved/broadcast. Subnet broadcast needs operator topology knowledge.
            guard number >> 24 != 0, number >> 24 < 224, number & 0xffff0000 != 0xa9fe0000,
                  number & 255 != 255 else { throw ProvenanceError("unsupported IPv4 destination") }
        } else if inet_pton(AF_INET6, host, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            guard bytes.contains(where: { $0 != 0 }), bytes[0] != 0xff,
                  !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80),
                  !(bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255),
                  !(bytes.prefix(12).allSatisfy { $0 == 0 } && bytes.suffix(4) != [0,0,0,1])
            else { throw ProvenanceError("unsupported IPv6 destination") }
        } else { throw ProvenanceError("numeric unscoped unicast address required") }
        guard try SocketAddress(self).endpoint() == self else { throw ProvenanceError("canonical numeric address required") }
    }
}
public struct NetworkRegistration: Codable, Sendable {
    public var schemaVersion: Int
    public var scope: ProvenanceScope
    public var flow: FlowChallenge
    public var transport: NetworkTransport
    public var endpoint: NetworkEndpoint
    public var controlledTarget: Bool
    public var durationMilliseconds: Int
    public var maximumContacts: Int
    static let shape: Shape = .object(["schemaVersion": .scalar, "scope": .scalar, "flow": FlowChallenge.shape,
        "transport": .scalar, "endpoint": NetworkEndpoint.shape, "controlledTarget": .scalar,
        "durationMilliseconds": .scalar, "maximumContacts": .scalar])
    public static func decode(_ data: Data, receiver: Bool) throws -> Self {
        let value = try strictDecode(Self.self, data: data, shape: shape)
        try value.validate(receiver: receiver); return value
    }
    public func validate(receiver: Bool) throws {
        try flow.validate(); try endpoint.validate(allowZeroPort: receiver)
        guard schemaVersion == 1, controlledTarget, (100...10000).contains(durationMilliseconds),
              (1...16).contains(maximumContacts) else { throw ProvenanceError("invalid registration/bounds/controlledTarget") }
    }
}
public struct Timestamp: Codable, Sendable {
    public var utc: String
    public var monotonicNanoseconds: UInt64
    public static func now() -> Self {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .init(utc: formatter.string(from: Date()), monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
}
public func provenanceDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
