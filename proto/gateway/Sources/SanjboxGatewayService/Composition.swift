import Foundation
import SanjboxGatewayCore

/// Jeden řádek směrovací tabulky politiky (i vypnutý mount se eviduje, aby
/// odmítnutí bylo deterministické a auditované).
public struct RouteTableEntry: Sendable, Equatable {
    public let operation: GatewayOperation
    public let mount: String
    public let enabled: Bool
}

public enum RouteClass: Sendable, Equatable {
    case unknown
    case disabled(GatewayOperation)
    case active(GatewayOperation)
}

/// Neměnný pohled na složení brány: co politika deklaruje a co je aktivní.
public struct GatewayRuntimeConfiguration: Sendable, Equatable {
    public let zoneID: String
    public let auditCapacity: Int
    public let entries: [RouteTableEntry]

    public init(zoneID: String, auditCapacity: Int, entries: [RouteTableEntry]) {
        self.zoneID = zoneID
        self.auditCapacity = auditCapacity
        self.entries = entries.sorted { $0.mount < $1.mount }
    }

    public var activeOperations: [GatewayOperation] {
        entries.filter(\.enabled).map(\.operation).sorted()
    }

    public var declaredOperations: [GatewayOperation] {
        entries.map(\.operation).sorted()
    }

    /// Klasifikace podle mountu z politiky, ne podle sestaveného routeru:
    /// vypnutý nebo neznámý mount nikdy nepropadne k handleru.
    public func classify(path: String) -> RouteClass {
        let matches = entries.filter { path == $0.mount || path.hasPrefix($0.mount + "/") }
        guard let best = matches.max(by: { $0.mount.count < $1.mount.count }) else { return .unknown }
        return best.enabled ? .active(best.operation) : .disabled(best.operation)
    }

    /// Deterministické řádky pro CLI i pro protokol běhu.
    public var summaryLines: [String] {
        ["policy zoneID=\(zoneID) auditCapacity=\(auditCapacity)"]
            + entries.map { entry in
                "gateway \(entry.operation.rawValue) mount=\(entry.mount) state=\(entry.enabled ? "enabled" : "disabled")"
            }
    }
}

public enum CompositionError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Politiku nelze převzít: chyba validace, konfigurace odmítnutá handlerem
    /// nebo chybějící klíč. Texty jsou stabilní a neobsahují klíč ani tělo vstupu.
    case policy(PolicyError)
    case handlerConfiguration(GatewayOperation)
    case keyUnavailable(GatewayOperation)
    case invalidRouter(String)

    public var description: String {
        switch self {
        case .policy(let error): return "policy: \(error.description)"
        case .handlerConfiguration(let operation):
            return "handler rejected policy configuration for \"\(operation.rawValue)\""
        case .keyUnavailable(let operation):
            return "no key for operation \"\(operation.rawValue)\"; operation is not composed"
        case .invalidRouter(let reason): return "router: \(reason)"
        }
    }
}

/// Složí typované handlery ze `spikes/s5-gateway` podle politiky a obsluhuje
/// požadavky v jednom procesu. Žádný socket zde nevzniká; transport je oddělený
/// (`Transport.swift`) a v testech se používá in-process dispatch.
public actor GatewayService {
    public nonisolated let policy: GatewayPolicy
    public nonisolated let runtime: GatewayRuntimeConfiguration
    private let router: TypedRouter
    private var records: [AuditRecord] = []
    private var reserved = 0
    private var saturationCount: UInt64 = 0

    public init(policy: GatewayPolicy, keyProvider: any KeyProvider = MockKeyProvider(),
                upstream: UpstreamClient = UpstreamClient()) throws {
        let routes = try Self.makeRoutes(policy: policy, keyProvider: keyProvider, upstream: upstream)
        do {
            router = try TypedRouter(routes: routes)
        } catch RouteFailure.duplicateMount {
            throw CompositionError.invalidRouter("duplicate mount")
        } catch RouteFailure.invalidMount {
            throw CompositionError.invalidRouter("invalid mount")
        } catch {
            throw CompositionError.invalidRouter("invalid method set")
        }
        self.policy = policy
        runtime = GatewayRuntimeConfiguration(
            zoneID: policy.zoneID,
            auditCapacity: policy.auditCapacity,
            entries: policy.gateways.map {
                RouteTableEntry(operation: $0.operation, mount: $0.mount, enabled: $0.isEnabled)
            }
        )
    }

    /// In-process dispatch. Neotevírá port; vrací odpověď nebo SSE producenta.
    public func dispatch(_ request: HTTPRequest) async throws -> GatewayReply {
        let operation: GatewayOperation
        switch runtime.classify(path: request.path) {
        case .unknown:
            return deny(.operationNotConfigured, request: request, status: 404)
        case .disabled(let disabled):
            return deny(.operationDisabled, request: request, status: 403, operation: disabled)
        case .active(let active):
            operation = active
        }
        guard reserve() else {
            saturationCount += 1
            return .response(.error(503))
        }
        defer { reserved -= 1 }
        do {
            let reply = try await router.reply(to: request)
            append(operation: operation, request: request, decision: .routed, reason: "",
                   status: status(of: reply))
            return reply
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Chyba handleru se nepřenáší jako "průhledný" přenos: klient dostane
            // deterministickou 502 a rozhodnutí zůstává v auditu.
            append(operation: operation, request: request, decision: .routed,
                   reason: "", status: 502)
            return .response(.error(502))
        }
    }

    public func auditRecords() -> [AuditRecord] { records }

    public func auditText() -> String { records.map(\.canonicalLine).joined(separator: "\n") }

    public func auditSaturationCount() -> UInt64 { saturationCount }

    // MARK: - Sestavení handlerů

    static func makeRoutes(policy: GatewayPolicy, keyProvider: any KeyProvider,
                           upstream: UpstreamClient) throws -> [TypedRoute] {
        var routes: [TypedRoute] = []
        for rule in policy.enabledRules {
            switch rule {
            case .npm(let npm):
                let configuration: NPMConfiguration
                do {
                    configuration = try NPMConfiguration(
                        registryHostname: npm.upstreamHostname,
                        artifactHostnames: Set(npm.artifactHostnames),
                        publicOrigin: npm.publicOrigin,
                        mount: npm.mount,
                        cooldown: npm.cooldownSeconds,
                        maximumMetadataBytes: npm.limits.metadataBytes,
                        maximumArtifactBytes: npm.limits.artifactBytes,
                        maximumAuditRecords: npm.limits.auditRecords,
                        maximumOperations: npm.limits.operations,
                        lifetime: .seconds(npm.limits.lifetimeSeconds)
                    )
                } catch {
                    throw CompositionError.handlerConfiguration(.npm)
                }
                routes.append(NPMGateway(configuration: configuration, upstream: upstream).route())
            case .pypi(let pypi):
                let configuration: PyPIConfiguration
                let limits: RegistryLimits
                do {
                    limits = try RegistryLimits(
                        metadataBytes: pypi.limits.metadataBytes,
                        artifactBytes: pypi.limits.artifactBytes,
                        files: pypi.limits.files,
                        operations: pypi.limits.operations,
                        auditRecords: pypi.limits.auditRecords,
                        lifetime: .seconds(pypi.limits.lifetimeSeconds)
                    )
                } catch {
                    throw CompositionError.handlerConfiguration(.pypi)
                }
                do {
                    configuration = try PyPIConfiguration(
                        registryHostname: pypi.upstreamHostname,
                        artifactHostnames: Set(pypi.artifactHostnames),
                        publicOrigin: pypi.publicOrigin,
                        mount: pypi.mount,
                        cooldown: pypi.cooldownSeconds,
                        limits: limits
                    )
                } catch {
                    throw CompositionError.handlerConfiguration(.pypi)
                }
                routes.append(PyPIGateway(configuration: configuration, upstream: upstream).route())
            case .git(let git):
                let configuration: GitConfiguration
                do {
                    configuration = try GitConfiguration(
                        hostname: git.upstreamHostname,
                        repositoryPath: git.repositoryPath,
                        mount: git.mount,
                        allowPush: git.allowPush,
                        maximumRequestBytes: git.maximumRequestBytes,
                        limits: try RegistryLimits(
                            metadataBytes: git.limits.metadataBytes,
                            artifactBytes: git.limits.artifactBytes,
                            files: git.limits.files,
                            operations: git.limits.operations,
                            auditRecords: git.limits.auditRecords,
                            lifetime: .seconds(git.limits.lifetimeSeconds)
                        )
                    )
                } catch {
                    throw CompositionError.handlerConfiguration(.git)
                }
                routes.append(GitGateway(configuration: configuration, upstream: upstream).route())
            case .model(let model):
                guard let key = keyProvider.key(for: .model) else {
                    throw CompositionError.keyUnavailable(.model)
                }
                let gateway: ModelAPIGateway
                do {
                    let configuration = try ModelAPIConfiguration(
                        zoneID: policy.zoneID,
                        allowedModels: Set(model.allowedModels),
                        budgetUnits: model.budgetUnits,
                        chargePerRequest: model.chargePerRequest,
                        requestsPerWindow: model.requestsPerWindow,
                        rateWindow: .seconds(model.rateWindowSeconds),
                        maximumConcurrent: model.maximumConcurrent,
                        maximumRecords: model.maximumRecords,
                        maximumInputBytes: model.maximumInputBytes,
                        maximumOutputTokens: model.maximumOutputTokens,
                        maximumOutputBytes: model.maximumOutputBytes,
                        maximumEvents: model.maximumEvents,
                        lifetime: .seconds(model.lifetimeSeconds)
                    )
                    gateway = try ModelAPIGateway(configuration: configuration, testKey: key, upstream: upstream)
                } catch {
                    throw CompositionError.handlerConfiguration(.model)
                }
                routes.append(gateway.route())
            }
        }
        return routes
    }

    // MARK: - Audit

    private func reserve() -> Bool { records.count + reserved < runtime.auditCapacity }

    private func deny(_ reason: DenialReason, request: HTTPRequest, status: Int,
                      operation: GatewayOperation? = nil) -> GatewayReply {
        // Odmítnutí musí být v auditu, pokud je místo; zaplněná kapacita se
        // nezahazuje, jen se odmítne další požadavek.
        guard reserve() else {
            saturationCount += 1
            return .response(.error(503))
        }
        append(operation: operation, request: request, decision: .denied,
               reason: reason.rawValue, status: status)
        return .response(.error(status))
    }

    private func append(operation: GatewayOperation?, request: HTTPRequest, decision: AuditDecision,
                        reason: String, status: Int) {
        guard records.count < runtime.auditCapacity else {
            saturationCount += 1
            return
        }
        records.append(AuditRecord(
            sequence: UInt64(records.count + 1),
            operation: operation?.rawValue ?? "unknown",
            method: request.method,
            path: request.path,
            decision: decision,
            reason: reason,
            status: status
        ))
    }

    private func status(of reply: GatewayReply) -> Int {
        switch reply {
        case .response(let response): return response.status
        case .events: return 200
        }
    }
}
