import Darwin
import Foundation
import S1Instrumentation

@main struct InstrumentCLI {
    @MainActor static func main() {
        do { exit(try run(Array(CommandLine.arguments.dropFirst()))) }
        catch { fputs("s1-instrument: \(error)\n", stderr); exit(2) }
    }
    @MainActor static func run(_ args: [String]) throws -> Int32 {
        let usage = """
        sanjbox-s1-instrument record --plan-json JSON --expect-json JSON [--apply]
        sanjbox-s1-instrument offscreen --run-id ID --expect-json JSON [--apply]
        sanjbox-s1-instrument plan --plan-json JSON
        sanjbox-s1-instrument evaluate --fixture NAME --run-id ID [--apply]
        Default is dry-run: no measurements, GUI, files, or fixture reads.
        evaluate reads only /private/tmp/sanjbox-a2-fixture-<your-uid>-<NAME>.json.
        plan/record JSON schema and manual same-Mac coordination: INSTRUMENTATION.md.
        """
        guard let command = args.first else { print(usage); return 0 }
        if command == "--help" { print(usage); return 0 }
        guard ["record", "plan", "evaluate", "offscreen"].contains(command), args.count <= 10 else { throw InstrumentError("unsupported command or argument count") }
        var options: [String: String] = [:]
        var apply = false
        var index = 1
        while index < args.count {
            let key = args[index]
            if key == "--apply" {
                guard !apply else { throw InstrumentError("duplicate --apply") }; apply = true; index += 1; continue
            }
            guard ["--plan-json", "--expect-json", "--fixture", "--run-id"].contains(key), options[key] == nil, index + 1 < args.count else { throw InstrumentError("unknown, missing or duplicate option") }
            let value = args[index + 1]
            guard value.utf8.count <= 16_384 else { throw InstrumentError("option exceeds 16 KiB") }
            options[key] = value; index += 2
        }
        let allowed: Set<String> = command == "record" ? ["--plan-json", "--expect-json"] : command == "plan" ? ["--plan-json"] : command == "offscreen" ? ["--run-id", "--expect-json"] : ["--fixture", "--run-id"]
        guard Set(options.keys) == allowed && !(command == "plan" && apply) else { throw InstrumentError("command requires exactly its documented options") }
        if command == "evaluate" {
            guard safeID(options["--fixture"]!), safeID(options["--run-id"]!) else { throw InstrumentError("invalid run or fixture ID") }
            if !apply { print("dry-run: evaluate staged own fixture \(options["--fixture"]!) into new report dataset \(options["--run-id"]!); no input read"); return 0 }
            let data = try Dataset.readFixture(name: options["--fixture"]!)
            let bundle = try StrictJSON.decode(EvidenceBundle.self, from: data)
            let report = try Analyzer.evaluate(bundle)
            let dataset = try Dataset(runID: options["--run-id"]!, role: "report")
            try dataset.write("report.json", report)
            print(dataset.path)
            return report.analyses.allSatisfy(\.evidenceComplete) ? 0 : 3
        }
        if command == "offscreen" {
            guard safeID(options["--run-id"]!) else { throw InstrumentError("invalid run ID") }
            let expected = try decodeExpectation(options["--expect-json"]!)
            if !apply { print("dry-run: one serial fixed offscreen workload; operator must ensure no other heavy job; new dataset \(options["--run-id"]!)"); return 0 }
            let result = try InstrumentRunner.offscreen(runID: options["--run-id"]!, expected: expected)
            print(result.path); return result.valid ? 0 : 3
        }
        let planData = Data(options["--plan-json"]!.utf8)
        try StrictJSON.validate(planData)
        try keys(planData, expected: ["runID", "profile", "kind", "start", "phases"])
        if let object = try JSONSerialization.jsonObject(with: planData) as? [String: Any], let phases = object["phases"] as? [[String: Any]] {
            for phase in phases where Set(phase.keys) != ["name", "seconds"] { throw InstrumentError("unknown phase fields") }
        }
        let plan = try StrictJSON.decode(Plan.self, from: planData); try plan.validate()
        if command == "plan" { print(String(decoding: try encoded(plan), as: UTF8.self)); return 0 }
        let expectation = try decodeExpectation(options["--expect-json"]!)
        if !apply {
            print("dry-run: identity-gated \(plan.kind.rawValue), \(plan.profile.rawValue), start \(plan.start), end \(plan.end); new per-UID dataset for \(plan.runID); no measurement or GUI")
            return 0
        }
        let result = try InstrumentRunner.record(plan: plan, expected: expectation)
        print(result.path)
        return result.valid ? 0 : 3
    }
    static func decodeExpectation(_ text: String) throws -> IdentityExpectation {
        let data = Data(text.utf8)
        try StrictJSON.validate(data)
        try keys(data, expected: ["uid", "gid", "kernelGroups", "requiredGroups", "forbiddenGroups", "auditSessionID", "onConsole"])
        let expected = try StrictJSON.decode(IdentityExpectation.self, from: data); try expected.validate()
        return expected
    }
    static func safeID(_ value: String) -> Bool {
        (8...96).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
    }
    static func keys(_ data: Data, expected: Set<String>) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == expected else { throw InstrumentError("JSON requires exactly the documented fields") }
    }
}
