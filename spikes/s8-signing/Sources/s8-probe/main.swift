import Darwin
import Dispatch
import Foundation
import S8Preparation
import SanjboxProbeKit

// A last-resort CLI wall deadline also covers synchronous Security/membership calls.
// It is not a framework cancellation mechanism or a proof of deadline enforcement by macOS.
DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
    FileHandle.standardError.write(Data("S8 preparation exceeded 45-second process deadline; preserve partial output\n".utf8))
    exit(124)
}

let usage = """
usage: s8-probe context
       s8-probe h1-fuzz --expect FILE [--iterations 1000] [--seed 21304]
       s8-probe mock --expect FILE [--iterations 1000] [--seed 21304]
       s8-probe experiments --expect FILE
       s8-probe service-workflow --expect FILE
       s8-probe prepare --expect FILE [--apply yes]
       s8-probe inspect --expect FILE --root OWN_FIXTURE_ROOT --fixture hardened|plain|unsigned|tampered
       s8-probe cleanup --expect FILE --root OWN_FIXTURE_ROOT [--apply yes]
All measurement commands verify complete preregistered identity first.
prepare/cleanup default to dry-run. No service registration, attach, TCC, accounts, or Keychain access.
"""

struct IdentityReport: Encodable {
    var kind = "identity"
    var context: ProbeContext
    var valid: Bool?
    var issues: [String]
    var candidateExpectation: S8Expectation?
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(code)
}

do {
    let argv = Array(CommandLine.arguments.dropFirst())
    guard let command = argv.first else { fail(usage) }
    let allowed: Set<String>
    switch command {
    case "context": allowed = []
    case "mock", "h1-fuzz": allowed = ["expect", "iterations", "seed"]
    case "experiments", "service-workflow": allowed = ["expect"]
    case "prepare": allowed = ["expect", "apply"]
    case "inspect": allowed = ["expect", "root", "fixture"]
    case "cleanup": allowed = ["expect", "root", "apply"]
    default: fail(usage)
    }
    var options: [String: String] = [:]
    var index = 1
    while index < argv.count {
        let flag = argv[index]
        guard flag.hasPrefix("--"), allowed.contains(String(flag.dropFirst(2))), index + 1 < argv.count,
              options[String(flag.dropFirst(2))] == nil else { fail("invalid or duplicate option\n" + usage) }
        options[String(flag.dropFirst(2))] = argv[index + 1]; index += 2
    }
    if let apply = options["apply"], apply != "yes" { fail("--apply accepts only yes") }
    let expected: S8Expectation?
    if command == "context" { expected = nil }
    else {
        guard let path = options["expect"], path.hasPrefix("/"), path.hasSuffix(".json") else { fail("explicit absolute synthetic expectation JSON required") }
        expected = try readExpectation(path)
    }
    let context = try captureIdentity(groups: Set((expected?.requiredGroups ?? []) + (expected?.forbiddenGroups ?? [])))
    let issues = (expected?.mismatches(in: context) ?? []) + selfSignatureIssues().map { "caller signing: " + $0 }
    try printJSON(IdentityReport(context: context, valid: expected.map { _ in issues.isEmpty }, issues: issues,
                                 candidateExpectation: command == "context" ? try? S8Expectation(candidate: context) : nil))
    if command == "context" { exit(issues.isEmpty ? 0 : 3) }
    guard issues.isEmpty else { exit(3) }
    switch command {
    case "h1-fuzz":
        guard let count = Int(options["iterations"] ?? "1000"), let seed = UInt64(options["seed"] ?? "21304") else { fail("invalid fuzz bound or seed") }
        let report = try H1Fuzzer.run(iterations: count, seed: seed)
        try printJSON(report)
        exit(report.succeeded ? 0 : 1)
    case "mock":
        guard let count = Int(options["iterations"] ?? "1000"), let seed = UInt64(options["seed"] ?? "21304") else { fail("invalid fuzz bound or seed") }
        let report = try MockFuzzer.run(iterations: count, seed: seed)
        try printJSON(report)
        exit(report.failures.isEmpty && report.unexpectedAccepts == 0 && report.positiveControls == 4 ? 0 : 1)
    case "experiments": try printJSON(ServiceExperiments.plans())
    case "service-workflow": try printJSON(SyntheticServiceWorkflows.plans())
    case "prepare":
        if options["apply"] != "yes" {
            try printJSON(["mode": "dry-run", "operation": "create fresh /private/tmp/sanjbox-s8-fixtures-UUID (0700), compile embedded C with xcrun clang -arch arm64 -O0, ad-hoc codesign -s - --timestamp=none; plain/hardened/unsigned/tampered; no execution", "cleanup": "s8-probe cleanup --expect FILE --root RETURNED_ROOT --apply yes"])
        } else { try printJSON(["mode": "applied-own-synthetic-fixtures", "root": SyntheticFixtures.prepare()]) }
    case "inspect":
        guard let root = options["root"], let fixture = options["fixture"] else { fail("root and fixture required") }
        let report = try SyntheticFixtures.inspect(root: root, name: fixture)
        try printJSON(report)
        exit(report.syntheticStaticPolicySatisfied ? 0 : 1)
    case "cleanup":
        guard let root = options["root"] else { fail("root required") }
        if options["apply"] != "yes" {
            try SyntheticFixtures.cleanup(root: root, apply: false)
            try printJSON(["mode": "dry-run", "operation": "validate owner, type, modes, names and hashes; unlink only plain, hardened, unsigned, tampered, fixture.c, manifest.json; rmdir exact empty root", "root": root])
        } else { try SyntheticFixtures.cleanup(root: root); try printJSON(["mode": "cleaned-own-fixtures", "root": root]) }
    default: fail(usage)
    }
} catch { fail("S8 refused: \(error)", code: 4) }
