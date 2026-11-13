import Foundation
import SanjboxContracts

public protocol HelperTransport: Sendable {
    func exchange(_ request: Data) throws -> Data
}

/// The only admission path for replies: H1 decode AND correlation on this request's reply channel.
public struct HelperClient: Sendable {
    private let transport: any HelperTransport
    public init(transport: any HelperTransport) { self.transport = transport }

    public func send(_ request: HelperMessage) throws -> HelperReply {
        let bytes: Data
        do { bytes = try request.encoded() } catch { throw CLIError.invalidInput }
        let response = try transport.exchange(bytes)
        let reply: HelperReply
        do {
            reply = try HelperReply.decode(response)
            try reply.validate(for: request)
        } catch { throw CLIError.invalidReply }
        if let code = reply.errorCode { throw CLIError.helperFailed(code) }
        return reply
    }

    public static func render(_ reply: HelperReply) -> String {
        // Call only with a validated response from send(). No argv, path or untrusted diagnostic echo.
        if reply.outcome == .accepted {
            return "mock accepted kind=\(reply.requestKind.rawValue) zone=\(reply.zoneID ?? "") execution=\(reply.executionID ?? ""); process completion unknown (no process executed)"
        }
        return "mock completed kind=\(reply.requestKind.rawValue) zone=\(reply.zoneID ?? ""); synthetic state only"
    }
}

public enum SanjboxMain {
    public static func run(_ arguments: [String]) -> (code: Int32, stdout: String, stderr: String) {
        do {
            switch try CLICommand.parse(arguments) {
            case .help: return (0, CLICommand.usage + "\n", "")
            case .request(let request):
                let phase: MockPhase = request.kind == .snapshot ? .paused : request.kind == .rollback ? .stopped : .running
                let helper = MockHelper(phase: phase)
                let server = MockXPCServer(helper: helper)
                defer { server.invalidate() }
                let client = HelperClient(transport: XPCTransport(endpoint: server.endpoint))
                return (0, HelperClient.render(try client.send(request)) + "\n", "")
            }
        } catch let error as CLIError {
            return (error.exitCode, "", "sanjbox: \(error.diagnostic)\n")
        } catch {
            return (70, "", "sanjbox: mock request failed\n")
        }
    }
}
