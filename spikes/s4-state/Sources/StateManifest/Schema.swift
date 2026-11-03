import Foundation

struct ManifestError: Error, CustomStringConvertible {
    var description: String
    init(_ message: String) { description = message }
}

private indirect enum Shape: Sendable {
    case scalar
    case object([String: Shape])
    case array(Shape)

    func rejectUnknownFields(in value: Any, depth: Int = 0) throws {
        guard depth <= 16 else { throw ManifestError("schema nesting limit exceeded") }
        switch self {
        case .scalar:
            if let string = value as? String, string.utf8.count > 4096 { throw ManifestError("schema string limit exceeded") }
            if value is [String: Any] || value is [Any] { throw ManifestError("expected scalar schema field") }
        case .object(let fields):
            guard let object = value as? [String: Any] else { throw ManifestError("expected JSON object") }
            guard Set(object.keys).isSubset(of: Set(fields.keys)) else { throw ManifestError("unknown schema field; measured/verified fields are not supported") }
            for (key, child) in object { try fields[key]!.rejectUnknownFields(in: child, depth: depth + 1) }
        case .array(let element):
            guard let array = value as? [Any], array.count <= 128 else { throw ManifestError("expected bounded JSON array") }
            for child in array { try element.rejectUnknownFields(in: child, depth: depth + 1) }
        }
    }
}

private func fields(_ names: [String]) -> [String: Shape] { Dictionary(uniqueKeysWithValues: names.map { ($0, .scalar) }) }

private let manifestShape = Shape.object([
    "schema": .scalar, "intent": .scalar, "phase": .scalar,
    "zone": .object(fields(["id", "uid", "gid"])),
    "containers": .array(.object(fields(["id", "declaredUUID", "planningBudgetBytes"]))),
    "volumes": .array(.object(fields(["id", "containerID", "declaredUUID", "mountPoint", "filesystem", "caseSensitive", "ownership"]).merging([
        "quota": .object(fields(["mode", "limitBytes", "reserveBytes"]))
    ], uniquingKeysWith: { first, _ in first }))),
    "roots": .array(.object(fields(["id", "role", "volumeID", "relativePath", "ownerUID", "rollback", "purpose"]))),
    "runtimePolicy": .scalar,
    "rollback": .object(fields(["unitID", "strategy", "quiescence", "recoveryRequired", "startPolicy"]).merging([
        "volumeIDs": .array(.scalar)
    ], uniquingKeysWith: { first, _ in first })),
    "hostControl": .object(fields(["directoryPath", "ownerUID", "directoryMode", "policyFile", "recoveryFile", "rollback"])),
    "readOnlyInputs": .array(.object(fields(["id", "path", "purpose"]))),
    "outsideWrites": .scalar, "hostAccess": .scalar
])

private let expectationShape = Shape.object([
    "schema": .scalar, "auditSessionID": .scalar,
    "expectation": .object(fields(["effectiveUID", "realUID", "effectiveGID", "realGID", "userName",
        "launchdManagerName", "launchdManagerUID", "windowSessionUID", "onConsole"]).merging([
            "requiredGroups": .array(.scalar), "forbiddenGroups": .array(.scalar), "forbiddenAuditSessionIDs": .array(.scalar)
        ], uniquingKeysWith: { first, _ in first }))
])

func decodeManifest(_ data: Data) throws -> Manifest { try strictDecode(data, shape: manifestShape) }
func decodeExpectation(_ data: Data) throws -> ExpectedContext { try strictDecode(data, shape: expectationShape) }

private func strictDecode<T: Decodable>(_ data: Data, shape: Shape) throws -> T {
    do {
        var preflight = try JSONPreflight(data)
        try preflight.check()
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        try shape.rejectUnknownFields(in: json)
        return try JSONDecoder().decode(T.self, from: data)
    } catch let error as ManifestError { throw error }
    catch { throw ManifestError("invalid JSON/schema types or missing required field") }
}
