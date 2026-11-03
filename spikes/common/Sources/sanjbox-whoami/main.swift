import Foundation
import SanjboxProbeKit

// sanjbox-whoami — reports the credentials and session this process runs with and, with
// --expect, decides whether a measurement taken in this context is valid.

let usage = """
    usage: sanjbox-whoami [--expect FILE] [--log FILE] [--case ID]
      --expect FILE  ProbeExpectation JSON written before the run; mismatch exits with 3
      --log FILE     append a RunRecord line (JSON Lines) to FILE
      --case ID      test case ID from COVERAGE.md recorded in the log
    """

struct Report: Encodable {
    var context: ProbeContext
    var mismatches: [Mismatch]
    /// nil when no expectation was given: the context is reported but not judged.
    var valid: Bool?
}

let arguments: ProbeArguments
do {
    arguments = try ProbeArguments(Array(CommandLine.arguments.dropFirst()), valueFlags: ["expect", "log", "case"])
} catch {
    exitWithError("\(error)\n\(usage)")
}
guard arguments.positional.isEmpty else { exitWithError(usage) }

var expectation: ProbeExpectation?
if let path = arguments.options["expect"] {
    do {
        expectation = try JSONLines.decoder.decode(ProbeExpectation.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        exitWithError("cannot read expectation \(path): \(error)")
    }
}

let context = ProbeContext.capture(groupsOfInterest: expectation?.groupsOfInterest ?? [])
let mismatches = expectation?.mismatches(in: context) ?? []
let report = Report(context: context, mismatches: mismatches, valid: expectation.map { _ in mismatches.isEmpty })

if let logPath = arguments.options["log"] {
    let record = RunRecord(
        probe: "sanjbox-whoami",
        caseID: arguments.options["case"],
        outcome: mismatches.isEmpty ? .passed : .invalidMeasurement,
        context: context,
        mismatches: mismatches
    )
    do { try JSONLines.append(record, to: URL(fileURLWithPath: logPath)) } catch {
        exitWithError("cannot append to \(logPath): \(error)")
    }
}

do { try printJSON(report) } catch { exitWithError("cannot encode report: \(error)") }
exit(report.valid == false ? ProbeExit.invalidMeasurement.rawValue : ProbeExit.ok.rawValue)
