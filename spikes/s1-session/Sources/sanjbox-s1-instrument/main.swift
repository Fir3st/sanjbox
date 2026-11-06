import Darwin
import Foundation
import S1Instrumentation

@main struct InstrumentCLI {
    @MainActor static func main() {
        do { exit(try run(Array(CommandLine.arguments.dropFirst()))) }
        catch { fputs("s1-instrument: \(error)\n", stderr); exit(2) }
    }
    @MainActor static func run(_ args: [String]) throws -> Int32 {
        if args.first == "owned-memory-fixture" {
            guard args.count == 4 && args[1] == "--fixture-json" && args[3] == "--apply" && args[2].utf8.count <= 16_384 else { throw InstrumentError("internal fixture requires bounded protocol and --apply") }
            try InstrumentRunner.ownedMemoryFixture(requestJSON: Data(args[2].utf8)); return 0
        }
        let usage = """
        sanjbox-s1-instrument record --plan-json JSON --expect-json JSON [--apply]
        sanjbox-s1-instrument offscreen --run-id ID --expect-json JSON [--apply]
        sanjbox-s1-instrument plan --plan-json JSON
        sanjbox-s1-instrument evaluate --fixture NAME --run-id ID [--apply]
        sanjbox-s1-instrument login-marker --marker-json JSON --expect-json JSON [--apply]
        sanjbox-s1-instrument process-memory --memory-json JSON --expect-json JSON [--apply]
        sanjbox-s1-instrument evaluate-supplement --fixture NAME --run-id ID [--apply]
        sanjbox-s1-instrument process-series --series-json JSON --expect-json JSON [--apply]
        sanjbox-s1-instrument owned-process-series --run-id ID --expect-json JSON [--apply]
        sanjbox-s1-instrument evaluate-process-series --fixture NAME --run-id ID [--apply]
        Default is dry-run: no measurements, GUI, files, or fixture reads.
        evaluate reads only /private/tmp/sanjbox-a2-fixture-<your-uid>-<NAME>.json.
        plan/record JSON schema and manual same-Mac coordination: INSTRUMENTATION.md.
        """
        guard let command = args.first else { print(usage); return 0 }
        if command == "--help" && args.count == 1 { print(usage); return 0 }
        guard ["record", "plan", "evaluate", "offscreen", "login-marker", "process-memory", "evaluate-supplement", "process-series", "owned-process-series", "evaluate-process-series"].contains(command), args.count <= 10 else { throw InstrumentError("unsupported command or argument count") }
        var options: [String: String] = [:]
        var apply = false
        var index = 1
        while index < args.count {
            let key = args[index]
            if key == "--apply" {
                guard !apply else { throw InstrumentError("duplicate --apply") }; apply = true; index += 1; continue
            }
            guard ["--plan-json", "--expect-json", "--fixture", "--run-id", "--marker-json", "--memory-json", "--series-json"].contains(key), options[key] == nil, index + 1 < args.count else { throw InstrumentError("unknown, missing or duplicate option") }
            let value = args[index + 1]
            guard value.utf8.count <= 16_384 else { throw InstrumentError("option exceeds 16 KiB") }
            options[key] = value; index += 2
        }
        let allowed: Set<String> = command == "process-series" ? ["--series-json", "--expect-json"] : command == "owned-process-series" ? ["--run-id", "--expect-json"] : command == "login-marker" ? ["--marker-json", "--expect-json"] : command == "process-memory" ? ["--memory-json", "--expect-json"] : command == "record" ? ["--plan-json", "--expect-json"] : command == "plan" ? ["--plan-json"] : command == "offscreen" ? ["--run-id", "--expect-json"] : ["--fixture", "--run-id"]
        guard Set(options.keys) == allowed && !(command == "plan" && apply) else { throw InstrumentError("command requires exactly its documented options") }
        if command == "process-series" {
            let plan = try StrictJSON.decodeExact(ProcessSeriesPlan.self, from: Data(options["--series-json"]!.utf8))
            try plan.validate()
            let expected = try decodeExpectation(options["--expect-json"]!)
            try plan.validate(expectedUID: expected.uid)
            if !apply { print("dry-run: \(plan.registrations.count) explicitly registered same-UID test processes, \(plan.seconds) seconds; no target read"); return 0 }
            signal(SIGALRM, SIG_DFL); alarm(UInt32(ceil(plan.seconds)) + 30)
            defer { alarm(0) }
            let result = try InstrumentRunner.processSeries(plan: plan, expected: expected)
            print(result.path); return result.valid ? 0 : 3
        }
        if command == "owned-process-series" {
            guard safeID(options["--run-id"]!) else { throw InstrumentError("invalid run ID") }
            let expected = try decodeExpectation(options["--expect-json"]!)
            if !apply { print("dry-run: fixed 6-second own-child validation, 16 + 8 MiB, arrival/exit retained incomplete; no child launched"); return 0 }
            signal(SIGALRM, SIG_DFL); alarm(30)
            defer { alarm(0) }
            let result = try InstrumentRunner.ownedProcessSeries(runID: options["--run-id"]!, expected: expected)
            print(result.path); return result.valid ? 0 : 3
        }
        if command == "evaluate-process-series" {
            guard safeID(options["--fixture"]!), safeID(options["--run-id"]!) else { throw InstrumentError("invalid run or fixture ID") }
            if !apply { print("dry-run: evaluate registered process series; no fixture read"); return 0 }
            let raw = try StrictJSON.decodeExact(ProcessSeriesRecording.self, from: Dataset.readFixture(name: options["--fixture"]!))
            let report = try ProcessSeriesAnalyzer.evaluate(raw)
            let dataset = try Dataset(runID: options["--run-id"]!, role: "report")
            try dataset.write("report.json", report)
            print(dataset.path); return report.acquisitionComplete ? 0 : 3
        }
        if command == "login-marker" {
            let request = try StrictJSON.decodeExact(LoginMarkerRequest.self, from: Data(options["--marker-json"]!.utf8))
            try request.validate()
            let expected = try decodeExpectation(options["--expect-json"]!)
            if !apply { print("dry-run: manual login marker only; no login, event observation, or timing acceptance"); return 0 }
            let result = try InstrumentRunner.loginMarker(request: request, expected: expected)
            print(result.path); return result.valid ? 0 : 3
        }
        if command == "process-memory" {
            let plan = try StrictJSON.decodeExact(ProcessMemoryPlan.self, from: Data(options["--memory-json"]!.utf8))
            try plan.validate()
            let expected = try decodeExpectation(options["--expect-json"]!)
            if !apply { print("dry-run: registered own recorder fixture only; no PID inventory; \(plan.seconds) seconds, \(plan.fixtureMiB) MiB synthetic allocation"); return 0 }
            let result = try InstrumentRunner.processMemory(plan: plan, expected: expected)
            print(result.path); return result.valid ? 0 : 3
        }
        if command == "evaluate-supplement" {
            guard safeID(options["--fixture"]!), safeID(options["--run-id"]!) else { throw InstrumentError("invalid run or fixture ID") }
            if !apply { print("dry-run: validate supplementary staged own fixture; no input read"); return 0 }
            let data = try Dataset.readFixture(name: options["--fixture"]!)
            let report = try SupplementaryAnalyzer.evaluate(StrictJSON.decodeExact(SupplementaryBundle.self, from: data))
            let dataset = try Dataset(runID: options["--run-id"]!, role: "report")
            try dataset.write("report.json", report)
            print(dataset.path); return report.evidenceComplete ? 0 : 3
        }
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
