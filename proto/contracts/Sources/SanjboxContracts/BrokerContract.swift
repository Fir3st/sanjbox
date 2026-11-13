import Foundation

/// Version 1 is the first nonempty broker contract. Version 0 accepted no messages.
/// This metadata contract never resolves a PID, global IOSurface ID, path or Mach port name.
public enum BrokerContract {
    public static let protocolVersion: UInt32 = 1
    public static let maxBytes = 4096
    public static let maxBodyBytes = 2048
    public static let acceptedKinds = Set(BrokerMessageKind.allCases.map(\.rawValue))

    static let shape = Shape.object([
        "version": .integer(minimum: 0, maximum: UInt64(UInt32.max)),
        "kind": .scalar(maxBytes: 64), "body": .scalar(maxBytes: maxBytes),
    ])

    /// Fully validates the body before returning the envelope; no accepted-but-unchecked payload.
    public static func decode(_ data: Data) throws -> BrokerEnvelope {
        let envelope = try StrictJSON.decode(data, shape: shape, limit: maxBytes,
                                             stringLimit: maxBytes, as: BrokerEnvelope.self)
        try envelope.validateHeader()
        _ = try BrokerMessage.decodeBody(envelope)
        return envelope
    }
}

public struct BrokerEnvelope: Codable, Equatable, Sendable {
    public var version: UInt32
    public var kind: String
    public var body: Data

    public init(version: UInt32 = BrokerContract.protocolVersion, kind: String, body: Data) {
        self.version = version; self.kind = kind; self.body = body
    }

    func validateHeader() throws {
        guard version == BrokerContract.protocolVersion else {
            throw ContractError("invalid-version", "broker expects version \(BrokerContract.protocolVersion)")
        }
        guard BrokerContract.acceptedKinds.contains(kind) else {
            throw ContractError("unknown-message-kind", "unsupported broker kind")
        }
        guard body.count <= BrokerContract.maxBodyBytes else { throw ContractError.inputTooLarge("broker body") }
    }

    public func encoded() throws -> Data {
        try validateHeader()
        _ = try BrokerMessage.decodeBody(self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= BrokerContract.maxBytes else { throw ContractError.inputTooLarge("broker envelope") }
        return data
    }
}

public enum BrokerMessageKind: String, CaseIterable, Sendable {
    case frame = "broker.frame"
    case keyInput = "broker.input.key"
    case pointerInput = "broker.input.pointer"
}

public enum BrokerPeerRole: String, Sendable { case hostController, sessionAgent }
public enum BrokerKeyAction: String, Codable, Sendable { case down, up }
public enum BrokerPointerAction: String, Codable, Sendable { case move, down, up }

/// Trusted adapter state established by audit-token/signature/session checks, never from JSON.
/// `lastSequence` is per stream and sending direction. The adapter must atomically advance it
/// only after admission, and must verify the actual Mach attachment's kind, ownership and size.
public struct BrokerDeliveryContext: Sendable {
    public var peerRole: BrokerPeerRole
    public var zoneID: String
    public var streamID: String
    public var width: UInt32
    public var height: UInt32
    public var lastSequence: UInt64
    public var surfaceAttachmentCount: Int

    public init(peerRole: BrokerPeerRole, zoneID: String, streamID: String, width: UInt32,
                height: UInt32, lastSequence: UInt64, surfaceAttachmentCount: Int) {
        self.peerRole = peerRole; self.zoneID = zoneID; self.streamID = streamID
        self.width = width; self.height = height; self.lastSequence = lastSequence
        self.surfaceAttachmentCount = surfaceAttachmentCount
    }
}

public struct BrokerFrame: Codable, Equatable, Sendable {
    public var zoneID: String
    public var streamID: String
    public var sequence: UInt64
    public var width: UInt32
    public var height: UInt32
    /// Exactly index zero of the one out-of-band IOSurface Mach send right; never a global ID.
    public var surfaceAttachmentIndex: UInt32

    public init(zoneID: String, streamID: String, sequence: UInt64, width: UInt32, height: UInt32,
                surfaceAttachmentIndex: UInt32 = 0) {
        self.zoneID = zoneID; self.streamID = streamID; self.sequence = sequence
        self.width = width; self.height = height; self.surfaceAttachmentIndex = surfaceAttachmentIndex
    }
    static let shape = Shape.object([
        "zoneID": .scalar(maxBytes: 8), "streamID": .scalar(maxBytes: 32),
        "sequence": .integer(minimum: 1, maximum: UInt64.max),
        "width": .integer(minimum: 1, maximum: 8192), "height": .integer(minimum: 1, maximum: 8192),
        "surfaceAttachmentIndex": .integer(minimum: 0, maximum: 0),
    ])
}

public struct BrokerKeyInput: Codable, Equatable, Sendable {
    public var zoneID: String
    public var streamID: String
    public var sequence: UInt64
    public var keyCode: UInt32
    public var action: BrokerKeyAction
    /// Explicit five-bit mask: shift/control/option/command/caps-lock, bits 0...4.
    public var modifiers: UInt32

    public init(zoneID: String, streamID: String, sequence: UInt64, keyCode: UInt32,
                action: BrokerKeyAction, modifiers: UInt32 = 0) {
        self.zoneID = zoneID; self.streamID = streamID; self.sequence = sequence
        self.keyCode = keyCode; self.action = action; self.modifiers = modifiers
    }
    static let shape = Shape.object([
        "zoneID": .scalar(maxBytes: 8), "streamID": .scalar(maxBytes: 32),
        "sequence": .integer(minimum: 1, maximum: UInt64.max),
        "keyCode": .integer(minimum: 0, maximum: 127), "action": .scalar(maxBytes: 8),
        "modifiers": .integer(minimum: 0, maximum: 31),
    ])
}

public struct BrokerPointerInput: Codable, Equatable, Sendable {
    public var zoneID: String
    public var streamID: String
    public var sequence: UInt64
    public var x: UInt32
    public var y: UInt32
    public var action: BrokerPointerAction
    /// Zero for move, one for primary button, two for secondary button.
    public var button: UInt32

    public init(zoneID: String, streamID: String, sequence: UInt64, x: UInt32, y: UInt32,
                action: BrokerPointerAction, button: UInt32 = 0) {
        self.zoneID = zoneID; self.streamID = streamID; self.sequence = sequence
        self.x = x; self.y = y; self.action = action; self.button = button
    }
    static let shape = Shape.object([
        "zoneID": .scalar(maxBytes: 8), "streamID": .scalar(maxBytes: 32),
        "sequence": .integer(minimum: 1, maximum: UInt64.max),
        "x": .integer(minimum: 0, maximum: 8191), "y": .integer(minimum: 0, maximum: 8191),
        "action": .scalar(maxBytes: 8), "button": .integer(minimum: 0, maximum: 2),
    ])
}

public enum BrokerMessage: Equatable, Sendable {
    case frame(BrokerFrame)
    case keyInput(BrokerKeyInput)
    case pointerInput(BrokerPointerInput)

    public var kind: BrokerMessageKind {
        switch self { case .frame: .frame; case .keyInput: .keyInput; case .pointerInput: .pointerInput }
    }
    public var requiredPeerRole: BrokerPeerRole { if case .frame = self { .sessionAgent } else { .hostController } }
    public var requiredSurfaceAttachments: Int { if case .frame = self { 1 } else { 0 } }
    private var binding: (zoneID: String, streamID: String, sequence: UInt64) {
        switch self {
        case .frame(let r): (r.zoneID, r.streamID, r.sequence)
        case .keyInput(let r): (r.zoneID, r.streamID, r.sequence)
        case .pointerInput(let r): (r.zoneID, r.streamID, r.sequence)
        }
    }

    public static func decode(_ data: Data) throws -> BrokerMessage {
        try decodeBody(BrokerContract.decode(data))
    }
    static func decodeBody(_ envelope: BrokerEnvelope) throws -> BrokerMessage {
        let message: BrokerMessage
        switch BrokerMessageKind(rawValue: envelope.kind) {
        case .frame: message = .frame(try StrictJSON.decode(envelope.body, shape: BrokerFrame.shape, limit: BrokerContract.maxBodyBytes, as: BrokerFrame.self))
        case .keyInput: message = .keyInput(try StrictJSON.decode(envelope.body, shape: BrokerKeyInput.shape, limit: BrokerContract.maxBodyBytes, as: BrokerKeyInput.self))
        case .pointerInput: message = .pointerInput(try StrictJSON.decode(envelope.body, shape: BrokerPointerInput.shape, limit: BrokerContract.maxBodyBytes, as: BrokerPointerInput.self))
        case nil: throw ContractError("unknown-message-kind", "unsupported broker kind")
        }
        try message.validate()
        return message
    }

    public func validate() throws {
        guard Identifier.isValidZoneID(binding.zoneID), Identifier.isValidPlanID(binding.streamID) else {
            throw ContractError.invalidIdentifier("broker zone/stream")
        }
        guard binding.sequence > 0 else { throw ContractError.invalidRange("broker sequence") }
        switch self {
        case .frame(let r):
            guard (1...8192).contains(r.width), (1...8192).contains(r.height), r.surfaceAttachmentIndex == 0 else {
                throw ContractError.invalidRange("frame dimensions/attachment")
            }
        case .keyInput(let r):
            guard r.keyCode <= 127, r.modifiers <= 31 else { throw ContractError.invalidRange("key code/modifiers") }
        case .pointerInput(let r):
            guard r.x < 8192, r.y < 8192, r.button <= 2 else { throw ContractError.invalidRange("pointer coordinates/button") }
            guard r.action == .move ? r.button == 0 : r.button > 0 else { throw ContractError.invalidValue("pointer action/button") }
        }
    }

    public func validateDelivery(in context: BrokerDeliveryContext) throws {
        try validate()
        guard requiredPeerRole == context.peerRole, binding.zoneID == context.zoneID,
              binding.streamID == context.streamID,
              context.surfaceAttachmentCount == requiredSurfaceAttachments,
              (1...8192).contains(context.width), (1...8192).contains(context.height) else {
            throw ContractError.invalidValue("broker trusted binding/role/attachments")
        }
        guard binding.sequence > context.lastSequence else { throw ContractError("sequence-violation", "stale broker sequence") }
        switch self {
        case .frame(let r):
            guard r.width == context.width, r.height == context.height else { throw ContractError.invalidValue("frame dimensions differ from stream") }
        case .pointerInput(let r):
            guard r.x < context.width, r.y < context.height else { throw ContractError.invalidRange("pointer outside stream") }
        case .keyInput: break
        }
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body: Data
        switch self {
        case .frame(let r): body = try encoder.encode(r)
        case .keyInput(let r): body = try encoder.encode(r)
        case .pointerInput(let r): body = try encoder.encode(r)
        }
        return try BrokerEnvelope(kind: kind.rawValue, body: body).encoded()
    }
}
