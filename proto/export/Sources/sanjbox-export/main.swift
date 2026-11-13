import Foundation
import SanjboxExportCLI

// Tenký obal: veškerá logika a exit kódy jsou v knihovně SanjboxExportCLI,
// aby je šlo testovat bez spouštění procesu.
let status = ExportCLI().run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    stdout: { FileHandle.standardOutput.write(Data($0.utf8)) },
    stderr: { FileHandle.standardError.write(Data($0.utf8)) }
)
exit(status)
