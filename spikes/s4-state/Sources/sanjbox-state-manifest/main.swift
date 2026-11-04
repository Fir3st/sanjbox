import Foundation
import StateManifest

do {
    let result = try StateManifestCommand.run(Array(CommandLine.arguments.dropFirst()))
    FileHandle.standardOutput.write(result.data)
    exit(result.exitCode)
} catch {
    FileHandle.standardError.write(Data(("state manifest: \(error)\n").utf8))
    exit(2)
}
