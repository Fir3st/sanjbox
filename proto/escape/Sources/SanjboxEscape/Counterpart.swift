import Darwin
import Foundation
import SanjboxProbeKit

struct ListenerDescription: Codable {
    struct Endpoint: Codable { var host: String; var port: UInt16 }
    var transport: String
    var endpoint: Endpoint
}
public struct CounterpartSummary: Codable, Sendable {
    public var complete: Bool
    public var problems: [String]
    public var tcpConnections: Int
    public var udpDatagrams: Int
    public var bytes: Int
    public var findings: [CanaryScanner.Finding]
    var receivedAnything: Bool {
        tcpConnections != 0 || udpDatagrams != 0 || bytes != 0 || !findings.isEmpty
    }
}
public struct CounterpartEvidence: Codable, Sendable {
    public let role: String
    public let reportExit: Int32
    public let report: CounterpartSummary
    public let eventsJSONL: String
    public let rawPayload: Data?
    var complete: Bool {
        report.complete && report.problems.isEmpty && reportExit == (report.receivedAnything ? 1 : 0)
    }
    func received(_ canary: Canary) -> Bool {
        complete && report.tcpConnections == 1 && report.udpDatagrams == 0 &&
        report.bytes == canary.token.utf8.count && rawPayload == Data(canary.token.utf8) &&
        report.findings.contains { $0.token == canary.token && $0.encoding == "raw" }
    }
    var empty: Bool { complete && !report.receivedAnything }
}

struct LoopbackCounterpart {
    let executable: URL
    init(executable: URL) throws {
        var metadata = stat()
        guard executable.path.hasPrefix("/"), lstat(executable.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o6000 == 0,
              access(executable.path, X_OK) == 0 else {
            throw HarnessError.invalid("counterpart must be a regular executable without set-ID bits")
        }
        self.executable = executable
    }

    func run(in directory: URL, role: String, canary: Canary, send: Bool,
             omitStopped: Bool = false) throws -> CounterpartEvidence {
        let log = directory.appendingPathComponent("events.jsonl")
        let raw = directory.appendingPathComponent("raw")
        let registry = directory.appendingPathComponent("canaries.jsonl")
        // JSONLines uses the shared millisecond ISO formatter, not JSONEncoder's ISO strategy.
        try JSONLines.append(canary, to: registry)
        let child = try ChildProcess(executable: executable,
            arguments: ["listen", "--bind", "127.0.0.1", "--tcp", "0", "--log", log.path,
                        "--raw", raw.path, "--registry", registry.path], directory: directory, label: "listener")
        defer { child.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var endpoint: ListenerDescription.Endpoint?
        while ProcessInfo.processInfo.systemUptime < deadline, child.process.isRunning {
            if let listeners = try? JSONDecoder().decode([ListenerDescription].self, from: child.outputData()),
               listeners.count == 1, listeners[0].transport == "tcp", listeners[0].endpoint.host == "127.0.0.1",
               listeners[0].endpoint.port > 0 {
                endpoint = listeners[0].endpoint
                break
            }
            usleep(10_000)
        }
        guard let endpoint else { throw HarnessError.invalid("counterpart did not become ready on IPv4 loopback") }
        // Bounded settling interval fixed before all runs; this is synthetic harness calibration only.
        if send { try sendLoopback(port: endpoint.port, bytes: Data(canary.token.utf8)) }
        usleep(100_000)
        child.process.terminate()
        guard try child.wait(seconds: 5) == 0 else { throw HarnessError.invalid("counterpart stop failed") }
        if omitStopped {
            let contents = try String(contentsOf: log, encoding: .utf8)
            var lines = contents.split(separator: "\n").map(String.init)
            guard !lines.isEmpty else { throw HarnessError.invalid("missing counterpart events") }
            lines.removeLast()
            try (lines.joined(separator: "\n") + "\n").write(to: log, atomically: false, encoding: .utf8)
        }
        let reporter = try ChildProcess(executable: executable, arguments: ["report", "--log", log.path],
                                        directory: directory, label: "report")
        let code = try reporter.wait(seconds: 5)
        guard [0, 1, 3].contains(code) else { throw HarnessError.invalid("counterpart report failed") }
        let summary = try JSONDecoder().decode(CounterpartSummary.self, from: reporter.outputData())
        let payloadPath = raw.appendingPathComponent("1-tcp-\(endpoint.port).bin")
        var payload: Data?
        if send, FileManager.default.fileExists(atPath: payloadPath.path) {
            payload = try Data(contentsOf: payloadPath)
        }
        return CounterpartEvidence(role: role, reportExit: code, report: summary,
            eventsJSONL: try String(contentsOf: log, encoding: .utf8), rawPayload: payload)
    }
}

private func sendLoopback(port: UInt16, bytes: Data) throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw HarnessError.invalid("socket failed") }
    defer { close(fd) }
    var one: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0,
          fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw HarnessError.invalid("socket options failed") }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 || errno == EINPROGRESS else { throw HarnessError.invalid("loopback connect failed") }
    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&descriptor, 1, 1000) > 0 else { throw HarnessError.invalid("loopback connect timed out") }
    var status: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &status, &length) == 0, status == 0 else {
        throw HarnessError.invalid("loopback connect rejected")
    }
    var offset = 0
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    try bytes.withUnsafeBytes { raw in
        while offset < raw.count, ProcessInfo.processInfo.systemUptime < deadline {
            let count = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
            if count > 0 { offset += count }
            else if count < 0 && [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { usleep(1000) }
            else { throw HarnessError.invalid("loopback send failed") }
        }
    }
    guard offset == bytes.count else { throw HarnessError.invalid("loopback send timed out") }
    shutdown(fd, SHUT_WR)
}
