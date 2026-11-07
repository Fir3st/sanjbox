import Foundation

/// Typ operace, kterou brána umí složit. Množina je uzavřená: neznámý název
/// operace v politice je chyba validace, nikdy tichý průchod.
public enum GatewayOperation: String, CaseIterable, Codable, Sendable, Comparable {
    case npm, pypi, git, model

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct AnyCodingKey: CodingKey, Sendable, Hashable {
    public let stringValue: String
    public let intValue: Int?

    public init(_ string: String) { self.stringValue = string; intValue = nil }
    public init(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    public init(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}

/// Deterministické chyby validace politiky. Texty jsou součástí prototypového
/// kontraktu (testy je porovnávají), nikdy neobsahují vstupní data mimo cestu pole.
public enum PolicyError: Error, Equatable, Sendable, CustomStringConvertible {
    case malformed
    case unsupportedVersion(Int)
    case unknownOperation(String)
    case unknownField(String)
    case missingField(String)
    case invalidField(String)
    case duplicateOperation(GatewayOperation)
    case duplicateMount(String)
    case emptyGateways

    public var description: String {
        switch self {
        case .malformed: return "policy is not a well-formed document"
        case .unsupportedVersion(let version): return "policy.schemaVersion \(version) is not supported"
        case .unknownOperation(let name): return "unknown operation \"\(name)\""
        case .unknownField(let path): return "unknown field \"\(path)\""
        case .missingField(let path): return "missing field \"\(path)\""
        case .invalidField(let path): return "invalid field \"\(path)\""
        case .duplicateOperation(let operation): return "duplicate operation \"\(operation.rawValue)\""
        case .duplicateMount(let mount): return "duplicate mount \"\(mount)\""
        case .emptyGateways: return "policy declares no gateway"
        }
    }
}

// MARK: - Společné limity registrů (npm, PyPI, git)

/// Zrcadlí `RegistryLimits` ze `spikes/s5-gateway` (WP1.D5) v explicitní,
/// verzované podobě. Hodnoty mimo rozsah handleru se odmítnou už v politice,
/// takže chybějící/hraniční číslo nikdy neskončí jako "nějaký" handler.
public struct RegistryRuleLimits: Sendable, Equatable {
    public static let allowedKeys: Set<String> = [
        "metadataBytes", "artifactBytes", "files", "operations", "auditRecords", "lifetimeSeconds",
    ]

    public let metadataBytes: Int
    public let artifactBytes: Int
    public let files: Int
    public let operations: Int
    public let auditRecords: Int
    public let lifetimeSeconds: Int

    /// Výchozí limity shodné s `RegistryLimits` (D5). Statická konstanta drží
    /// validní literály, takže výchozí argumenty nepotřebují `try!`.
    public static let standard = RegistryRuleLimits(
        uncheckedMetadataBytes: 4_194_304, artifactBytes: 4_194_304, files: 10_000,
        operations: 4, auditRecords: 1_024, lifetimeSeconds: 90)

    public init(metadataBytes: Int = 4_194_304, artifactBytes: Int = 4_194_304, files: Int = 10_000,
                operations: Int = 4, auditRecords: Int = 1_024, lifetimeSeconds: Int = 90) throws {
        try Self.validate(metadataBytes: metadataBytes, artifactBytes: artifactBytes, files: files,
                          operations: operations, auditRecords: auditRecords,
                          lifetimeSeconds: lifetimeSeconds, path: "limits")
        self.init(uncheckedMetadataBytes: metadataBytes, artifactBytes: artifactBytes, files: files,
                  operations: operations, auditRecords: auditRecords, lifetimeSeconds: lifetimeSeconds)
    }

    /// Bez validace: jediný volající je `standard` s ručně ověřenými literály.
    private init(uncheckedMetadataBytes metadataBytes: Int, artifactBytes: Int, files: Int,
                 operations: Int, auditRecords: Int, lifetimeSeconds: Int) {
        self.metadataBytes = metadataBytes
        self.artifactBytes = artifactBytes
        self.files = files
        self.operations = operations
        self.auditRecords = auditRecords
        self.lifetimeSeconds = lifetimeSeconds
    }

    init(from container: KeyedDecodingContainer<AnyCodingKey>, path: String) throws {
        try PolicyStrictness.rejectUnknown(container, allowed: Self.allowedKeys, path: path)
        let metadataBytes = try container.decode(Int.self, forKey: AnyCodingKey("metadataBytes"))
        let artifactBytes = try container.decode(Int.self, forKey: AnyCodingKey("artifactBytes"))
        let files = try container.decode(Int.self, forKey: AnyCodingKey("files"))
        let operations = try container.decode(Int.self, forKey: AnyCodingKey("operations"))
        let auditRecords = try container.decode(Int.self, forKey: AnyCodingKey("auditRecords"))
        let lifetimeSeconds = try container.decode(Int.self, forKey: AnyCodingKey("lifetimeSeconds"))
        try Self.validate(metadataBytes: metadataBytes, artifactBytes: artifactBytes, files: files,
                          operations: operations, auditRecords: auditRecords,
                          lifetimeSeconds: lifetimeSeconds, path: path)
        self.metadataBytes = metadataBytes
        self.artifactBytes = artifactBytes
        self.files = files
        self.operations = operations
        self.auditRecords = auditRecords
        self.lifetimeSeconds = lifetimeSeconds
    }

    static func validate(metadataBytes: Int, artifactBytes: Int, files: Int, operations: Int,
                         auditRecords: Int, lifetimeSeconds: Int, path: String) throws {
        func fail(_ name: String) throws -> Never { throw PolicyError.invalidField("\(path).\(name)") }
        guard (1...4_194_304).contains(metadataBytes) else { try fail("metadataBytes") }
        guard (1...4_194_304).contains(artifactBytes) else { try fail("artifactBytes") }
        guard (1...10_000).contains(files) else { try fail("files") }
        guard (1...16).contains(operations) else { try fail("operations") }
        guard (1...10_000).contains(auditRecords) else { try fail("auditRecords") }
        guard (1...120).contains(lifetimeSeconds) else { try fail("lifetimeSeconds") }
    }

    func encodeFields(into container: inout KeyedEncodingContainer<AnyCodingKey>) throws {
        try container.encode(metadataBytes, forKey: AnyCodingKey("metadataBytes"))
        try container.encode(artifactBytes, forKey: AnyCodingKey("artifactBytes"))
        try container.encode(files, forKey: AnyCodingKey("files"))
        try container.encode(operations, forKey: AnyCodingKey("operations"))
        try container.encode(auditRecords, forKey: AnyCodingKey("auditRecords"))
        try container.encode(lifetimeSeconds, forKey: AnyCodingKey("lifetimeSeconds"))
    }
}

// MARK: - Pravidla jednotlivých operací

public struct NPMRule: Sendable, Equatable {
    public static let allowedKeys: Set<String> = [
        "operation", "enabled", "mount", "publicOrigin", "upstreamHostname", "artifactHostnames",
        "cooldownSeconds", "limits",
    ]

    public let enabled: Bool
    public let mount: String
    public let publicOrigin: String
    public let upstreamHostname: String
    public let artifactHostnames: [String]
    public let cooldownSeconds: Double
    public let limits: RegistryRuleLimits

    public init(enabled: Bool = true, mount: String = "/npm", publicOrigin: String,
                upstreamHostname: String = "registry.npmjs.org", artifactHostnames: [String] = [],
                cooldownSeconds: Double = 3_600, limits: RegistryRuleLimits = .standard) {
        self.enabled = enabled
        self.mount = mount
        self.publicOrigin = publicOrigin
        self.upstreamHostname = upstreamHostname
        self.artifactHostnames = artifactHostnames
        self.cooldownSeconds = cooldownSeconds
        self.limits = limits
    }

    init(from container: KeyedDecodingContainer<AnyCodingKey>, path: String) throws {
        try PolicyStrictness.rejectUnknown(container, allowed: Self.allowedKeys, path: path)
        self.enabled = try container.decode(Bool.self, forKey: AnyCodingKey("enabled"))
        self.mount = try container.decode(String.self, forKey: AnyCodingKey("mount"))
        self.publicOrigin = try container.decode(String.self, forKey: AnyCodingKey("publicOrigin"))
        self.upstreamHostname = try container.decode(String.self, forKey: AnyCodingKey("upstreamHostname"))
        self.artifactHostnames = try container.decode([String].self, forKey: AnyCodingKey("artifactHostnames"))
        self.cooldownSeconds = try container.decode(Double.self, forKey: AnyCodingKey("cooldownSeconds"))
        let limits = try container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("limits"))
        self.limits = try RegistryRuleLimits(from: limits, path: "\(path).limits")
    }

    func encodeFields(into container: inout KeyedEncodingContainer<AnyCodingKey>) throws {
        try container.encode(enabled, forKey: AnyCodingKey("enabled"))
        try container.encode(mount, forKey: AnyCodingKey("mount"))
        try container.encode(publicOrigin, forKey: AnyCodingKey("publicOrigin"))
        try container.encode(upstreamHostname, forKey: AnyCodingKey("upstreamHostname"))
        try container.encode(artifactHostnames, forKey: AnyCodingKey("artifactHostnames"))
        try container.encode(cooldownSeconds, forKey: AnyCodingKey("cooldownSeconds"))
        var nested = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("limits"))
        try limits.encodeFields(into: &nested)
    }
}

public struct PyPIRule: Sendable, Equatable {
    public static let allowedKeys: Set<String> = [
        "operation", "enabled", "mount", "publicOrigin", "upstreamHostname", "artifactHostnames",
        "cooldownSeconds", "limits",
    ]

    public let enabled: Bool
    public let mount: String
    public let publicOrigin: String
    public let upstreamHostname: String
    public let artifactHostnames: [String]
    public let cooldownSeconds: Double
    public let limits: RegistryRuleLimits

    public init(enabled: Bool = true, mount: String = "/pypi", publicOrigin: String,
                upstreamHostname: String = "pypi.org", artifactHostnames: [String] = ["files.pythonhosted.org"],
                cooldownSeconds: Double = 3_600, limits: RegistryRuleLimits = .standard) {
        self.enabled = enabled
        self.mount = mount
        self.publicOrigin = publicOrigin
        self.upstreamHostname = upstreamHostname
        self.artifactHostnames = artifactHostnames
        self.cooldownSeconds = cooldownSeconds
        self.limits = limits
    }

    init(from container: KeyedDecodingContainer<AnyCodingKey>, path: String) throws {
        try PolicyStrictness.rejectUnknown(container, allowed: Self.allowedKeys, path: path)
        self.enabled = try container.decode(Bool.self, forKey: AnyCodingKey("enabled"))
        self.mount = try container.decode(String.self, forKey: AnyCodingKey("mount"))
        self.publicOrigin = try container.decode(String.self, forKey: AnyCodingKey("publicOrigin"))
        self.upstreamHostname = try container.decode(String.self, forKey: AnyCodingKey("upstreamHostname"))
        self.artifactHostnames = try container.decode([String].self, forKey: AnyCodingKey("artifactHostnames"))
        self.cooldownSeconds = try container.decode(Double.self, forKey: AnyCodingKey("cooldownSeconds"))
        let limits = try container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("limits"))
        self.limits = try RegistryRuleLimits(from: limits, path: "\(path).limits")
    }

    func encodeFields(into container: inout KeyedEncodingContainer<AnyCodingKey>) throws {
        try container.encode(enabled, forKey: AnyCodingKey("enabled"))
        try container.encode(mount, forKey: AnyCodingKey("mount"))
        try container.encode(publicOrigin, forKey: AnyCodingKey("publicOrigin"))
        try container.encode(upstreamHostname, forKey: AnyCodingKey("upstreamHostname"))
        try container.encode(artifactHostnames, forKey: AnyCodingKey("artifactHostnames"))
        try container.encode(cooldownSeconds, forKey: AnyCodingKey("cooldownSeconds"))
        var nested = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("limits"))
        try limits.encodeFields(into: &nested)
    }
}

public struct GitRule: Sendable, Equatable {
    public static let allowedKeys: Set<String> = [
        "operation", "enabled", "mount", "upstreamHostname", "repositoryPath", "allowPush",
        "maximumRequestBytes", "limits",
    ]
    /// `GitGateway` z WP1.D5 obsluhuje jediný pevný projekt `project.git`
    /// (`operation()` porovnává `mount + "/project.git"`). Politika jinou cestu
    /// odmítne, aby složení nevzniklo "zelené", ale nikdy nic neobsloužilo.
    public static let supportedRepositoryPath = "/project.git"

    public let enabled: Bool
    public let mount: String
    public let upstreamHostname: String
    public let repositoryPath: String
    public let allowPush: Bool
    public let maximumRequestBytes: Int
    public let limits: RegistryRuleLimits

    public init(enabled: Bool = true, mount: String = "/git", upstreamHostname: String,
                repositoryPath: String = GitRule.supportedRepositoryPath, allowPush: Bool = false,
                maximumRequestBytes: Int = 1_048_576, limits: RegistryRuleLimits = .standard) {
        self.enabled = enabled
        self.mount = mount
        self.upstreamHostname = upstreamHostname
        self.repositoryPath = repositoryPath
        self.allowPush = allowPush
        self.maximumRequestBytes = maximumRequestBytes
        self.limits = limits
    }

    init(from container: KeyedDecodingContainer<AnyCodingKey>, path: String) throws {
        try PolicyStrictness.rejectUnknown(container, allowed: Self.allowedKeys, path: path)
        self.enabled = try container.decode(Bool.self, forKey: AnyCodingKey("enabled"))
        self.mount = try container.decode(String.self, forKey: AnyCodingKey("mount"))
        self.upstreamHostname = try container.decode(String.self, forKey: AnyCodingKey("upstreamHostname"))
        self.repositoryPath = try container.decode(String.self, forKey: AnyCodingKey("repositoryPath"))
        self.allowPush = try container.decode(Bool.self, forKey: AnyCodingKey("allowPush"))
        self.maximumRequestBytes = try container.decode(Int.self, forKey: AnyCodingKey("maximumRequestBytes"))
        let limits = try container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("limits"))
        self.limits = try RegistryRuleLimits(from: limits, path: "\(path).limits")
        guard repositoryPath == Self.supportedRepositoryPath else {
            throw PolicyError.invalidField("\(path).repositoryPath")
        }
        guard (1...1_048_576).contains(maximumRequestBytes) else {
            throw PolicyError.invalidField("\(path).maximumRequestBytes")
        }
    }

    func encodeFields(into container: inout KeyedEncodingContainer<AnyCodingKey>) throws {
        try container.encode(enabled, forKey: AnyCodingKey("enabled"))
        try container.encode(mount, forKey: AnyCodingKey("mount"))
        try container.encode(upstreamHostname, forKey: AnyCodingKey("upstreamHostname"))
        try container.encode(repositoryPath, forKey: AnyCodingKey("repositoryPath"))
        try container.encode(allowPush, forKey: AnyCodingKey("allowPush"))
        try container.encode(maximumRequestBytes, forKey: AnyCodingKey("maximumRequestBytes"))
        var nested = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("limits"))
        try limits.encodeFields(into: &nested)
    }
}

public struct ModelRule: Sendable, Equatable {
    public static let allowedKeys: Set<String> = [
        "operation", "enabled", "mount", "allowedModels", "budgetUnits", "chargePerRequest",
        "requestsPerWindow", "rateWindowSeconds", "maximumConcurrent", "maximumRecords",
        "maximumInputBytes", "maximumOutputTokens", "maximumOutputBytes", "maximumEvents",
        "lifetimeSeconds",
    ]
    /// `ModelAPIGateway.route()` je pevně mountovaný na `/model`; jiný mount
    /// v politice by nebyl obsluhován, proto se odmítne.
    public static let supportedMount = "/model"

    public let enabled: Bool
    public let mount: String
    public let allowedModels: [String]
    public let budgetUnits: UInt64
    public let chargePerRequest: UInt64
    public let requestsPerWindow: Int
    public let rateWindowSeconds: Int
    public let maximumConcurrent: Int
    public let maximumRecords: Int
    public let maximumInputBytes: Int
    public let maximumOutputTokens: Int
    public let maximumOutputBytes: Int
    public let maximumEvents: Int
    public let lifetimeSeconds: Int

    public init(enabled: Bool = true, mount: String = ModelRule.supportedMount,
                allowedModels: [String], budgetUnits: UInt64, chargePerRequest: UInt64 = 1,
                requestsPerWindow: Int = 10, rateWindowSeconds: Int = 60, maximumConcurrent: Int = 2,
                maximumRecords: Int = 16, maximumInputBytes: Int = 32_768, maximumOutputTokens: Int = 1_024,
                maximumOutputBytes: Int = 262_144, maximumEvents: Int = 4_096, lifetimeSeconds: Int = 60) {
        self.enabled = enabled
        self.mount = mount
        self.allowedModels = allowedModels
        self.budgetUnits = budgetUnits
        self.chargePerRequest = chargePerRequest
        self.requestsPerWindow = requestsPerWindow
        self.rateWindowSeconds = rateWindowSeconds
        self.maximumConcurrent = maximumConcurrent
        self.maximumRecords = maximumRecords
        self.maximumInputBytes = maximumInputBytes
        self.maximumOutputTokens = maximumOutputTokens
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumEvents = maximumEvents
        self.lifetimeSeconds = lifetimeSeconds
    }

    init(from container: KeyedDecodingContainer<AnyCodingKey>, path: String) throws {
        try PolicyStrictness.rejectUnknown(container, allowed: Self.allowedKeys, path: path)
        self.enabled = try container.decode(Bool.self, forKey: AnyCodingKey("enabled"))
        self.mount = try container.decode(String.self, forKey: AnyCodingKey("mount"))
        self.allowedModels = try container.decode([String].self, forKey: AnyCodingKey("allowedModels"))
        self.budgetUnits = try container.decode(UInt64.self, forKey: AnyCodingKey("budgetUnits"))
        self.chargePerRequest = try container.decode(UInt64.self, forKey: AnyCodingKey("chargePerRequest"))
        self.requestsPerWindow = try container.decode(Int.self, forKey: AnyCodingKey("requestsPerWindow"))
        self.rateWindowSeconds = try container.decode(Int.self, forKey: AnyCodingKey("rateWindowSeconds"))
        self.maximumConcurrent = try container.decode(Int.self, forKey: AnyCodingKey("maximumConcurrent"))
        self.maximumRecords = try container.decode(Int.self, forKey: AnyCodingKey("maximumRecords"))
        self.maximumInputBytes = try container.decode(Int.self, forKey: AnyCodingKey("maximumInputBytes"))
        self.maximumOutputTokens = try container.decode(Int.self, forKey: AnyCodingKey("maximumOutputTokens"))
        self.maximumOutputBytes = try container.decode(Int.self, forKey: AnyCodingKey("maximumOutputBytes"))
        self.maximumEvents = try container.decode(Int.self, forKey: AnyCodingKey("maximumEvents"))
        self.lifetimeSeconds = try container.decode(Int.self, forKey: AnyCodingKey("lifetimeSeconds"))
        try validate(path: path)
    }

    func encodeFields(into container: inout KeyedEncodingContainer<AnyCodingKey>) throws {
        try container.encode(enabled, forKey: AnyCodingKey("enabled"))
        try container.encode(mount, forKey: AnyCodingKey("mount"))
        try container.encode(allowedModels, forKey: AnyCodingKey("allowedModels"))
        try container.encode(budgetUnits, forKey: AnyCodingKey("budgetUnits"))
        try container.encode(chargePerRequest, forKey: AnyCodingKey("chargePerRequest"))
        try container.encode(requestsPerWindow, forKey: AnyCodingKey("requestsPerWindow"))
        try container.encode(rateWindowSeconds, forKey: AnyCodingKey("rateWindowSeconds"))
        try container.encode(maximumConcurrent, forKey: AnyCodingKey("maximumConcurrent"))
        try container.encode(maximumRecords, forKey: AnyCodingKey("maximumRecords"))
        try container.encode(maximumInputBytes, forKey: AnyCodingKey("maximumInputBytes"))
        try container.encode(maximumOutputTokens, forKey: AnyCodingKey("maximumOutputTokens"))
        try container.encode(maximumOutputBytes, forKey: AnyCodingKey("maximumOutputBytes"))
        try container.encode(maximumEvents, forKey: AnyCodingKey("maximumEvents"))
        try container.encode(lifetimeSeconds, forKey: AnyCodingKey("lifetimeSeconds"))
    }

    func validate(path: String) throws {
        func fail(_ name: String) throws -> Never { throw PolicyError.invalidField("\(path).\(name)") }
        guard mount == Self.supportedMount else { try fail("mount") }
        guard (1...32).contains(allowedModels.count) else { try fail("allowedModels") }
        guard allowedModels.allSatisfy({ name in
            (1...128).contains(name.utf8.count) && name.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || "-_.".utf8.contains($0)
            }
        }) else { try fail("allowedModels") }
        guard budgetUnits > 0 else { try fail("budgetUnits") }
        guard chargePerRequest > 0, chargePerRequest <= budgetUnits else { try fail("chargePerRequest") }
        guard (1...1_000).contains(requestsPerWindow) else { try fail("requestsPerWindow") }
        guard (1...86_400).contains(rateWindowSeconds) else { try fail("rateWindowSeconds") }
        guard (1...32).contains(maximumConcurrent) else { try fail("maximumConcurrent") }
        guard (1...10_000).contains(maximumRecords) else { try fail("maximumRecords") }
        guard (1...65_536).contains(maximumInputBytes) else { try fail("maximumInputBytes") }
        guard (1...8_192).contains(maximumOutputTokens) else { try fail("maximumOutputTokens") }
        guard (1...1_048_576).contains(maximumOutputBytes) else { try fail("maximumOutputBytes") }
        guard (1...16_384).contains(maximumEvents) else { try fail("maximumEvents") }
        guard (1...120).contains(lifetimeSeconds) else { try fail("lifetimeSeconds") }
    }
}

/// Pravidlo jedné operace. `enabled: false` znamená "deklarováno, ale neskládá se";
/// požadavek na vypnutý mount se deterministicky odmítá a audituje.
public enum GatewayRule: Sendable, Equatable, Decodable {
    case npm(NPMRule)
    case pypi(PyPIRule)
    case git(GitRule)
    case model(ModelRule)

    public var operation: GatewayOperation {
        switch self {
        case .npm: return .npm
        case .pypi: return .pypi
        case .git: return .git
        case .model: return .model
        }
    }

    public var isEnabled: Bool {
        switch self {
        case .npm(let rule): return rule.enabled
        case .pypi(let rule): return rule.enabled
        case .git(let rule): return rule.enabled
        case .model(let rule): return rule.enabled
        }
    }

    public var mount: String {
        switch self {
        case .npm(let rule): return rule.mount
        case .pypi(let rule): return rule.mount
        case .git(let rule): return rule.mount
        case .model(let rule): return rule.mount
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let name = try container.decode(String.self, forKey: AnyCodingKey("operation"))
        guard let operation = GatewayOperation(rawValue: name) else {
            throw PolicyError.unknownOperation(name)
        }
        switch operation {
        case .npm: self = .npm(try NPMRule(from: container, path: "npm"))
        case .pypi: self = .pypi(try PyPIRule(from: container, path: "pypi"))
        case .git: self = .git(try GitRule(from: container, path: "git"))
        case .model: self = .model(try ModelRule(from: container, path: "model"))
        }
    }

    func encode(to container: inout KeyedEncodingContainer<AnyCodingKey>) throws {
        try container.encode(operation.rawValue, forKey: AnyCodingKey("operation"))
        switch self {
        case .npm(let rule): try rule.encodeFields(into: &container)
        case .pypi(let rule): try rule.encodeFields(into: &container)
        case .git(let rule): try rule.encodeFields(into: &container)
        case .model(let rule): try rule.encodeFields(into: &container)
        }
    }
}

// MARK: - Politika

/// Provizorní návrh politiky brány (draft v1) čekající na formát z WP1.H1.
/// Výměna formátu se dotkne jen tohoto souboru a dekodéru; složení handlerů
/// (`Composition.swift`) pracuje s typy `GatewayPolicy`/`GatewayRule`, ne s JSON.
public struct GatewayPolicy: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1
    public static let allowedKeys: Set<String> = ["schemaVersion", "zoneID", "auditCapacity", "gateways"]

    public let schemaVersion: Int
    public let zoneID: String
    public let auditCapacity: Int
    public let gateways: [GatewayRule]

    public init(schemaVersion: Int = GatewayPolicy.currentSchemaVersion, zoneID: String,
                auditCapacity: Int = 256, gateways: [GatewayRule]) throws {
        try Self.validate(schemaVersion: schemaVersion, zoneID: zoneID, auditCapacity: auditCapacity,
                          gateways: gateways)
        self.schemaVersion = schemaVersion
        self.zoneID = zoneID
        self.auditCapacity = auditCapacity
        self.gateways = gateways
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try PolicyStrictness.rejectUnknown(container, allowed: Self.allowedKeys, path: "policy")
        let schemaVersion = try container.decode(Int.self, forKey: AnyCodingKey("schemaVersion"))
        let zoneID = try container.decode(String.self, forKey: AnyCodingKey("zoneID"))
        let auditCapacity = try container.decode(Int.self, forKey: AnyCodingKey("auditCapacity"))
        var items = try container.nestedUnkeyedContainer(forKey: AnyCodingKey("gateways"))
        var gateways: [GatewayRule] = []
        while !items.isAtEnd {
            let element = try items.decode(GatewayRule.self)
            gateways.append(element)
        }
        try Self.validate(schemaVersion: schemaVersion, zoneID: zoneID, auditCapacity: auditCapacity,
                          gateways: gateways)
        self.schemaVersion = schemaVersion
        self.zoneID = zoneID
        self.auditCapacity = auditCapacity
        self.gateways = gateways
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(schemaVersion, forKey: AnyCodingKey("schemaVersion"))
        try container.encode(zoneID, forKey: AnyCodingKey("zoneID"))
        try container.encode(auditCapacity, forKey: AnyCodingKey("auditCapacity"))
        var items = container.nestedUnkeyedContainer(forKey: AnyCodingKey("gateways"))
        for rule in gateways { try items.encode(RuleEnvelope(rule: rule)) }
    }

    /// Dekóduje a validuje politiku. Neznámá pole, neznámé operace i chybějící
    /// pole jsou odmítnuty; nikdy se nedoplňují implicitní hodnoty.
    public static func decode(_ data: Data) throws -> GatewayPolicy {
        do {
            return try JSONDecoder().decode(GatewayPolicy.self, from: data)
        } catch let error as PolicyError {
            throw error
        } catch let error as DecodingError {
            throw PolicyStrictness.translate(error)
        } catch {
            throw PolicyError.malformed
        }
    }

    public var enabledRules: [GatewayRule] {
        gateways.filter { $0.isEnabled }.sorted { $0.mount < $1.mount }
    }

    /// Pravidlo, které brána **skutečně obsluhuje** (`enabled: true`). Vypnutá
    /// deklarace se sem záměrně nepropíše, aby se "deklarováno" nepletlo
    /// s "obsluhováno"; pro ni je tu `declaredRule(for:)`.
    public func rule(for operation: GatewayOperation) -> GatewayRule? {
        gateways.first { $0.operation == operation && $0.isEnabled }
    }

    /// Pravidlo tak, jak je deklarované v politice, i když je vypnuté.
    public func declaredRule(for operation: GatewayOperation) -> GatewayRule? {
        gateways.first { $0.operation == operation }
    }

    static func validate(schemaVersion: Int, zoneID: String, auditCapacity: Int,
                         gateways: [GatewayRule]) throws {
        guard schemaVersion == currentSchemaVersion else {
            throw PolicyError.unsupportedVersion(schemaVersion)
        }
        guard (1...128).contains(zoneID.utf8.count), zoneID.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || "-_.".utf8.contains($0)
        }) else { throw PolicyError.invalidField("zoneID") }
        guard (1...10_000).contains(auditCapacity) else { throw PolicyError.invalidField("auditCapacity") }
        guard !gateways.isEmpty else { throw PolicyError.emptyGateways }

        var operations = Set<GatewayOperation>()
        var mounts = Set<String>()
        for rule in gateways {
            guard operations.insert(rule.operation).inserted else {
                throw PolicyError.duplicateOperation(rule.operation)
            }
            let mount = rule.mount
            guard mount.first == "/", (2...64).contains(mount.utf8.count),
                  mount.dropFirst().utf8.allSatisfy({
                      (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                  }) else { throw PolicyError.invalidField("\(rule.operation.rawValue).mount") }
            guard mounts.insert(mount).inserted else { throw PolicyError.duplicateMount(mount) }
            switch rule {
            case .npm(let npm): try validateRegistryOrigin(npm.publicOrigin, path: "npm.publicOrigin",
                                                           cooldown: npm.cooldownSeconds, cooldownPath: "npm.cooldownSeconds")
            case .pypi(let pypi): try validateRegistryOrigin(pypi.publicOrigin, path: "pypi.publicOrigin",
                                                             cooldown: pypi.cooldownSeconds, cooldownPath: "pypi.cooldownSeconds")
            case .git(let git):
                guard git.repositoryPath == GitRule.supportedRepositoryPath else {
                    throw PolicyError.invalidField("git.repositoryPath")
                }
                guard (1...1_048_576).contains(git.maximumRequestBytes) else {
                    throw PolicyError.invalidField("git.maximumRequestBytes")
                }
            case .model(let model): try model.validate(path: "model")
            }
        }
    }

    static func validateRegistryOrigin(_ origin: String, path: String, cooldown: Double,
                                       cooldownPath: String) throws {
        guard let components = URLComponents(string: origin), let port = components.port,
              (1...65_535).contains(port), origin == "http://127.0.0.1:\(port)" else {
            throw PolicyError.invalidField(path)
        }
        guard cooldown.isFinite, cooldown >= 0 else { throw PolicyError.invalidField(cooldownPath) }
    }
}

private struct RuleEnvelope: Encodable {
    let rule: GatewayRule
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try rule.encode(to: &container)
    }
}

enum PolicyStrictness {
    /// Odmítne neznámá pole deterministicky (seřazená), aby výsledek nezávisel
    /// na pořadí klíčů ve vstupu.
    static func rejectUnknown(_ container: KeyedDecodingContainer<AnyCodingKey>,
                              allowed: Set<String>, path: String) throws {
        let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
        if let first = unknown.first { throw PolicyError.unknownField("\(path).\(first)") }
    }

    static func translate(_ error: DecodingError) -> PolicyError {
        func path(_ codingPath: [CodingKey], _ extra: String?) -> String {
            (codingPath.map(\.stringValue) + (extra.map { [$0] } ?? [])).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return .missingField(path(context.codingPath, key.stringValue))
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return .invalidField(path(context.codingPath, nil))
        case .dataCorrupted:
            return .malformed
        @unknown default:
            return .malformed
        }
    }
}
