import Foundation
import SanjboxGatewayService

let result = await GatewayCommand.run(Array(CommandLine.arguments.dropFirst()), emit: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) })
for line in result.output {
    print(line)
}
exit(result.exitCode)
