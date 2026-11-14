import Darwin
import Foundation
import SanjboxEscape

let args = Array(CommandLine.arguments.dropFirst())
let usage = "sanjbox-escape [plan] | run --apply --counterpart /absolute/path/sanjbox-counterpart"
do {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data: Data
    let code: Int32
    if args.isEmpty || args == ["plan"] {
        data = try encoder.encode(Catalog.load()); code = 0
    } else if args.count == 4, args[0] == "run", args[1] == "--apply", args[2] == "--counterpart", args[3].hasPrefix("/") {
        let report = try SyntheticRunner.run(counterpart: URL(fileURLWithPath: args[3]))
        data = try encoder.encode(report); code = report.exitCode
    } else { throw HarnessError.invalid(usage) }
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    exit(code)
} catch {
    FileHandle.standardError.write(Data("sanjbox-escape: \(error)\n".utf8)); exit(2)
}
