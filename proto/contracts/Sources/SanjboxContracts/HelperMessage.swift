import Foundation

/// Helper message set, version 1. Every kind names its body keys explicitly; a kind that is not in
/// this enum is rejected before any handler sees bytes. This is a prototype contract: no message
/// is ever sent to a real helper and no system operation is behind any of them.
public enum HelperMessageKind: String, CaseIterable, Sendable {
    case capabilities = "helper.capabilities"
    case createZone = "zone.create"
    case startZone = "zone.start"
    case pauseZone = "zone.pause"
    case stopZone = "zone.stop"
    case zoneStatus = "zone.status"
    case applyNetworkPolicy = "policy.apply"
}

public enum HelperMessage: Equatable, Sendable {
    case capabilities
    case createZone(CreateZoneRequest)
    case startZone(ZoneRef)
    case pauseZone(ZoneRef)
    case stopZone(ZoneRef)
    case zoneStatus(ZoneRef)
    case applyNetworkPolicy(ApplyNetworkPolicyRequest)

    public var kind: HelperMessageKind {
        switch self {
        case .capabilities: .capabilities
        case .createZone: .createZone
        case .startZone: .startZone
        case .pauseZone: .pauseZone
        case .stopZone: .stopZone
        case .zoneStatus: .zoneStatus
        case .applyNetworkPolicy: .applyNetworkPolicy
        }
    }

    /// Kind → body shape. Bodies are closed objects; `capabilities` takes the empty object.
    static func shape(for kind: HelperMessageKind) -> Shape {
        switch kind {
        case .capabilities: .object([:])
        case .createZone: CreateZoneRequest.shape
        case .startZone, .pauseZone, .stopZone, .zoneStatus: ZoneRef.shape
        case .applyNetworkPolicy: ApplyNetworkPolicyRequest.shape
        }
    }

    public static func decode(_ data: Data) throws -> HelperMessage {
        let envelope = try XPCEnvelope.decode(data)
        guard let kind = HelperMessageKind(rawValue: envelope.kind) else {
            throw ContractError("unknown-message-kind", "helper does not accept '\(envelope.kind)'")
        }
        let message: HelperMessage
        switch kind {
        case .capabilities:
            // The body must be the closed empty object; an ignored body would be a silent channel.
            _ = try StrictJSON.decode(envelope.body, shape: shape(for: kind), limit: XPCEnvelope.maxBodyBytes,
                                      as: EmptyBody.self)
            message = .capabilities
        case .createZone:
            message = .createZone(try decodeBody(envelope, kind, as: CreateZoneRequest.self))
        case .startZone:
            message = .startZone(try decodeBody(envelope, kind, as: ZoneRef.self))
        case .pauseZone:
            message = .pauseZone(try decodeBody(envelope, kind, as: ZoneRef.self))
        case .stopZone:
            message = .stopZone(try decodeBody(envelope, kind, as: ZoneRef.self))
        case .zoneStatus:
            message = .zoneStatus(try decodeBody(envelope, kind, as: ZoneRef.self))
        case .applyNetworkPolicy:
            message = .applyNetworkPolicy(try decodeBody(envelope, kind, as: ApplyNetworkPolicyRequest.self))
        }
        try message.validate()
        return message
    }

    private static func decodeBody<T: Decodable>(_ envelope: XPCEnvelope, _ kind: HelperMessageKind, as type: T.Type) throws -> T {
        try StrictJSON.decode(envelope.body, shape: shape(for: kind), limit: XPCEnvelope.maxBodyBytes, as: T.self)
    }

    /// Semantic checks that the shape and `Decodable` cannot express (identifier form, UID range,
    /// policy/zone agreement). Called on decode and on encode, so a caller cannot emit a message
    /// this contract would refuse to receive.
    public func validate() throws {
        switch self {
        case .capabilities:
            return
        case .createZone(let request):
            try request.validate()
        case .startZone(let ref), .pauseZone(let ref), .stopZone(let ref), .zoneStatus(let ref):
            try ref.validate()
        case .applyNetworkPolicy(let request):
            try request.validate()
        }
    }

    /// Canonical wire form: envelope JSON with sorted keys and a compact body document.
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body: Data
        switch self {
        case .capabilities:
            body = Data("{}".utf8)
        case .createZone(let request):
            body = try encoder.encode(request)
        case .startZone(let ref), .pauseZone(let ref), .stopZone(let ref), .zoneStatus(let ref):
            body = try encoder.encode(ref)
        case .applyNetworkPolicy(let request):
            body = try encoder.encode(request)
        }
        return try XPCEnvelope(kind: kind.rawValue, body: body).encoded()
    }
}

private struct EmptyBody: Codable {}

/// `zone.create`: declare a zone identity. The UID/GID are design identifiers, never looked up.
public struct CreateZoneRequest: Codable, Equatable, Sendable {
    public static let minUID: UInt32 = 501

    public var zoneID: String
    public var uid: UInt32
    public var gid: UInt32

    public init(zoneID: String, uid: UInt32, gid: UInt32) {
        self.zoneID = zoneID
        self.uid = uid
        self.gid = gid
    }

    static let shape = Shape.object([
        "zoneID": .scalar(maxBytes: 8),
        "uid": .integer(minimum: UInt64(CreateZoneRequest.minUID), maximum: UInt64(UInt32.max)),
        "gid": .integer(minimum: UInt64(CreateZoneRequest.minUID), maximum: UInt64(UInt32.max)),
    ])

    public func validate() throws {
        guard Identifier.isValidZoneID(zoneID) else { throw ContractError.invalidIdentifier("zoneID") }
        guard uid >= Self.minUID, gid >= Self.minUID else {
            throw ContractError.invalidRange("uid/gid below \(Self.minUID)")
        }
    }
}

/// `zone.start|pause|stop|status`: the whole payload is the zone identifier.
public struct ZoneRef: Codable, Equatable, Sendable {
    public var zoneID: String

    public init(zoneID: String) {
        self.zoneID = zoneID
    }

    static let shape = Shape.object(["zoneID": .scalar(maxBytes: 8)])

    public func validate() throws {
        guard Identifier.isValidZoneID(zoneID) else { throw ContractError.invalidIdentifier("zoneID") }
    }
}

/// `policy.apply`: the policy must belong to the zone named by the same message.
public struct ApplyNetworkPolicyRequest: Codable, Equatable, Sendable {
    public var zoneID: String
    public var policy: NetworkPolicy

    public init(zoneID: String, policy: NetworkPolicy) {
        self.zoneID = zoneID
        self.policy = policy
    }

    static let shape = Shape.object([
        "zoneID": .scalar(maxBytes: 8),
        "policy": NetworkPolicy.shape,
    ])

    public func validate() throws {
        guard Identifier.isValidZoneID(zoneID) else { throw ContractError.invalidIdentifier("zoneID") }
        try policy.validate()
        guard policy.zoneID == zoneID else {
            throw ContractError("invalid-policy", "policy.zoneID \(policy.zoneID) != \(zoneID)")
        }
    }
}
