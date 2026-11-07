import Foundation

public enum CommandFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case usage(String)
    case policy(PolicyError)
    case composition(CompositionError)
    case io

    public var description: String {
        switch self {
        case .usage(let text): return text
        case .policy(let error): return "policy rejected: \(error.description)"
        case .composition(let error): return "composition rejected: \(error.description)"
        case .io: return "cannot read policy file"
        }
    }
}

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let output: [String]

    public init(exitCode: Int32, output: [String]) {
        self.exitCode = exitCode
        self.output = output
    }
}

/// Příkazová obálka prototypu. Sama o sobě nic neotevírá: bez explicitního
/// `--listen 127.0.0.1:<port>` jen vypíše složení a skončí.
public enum GatewayCommand {
    public enum Invocation: Sendable, Equatable {
        case help
        case compose(policyPath: String)
        case serve(policyPath: String, address: LoopbackListener.Address)
    }

    public static let usageLines: [String] = [
        "usage: sanjbox-gateway-service --policy <file> [--listen 127.0.0.1:<port>]",
        "  --policy <file>   verzovaný draft politiky (schemaVersion \(GatewayPolicy.currentSchemaVersion))",
        "  --listen          opt-in reálný loopback listener; bez něj se žádný socket neotevře",
        "  --help            tato nápověda",
        "prototyp: otevřený socket ani běžící celek nejsou součástí MVP (IMPLEMENTATION §3)",
    ]

    public static func parse(_ arguments: [String]) throws -> Invocation {
        if arguments.contains("--help") || arguments.contains("-h") { return .help }
        var policyPath: String?
        var address: LoopbackListener.Address?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--policy":
                guard index + 1 < arguments.count else { throw CommandFailure.usage("--policy needs a file") }
                policyPath = arguments[index + 1]
                index += 2
            case "--listen":
                guard index + 1 < arguments.count else {
                    throw CommandFailure.usage("--listen needs 127.0.0.1:<port>")
                }
                guard let parsed = LoopbackListener.Address(text: arguments[index + 1]) else {
                    throw CommandFailure.usage("listener must be 127.0.0.1:<port> with port 1...65535")
                }
                address = parsed
                index += 2
            default:
                throw CommandFailure.usage("unknown argument \"\(argument)\"")
            }
        }
        guard let policyPath else { throw CommandFailure.usage("--policy <file> is required") }
        guard let address else { return .compose(policyPath: policyPath) }
        return .serve(policyPath: policyPath, address: address)
    }

    /// Vrací výstup a kód, nikdy netiskne sám (testy tak nepotřebují stdout).
    public static func run(_ arguments: [String]) async -> CommandResult {
        let invocation: Invocation
        do {
            invocation = try parse(arguments)
        } catch let failure as CommandFailure {
            return CommandResult(exitCode: 2, output: [failure.description] + usageLines)
        } catch {
            return CommandResult(exitCode: 2, output: ["invalid arguments"] + usageLines)
        }
        switch invocation {
        case .help:
            return CommandResult(exitCode: 0, output: usageLines)
        case .compose(let path):
            return await compose(policyPath: path, address: nil)
        case .serve(let path, let address):
            return await compose(policyPath: path, address: address)
        }
    }

    private static func compose(policyPath: String, address: LoopbackListener.Address?) async -> CommandResult {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: policyPath))
        } catch {
            return CommandResult(exitCode: 2, output: ["cannot read policy file: \(policyPath)"])
        }
        let policy: GatewayPolicy
        do {
            policy = try GatewayPolicy.decode(data)
        } catch let error as PolicyError {
            return CommandResult(exitCode: 3, output: ["policy rejected: \(error.description)"])
        } catch {
            return CommandResult(exitCode: 3, output: ["policy rejected: \(PolicyError.malformed.description)"])
        }
        let service: GatewayService
        do {
            service = try GatewayService(policy: policy)
        } catch let error as CompositionError {
            return CommandResult(exitCode: 3, output: ["composition rejected: \(error.description)"])
        } catch {
            return CommandResult(exitCode: 3, output: ["composition rejected"])
        }
        var lines = service.runtime.summaryLines
        lines.append("active: " + service.runtime.activeOperations.map(\.rawValue).joined(separator: ","))
        guard let address else {
            lines.append("listener disabled: no socket opened; pass --listen 127.0.0.1:<port> to enable one")
            return CommandResult(exitCode: 0, output: lines)
        }
        lines.append("prototype listener opt-in: \(address.text) (out of prototype scope, IMPLEMENTATION §3)")
        let listener = LoopbackListener(address: address)
        do {
            try await listener.run(serving: service)
        } catch {
            lines.append("listener stopped: \(String(describing: error))")
            return CommandResult(exitCode: 4, output: lines)
        }
        return CommandResult(exitCode: 0, output: lines)
    }
}
