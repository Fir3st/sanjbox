import Darwin
import Foundation
import SanjboxProbeKit

public enum BoundaryProbe: String, CaseIterable, Sendable {
    case xpc, tcc, capture, hostRead = "host-read", ingress, signing, lifecycle
    var plan: [String: String] {
        switch self {
        case .hostRead:
            ["implemented": "own UUID directory; fresh read positive/permission-denied controls; verified cleanup",
             "changes": "create 0700 /private/tmp/sanjbox-a4-fixture-UUID and two <=1024-byte synthetic files; unlink only verified own fixtures",
             "missing": "host/other-UID protected roots, write/hardlink boundaries and service metadata"]
        case .ingress:
            ["implemented": "two own IPv4 loopback sockets, exact canary round trip; 2-second I/O deadline",
             "changes": "temporary 127.0.0.1:ephemeral TCP listener and own client; close every socket",
             "missing": "wildcard ingress, host/LAN/other-area reachability, IPv6 and port squatting"]
        case .xpc:
            ["implemented": "own embedded service/client; exact OS signing requirement plus connection EUID/EGID/ASID",
             "changes": "activate only bundled fixture service; bounded own record and fixed watchdog exit",
             "missing": "full peer audit token/auditUID, global inventory, cross-UID/session boundary; explicit bundle/run/hash preregistration required"]
        case .lifecycle:
            ["implemented": "one fixed /bin/cat child, exact stdin/stdout canary, EOF and exclusive waitpid; 2-second I/O deadline",
             "changes": "spawn/reap own child with sanitized environment; timeout signals only its unreaped PID",
             "missing": "whole-UID stop/pause, start exclusion, launchd/cron/at/login items, fork race and crash recovery"]
        case .signing:
            ["implemented": "validate own running code signature and observe runtime flag/forbidden entitlement presence",
             "changes": "none; no code signing, identity enumeration, Keychain or certificate output",
             "missing": "TCC persistence, signed-agent attach protection, Personal Team/SMAppService (S8)"]
        case .tcc:
            ["implemented": "none; identity-gated unavailable result",
             "changes": "none; no TCC preflight, prompt, grant, database or protected-device API",
             "missing": "AX, Screen Recording, Input Monitoring, microphone, camera, Bluetooth, AppleEvents, notifications"]
        case .capture:
            ["implemented": "none; identity-gated unavailable result",
             "changes": "none; no window list, capture, clipboard, event posting or Accessibility",
             "missing": "synthetic per-session windows/clipboard, SCK/CGWindowList, event/AX cross-session oracles"]
        }
    }
}

struct BoundaryReport: Encodable {
    enum Status: String, Encodable {
        case dryRun, fixturePassed, fixtureFailed, invalidMeasurement, cleanupRefused, notImplemented, usageError
        var exitCode: Int32 {
            switch self {
            case .dryRun, .fixturePassed: 0
            case .fixtureFailed: 1
            case .usageError: 2
            case .invalidMeasurement: 3
            case .cleanupRefused: 4
            case .notImplemented: 5
            }
        }
    }
    let schemaVersion = 1
    let acceptanceEvidence = false
    let scope = "synthetic-self-fixture"
    let probe: String
    let status: Status
    let context: ProbeContext?
    let mismatches: [String]
    let details: [String: String]
}

public enum BoundaryCLI {
    public static func main(probe: BoundaryProbe) {
        let report = evaluate(probe: probe, arguments: Array(CommandLine.arguments.dropFirst()))
        do { try printJSON(report) } catch { exit(2) }
        exit(report.status.exitCode)
    }

    /// Dependency injection is internal for fixture tests; there is no CLI bypass/mock-identity flag.
    static func evaluate(
        probe: BoundaryProbe, arguments: [String],
        capture: (Set<UInt32>) throws -> ProbeContext = ContextCollector.capture,
        validateSignature: () throws -> Bool = { try SigningSelf.observe().policyMatches },
        perform: ((BoundaryProbe) throws -> (BoundaryReport.Status, [String: String]))? = nil
    ) -> BoundaryReport {
        func report(_ status: BoundaryReport.Status, _ details: [String: String],
                    context: ProbeContext? = nil, mismatches: [String] = []) -> BoundaryReport {
            BoundaryReport(probe: probe.rawValue + "-probe", status: status, context: context, mismatches: mismatches, details: details)
        }
        // No filesystem inputs exist. Parse only bounded argv/inline expectation before identity.
        guard arguments.count <= 3 else { return report(.usageError, ["error": "usage: [--dry-run] or --apply --expect-json JSON"]) }
        if arguments.isEmpty || arguments == ["--dry-run"] { return report(.dryRun, probe.plan) }
        guard arguments.count == 3, arguments[0] == "--apply", arguments[1] == "--expect-json" else {
            return report(.usageError, ["error": "usage: [--dry-run] or --apply --expect-json JSON; paths/PIDs/services are not accepted"])
        }
        let expected: BoundaryExpectation
        do { expected = try BoundaryExpectation.parse(arguments[2]) }
        catch { return report(.invalidMeasurement, ["error": "malformed or incomplete expectation; no probe interaction performed"]) }
        let context: ProbeContext
        do { context = try capture(expected.groupsOfInterest) }
        catch { return report(.invalidMeasurement, ["error": "identity collection failed; no probe interaction performed"]) }
        let mismatches = expected.mismatches(context)
        guard mismatches.isEmpty else {
            return report(.invalidMeasurement, ["error": "identity mismatch; no probe interaction performed"], context: context, mismatches: mismatches)
        }
        do {
            // Signing itself reports the observed profile; unavailable probes have no interaction.
            // Every other active CLI requires the GUIDE profile before creating any fixture.
            if probe != .signing && probe != .tcc && probe != .capture {
                guard try validateSignature() else {
                    return report(.invalidMeasurement, ["error": "own signature requires hardened runtime and no get-task-allow; no probe interaction performed"], context: context)
                }
            }
            let (status, details) = try perform?(probe) ?? Self.perform(probe, expected: expected)
            return report(status, details, context: context)
        } catch let failure as XPCObservedFailure {
            return report(.fixtureFailed, failure.details, context: context)
        } catch BoundaryError.conflict(let error) {
            return report(.cleanupRefused, ["error": error, "action": "preserve changed fixture; manual review, no blind recursive delete"], context: context)
        } catch {
            return report(.invalidMeasurement, ["error": String(describing: error)], context: context)
        }
    }

    private static func perform(_ probe: BoundaryProbe, expected: BoundaryExpectation) throws -> (BoundaryReport.Status, [String: String]) {
        switch probe {
        case .tcc, .capture: return (.notImplemented, probe.plan)
        case .xpc: return (.fixturePassed, try XPCFixture.run(expected: expected))
        case .ingress: return (.fixturePassed, try LoopbackFixture.run())
        case .signing:
            let observation = try SigningSelf.observe()
            return (observation.policyMatches ? .fixturePassed : .fixtureFailed,
                    ["hardenedRuntime": "\(observation.hardenedRuntime)",
                     "forbiddenEntitlementPresent": "\(observation.forbiddenEntitlementPresent)",
                     "scope": "own executable metadata only; no TCC or S8 verdict"])
        case .lifecycle:
            let canary = Data(("SANJBOX-CANARY-A4-" + UUID().uuidString).utf8)
            let result = try FixedChild.run(.echo, input: canary)
            guard result.data == canary else { throw BoundaryError.invalid("owned child positive control mismatch") }
            return (.fixturePassed, ["positiveControl": "exact canary echoed by own fixed child", "ownedChildReaped": "true",
                                     "scope": "EOF exit of one child; no whole-UID stop or restart exclusion"])
        case .hostRead:
            let fixture = try OwnedFixture()
            do {
                let canary = Data(("SANJBOX-CANARY-A4-" + UUID().uuidString).utf8)
                try fixture.create(.control, bytes: canary, mode: 0o600)
                try fixture.create(.denied, bytes: canary, mode: 0)
                guard try fixture.read(.control) == canary else { throw BoundaryError.invalid("file positive control failed") }
                var denied = false
                do { _ = try fixture.read(.denied) }
                catch let error as OwnedFixture.OpenFailure {
                    guard [EACCES, EPERM].contains(error.errno) else { throw BoundaryError.invalid("file denial is not a permission error") }
                    denied = true
                }
                guard try fixture.read(.control) == canary else { throw BoundaryError.invalid("file post-denial control failed") }
                try fixture.cleanup()
                return (denied ? .fixturePassed : .fixtureFailed,
                        ["positiveControls": "fresh control file opens before and after denial", "permissionDenied": "\(denied)",
                         "cleanup": "verified own files and UUID directory removed", "scope": "same-UID mode 000 fixture only; owner can chmod it"])
            } catch {
                try fixture.cleanup()
                throw error
            }
        }
    }
}
