import Foundation
import SanjboxContracts
import SanjboxGatewayCore

/// Trusted, caller-supplied handler configuration, bound by exact H1 gate ID.
/// Every gate requires one complete rule. No rule, destination or operation is inferred.
/// Use GatewayPolicy.decode for rules supplied on the wire (its strict fields remain required).
public struct H1GatewayConfiguration: Sendable {
    public let auditCapacity: Int
    public let rulesByGateID: [String: GatewayRule]

    public init(auditCapacity: Int, rulesByGateID: [String: GatewayRule]) {
        self.auditCapacity = auditCapacity
        self.rulesByGateID = rulesByGateID
    }
}

public enum H1AdapterError: String, Error, Sendable, CustomStringConvertible {
    case invalidPolicy, gateBindings, unsupportedType, typeMismatch, disabledGate
    case upstreamMismatch, unsupportedMethods, requestLimit, responseLimit
    public var description: String { "H1 adapter rejected: \(rawValue)" }
}

/// Validated, immutable composition of H1 authorization and explicit H4 settings.
/// Byte ceilings apply to HTTP entity bodies in each direction, including SSE syntax;
/// HTTP headers/chunk framing have their own transport bounds. No live credentials.
public struct H1GatewayAdapter: Sendable {
    public let networkPolicy: NetworkPolicy
    public let upstreamResponseBytesLimit: Int
    let handlerPolicy: GatewayPolicy
    private let gates: [GatewayOperation: TypedGate]

    public static func decode(_ data: Data, configuration: H1GatewayConfiguration) throws -> Self {
        // Never use ordinary JSONDecoder for H1 wire: strict duplicate/integer checks matter.
        try Self(networkPolicy: NetworkPolicy.decode(data), configuration: configuration)
    }

    public init(networkPolicy: NetworkPolicy, configuration: H1GatewayConfiguration) throws {
        // H1 DTOs are mutable; validate even programmatically constructed values.
        do { try networkPolicy.validate() } catch { throw H1AdapterError.invalidPolicy }
        guard Set(configuration.rulesByGateID.keys) == Set(networkPolicy.gates.map(\.id)) else {
            throw H1AdapterError.gateBindings
        }
        var gates: [GatewayOperation: TypedGate] = [:]
        var rules: [GatewayRule] = []
        for gate in networkPolicy.gates {
            let operation: GatewayOperation
            switch gate.type {
            case .npm: operation = .npm
            case .pypi: operation = .pypi
            case .git: operation = .git
            case .modelAPI: operation = .model
            case .brew: throw H1AdapterError.unsupportedType
            }
            guard let rule = configuration.rulesByGateID[gate.id], rule.operation == operation else {
                throw H1AdapterError.typeMismatch
            }
            // H4 currently owns one handler per operation; never collapse two H1 grants.
            guard gates[operation] == nil else { throw H1AdapterError.gateBindings }
            guard rule.isEnabled else { throw H1AdapterError.disabledGate }
            let responseLimit = Int(gate.responseBytesLimit)
            func registry(_ host: String, _ artifacts: [String], _ limits: RegistryRuleLimits) throws {
                guard host == gate.upstream, artifacts.allSatisfy({ $0 == gate.upstream }) else {
                    throw H1AdapterError.upstreamMismatch
                }
                guard limits.metadataBytes <= responseLimit, limits.artifactBytes <= responseLimit else {
                    throw H1AdapterError.responseLimit
                }
            }
            switch rule {
            case .npm(let rule): try registry(rule.upstreamHostname, rule.artifactHostnames, rule.limits)
            case .pypi(let rule): try registry(rule.upstreamHostname, rule.artifactHostnames, rule.limits)
            case .git(let rule):
                try registry(rule.upstreamHostname, [], rule.limits)
                guard rule.maximumRequestBytes <= Int(gate.requestBytesLimit) else {
                    throw H1AdapterError.requestLimit
                }
            case .model(let rule):
                guard gate.upstream == "api.anthropic.com" else { throw H1AdapterError.upstreamMismatch }
                guard gate.methods == ["POST"] else { throw H1AdapterError.unsupportedMethods }
                guard rule.maximumInputBytes <= Int(gate.requestBytesLimit) else {
                    throw H1AdapterError.requestLimit
                }
                guard rule.maximumOutputBytes <= responseLimit else { throw H1AdapterError.responseLimit }
            }
            gates[operation] = gate
            rules.append(rule)
        }
        handlerPolicy = try GatewayPolicy(h1ZoneID: networkPolicy.zoneID,
                                          auditCapacity: configuration.auditCapacity, gateways: rules)
        self.networkPolicy = networkPolicy
        self.gates = gates
        // Keep the existing shared connection cap. Its one parser budget is the minimum
        // of all H1 grants and D1's buffered default; this can only tighten a larger gate.
        upstreamResponseBytesLimit = min(4_194_304, networkPolicy.gates.map { Int($0.responseBytesLimit) }.min() ?? 4_194_304)
    }

    var upstreamLimits: UpstreamLimits {
        UpstreamLimits(responseBytes: upstreamResponseBytesLimit, streamBytes: upstreamResponseBytesLimit,
                       eventBytes: min(65_536, upstreamResponseBytesLimit))
    }

    func gate(for operation: GatewayOperation) -> TypedGate? { gates[operation] }

    func requestIsWithinLimit(_ request: HTTPRequest, operation: GatewayOperation) -> Bool {
        guard let gate = gates[operation], request.body.count <= Int(gate.requestBytesLimit) else { return false }
        if operation == .model, request.method == "POST" {
            // D3 reconstructs valid JSON using these same Foundation options. Check the
            // reconstructed byte count too: JSON escaping may grow a small incoming body.
            // D3 still performs the strict duplicate-key, schema and model authorization.
            guard let object = try? JSONSerialization.jsonObject(with: request.body),
                  JSONSerialization.isValidJSONObject(object),
                  let canonical = try? JSONSerialization.data(withJSONObject: object,
                                                               options: [.sortedKeys, .withoutEscapingSlashes]),
                  canonical.count <= Int(gate.requestBytesLimit) else { return false }
        }
        return true
    }
}
