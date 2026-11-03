import Darwin
import Foundation
import SanjboxProbeKit

public struct CommandResult {
    public let output: Data
    public let exitCode: Int32
}

public enum HostAuditCommand {
    public static let usage = """
    usage: sanjbox-host-audit --expect ABS.s4-expect.json --config ABS.s4-config.json [--baseline ABS.s4-report.json]
    Read-only metadata audit. No default roots, contents, permission changes, shell commands or output files.
    Exit 0: requested bounded metadata coverage complete; 4: coverage gaps; 3: invalid identity/session; 2: invalid input/I/O.
    Neither exit 0 nor unchanged drift proves effective access or isolation.
    """

    public static func run(_ arguments: [String]) throws -> CommandResult {
        try run(arguments, capture: { ProbeContext.capture(groupsOfInterest: $0) })
    }

    static func run(_ arguments: [String], capture: (Set<UInt32>) -> ProbeContext) throws -> CommandResult {
        if arguments == ["--help"] { return .init(output: Data((usage + "\n").utf8), exitCode: 0) }
        var options: [String: String] = [:]
        var pending = arguments[...]
        while let flag = pending.popFirst() {
            guard ["--expect", "--config", "--baseline"].contains(flag), options[flag] == nil,
                  let value = pending.popFirst() else { throw AuditFailure(usage) }
            options[flag] = value
        }
        guard let expectationPath = options["--expect"], let configPath = options["--config"] else { throw AuditFailure(usage) }
        // The only pre-measurement input is this owned expectation. No roots/config/baseline are read yet.
        let input: IdentityInput = try decodeOwned(expectationPath, suffix: ".s4-expect.json", limit: 64 * 1024)
        try input.validate()
        let context = capture(input.expectation.groupsOfInterest)
        var mismatches = input.expectation.mismatches(in: context).map { IdentityMismatch(field: $0.field, expected: $0.expected, actual: $0.actual) }
        if context.audit?.sessionID != input.auditSessionID {
            mismatches.append(.init(field: "auditSessionID", expected: String(input.auditSessionID), actual: context.audit.map { String($0.sessionID) } ?? "none"))
        }
        let identity = IdentityReport(context: context, mismatches: mismatches, valid: mismatches.isEmpty)
        guard identity.valid else { return .init(output: try encode(identity), exitCode: 3) }
        let config: Configuration = try decodeOwned(configPath, suffix: ".s4-config.json", limit: 64 * 1024)
        try config.validate()
        var baseline: Snapshot?
        if let path = options["--baseline"] {
            baseline = try decodeOwned(path, suffix: ".s4-report.json", limit: maximumReportBytes)
            try baseline?.validateBaseline()
        }
        let roots = Scanner(configuration: config).scan()
        let snapshot = Snapshot(generatedAt: ISO8601DateFormatter().string(from: Date()), identity: identity,
                                configuration: config, roots: roots, drift: compare(roots, configuration: config, baseline: baseline))
        let data = try encode(snapshot)
        guard data.count <= maximumReportBytes else { throw AuditFailure("report exceeded 32 MiB hard limit; reduce maxEntries") }
        return .init(output: data, exitCode: roots.allSatisfy(\.metadataComplete) ? 0 : 4)
    }
}

private func decodeOwned<T: Decodable>(_ path: String, suffix: String, limit: Int) throws -> T {
    let data = try readOwnedInput(path, suffix: suffix, limit: limit)
    do { return try JSONDecoder().decode(T.self, from: data) }
    catch { throw AuditFailure("invalid schema input; JSON must match the documented schema") }
}

func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(value)
    data.append(10)
    return data
}
