import Foundation
import SanjboxContracts

public enum CLIError: Error, Equatable, Sendable {
    case usage
    case invalidInput
    case connectionLost
    case timeout
    case invalidReply
    case helperFailed(HelperFailureCode)

    public var diagnostic: String {
        switch self {
        case .usage: "invalid syntax; use sanjbox --help"
        case .invalidInput: "request rejected by H1 validation"
        case .connectionLost: "mock XPC connection lost; outcome unknown; request was not retried"
        case .timeout: "mock XPC deadline exceeded; outcome unknown; request was not retried"
        case .invalidReply: "mock helper reply rejected; outcome unknown; request was not retried"
        case .helperFailed(let code): "mock helper refused request: \(code.rawValue)"
        }
    }
    public var exitCode: Int32 {
        switch self {
        case .usage, .invalidInput: 64
        case .connectionLost, .timeout: 69
        case .invalidReply: 76
        case .helperFailed: 70
        }
    }
}

public enum CLICommand: Equatable, Sendable {
    case help
    case request(HelperMessage)

    public static let usage = """
    sanjbox --mock shell ZONE [--working-root ROOT] [--working-directory RELATIVE]
    sanjbox --mock run ZONE [--working-root ROOT] [--working-directory RELATIVE] --executable-root ROOT -- EXECUTABLE [ARG ...]
    sanjbox --mock pause ZONE
    sanjbox --mock snapshot ZONE SNAPSHOT --restore-unit UNIT
    sanjbox --mock rollback ZONE SNAPSHOT --restore-unit UNIT

    H3 prototype: real local XPC, in-memory mock only; no command execution or PTY.
    Fixture: zone a1b2; roots home/project/prefix/tools/cache/tmp; unit full-state;
    baseline snapshot. Each invocation starts a fresh fixture (snapshot: paused,
    rollback: stopped, otherwise: running). Working root defaults to project.
    Everything after run's -- is literal argv, starting with a relative executable.
    Exit 0 means accepted/completed mock request, never a child process exit status.
    """

    public static func parse(_ arguments: [String]) throws -> CLICommand {
        if arguments == ["--help"] { return .help }
        guard arguments.count >= 3, arguments[0] == "--mock" else { throw CLIError.usage }
        let verb = arguments[1], zone = arguments[2]
        let tail = Array(arguments.dropFirst(3))
        let request: HelperMessage
        switch verb {
        case "pause":
            guard tail.isEmpty else { throw CLIError.usage }
            request = .pauseZone(.init(zoneID: zone))
        case "shell", "run":
            let separator = tail.firstIndex(of: "--")
            if verb == "shell", separator != nil { throw CLIError.usage }
            if verb == "run", separator == nil { throw CLIError.usage }
            let options = try parseOptions(Array(tail.prefix(separator ?? tail.count)),
                allowed: verb == "run" ? ["--working-root", "--working-directory", "--executable-root"] : ["--working-root", "--working-directory"])
            let root = options["--working-root"] ?? "project"
            let directory = options["--working-directory"] ?? "."
            if verb == "shell" {
                request = .shell(.init(zoneID: zone, workingRootID: root, workingDirectory: directory))
            } else {
                guard let separator, let executableRoot = options["--executable-root"],
                      separator + 1 < tail.count else { throw CLIError.usage }
                request = .run(.init(zoneID: zone, workingRootID: root, workingDirectory: directory,
                                     executableRootID: executableRoot, executablePath: tail[separator + 1],
                                     arguments: Array(tail.dropFirst(separator + 2))))
            }
        case "snapshot", "rollback":
            guard let snapshot = tail.first else { throw CLIError.usage }
            let options = try parseOptions(Array(tail.dropFirst()), allowed: ["--restore-unit"])
            guard let unit = options["--restore-unit"] else { throw CLIError.usage }
            let body = SnapshotRequest(zoneID: zone, snapshotID: snapshot, rollbackUnitID: unit)
            request = verb == "snapshot" ? .snapshot(body) : .rollback(body)
        default: throw CLIError.usage
        }
        do { try request.validate() } catch { throw CLIError.invalidInput }
        return .request(request)
    }

    private static func parseOptions(_ words: [String], allowed: Set<String>) throws -> [String: String] {
        guard words.count.isMultiple(of: 2) else { throw CLIError.usage }
        var result: [String: String] = [:]
        for index in stride(from: 0, to: words.count, by: 2) {
            let key = words[index]
            guard allowed.contains(key), result[key] == nil else { throw CLIError.usage }
            result[key] = words[index + 1]
        }
        return result
    }
}
