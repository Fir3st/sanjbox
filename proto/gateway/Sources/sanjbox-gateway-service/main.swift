import Foundation
import SanjboxGatewayService

let result = await GatewayCommand.run(Array(CommandLine.arguments.dropFirst()), emit: { print($0) })
for line in result.output {
    print(line)
}
exit(result.exitCode)
