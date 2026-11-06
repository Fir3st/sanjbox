import Darwin
import Foundation
import SanjboxProbeKit

public func emitProvenanceJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value) + Data([10])
    FileHandle.standardOutput.write(data)
}

/// Explicit opt-in dispatch shared by counterpart and C1. No legacy encoder or CLI semantics change.
public enum ProvenanceCLI {
    public static func handles(_ arguments: [String]) -> Bool {
        arguments.first.map { ["provenance", "provenance-identity", "provenance-prepare"].contains($0) } ?? false
    }
    public static func run(_ arguments: [String], receiver: Bool,
                           operation: (NetworkJournal) throws -> Bool) -> Int32 {
        signal(SIGALRM, SIG_DFL)
        alarm(30) // Wall-clock watchdog also covers identity/signature and local filesystem calls.
        defer { alarm(0) }
        do {
            let command = arguments[0]
            if command == "provenance-prepare" {
                let args = try ProbeArguments(Array(arguments.dropFirst()), valueFlags: ["run-id"])
                guard args.positional.isEmpty, let run = UUID(uuidString: try args.required("run-id")) else { throw ProvenanceError("prepare requires --run-id UUID") }
                try emitProvenanceJSON(FlowChallenge.prepare(runID: run)); return 0
            }
            if command == "provenance-identity" {
                guard arguments.count == 1 else { throw ProvenanceError("identity takes no arguments") }
                // Discovery is explicit, self-only, names-free; not preregistration or an area attestation.
                let expectation = NetworkExpectation(schemaVersion: 1, scope: .hostDiagnostic,
                    identity: try OwnNetworkIdentity.capture(), signature: try OwnSignature.capture(), forbiddenAuditSessionIDs: [])
                try emitProvenanceJSON(expectation); return 0
            }
            var raw = Array(arguments.dropFirst())
            let apply = raw.contains("--apply")
            if apply { raw.remove(at: raw.firstIndex(of: "--apply")!) }
            let args = try ProbeArguments(raw, valueFlags: ["expect", "input"])
            guard args.positional.isEmpty else { throw ProvenanceError("unexpected positional argument") }
            let expectationData = try ProvenanceInputFile.read(args.required("expect"), kind: "expect")
            let expectation = try NetworkExpectation.decode(expectationData)
            // In apply, same-process identity/signature preflight is before ANY target-file read.
            let actual = try apply ? expectation.preflight() : nil
            let registrationData = try ProvenanceInputFile.read(args.required("input"), kind: "probe")
            let registration = try NetworkRegistration.decode(registrationData, receiver: receiver)
            guard registration.scope == expectation.scope else { throw ProvenanceError("scope mismatch") }
            if !apply {
                try emitProvenanceJSON(["status": "dryRun", "scope": registration.scope.rawValue,
                    "operation": receiver ? "exactBindReceiver" : "singleFlowSender", "network": "none", "verdict": "none"])
                return 0
            }
            let journal = try NetworkJournal(registration: registration, expectationData: expectationData,
                registrationData: registrationData, role: receiver ? "receiver" : "sender")
            var registered = journal.event("registered")
            registered.identity = actual; registered.signature = expectation.signature; registered.registration = registration
            registered.expectationSHA256 = provenanceDigest(expectationData); registered.registrationSHA256 = provenanceDigest(registrationData)
            try journal.append(registered) // durable before first socket
            let completed = try operation(journal)
            try emitProvenanceJSON(["status": completed ? "operationFinished" : "incompleteOperation", "output": journal.path,
                "verdict": "none; inspect independent raw, no isolation or capture-completeness claim"])
            return completed ? 0 : 3
        } catch {
            fputs("provenance refused/incomplete: \(error)\n", stderr)
            return 2
        }
    }
}
