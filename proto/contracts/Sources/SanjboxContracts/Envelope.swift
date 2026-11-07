import Foundation

/// Transport header of one helper XPC message. The header is deliberately tiny: the contract
/// fixes the protocol version, a closed key set and an absolute byte budget before the body is
/// handed to a typed decoder. `body` is a JSON document (base64 in the wire form), not free bytes
/// to be interpreted differently by each handler.
public struct XPCEnvelope: Codable, Equatable, Sendable {
    /// Helper protocol version. Any other value is rejected, including newer and older ones.
    public static let helperProtocolVersion: UInt32 = 1
    /// Absolute wire limit for one helper message (header + base64 body). It must leave room for
    /// the base64 expansion of a full `maxBodyBytes` body: 48 KiB becomes 64 KiB of base64 text.
    public static let maxBytes = 72 * 1024
    /// Body limit; the body is decoded as JSON after base64 unescaping.
    public static let maxBodyBytes = 48 * 1024

    public var version: UInt32
    public var kind: String
    public var body: Data

    public init(version: UInt32 = XPCEnvelope.helperProtocolVersion, kind: String, body: Data) {
        self.version = version
        self.kind = kind
        self.body = body
    }

    static let shape = Shape.object([
        "version": .integer(minimum: 0, maximum: UInt64(UInt32.max)),
        "kind": .scalar(maxBytes: 64),
        // `Data` is a base64 string on the wire, so its textual length is 4/3 of the raw body.
        // The authoritative raw-byte budget is checked in `headerProblem()` after decoding;
        // bounding the string by the envelope limit keeps that check (and its error code) first.
        "body": .scalar(maxBytes: XPCEnvelope.maxBytes),
    ])

    /// Validates the wire form and returns the header. Unknown kinds are *not* judged here; the
    /// message set of a receiver decides that (`HelperMessage.decode`, `BrokerContract.decode`).
    public static func decode(_ data: Data) throws -> XPCEnvelope {
        // The body is a base64 string: its textual form is up to 4/3 of `maxBodyBytes`. Raising the
        // preflight string guard to the envelope limit keeps a full-size body decodable; the raw
        // byte budget is then enforced by `headerProblem()` after base64 decoding.
        let envelope = try StrictJSON.decode(data, shape: shape, limit: maxBytes, stringLimit: maxBytes,
                                             as: XPCEnvelope.self)
        if let problem = envelope.headerProblem() {
            throw problem
        }
        return envelope
    }

    /// Header-local checks: version, kind syntax and body budget.
    public func headerProblem() -> ContractError? {
        guard version == Self.helperProtocolVersion else {
            return ContractError("invalid-version", "expected \(Self.helperProtocolVersion), got \(version)")
        }
        guard (1...64).contains(kind.utf8.count), kind.utf8.allSatisfy({ (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 }) else {
            return ContractError("unknown-message-kind", "malformed kind '\(kind)'")
        }
        guard body.count <= Self.maxBodyBytes else {
            return ContractError.inputTooLarge("body \(body.count) > \(Self.maxBodyBytes)")
        }
        return nil
    }

    public func encoded() throws -> Data {
        if let problem = headerProblem() { throw problem }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
