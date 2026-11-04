import Foundation
import SanjboxProbeKit

public enum StateRecoveryCommand {
    public static let usage = """
    usage: sanjbox-state-recovery mock-demo --expect ABS.state-expect.json --manifest ABS.state-manifest.json [--dry-run | --apply]
    Default dry-run: identity and offline manifest validation only, no writes.
    --apply: exclusively create a private synthetic fixture, snapshot JSON canaries, change canaries,
    reconstruct new JSON images, switch mock selectors sequentially, verify, then remove only that fixture.
    No APFS, mount, user, system, process-lifecycle, real-start, or privileged operations exist.
    Exit 0: preview or successful mock; 2: usage/schema/I/O; 3: identity mismatch; 4: recovery refused.
    """

    public static func run(_ arguments: [String]) throws -> ValidationCommandResult {
        try run(arguments, capture: { ProbeContext.capture(groupsOfInterest: $0) })
    }
    static func run(_ arguments: [String], capture: (Set<UInt32>) -> ProbeContext) throws -> ValidationCommandResult {
        if arguments == ["--help"] { return .init(data: Data((usage + "\n").utf8), exitCode: 0) }
        var rest = arguments[...]
        guard rest.popFirst() == "mock-demo" else { throw RecoveryFailure(usage) }
        var options: [String: String] = [:], switches = Set<String>()
        while let flag = rest.popFirst() {
            if ["--dry-run", "--apply"].contains(flag) {
                guard switches.insert(flag).inserted else { throw RecoveryFailure(usage) }
            } else {
                guard ["--expect", "--manifest"].contains(flag), options[flag] == nil, let value = rest.popFirst() else { throw RecoveryFailure(usage) }
                options[flag] = value
            }
        }
        guard let expectPath = options["--expect"], let manifestPath = options["--manifest"], switches.count <= 1 else { throw RecoveryFailure(usage) }
        let expected = try decodeExpectation(ownedSchemaData(at: expectPath, suffix: ".state-expect.json", maximumBytes: 32 * 1024))
        try expected.requireComplete()
        let context = capture(expected.expectation.groupsOfInterest)
        var mismatch = expected.expectation.mismatches(in: context).map(\.field)
        if context.audit?.sessionID != expected.auditSessionID { mismatch.append("auditSessionID") }
        let identity = ContextCheck(context: context, mismatchFields: mismatch, valid: mismatch.isEmpty)
        guard identity.valid else { return .init(data: try recoveryEncode(identity), exitCode: 3) }
        let manifest = try decodeManifest(ownedSchemaData(at: manifestPath, suffix: ".state-manifest.json", maximumBytes: 256 * 1024))
        guard Validator().validate(manifest).consistentDesign else { throw RecoveryFailure("inconsistent B3 manifest") }
        guard switches.contains("--apply") else {
            return .init(data: try recoveryEncode(RecoveryInspection(phase: "dry-run", records: 0, mockStartAllowed: false,
                                                                    reason: "No writes; --apply runs only a generated synthetic fixture for all declared volumes")), exitCode: 0)
        }
        let store = try RecoveryStore.create(manifest: manifest)
        do {
            let backend = FileBackedRecoveryMock(store: store)
            try backend.initialize()
            let coordinator = RecoveryCoordinator(store: store, backend: backend)
            try coordinator.takeSnapshot()
            try backend.simulateChanges()
            try coordinator.rollback()
            let result = coordinator.inspect()
            guard result.mockStartAllowed else { throw RecoveryFailure(result.reason) }
            try store.cleanup()
            return .init(data: try recoveryEncode(result), exitCode: 0)
        } catch {
            // Retain the exact failed fixture for inspection; never erase an incomplete recovery record.
            let result = RecoveryInspection(phase: "denied", records: 0, mockStartAllowed: false,
                                            reason: "\(error); retained synthetic fixture: \(store.path)")
            return .init(data: try recoveryEncode(result), exitCode: 4)
        }
    }
}
