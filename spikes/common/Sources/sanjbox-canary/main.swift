import Foundation
import SanjboxProbeKit

// sanjbox-canary — creates synthetic canaries, finds them in captured data and removes them.

let usage = """
    usage:
      sanjbox-canary create  --label LABEL --dir DIR --registry FILE
      sanjbox-canary scan    --registry FILE [INPUT ...]   (no INPUT: read stdin)
      sanjbox-canary cleanup --registry FILE
    exit codes: 0 ok / nothing found, 1 canary found, 2 usage or I/O error, 4 cleanup refused something
    """

let rawArguments = Array(CommandLine.arguments.dropFirst())
guard let command = rawArguments.first else { exitWithError(usage) }

let arguments: ProbeArguments
do {
    arguments = try ProbeArguments(Array(rawArguments.dropFirst()), valueFlags: ["label", "dir", "registry"])
} catch {
    exitWithError("\(error)\n\(usage)")
}

func registryURL(_ arguments: ProbeArguments) -> URL {
    do { return URL(fileURLWithPath: try arguments.required("registry")) } catch { exitWithError("\(error)\n\(usage)") }
}

func loadRegistry(_ arguments: ProbeArguments) -> [Canary] {
    let url = registryURL(arguments)
    do { return try JSONLines.read(Canary.self, from: url) } catch {
        exitWithError("cannot read registry \(url.path): \(error)")
    }
}

switch command {
case "create":
    do {
        let directory = URL(fileURLWithPath: try arguments.required("dir"), isDirectory: true)
        let canary = try Canary.make(label: try arguments.required("label")).written(to: directory)
        try JSONLines.append(canary, to: registryURL(arguments))
        print(canary.path ?? "")
    } catch {
        exitWithError("create failed: \(error)")
    }

case "scan":
    let scanner = CanaryScanner(canaries: loadRegistry(arguments))
    let inputs = arguments.positional.isEmpty ? ["-"] : arguments.positional
    var findings: [String: [CanaryScanner.Finding]] = [:]
    for input in inputs {
        let data: Data
        do {
            data = input == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(fileURLWithPath: input))
        } catch {
            exitWithError("cannot read \(input): \(error)")
        }
        let found = scanner.findings(in: data)
        if !found.isEmpty { findings[input] = found }
    }
    do { try printJSON(findings) } catch { exitWithError("cannot encode findings: \(error)") }
    exit(findings.isEmpty ? ProbeExit.ok.rawValue : ProbeExit.finding.rawValue)

case "cleanup":
    var refused = false
    for canary in loadRegistry(arguments) {
        let result = canary.removeFile()
        if case .refused = result { refused = true }
        print("\(canary.label)\t\(canary.path ?? "-")\t\(result)")
    }
    exit(refused ? ProbeExit.refused.rawValue : ProbeExit.ok.rawValue)

default:
    exitWithError(usage)
}
