import Foundation
import SanjboxCLI

let result = SanjboxMain.run(Array(CommandLine.arguments.dropFirst()))
FileHandle.standardOutput.write(Data(result.stdout.utf8))
FileHandle.standardError.write(Data(result.stderr.utf8))
exit(result.code)
