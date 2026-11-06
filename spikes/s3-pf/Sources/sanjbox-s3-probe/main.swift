import C1ProbeKit
import SanjboxNetworkProvenance
import Foundation
import SanjboxProbeKit

let provenanceArguments = Array(CommandLine.arguments.dropFirst())
if ProvenanceCLI.handles(provenanceArguments) {
    exit(ProvenanceCLI.run(provenanceArguments, receiver: false, operation: ProvenanceSender.run))
}

let usage = "usage: sanjbox-s3-probe --input FILE --expect FILE [--apply] (default: dry-run, no identity/network capture)"
var raw = Array(CommandLine.arguments.dropFirst())
let apply = raw.contains("--apply")
if apply { raw.remove(at: raw.firstIndex(of: "--apply")!) }

do {
    let args = try ProbeArguments(raw, valueFlags: ["input", "expect"])
    guard args.positional.isEmpty else { throw ProbeError.invalidInput }
    let expectation = try JSONDecoder().decode(C1Expectation.self, from: InputFile.read(args.required("expect"), kind: "expect"))
    try C1Probe.validateExpectation(expectation)
    if !apply {
        let input = try JSONDecoder().decode(ProbeInput.self, from: InputFile.read(args.required("input"), kind: "probe"))
        try input.validate()
        print("DRY-RUN: will verify same-process UID/GID/groups/audit/Aqua context before any socket; would send \(input.sendCount) bounded synthetic \(input.transport) canaries to literal \(input.address):\(input.port). No measurement or verdict.")
        exit(0)
    }
    // First measurement action: the common identity check, in this sending process.
    let context = ProbeContext.capture(groupsOfInterest: expectation.identity.groupsOfInterest)
    let mismatches = expectation.identity.mismatches(in: context)
    let matched = C1Probe.matches(expectation, context)
    let credentials = RunRecord(probe: "sanjbox-s3-probe.identity", caseID: nil,
                                outcome: matched ? .passed : .invalidMeasurement,
                                context: context, mismatches: mismatches, details: ["expectedAuditSessionID": "\(expectation.auditSessionID)", "actualAuditSessionID": context.audit.map { "\($0.sessionID)" } ?? "missing"])
    try printJSON(credentials)
    guard matched else { exit(ProbeExit.invalidMeasurement.rawValue) }
    // Probe config/target is read only after the credentials check passed.
    let input = try C1Probe.validatedInput(expectation: expectation, context: context) {
        try JSONDecoder().decode(ProbeInput.self, from: InputFile.read(args.required("input"), kind: "probe"))
    }
    do {
        let bytes = try C1Probe.run(input: input, expectation: expectation, context: context, send: sendCanary)
        try printJSON(RunRecord(probe: "sanjbox-s3-probe.send", caseID: input.caseID, outcome: .unclear,
                                context: context, details: ["localKernelAcceptedBytes": "\(bytes)", "verdict": "external oracle required"]))
    } catch {
        try printJSON(RunRecord(probe: "sanjbox-s3-probe.send", caseID: input.caseID, outcome: .unclear,
                                context: context, details: ["clientError": "\(error)", "verdict": "client failure is not proof of isolation"]))
    }
} catch {
    exitWithError("\(error)\n\(usage)")
}
