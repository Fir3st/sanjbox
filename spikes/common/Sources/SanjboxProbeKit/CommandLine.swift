import Foundation

/// Exit codes shared by all Sanjbox probes, so scripts can tell a usage error from a bad run.
public enum ProbeExit: Int32 {
    case ok = 0
    /// A canary was found by `scan`.
    case finding = 1
    case usage = 2
    /// Probe credentials or session did not match the expectation: repeat the run.
    case invalidMeasurement = 3
    /// Cleanup refused to touch something it could not verify; inspect manually.
    case refused = 4
}

/// Minimal `--flag value` parser; probes deliberately avoid external dependencies.
public struct ProbeArguments {
    public private(set) var options: [String: String] = [:]
    public private(set) var positional: [String] = []

    /// - Parameter valueFlags: flags that take a value, written without the leading `--`.
    public init(_ arguments: [String], valueFlags: Set<String>) throws {
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            guard argument.hasPrefix("--") else {
                positional.append(argument)
                continue
            }
            let name = String(argument.dropFirst(2))
            guard valueFlags.contains(name) else { throw ProbeArgumentError.unknownFlag(argument) }
            guard let value = remaining.popFirst() else { throw ProbeArgumentError.missingValue(argument) }
            options[name] = value
        }
    }

    public func required(_ name: String) throws -> String {
        guard let value = options[name] else { throw ProbeArgumentError.missingFlag("--\(name)") }
        return value
    }
}

public enum ProbeArgumentError: Error, CustomStringConvertible {
    case unknownFlag(String), missingValue(String), missingFlag(String)

    public var description: String {
        switch self {
        case .unknownFlag(let flag): "unknown flag \(flag)"
        case .missingValue(let flag): "missing value for \(flag)"
        case .missingFlag(let flag): "missing required \(flag)"
        }
    }
}

/// Pretty JSON for human-readable probe output on stdout.
public func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONLines.makeEncoder(prettyPrinted: true)
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

/// Prints to stderr and exits; used for usage and I/O errors in probe executables.
public func exitWithError(_ message: String, code: ProbeExit = .usage) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code.rawValue)
}
