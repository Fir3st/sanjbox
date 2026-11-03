import Foundation
import S1Probe
import SanjboxProbeKit

// sanjbox-s1-probe — runs inside a compartment's session and reports what the session offers
// (S1, WP1.A1). The credential check comes first; a mismatch ends the run as invalid.

let usage = """
    usage:
      sanjbox-s1-probe measure [--expect FILE] [--log FILE] [--case ID] [--render-seconds N]
                               [--request-screen-capture]
      sanjbox-s1-probe context
    measure prints one S1Measurement JSON line; --log also appends it to FILE.
      --render-seconds N        on-screen presentation length, default 5
      --request-screen-capture  show the Screen Recording prompt for the responsible app (GUI-10)
    context prints the credentials and session of this process (e.g. the host console session ID).
    exit codes: 0 measured, 3 invalid measurement (context differs from --expect), 2 usage or I/O error
    """

let rawArguments = Array(CommandLine.arguments.dropFirst())
guard let command = rawArguments.first else { exitWithError(usage) }

let arguments: ProbeArguments
do {
    arguments = try ProbeArguments(
        Array(rawArguments.dropFirst()).filter { $0 != "--request-screen-capture" },
        valueFlags: ["expect", "log", "case", "render-seconds"]
    )
} catch {
    exitWithError("\(error)\n\(usage)")
}
guard arguments.positional.isEmpty else { exitWithError(usage) }

@MainActor
func measure(_ arguments: ProbeArguments, requestScreenCapture: Bool) -> Never {
    var expectation: ProbeExpectation?
    if let path = arguments.options["expect"] {
        do {
            expectation = try JSONLines.decoder.decode(ProbeExpectation.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            exitWithError("cannot read expectation \(path): \(error)")
        }
    }
    let renderSeconds = arguments.options["render-seconds"].map { Double($0) } ?? 5
    guard let renderSeconds, renderSeconds > 0 else { exitWithError("invalid --render-seconds\n\(usage)") }

    let context = ProbeContext.capture(groupsOfInterest: expectation?.groupsOfInterest ?? [])
    let mismatches = expectation?.mismatches(in: context) ?? []
    var record = S1Measurement(
        caseID: arguments.options["case"], context: context, mismatches: mismatches,
        valid: expectation.map { _ in mismatches.isEmpty }
    )

    if record.valid != false {
        // Memory first: it describes the session, not the session plus this probe's workloads.
        record.uidProcesses = UIDProcesses.capture()
        record.displays = DisplayInfo.online()
        record.metalDevices = MetalDeviceInfo.all()
        do { record.offscreen = try OffscreenWorkload.run() } catch { record.errors["offscreen"] = "\(error)" }
        do { record.presentation = try Presentation.run(seconds: renderSeconds) } catch {
            record.errors["presentation"] = "\(error)"
        }
        record.screenCapture = ScreenCaptureAccess.check(request: requestScreenCapture)
    }

    do {
        let line = String(decoding: try JSONLines.encoder.encode(record), as: UTF8.self)
        print(line)
        if let path = arguments.options["log"] { try JSONLines.append(record, to: URL(fileURLWithPath: path)) }
    } catch {
        exitWithError("cannot write measurement: \(error)")
    }
    exit(record.valid == false ? ProbeExit.invalidMeasurement.rawValue : ProbeExit.ok.rawValue)
}

switch command {
case "measure":
    measure(arguments, requestScreenCapture: rawArguments.contains("--request-screen-capture"))
case "context":
    do { try printJSON(ProbeContext.capture()) } catch { exitWithError("cannot encode context: \(error)") }
default:
    exitWithError(usage)
}
