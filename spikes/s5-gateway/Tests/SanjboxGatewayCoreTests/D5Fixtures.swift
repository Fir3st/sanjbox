import Foundation
@testable import SanjboxGatewayCore

let d5Now = Date(timeIntervalSince1970: 1_800_000_000)
let d5Bytes = Data("synthetic Python distribution; never executed".utf8)
let d5Filename = "fixture-1.0.0-py3-none-any.whl"
let d5FileTarget = "/pypi/files/fixture/" + d5Filename
func d5ISO(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
func d5Request(_ target: String, method: String = "GET", headers: [String: String] = [:], body: Data = Data()) -> HTTPRequest {
    HTTPRequest(method: method, target: target, headers: headers, body: body)
}
func d5File(filename: String = d5Filename, time: String? = d5ISO(d5Now.addingTimeInterval(-3600)),
            bytes: Data = d5Bytes) -> [String: Any] {
    var file: [String: Any] = ["filename": filename, "url": "https://files.example/packages/" + filename,
                              "hashes": ["sha256": registrySHA256(bytes)], "size": bytes.count, "requires-python": ">=3.9"]
    if let time { file["upload-time"] = time }
    return file
}
func d5Index(files: [[String: Any]] = [d5File()], extras: [String: Any] = [:]) throws -> Data {
    var root: [String: Any] = ["meta": ["api-version": "1.4"], "name": "fixture", "files": files]
    root.merge(extras) { _, new in new }
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
}
struct D5Wire: Sendable {
    var status = 200
    var type = "application/vnd.pypi.simple.v1+json"
    var headers: [String: String] = [:]
    var body: Data
    var data: Data {
        var head = "HTTP/1.1 \(status) Fixture\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}
struct D5Hosts: HostAddressProvider { func addresses() throws -> Set<SanjboxGatewayCore.IPAddress> { [] } }
actor D5DNS: DestinationResolver {
    var calls: [String] = []
    let answers: [String]
    init(_ answers: [String] = []) { self.answers = answers }
    func addresses(for hostname: String) async throws -> [SanjboxGatewayCore.IPAddress] {
        let index = calls.count; calls.append(hostname)
        return [try SanjboxGatewayCore.IPAddress(index < answers.count ? answers[index] : "8.8.8.8")]
    }
}
final class D5Backend: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(String, HTTPRequest)] = []
    let delay: Duration
    private let responder: @Sendable (String, HTTPRequest, Int) throws -> D5Wire
    init(delay: Duration = .zero, _ responder: @escaping @Sendable (String, HTTPRequest, Int) throws -> D5Wire) {
        self.delay = delay; self.responder = responder
    }
    func reply(host: String, wire: Data) throws -> Data {
        try lock.withLock {
            var decoder = HTTPRequestDecoder()
            guard let request = try decoder.append(wire) else { throw RegistryFailure.metadata }
            requests.append((host, request))
            return try responder(host, request, requests.count).data
        }
    }
    var calls: [(String, HTTPRequest)] { lock.withLock { requests } }
}
final class D5Connection: UpstreamConnection, @unchecked Sendable {
    let backend: D5Backend
    let host: String
    private let lock = NSLock()
    private var pending = Data()
    init(_ backend: D5Backend, _ host: String) { self.backend = backend; self.host = host }
    func start(timeout: Duration) async throws { try Task.checkCancellation() }
    func send(_ data: Data, timeout: Duration) async throws {
        let response = try backend.reply(host: host, wire: data)
        lock.withLock { pending = response }
    }
    func receive(timeout: Duration) async throws -> ReceivedBytes {
        if backend.delay > .zero { try await Task.sleep(for: backend.delay) }
        try Task.checkCancellation()
        return lock.withLock {
            let part = Data(pending.prefix(16_384)); pending = Data(pending.dropFirst(part.count))
            return ReceivedBytes(data: part, endOfStream: pending.isEmpty)
        }
    }
    func cancel() {}
}
func d5Client(_ backend: D5Backend, dns: D5DNS = D5DNS()) -> UpstreamClient {
    UpstreamClient(resolver: dns, hostAddresses: D5Hosts(), dialer: RecordingDialer { D5Connection(backend, $0.hostname) })
}
func d5PyPI(_ backend: D5Backend, configuration: PyPIConfiguration? = nil, dns: D5DNS = D5DNS(),
            now: @escaping @Sendable () -> Date = { d5Now }) throws -> PyPIGateway {
    PyPIGateway(configuration: try configuration ?? PyPIConfiguration(registryHostname: "index.example", artifactHostnames: ["files.example"],
        publicOrigin: "http://127.0.0.1:8765", cooldown: 3600), upstream: d5Client(backend, dns: dns), now: now)
}
func d5DefaultBackend(_ metadata: Data? = nil) throws -> D5Backend {
    let data = try metadata ?? d5Index()
    return D5Backend { _, request, _ in D5Wire(body: request.target.hasPrefix("/simple/") ? data : d5Bytes) }
}
