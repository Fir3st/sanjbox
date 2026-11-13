import Foundation

/// Documented, stable v0 network policy format.
///
/// Wire form is a single JSON object with a closed key set. Canonical encoding sorts keys and has
/// no pretty printing, so two equal policies produce the same bytes. The format only *describes*
/// intent: it is not a pf anchor, not an enforcement proof and not a bind policy.
public struct NetworkPolicy: Codable, Equatable, Sendable {
    public static let schemaName = "sanjbox.network-policy.v1"
    public static let maxBytes = 16 * 1024
    public static let maxGates = 16

    public var schema: String
    public var zoneID: String
    /// Only `deny` is representable: the v0 policy has no allow-by-default mode, so a policy
    /// cannot silently widen into "everything not listed passes".
    public var defaultAction: String
    public var gates: [TypedGate]

    public init(schema: String = NetworkPolicy.schemaName, zoneID: String, defaultAction: String = "deny",
                gates: [TypedGate]) {
        self.schema = schema
        self.zoneID = zoneID
        self.defaultAction = defaultAction
        self.gates = gates
    }

    static let shape = Shape.object([
        "schema": .scalar(maxBytes: 64),
        "zoneID": .scalar(maxBytes: 8),
        "defaultAction": .scalar(maxBytes: 16),
        "gates": .array(TypedGate.shape, max: NetworkPolicy.maxGates),
    ])

    public static func decode(_ data: Data) throws -> NetworkPolicy {
        let policy = try StrictJSON.decode(data, shape: shape, limit: maxBytes, as: NetworkPolicy.self)
        try policy.validate()
        return policy
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Rejects every documented violation with a stable code. The first violation wins so a
    /// caller cannot mistake a partially valid policy for an applied one.
    public func validate() throws {
        guard schema == Self.schemaName else {
            throw ContractError("invalid-policy", "schema \(schema) != \(Self.schemaName)")
        }
        guard Identifier.isValidZoneID(zoneID) else {
            throw ContractError.invalidIdentifier("policy.zoneID")
        }
        guard defaultAction == "deny" else {
            throw ContractError("invalid-policy", "defaultAction must be deny")
        }
        guard gates.count <= Self.maxGates else {
            throw ContractError("collection-limit", "gates \(gates.count) > \(Self.maxGates)")
        }
        var seen = Set<String>()
        for (index, gate) in gates.enumerated() {
            guard seen.insert(gate.id).inserted else {
                throw ContractError("invalid-policy", "duplicate gate id \(gate.id) at index \(index)")
            }
            try gate.validate(path: "gates[\(index)]")
        }
    }
}

/// One typed gate: a named egress destination that a future gateway (WP1.H4 / WP2.5) may serve.
/// `type` selects the protocol subset; the v0 format deliberately carries no credential or
/// approval material and no wildcard.
public struct TypedGate: Codable, Equatable, Sendable {
    public static let maxRequestBytesLimit: UInt32 = 8 * 1024 * 1024
    public static let maxResponseBytesLimit: UInt32 = 16 * 1024 * 1024
    public static let maxMethods = 4

    public var id: String
    public var type: GateType
    /// Lowercase DNS hostname, no scheme, no port, no path, no wildcard.
    public var upstream: String
    /// Only `model-api` declares HTTP methods; every other type must send an empty array.
    public var methods: [String]
    public var requestBytesLimit: UInt32
    public var responseBytesLimit: UInt32

    public init(id: String, type: GateType, upstream: String, methods: [String] = [],
                requestBytesLimit: UInt32 = 1_048_576, responseBytesLimit: UInt32 = 4_194_304) {
        self.id = id
        self.type = type
        self.upstream = upstream
        self.methods = methods
        self.requestBytesLimit = requestBytesLimit
        self.responseBytesLimit = responseBytesLimit
    }

    static let shape = Shape.object([
        "id": .scalar(maxBytes: 32),
        "type": .scalar(maxBytes: 16),
        "upstream": .scalar(maxBytes: 253),
        "methods": .array(.scalar(maxBytes: 8), max: TypedGate.maxMethods),
        "requestBytesLimit": .integer(minimum: 1, maximum: UInt64(TypedGate.maxRequestBytesLimit)),
        "responseBytesLimit": .integer(minimum: 1, maximum: UInt64(TypedGate.maxResponseBytesLimit)),
    ])

    public func validate(path: String = "gate") throws {
        guard Identifier.isValidPlanID(id) else { throw ContractError.invalidIdentifier("\(path).id") }
        guard Identifier.isValidHostname(upstream) else { throw ContractError("invalid-policy", "\(path).upstream") }
        guard requestBytesLimit >= 1, requestBytesLimit <= Self.maxRequestBytesLimit else {
            throw ContractError.invalidRange("\(path).requestBytesLimit")
        }
        guard responseBytesLimit >= 1, responseBytesLimit <= Self.maxResponseBytesLimit else {
            throw ContractError.invalidRange("\(path).responseBytesLimit")
        }
        guard methods.count <= Self.maxMethods else { throw ContractError("collection-limit", "\(path).methods") }
        switch type {
        case .modelAPI:
            guard !methods.isEmpty else { throw ContractError("invalid-policy", "\(path).methods required for model-api") }
        default:
            guard methods.isEmpty else { throw ContractError("invalid-policy", "\(path).methods only valid for model-api") }
        }
        for method in methods where !GateType.modelMethods.contains(method) {
            throw ContractError("invalid-policy", "\(path).methods \(method)")
        }
        guard Set(methods).count == methods.count else { throw ContractError("invalid-policy", "\(path).methods duplicate") }
    }
}

public enum GateType: String, Codable, CaseIterable, Sendable {
    case npm
    case pypi
    case git
    case brew
    case modelAPI = "model-api"

    /// Closed HTTP method subset for the only type that speaks raw HTTP in v0.
    public static let modelMethods: Set<String> = ["GET", "POST"]
}
