import Darwin
import Foundation
import SanjboxNetworkProvenance
import SanjboxCounterpart
import SanjboxProbeKit

// sanjbox-counterpart — independent receiving side for network leak tests (WP0.4).

let usage = """
    usage:
      sanjbox-counterpart listen --log FILE --raw DIR [--tcp PORTS] [--udp PORTS] [--bind ADDR] [--registry FILE]
      sanjbox-counterpart report --log FILE
    PORTS is a comma-separated list (0 = any free port); at least one TCP or UDP port is required.
    ADDR is a numeric address, default :: (IPv6 and IPv4). FILE for --log must not exist yet.
    listen prints the bound listeners and runs until SIGINT or SIGTERM; then it drains and closes
    every flow and writes the stopped event.
    report exit codes: 0 complete run, nothing received; 1 something received;
      3 incomplete log (invalid measurement); 2 usage or I/O error
    """

let rawArguments = Array(CommandLine.arguments.dropFirst())
if ProvenanceCLI.handles(rawArguments) {
    exit(ProvenanceCLI.run(rawArguments, receiver: true, operation: ProvenanceReceiver.run))
}
guard let command = rawArguments.first else { exitWithError(usage) }

let arguments: ProbeArguments
do {
    arguments = try ProbeArguments(Array(rawArguments.dropFirst()), valueFlags: ["log", "raw", "tcp", "udp", "bind", "registry"])
} catch {
    exitWithError("\(error)\n\(usage)")
}

func ports(_ flag: String, _ arguments: ProbeArguments) -> [UInt16] {
    guard let list = arguments.options[flag] else { return [] }
    return list.split(separator: ",").map { item in
        guard let port = UInt16(item) else { exitWithError("invalid port \(item) in --\(flag)\n\(usage)") }
        return port
    }
}

func listen(_ arguments: ProbeArguments) -> Never {
    let tcpPorts = ports("tcp", arguments)
    let udpPorts = ports("udp", arguments)
    guard !(tcpPorts.isEmpty && udpPorts.isEmpty) else { exitWithError("no --tcp or --udp port\n\(usage)") }

    let configuration: Counterpart.Configuration
    do {
        let canaries = try arguments.options["registry"].map { try JSONLines.read(Canary.self, from: URL(fileURLWithPath: $0)) }
        configuration = Counterpart.Configuration(
            bindAddress: arguments.options["bind"] ?? "::", tcpPorts: tcpPorts, udpPorts: udpPorts,
            logURL: URL(fileURLWithPath: try arguments.required("log")),
            rawDirectory: URL(fileURLWithPath: try arguments.required("raw"), isDirectory: true),
            canaries: canaries ?? []
        )
    } catch {
        exitWithError("\(error)\n\(usage)")
    }

    let counterpart: Counterpart
    do { counterpart = try Counterpart.start(configuration) } catch { exitWithError("cannot start: \(error)") }
    do { try printJSON(counterpart.listeners) } catch { exitWithError("cannot encode listeners: \(error)") }
    fflush(stdout)

    let signalSources = [SIGINT, SIGTERM].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            counterpart.stop()
            exit(ProbeExit.ok.rawValue)
        }
        source.resume()
        return source
    }
    withExtendedLifetime(signalSources) { dispatchMain() }
}

func report(_ arguments: ProbeArguments) -> Never {
    let report: CounterpartReport
    do {
        let url = URL(fileURLWithPath: try arguments.required("log"))
        report = CounterpartReport(events: try JSONLines.read(CounterpartEvent.self, from: url))
        try printJSON(report)
    } catch {
        exitWithError("cannot read event log: \(error)")
    }
    let code: ProbeExit = !report.complete ? .invalidMeasurement : report.receivedAnything ? .finding : .ok
    exit(code.rawValue)
}

switch command {
case "listen": listen(arguments)
case "report": report(arguments)
default: exitWithError(usage)
}
