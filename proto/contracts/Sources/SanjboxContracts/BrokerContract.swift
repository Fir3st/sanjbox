import Foundation

/// Broker envelope, `broker-v0`.
///
/// The broker message set is **intentionally an empty subset** of the broker described in PLAN.
/// Broker/WP3.2 does not exist, so v0 only fixes the versioned envelope and the rejection rules:
/// a receiver must refuse any kind, and must refuse it *after* the header checks so that a wrong
/// version is reported as a version error rather than as an unknown message.
public enum BrokerContract {
    public static let protocolVersion: UInt32 = 0
    public static let maxBytes = 4 * 1024
    /// Accepted message kinds. Empty by design; see README.
    public static let acceptedKinds: Set<String> = []

    static let shape = Shape.object([
        "version": .integer(minimum: 0, maximum: UInt64(UInt32.max)),
        "kind": .scalar(maxBytes: 64),
        "body": .scalar(maxBytes: maxBytes),
    ])

    /// Decodes and validates a broker envelope. Always throws with `unknown-message-kind` for a
    /// well-formed v0 envelope, because no kind is accepted yet. Kept as a throwing API on purpose:
    /// a future broker widens `acceptedKinds` and the same call sites start accepting messages.
    @discardableResult
    public static func decode(_ data: Data) throws -> BrokerEnvelope {
        let envelope = try StrictJSON.decode(data, shape: shape, limit: maxBytes, as: BrokerEnvelope.self)
        guard envelope.version == protocolVersion else {
            throw ContractError("invalid-version", "expected \(protocolVersion), got \(envelope.version)")
        }
        guard (1...64).contains(envelope.kind.utf8.count) else {
            throw ContractError("unknown-message-kind", "malformed kind")
        }
        guard acceptedKinds.contains(envelope.kind) else {
            throw ContractError("unknown-message-kind", "broker-v0 accepts no kind, got '\(envelope.kind)'")
        }
        return envelope
    }
}

public struct BrokerEnvelope: Codable, Equatable, Sendable {
    public var version: UInt32
    public var kind: String
    public var body: Data

    public init(version: UInt32 = BrokerContract.protocolVersion, kind: String, body: Data) {
        self.version = version
        self.kind = kind
        self.body = body
    }

    public func encoded() throws -> Data {
        guard version == BrokerContract.protocolVersion else {
            throw ContractError("invalid-version", "expected \(BrokerContract.protocolVersion), got \(version)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
