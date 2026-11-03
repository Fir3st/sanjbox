import Darwin
import Foundation
import SanjboxGatewayCore
import SanjboxProbeKit

@main struct GatewayCommand {
    @MainActor static func main() async {
        let usage = "sanjbox-gateway --mode mock --expect FILE [--port 8765]"
        do {
            let arguments = try ProbeArguments(Array(CommandLine.arguments.dropFirst()),
                                               valueFlags: ["mode", "expect", "port"])
            guard arguments.positional.isEmpty, try arguments.required("mode") == "mock",
                  let port = UInt16(arguments.options["port"] ?? "8765") else {
                exitWithError(usage)
            }
            let expectation = try JSONLines.decoder.decode(ProbeExpectation.self, from:
                Data(contentsOf: URL(fileURLWithPath: try arguments.required("expect"))))
            // First measurement, before a listener exists: same kit as sanjbox-whoami.
            let context = ProbeContext.capture(groupsOfInterest: expectation.groupsOfInterest)
            let mismatches = expectation.mismatches(in: context)
            let record = RunRecord(probe: "sanjbox-gateway", caseID: nil,
                                   outcome: mismatches.isEmpty ? .unclear : .invalidMeasurement,
                                   context: context, mismatches: mismatches,
                                   details: ["mode": "mock", "evidence": "not a gate verdict"])
            FileHandle.standardOutput.write(try JSONLines.makeEncoder().encode(record))
            FileHandle.standardOutput.write(Data("\n".utf8))
            guard mismatches.isEmpty else { exit(ProbeExit.invalidMeasurement.rawValue) }

            let router = try TypedRouter(routes: [
                TypedRoute(mount: "/mock", methods: ["GET"]) { request in
                    switch request.path {
                    case "/mock/status":
                        return .response(HTTPResponse(body: Data("{\"mode\":\"mock\",\"upstream\":false}\n".utf8)))
                    case "/mock/events":
                        return .events { emit in
                            for index in 1...3 {
                                try await emit(SSEEvent(data: "{\"mock\":true,\"sequence\":\(index)}", event: "message", id: "\(index)"))
                                try await Task.sleep(for: .milliseconds(100))
                            }
                        }
                    default: return .response(.error(404))
                    }
                },
            ])
            let server = GatewayServer(router: router)
            let actualPort = try await server.start(port: port)
            FileHandle.standardError.write(Data("MOCK only: http://127.0.0.1:\(actualPort)/mock/{status,events}\n".utf8))
            // Keep CLI alive; SIGINT/SIGTERM terminate the process and close its
            // sockets. No persistent system state, user or firewall rule exists.
            while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
            server.stop()
        } catch {
            // Do not print errors that could contain request/expectation contents.
            exitWithError("gateway could not start; check arguments and expectation file\n\(usage)")
        }
    }
}
