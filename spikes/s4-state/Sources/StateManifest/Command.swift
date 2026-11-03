import Foundation
import SanjboxProbeKit

struct ExpectedContext: Codable {
    var schema: String
    var expectation: ProbeExpectation
    var auditSessionID: Int32

    func requireComplete() throws {
        guard schema == "sanjbox.state-expect.v1", expectation.realUID != nil, expectation.realGID != nil,
              expectation.effectiveGID != nil, expectation.requiredGroups != nil, expectation.forbiddenGroups != nil,
              expectation.launchdManagerName != nil, expectation.launchdManagerUID != nil else {
            throw ManifestError("expectation requires real/effective UID/GID, both group lists, launchd manager and audit session")
        }
    }
}

struct ContextCheck: Encodable {
    var context: ProbeContext
    var mismatchFields: [String]
    var valid: Bool
    let purpose = "validator identity only; not an observation or oracle of declared filesystem topology"
}

struct CommandReport: Encodable {
    var identity: ContextCheck
    var validation: ValidationReport?
}

public struct ValidationCommandResult {
    public var data: Data
    public var exitCode: Int32
}

public enum StateManifestCommand {
    public static let usage = """
    usage: sanjbox-state-manifest --expect ABS.state-expect.json --manifest ABS.state-manifest.json
    Offline design validation only. No declared path is inspected; no output file, disk, mount or snapshot is created.
    Exit 0: consistent declaration (not verified); 1: inconsistent declaration; 2: schema/I/O; 3: identity/session mismatch.
    """

    public static func run(_ arguments: [String]) throws -> ValidationCommandResult {
        try run(arguments, capture: { ProbeContext.capture(groupsOfInterest: $0) })
    }

    static func run(_ arguments: [String], capture: (Set<UInt32>) -> ProbeContext) throws -> ValidationCommandResult {
        if arguments == ["--help"] { return .init(data: Data((usage + "\n").utf8), exitCode: 0) }
        var options: [String: String] = [:]
        var remainder = arguments[...]
        while let flag = remainder.popFirst() {
            guard ["--expect", "--manifest"].contains(flag), options[flag] == nil, let value = remainder.popFirst() else { throw ManifestError(usage) }
            options[flag] = value
        }
        guard let expectationPath = options["--expect"], let manifestPath = options["--manifest"] else { throw ManifestError(usage) }
        let expected = try decodeExpectation(ownedSchemaData(at: expectationPath, suffix: ".state-expect.json", maximumBytes: 32 * 1024))
        try expected.requireComplete()
        let context = capture(expected.expectation.groupsOfInterest)
        var mismatches = expected.expectation.mismatches(in: context).map(\.field)
        if context.audit?.sessionID != expected.auditSessionID { mismatches.append("auditSessionID") }
        let identity = ContextCheck(context: context, mismatchFields: mismatches, valid: mismatches.isEmpty)
        if !identity.valid { return try result(CommandReport(identity: identity, validation: nil), code: 3) }
        // No manifest schema or declared path is processed until the identity preflight succeeds.
        let input = try ownedSchemaData(at: manifestPath, suffix: ".state-manifest.json", maximumBytes: 256 * 1024)
        let manifest = try decodeManifest(input)
        let validation = Validator().validate(manifest)
        return try result(CommandReport(identity: identity, validation: validation), code: validation.consistentDesign ? 0 : 1)
    }
}

private func result<T: Encodable>(_ object: T, code: Int32) throws -> ValidationCommandResult {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(object)
    guard data.count <= 1024 * 1024 else { throw ManifestError("validation output exceeds 1 MiB limit") }
    data.append(10)
    return .init(data: data, exitCode: code)
}
