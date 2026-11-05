import Foundation
import HostAudit

do {
    let result = try HostHardeningCommand.run(Array(CommandLine.arguments.dropFirst()))
    FileHandle.standardOutput.write(result.output)
    exit(result.exitCode)
} catch {
    FileHandle.standardError.write(Data(("host hardening: \(error)\n").utf8))
    exit(2)
}
