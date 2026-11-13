import Foundation

/// Duplicated `sanjbox.state-manifest.v1` schema (source of truth is
/// `spikes/s4-state/SCHEMA.md`; the spike's `StateManifest` types are `internal`, so this package
/// re-declares the document instead of importing it). Drift risk is documented in README:
/// consolidation belongs in a separate package with review.
public enum StateManifestSchema {
    public static let name = "sanjbox.state-manifest.v1"
    public static let maxBytes = 256 * 1024
    public static let requiredRootRoles: Set<String> = ["home", "project", "prefix", "cache", "tmp"]

    static let shape = Shape.object([
        "schema": .scalar(maxBytes: 64),
        "intent": .scalar(maxBytes: 32),
        "phase": .scalar(maxBytes: 16),
        "zone": ManifestZone.shape,
        "containers": .array(ManifestContainer.shape, max: 8),
        "volumes": .array(ManifestVolume.shape, max: 16),
        "roots": .array(ManifestRoot.shape, max: 64),
        "runtimePolicy": .scalar(maxBytes: 32),
        "rollback": ManifestRollback.shape,
        "hostControl": ManifestHostControl.shape,
        "readOnlyInputs": .array(ManifestReadOnlyInput.shape, max: 32),
        "outsideWrites": .scalar(maxBytes: 32),
        "hostAccess": .scalar(maxBytes: 32),
    ])

    public static func decode(_ data: Data) throws -> StateManifestDocument {
        let document = try StrictJSON.decode(data, shape: shape, limit: maxBytes, as: StateManifestDocument.self)
        try validate(document)
        return document
    }

    public static func encode(_ document: StateManifestDocument) throws -> Data {
        try validate(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= maxBytes else { throw ContractError.inputTooLarge("manifest encoded bytes") }
        // Enforce wire string/collection limits as well as semantic rules for typed callers.
        _ = try StrictJSON.decode(data, shape: shape, limit: maxBytes, as: StateManifestDocument.self)
        return data
    }

    /// Full B3 offline report, including warnings and planned topology. No host paths are read.
    public static func report(_ document: StateManifestDocument) -> ManifestValidationReport {
        B3ManifestValidator().validate(document)
    }

    /// Compatibility API: warnings do not reject a consistent design. Detailed B3 finding codes
    /// and severity are available in `report`; the existing ContractError vocabulary is preserved.
    public static func validate(_ document: StateManifestDocument) throws {
        // Preserve the pre-existing identity diagnostic before derived prefix/root findings.
        guard Identifier.isValidZoneID(document.zone.id) else { throw ContractError.invalidIdentifier("zone.id") }
        guard document.zone.uid != 0, document.zone.gid != 0 else { throw ContractError.invalidRange("zone.uid/gid") }
        guard let finding = report(document).findings.first(where: { $0.severity == "error" }) else { return }
        let code: String
        switch finding.code {
        case "collection-limit": code = "collection-limit"
        case "zone-id", "identifier": code = "invalid-identifier"
        case "zone-identity", "zero-container-budget", "quota-limit", "budget-overflow": code = "invalid-range"
        default: code = "invalid-value"
        }
        throw ContractError(code, "\(finding.code) at \(finding.location): \(finding.explanation)")
    }

    static let forbiddenMountPoints: Set<String> = [
        "/", "/users", "/volumes", "/opt", "/opt/snj", "/applications", "/library", "/system", "/private", "/usr",
    ]

    /// Lexical path check only: no filesystem call, no symlink or alias resolution. Absolute paths
    /// that name a common host alias (`/tmp`, `/var`, `/etc`, `/System/Volumes/Data`) are refused so
    /// a design cannot claim separation from a path the host folds onto the same location.
    static func isNormalizedPath(_ value: String, absolute: Bool) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 1024, !value.contains("\\") else { return false }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        guard value.hasPrefix("/") == absolute else { return false }
        if value == "." { return true }
        guard value != "/", !value.hasSuffix("/") else { return false }
        var body = value
        if absolute { body.removeFirst() }
        let components = body.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        if absolute {
            let folded = foldedPath(value)
            for alias in ["/tmp", "/var", "/etc", "/System/Volumes/Data"] {
                let foldedAlias = foldedPath(alias)
                if folded == foldedAlias || folded.hasPrefix(foldedAlias + "/") { return false }
            }
        }
        return true
    }

    /// Case- and Unicode-normalization-folded path, matching spikes/s4-state `foldedPath`.
    static func foldedPath(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func overlaps(_ lhs: String, _ rhs: String) -> Bool {
        let a = foldedPath(lhs), b = foldedPath(rhs)
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }
}

public struct StateManifestDocument: Codable, Equatable, Sendable {
    public var schema: String
    public var intent: String
    public var phase: String
    public var zone: ManifestZone
    public var containers: [ManifestContainer]
    public var volumes: [ManifestVolume]
    public var roots: [ManifestRoot]
    public var runtimePolicy: String
    public var rollback: ManifestRollback
    public var hostControl: ManifestHostControl
    public var readOnlyInputs: [ManifestReadOnlyInput]
    public var outsideWrites: String
    public var hostAccess: String

    public init(schema: String = StateManifestSchema.name, intent: String, phase: String, zone: ManifestZone,
                containers: [ManifestContainer], volumes: [ManifestVolume], roots: [ManifestRoot],
                runtimePolicy: String, rollback: ManifestRollback, hostControl: ManifestHostControl,
                readOnlyInputs: [ManifestReadOnlyInput], outsideWrites: String, hostAccess: String) {
        self.schema = schema
        self.intent = intent
        self.phase = phase
        self.zone = zone
        self.containers = containers
        self.volumes = volumes
        self.roots = roots
        self.runtimePolicy = runtimePolicy
        self.rollback = rollback
        self.hostControl = hostControl
        self.readOnlyInputs = readOnlyInputs
        self.outsideWrites = outsideWrites
        self.hostAccess = hostAccess
    }
}

public struct ManifestZone: Codable, Equatable, Sendable {
    public var id: String
    public var uid: UInt32
    public var gid: UInt32

    public init(id: String, uid: UInt32, gid: UInt32) {
        self.id = id
        self.uid = uid
        self.gid = gid
    }

    static let shape = Shape.object([
        "id": .scalar(maxBytes: 8),
        "uid": .integer(minimum: 1, maximum: UInt64(UInt32.max)),
        "gid": .integer(minimum: 1, maximum: UInt64(UInt32.max)),
    ])
}

public struct ManifestContainer: Codable, Equatable, Sendable {
    public var id: String
    public var declaredUUID: String?
    public var planningBudgetBytes: UInt64?

    public init(id: String, declaredUUID: String? = nil, planningBudgetBytes: UInt64? = nil) {
        self.id = id
        self.declaredUUID = declaredUUID
        self.planningBudgetBytes = planningBudgetBytes
    }

    static let shape = Shape.object([
        "id": .scalar(maxBytes: 32),
        "declaredUUID": .optionalScalar(maxBytes: 36),
        "planningBudgetBytes": .optionalInteger(minimum: 1, maximum: UInt64.max),
    ])
}

public struct ManifestQuota: Codable, Equatable, Sendable {
    public var mode: String
    public var limitBytes: UInt64?
    public var reserveBytes: UInt64

    public init(mode: String, limitBytes: UInt64? = nil, reserveBytes: UInt64) {
        self.mode = mode
        self.limitBytes = limitBytes
        self.reserveBytes = reserveBytes
    }

    static let shape = Shape.object([
        "mode": .scalar(maxBytes: 16),
        "limitBytes": .optionalInteger(minimum: 1, maximum: UInt64.max),
        "reserveBytes": .integer(minimum: 0, maximum: UInt64.max),
    ])
}

public struct ManifestVolume: Codable, Equatable, Sendable {
    public var id: String
    public var containerID: String
    public var declaredUUID: String?
    public var mountPoint: String
    public var filesystem: String
    public var caseSensitive: Bool
    public var ownership: String
    public var quota: ManifestQuota

    public init(id: String, containerID: String, declaredUUID: String? = nil, mountPoint: String,
                filesystem: String = "apfs", caseSensitive: Bool = false, ownership: String = "required",
                quota: ManifestQuota) {
        self.id = id
        self.containerID = containerID
        self.declaredUUID = declaredUUID
        self.mountPoint = mountPoint
        self.filesystem = filesystem
        self.caseSensitive = caseSensitive
        self.ownership = ownership
        self.quota = quota
    }

    static let shape = Shape.object([
        "id": .scalar(maxBytes: 32),
        "containerID": .scalar(maxBytes: 32),
        "declaredUUID": .optionalScalar(maxBytes: 36),
        "mountPoint": .scalar(maxBytes: 1024),
        "filesystem": .scalar(maxBytes: 16),
        "caseSensitive": .scalar(maxBytes: 8),
        "ownership": .scalar(maxBytes: 16),
        "quota": ManifestQuota.shape,
    ])
}

public struct ManifestRoot: Codable, Equatable, Sendable {
    public var id: String
    public var role: String
    public var volumeID: String
    public var relativePath: String
    public var ownerUID: UInt32
    public var rollback: String
    public var purpose: String

    public init(id: String, role: String, volumeID: String, relativePath: String, ownerUID: UInt32,
                rollback: String = "whole-volume", purpose: String) {
        self.id = id
        self.role = role
        self.volumeID = volumeID
        self.relativePath = relativePath
        self.ownerUID = ownerUID
        self.rollback = rollback
        self.purpose = purpose
    }

    static let shape = Shape.object([
        "id": .scalar(maxBytes: 32),
        "role": .scalar(maxBytes: 16),
        "volumeID": .scalar(maxBytes: 32),
        "relativePath": .scalar(maxBytes: 1024),
        "ownerUID": .integer(minimum: 1, maximum: UInt64(UInt32.max)),
        "rollback": .scalar(maxBytes: 32),
        "purpose": .scalar(maxBytes: 256),
    ])
}

public struct ManifestRollback: Codable, Equatable, Sendable {
    public var unitID: String
    public var volumeIDs: [String]
    public var strategy: String
    public var quiescence: String
    public var recoveryRequired: Bool
    public var startPolicy: String

    public init(unitID: String, volumeIDs: [String], strategy: String = "rebuild-writable-state-then-switch",
                quiescence: String = "whole-uid-required", recoveryRequired: Bool = true,
                startPolicy: String = "deny-until-verified") {
        self.unitID = unitID
        self.volumeIDs = volumeIDs
        self.strategy = strategy
        self.quiescence = quiescence
        self.recoveryRequired = recoveryRequired
        self.startPolicy = startPolicy
    }

    static let shape = Shape.object([
        "unitID": .scalar(maxBytes: 32),
        "volumeIDs": .array(.scalar(maxBytes: 32), max: 16),
        "strategy": .scalar(maxBytes: 64),
        "quiescence": .scalar(maxBytes: 32),
        "recoveryRequired": .scalar(maxBytes: 8),
        "startPolicy": .scalar(maxBytes: 32),
    ])
}

public struct ManifestHostControl: Codable, Equatable, Sendable {
    public var directoryPath: String
    public var ownerUID: UInt32
    public var directoryMode: String
    public var policyFile: String
    public var recoveryFile: String
    public var rollback: String

    public init(directoryPath: String, ownerUID: UInt32 = 0, directoryMode: String = "0700",
                policyFile: String, recoveryFile: String, rollback: String = "excluded") {
        self.directoryPath = directoryPath
        self.ownerUID = ownerUID
        self.directoryMode = directoryMode
        self.policyFile = policyFile
        self.recoveryFile = recoveryFile
        self.rollback = rollback
    }

    static let shape = Shape.object([
        "directoryPath": .scalar(maxBytes: 1024),
        "ownerUID": .integer(minimum: 0, maximum: UInt64(UInt32.max)),
        "directoryMode": .scalar(maxBytes: 8),
        "policyFile": .scalar(maxBytes: 128),
        "recoveryFile": .scalar(maxBytes: 128),
        "rollback": .scalar(maxBytes: 16),
    ])
}

public struct ManifestReadOnlyInput: Codable, Equatable, Sendable {
    public var id: String
    public var path: String
    public var purpose: String

    public init(id: String, path: String, purpose: String) {
        self.id = id
        self.path = path
        self.purpose = purpose
    }

    static let shape = Shape.object([
        "id": .scalar(maxBytes: 32),
        "path": .scalar(maxBytes: 1024),
        "purpose": .scalar(maxBytes: 256),
    ])
}
