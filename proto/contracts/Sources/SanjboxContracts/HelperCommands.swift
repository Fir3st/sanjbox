import Foundation

/// Names are manifest root IDs, never host paths. The future helper must resolve them relative
/// to its authenticated zone binding and descriptor-verified root, after lifecycle admission.
public struct ShellRequest: Codable, Equatable, Sendable {
    public var zoneID: String
    public var workingRootID: String
    public var workingDirectory: String
    public init(zoneID: String, workingRootID: String, workingDirectory: String = ".") {
        self.zoneID = zoneID; self.workingRootID = workingRootID; self.workingDirectory = workingDirectory
    }
    static let shape = Shape.object([
        "zoneID": .scalar(maxBytes: 8), "workingRootID": .scalar(maxBytes: 32),
        "workingDirectory": .scalar(maxBytes: 1024),
    ])
    public func validate() throws {
        try ZoneRef(zoneID: zoneID).validate()
        guard Identifier.isValidPlanID(workingRootID) else { throw ContractError.invalidIdentifier("workingRootID") }
        guard StateManifestSchema.isNormalizedPath(workingDirectory, absolute: false) else {
            throw ContractError.invalidValue("workingDirectory must be relative to declared zone root")
        }
    }
}

/// An argv vector, never a shell command string. No caller-selected UID, environment, host path,
/// bootstrap domain or privilege bit. Executable roots must be declared zone/public inputs.
public struct RunRequest: Codable, Equatable, Sendable {
    public var zoneID: String
    public var workingRootID: String
    public var workingDirectory: String
    public var executableRootID: String
    public var executablePath: String
    public var arguments: [String]
    public init(zoneID: String, workingRootID: String, workingDirectory: String = ".",
                executableRootID: String, executablePath: String, arguments: [String] = []) {
        self.zoneID = zoneID; self.workingRootID = workingRootID; self.workingDirectory = workingDirectory
        self.executableRootID = executableRootID; self.executablePath = executablePath; self.arguments = arguments
    }
    static let shape = Shape.object([
        "zoneID": .scalar(maxBytes: 8), "workingRootID": .scalar(maxBytes: 32),
        "workingDirectory": .scalar(maxBytes: 1024), "executableRootID": .scalar(maxBytes: 32),
        "executablePath": .scalar(maxBytes: 1024), "arguments": .array(.scalar(maxBytes: 1024), max: 64),
    ])
    public func validate() throws {
        try ShellRequest(zoneID: zoneID, workingRootID: workingRootID, workingDirectory: workingDirectory).validate()
        guard Identifier.isValidPlanID(executableRootID) else { throw ContractError.invalidIdentifier("executableRootID") }
        guard executablePath != ".", StateManifestSchema.isNormalizedPath(executablePath, absolute: false) else {
            throw ContractError.invalidValue("executablePath must name a relative file")
        }
        guard arguments.count <= 64 else { throw ContractError("collection-limit", "run arguments") }
        guard arguments.allSatisfy({ $0.utf8.count <= 1024 }) else { throw ContractError("string-limit", "run argument") }
        guard !arguments.contains(where: { $0.contains("\0") }) else { throw ContractError.invalidValue("NUL in argv") }
        guard arguments.reduce(0, { $0 + $1.utf8.count }) <= 32768 else { throw ContractError.inputTooLarge("argv exceeds 32 KiB") }
    }
}

/// Both commands address one full manifest restore unit. No per-directory snapshot/rollback.
public struct SnapshotRequest: Codable, Equatable, Sendable {
    public var zoneID: String
    public var snapshotID: String
    public var rollbackUnitID: String
    public init(zoneID: String, snapshotID: String, rollbackUnitID: String) {
        self.zoneID = zoneID; self.snapshotID = snapshotID; self.rollbackUnitID = rollbackUnitID
    }
    static let shape = Shape.object([
        "zoneID": .scalar(maxBytes: 8), "snapshotID": .scalar(maxBytes: 32), "rollbackUnitID": .scalar(maxBytes: 32),
    ])
    public func validate() throws {
        try ZoneRef(zoneID: zoneID).validate()
        guard Identifier.isValidPlanID(snapshotID), Identifier.isValidPlanID(rollbackUnitID) else {
            throw ContractError.invalidIdentifier("snapshot/restore unit")
        }
    }
}

public enum HelperReplyOutcome: String, Codable, Sendable { case accepted, completed, failed }
public enum HelperFailureCode: String, Codable, Sendable {
    case invalidRequest = "invalid-request"
    case unauthorized
    case invalidState = "invalid-state"
    case unavailable
    case operationFailed = "operation-failed"
}

/// One reply on the request's XPC reply channel, correlated by kind and zone. `accepted` for
/// shell/run means only a zone execution was admitted; executionID is an opaque zone handle,
/// never a PID/host command or proof of process completion. Stdio transport is an H3 adapter.
public struct HelperReply: Codable, Equatable, Sendable {
    public var requestKind: HelperMessageKind
    public var zoneID: String?
    public var outcome: HelperReplyOutcome
    public var executionID: String?
    public var state: ZoneState?
    public var errorCode: HelperFailureCode?
    public init(requestKind: HelperMessageKind, zoneID: String?, outcome: HelperReplyOutcome,
                executionID: String? = nil, state: ZoneState? = nil, errorCode: HelperFailureCode? = nil) {
        self.requestKind = requestKind; self.zoneID = zoneID; self.outcome = outcome
        self.executionID = executionID; self.state = state; self.errorCode = errorCode
    }
    static let shape = Shape.object([
        "requestKind": .scalar(maxBytes: 64), "zoneID": .optionalScalar(maxBytes: 8),
        "outcome": .scalar(maxBytes: 16), "executionID": .optionalScalar(maxBytes: 32),
        "state": .optionalScalar(maxBytes: 16), "errorCode": .optionalScalar(maxBytes: 32),
    ])
    public func validate() throws {
        guard requestKind == .capabilities ? zoneID == nil : zoneID.map(Identifier.isValidZoneID) == true else {
            throw ContractError.invalidIdentifier("reply zone binding")
        }
        if outcome == .failed {
            guard errorCode != nil, executionID == nil, state == nil else { throw ContractError.invalidValue("failure reply fields") }
        } else {
            guard errorCode == nil else { throw ContractError.invalidValue("success with error") }
            if requestKind == .shell || requestKind == .run {
                guard outcome == .accepted, executionID.map(Identifier.isValidPlanID) == true, state == nil else {
                    throw ContractError.invalidValue("launch reply requires execution handle")
                }
            } else {
                guard outcome == .completed, executionID == nil,
                      requestKind == .zoneStatus ? state != nil : state == nil else {
                    throw ContractError.invalidValue("completed reply fields")
                }
            }
        }
    }
    public func validate(for request: HelperMessage) throws {
        try request.validate(); try validate()
        guard request.kind == requestKind, request.zoneID == zoneID else { throw ContractError.invalidValue("reply does not match request") }
    }
    public static func decode(_ data: Data) throws -> HelperReply {
        let envelope = try XPCEnvelope.decode(data)
        guard envelope.kind == "helper.reply" else { throw ContractError("unknown-message-kind", "expected helper.reply") }
        let reply = try StrictJSON.decode(envelope.body, shape: shape, limit: XPCEnvelope.maxBodyBytes, as: HelperReply.self)
        try reply.validate(); return reply
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try XPCEnvelope(kind: "helper.reply", body: encoder.encode(self)).encoded()
    }
}
