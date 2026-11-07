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
        return try encoder.encode(document)
    }

    /// Offline structural validation. It is a deliberate subset of the B3 validator in
    /// `spikes/s4-state`: it never inspects the host, mounts nothing and proves no deployment.
    /// The first violation is thrown, with a stable code from `ContractError`.
    public static func validate(_ document: StateManifestDocument) throws {
        guard document.schema == name else {
            throw ContractError("invalid-value", "schema \(document.schema) != \(name)")
        }
        guard document.intent == "design-only" else {
            throw ContractError("invalid-value", "intent must be design-only")
        }
        guard ["mvp", "f4-design"].contains(document.phase) else {
            throw ContractError("invalid-value", "phase")
        }
        guard Identifier.isValidZoneID(document.zone.id) else {
            throw ContractError.invalidIdentifier("zone.id")
        }
        guard document.zone.uid != 0, document.zone.gid != 0 else {
            throw ContractError.invalidRange("zone.uid/gid must be nonzero")
        }
        guard document.hostAccess == "controlled-export-only" else {
            throw ContractError("invalid-value", "hostAccess")
        }
        guard document.outsideWrites == "forbidden-unverified" else {
            throw ContractError("invalid-value", "outsideWrites")
        }

        guard (1...8).contains(document.containers.count), (1...16).contains(document.volumes.count),
              (1...64).contains(document.roots.count), document.readOnlyInputs.count <= 32,
              document.rollback.volumeIDs.count <= 16 else {
            throw ContractError("collection-limit", "containers/volumes/roots/readOnlyInputs/rollback")
        }
        for (label, ids) in [("containers", document.containers.map(\.id)),
                             ("volumes", document.volumes.map(\.id)),
                             ("roots", document.roots.map(\.id)),
                             ("readOnlyInputs", document.readOnlyInputs.map(\.id))] {
            for id in ids where !Identifier.isValidPlanID(id) {
                throw ContractError.invalidIdentifier("\(label).\(id)")
            }
            guard Set(ids).count == ids.count else {
                throw ContractError("invalid-value", "\(label) duplicate id")
            }
        }

        var seenUUIDs = Set<String>()
        for (label, value) in document.containers.map({ ("container:\($0.id)", $0.declaredUUID) })
            + document.volumes.map({ ("volume:\($0.id)", $0.declaredUUID) }) {
            guard let value else { continue }
            guard value.utf8.count == 36, let uuid = UUID(uuidString: value),
                  uuid.uuidString != "00000000-0000-0000-0000-000000000000" else {
                throw ContractError("invalid-value", "\(label).declaredUUID")
            }
            guard seenUUIDs.insert(uuid.uuidString).inserted else {
                throw ContractError("invalid-value", "\(label).declaredUUID aliases another declared UUID")
            }
        }

        let containerIDs = Set(document.containers.map(\.id))
        let volumeIDs = Set(document.volumes.map(\.id))
        for container in document.containers {
            if container.planningBudgetBytes == 0 {
                throw ContractError.invalidRange("container:\(container.id).planningBudgetBytes")
            }
        }
        for volume in document.volumes {
            guard containerIDs.contains(volume.containerID) else {
                throw ContractError("invalid-value", "volume:\(volume.id) references an undeclared container")
            }
            guard Self.isNormalizedPath(volume.mountPoint, absolute: true),
                  !Self.forbiddenMountPoints.contains(volume.mountPoint.lowercased()) else {
                throw ContractError("invalid-value", "volume:\(volume.id).mountPoint")
            }
            guard volume.filesystem == "apfs", volume.ownership == "required" else {
                throw ContractError("invalid-value", "volume:\(volume.id) filesystem/ownership")
            }
            switch volume.quota.mode {
            case "limited":
                guard let limit = volume.quota.limitBytes, limit > 0 else {
                    throw ContractError.invalidRange("volume:\(volume.id).quota.limitBytes")
                }
                guard volume.quota.reserveBytes <= limit else {
                    throw ContractError("invalid-value", "volume:\(volume.id) reserve exceeds limit")
                }
            case "unbounded", "unresolved":
                guard volume.quota.limitBytes == nil else {
                    throw ContractError("invalid-value", "volume:\(volume.id).quota.limitBytes must be omitted")
                }
            default:
                throw ContractError("invalid-value", "volume:\(volume.id).quota.mode")
            }
        }

        let roleCounts = Dictionary(document.roots.map { ($0.role, 1) }, uniquingKeysWith: +)
        guard requiredRootRoles.allSatisfy({ roleCounts[$0] == 1 }) else {
            throw ContractError("invalid-value", "roots must declare exactly one home/project/prefix/cache/tmp")
        }
        let runtimeCount = roleCounts["runtime", default: 0]
        if document.phase == "mvp" {
            guard document.runtimePolicy == "deferred-f4", runtimeCount == 0 else {
                throw ContractError("invalid-value", "mvp must defer runtime (C-002)")
            }
        } else {
            guard document.runtimePolicy == "declared-unverified", runtimeCount == 1 else {
                throw ContractError("invalid-value", "f4-design requires one runtime root")
            }
        }
        for root in document.roots {
            guard Self.requiredRootRoles.contains(root.role) || ["runtime", "additional"].contains(root.role) else {
                throw ContractError("invalid-value", "root:\(root.id).role")
            }
            guard root.ownerUID == document.zone.uid else {
                throw ContractError("invalid-value", "root:\(root.id).ownerUID")
            }
            guard root.rollback == "whole-volume" else {
                throw ContractError("invalid-value", "root:\(root.id).rollback")
            }
            guard !root.purpose.isEmpty, root.purpose.utf8.count <= 256 else {
                throw ContractError("invalid-value", "root:\(root.id).purpose")
            }
            guard volumeIDs.contains(root.volumeID) else {
                throw ContractError("invalid-value", "root:\(root.id) references an undeclared volume")
            }
            guard Self.isNormalizedPath(root.relativePath, absolute: false) else {
                throw ContractError("invalid-value", "root:\(root.id).relativePath")
            }
            if root.role == "prefix" {
                let volume = document.volumes.first { $0.id == root.volumeID }
                let joined = volume.map { $0.mountPoint + (root.relativePath == "." ? "" : "/" + root.relativePath) }
                guard joined == "/opt/snj/" + document.zone.id else {
                    throw ContractError("invalid-value", "root:\(root.id) prefix layout")
                }
            }
        }

        let restore = document.rollback
        guard Identifier.isValidPlanID(restore.unitID), Set(restore.volumeIDs).count == restore.volumeIDs.count,
              Set(restore.volumeIDs) == volumeIDs else {
            throw ContractError("invalid-value", "rollback must include every declared volume exactly once")
        }
        guard restore.strategy == "rebuild-writable-state-then-switch",
              restore.quiescence == "whole-uid-required", restore.recoveryRequired,
              restore.startPolicy == "deny-until-verified" else {
            throw ContractError("invalid-value", "rollback contract")
        }

        let control = document.hostControl
        guard Self.isNormalizedPath(control.directoryPath, absolute: true), control.ownerUID == 0,
              control.directoryMode == "0700", control.rollback == "excluded" else {
            throw ContractError("invalid-value", "hostControl")
        }
        for name in [control.policyFile, control.recoveryFile] where !Identifier.isValidFileName(name) {
            throw ContractError("invalid-value", "hostControl file name")
        }
        guard control.policyFile.lowercased() != control.recoveryFile.lowercased() else {
            throw ContractError("invalid-value", "hostControl file names alias")
        }
        for volume in document.volumes where Self.overlaps(control.directoryPath, volume.mountPoint) {
            throw ContractError("invalid-value", "hostControl inside volume \(volume.id)")
        }
        for input in document.readOnlyInputs {
            guard Self.isNormalizedPath(input.path, absolute: true), !input.purpose.isEmpty,
                  input.purpose.utf8.count <= 256 else {
                throw ContractError("invalid-value", "readOnlyInput:\(input.id)")
            }
            for volume in document.volumes where Self.overlaps(input.path, volume.mountPoint) {
                throw ContractError("invalid-value", "readOnlyInput:\(input.id) overlaps volume \(volume.id)")
            }
            guard !Self.overlaps(input.path, control.directoryPath) else {
                throw ContractError("invalid-value", "readOnlyInput:\(input.id) overlaps hostControl")
            }
        }
        for i in document.readOnlyInputs.indices {
            for j in document.readOnlyInputs.indices where j > i {
                if Self.overlaps(document.readOnlyInputs[i].path, document.readOnlyInputs[j].path) {
                    throw ContractError("invalid-value", "readOnlyInputs overlap or alias")
                }
            }
        }

        for container in document.containers {
            var reserves: UInt64 = 0
            for volume in document.volumes where volume.containerID == container.id {
                let sum = reserves.addingReportingOverflow(volume.quota.reserveBytes)
                guard !sum.overflow else { throw ContractError.invalidRange("reserves of \(container.id)") }
                reserves = sum.partialValue
            }
            if let budget = container.planningBudgetBytes, reserves > budget {
                throw ContractError("invalid-value", "reserves of \(container.id) exceed planningBudgetBytes")
            }
        }
    }

    static let forbiddenMountPoints: Set<String> = [
        "/", "/users", "/volumes", "/opt", "/opt/snj", "/applications", "/library", "/system", "/private", "/usr",
    ]

    /// Lexical path check only: no filesystem call, no symlink or alias resolution.
    static func isNormalizedPath(_ value: String, absolute: Bool) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 1024, !value.contains("\\") else { return false }
        guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return false }
        guard value.hasPrefix("/") == absolute else { return false }
        if value == "." { return true }
        guard value != "/", !value.hasSuffix("/") else { return false }
        var body = value
        if absolute { body.removeFirst() }
        let components = body.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func overlaps(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.split(separator: "/").map(String.init)
        let b = rhs.split(separator: "/").map(String.init)
        let shortest = min(a.count, b.count)
        return Array(a.prefix(shortest)) == Array(b.prefix(shortest))
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
        "planningBudgetBytes": .optionalInteger(minimum: 1, maximum: 9_007_199_254_740_991),
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
        "limitBytes": .optionalInteger(minimum: 1, maximum: 9_007_199_254_740_991),
        "reserveBytes": .integer(minimum: 0, maximum: 9_007_199_254_740_991),
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
