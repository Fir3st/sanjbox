import Foundation
import SanjboxGatewayCore
import SanjboxGatewayService
import Synchronization

// Fixtures a mocky pro WP1.H4. Žádný test neotevírá port ani nečte tajemství;
// klíče i obsahy jsou syntetické kanárky.

let zoneID = "zone-fixture-01"
let modelKeyText = MockKeyProvider.defaultModelKeyText
let canary = "SANJBOX-H4-CANARY-0001"

/// Sestaví požadavek stejnou cestou jako transport (přes `HTTPRequestDecoder`),
/// protože `HTTPRequest` nemá veřejný inicializátor z WP1.D1.
func request(_ method: String, _ target: String,
             headers: [String: String] = [:], body: Data = Data()) throws -> HTTPRequest {
    var head = "\(method) \(target) HTTP/1.1\r\nHost: gateway.test\r\n"
    for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
        head += "\(key): \(value)\r\n"
    }
    if !body.isEmpty { head += "Content-Length: \(body.count)\r\n" }
    var decoder = HTTPRequestDecoder()
    guard let decoded = try decoder.append(Data((head + "\r\n").utf8) + body) else {
        throw HTTPFailure.malformed
    }
    return decoded
}

func status(of reply: GatewayReply) -> Int? {
    guard case .response(let response) = reply else { return nil }
    return response.status
}

func body(of reply: GatewayReply) -> Data? {
    guard case .response(let response) = reply else { return nil }
    return response.body
}

func encodeModelRequest(model: String = "fixture-model", stream: Bool = true,
                        maxTokens: Int = 32) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "model": model,
        "max_tokens": maxTokens,
        "stream": stream,
        "messages": [["role": "user", "content": "synthetic prompt"]],
    ], options: [.sortedKeys])
}

enum Fixture {
    static let origin = "http://127.0.0.1:18765"

    static func npm(enabled: Bool = true, mount: String = "/npm", cooldown: Double = 3_600,
                    operations: Int = 4, upstream: String = "registry.example") -> GatewayRule {
        .npm(NPMRule(enabled: enabled, mount: mount, publicOrigin: origin, upstreamHostname: upstream,
                     cooldownSeconds: cooldown,
                     limits: try! RegistryRuleLimits(operations: operations)))
    }

    static func pypi(enabled: Bool = true, mount: String = "/pypi") -> GatewayRule {
        .pypi(PyPIRule(enabled: enabled, mount: mount, publicOrigin: origin, upstreamHostname: "pypi.example"))
    }

    static func git(enabled: Bool = true, mount: String = "/git", allowPush: Bool = false) -> GatewayRule {
        .git(GitRule(enabled: enabled, mount: mount, upstreamHostname: "github.example", allowPush: allowPush))
    }

    static func model(enabled: Bool = true, budgetUnits: UInt64 = 100) -> GatewayRule {
        .model(ModelRule(enabled: enabled, allowedModels: ["fixture-model"], budgetUnits: budgetUnits))
    }

    static func policy(_ rules: [GatewayRule], auditCapacity: Int = 256) throws -> GatewayPolicy {
        try GatewayPolicy(zoneID: zoneID, auditCapacity: auditCapacity, gateways: rules)
    }

    static func allEnabled() throws -> GatewayPolicy {
        try policy([npm(), pypi(), git(), model()])
    }

    /// JSON draftu v1 se všemi čtyřmi operacemi; negativní testy ho upravují.
    static let policyJSON = """
    {
      "schemaVersion": 1,
      "zoneID": "zone-fixture-01",
      "auditCapacity": 256,
      "gateways": [
        {
          "operation": "npm",
          "enabled": true,
          "mount": "/npm",
          "publicOrigin": "http://127.0.0.1:18765",
          "upstreamHostname": "registry.example",
          "artifactHostnames": [],
          "cooldownSeconds": 3600,
          "limits": {
            "metadataBytes": 4194304,
            "artifactBytes": 4194304,
            "files": 10000,
            "operations": 4,
            "auditRecords": 1024,
            "lifetimeSeconds": 90
          }
        },
        {
          "operation": "pypi",
          "enabled": true,
          "mount": "/pypi",
          "publicOrigin": "http://127.0.0.1:18765",
          "upstreamHostname": "pypi.example",
          "artifactHostnames": ["files.example"],
          "cooldownSeconds": 3600,
          "limits": {
            "metadataBytes": 4194304,
            "artifactBytes": 4194304,
            "files": 10000,
            "operations": 4,
            "auditRecords": 1024,
            "lifetimeSeconds": 90
          }
        },
        {
          "operation": "git",
          "enabled": true,
          "mount": "/git",
          "upstreamHostname": "github.example",
          "repositoryPath": "/project.git",
          "allowPush": false,
          "maximumRequestBytes": 1048576,
          "limits": {
            "metadataBytes": 4194304,
            "artifactBytes": 4194304,
            "files": 10000,
            "operations": 4,
            "auditRecords": 1024,
            "lifetimeSeconds": 90
          }
        },
        {
          "operation": "model",
          "enabled": true,
          "mount": "/model",
          "allowedModels": ["fixture-model"],
          "budgetUnits": 100,
          "chargePerRequest": 1,
          "requestsPerWindow": 10,
          "rateWindowSeconds": 60,
          "maximumConcurrent": 2,
          "maximumRecords": 16,
          "maximumInputBytes": 32768,
          "maximumOutputTokens": 1024,
          "maximumOutputBytes": 262144,
          "maximumEvents": 4096,
          "lifetimeSeconds": 60
        }
      ]
    }
    """
}

/// Mock resolveru: nikdy nic nedialuje, jen zaznamená dotaz a odmítne.
/// Síťový socket tedy v testech nevzniká, ale cesta přes politiku upstreamu
/// v reálném handleru se skutečně provede.
final class RefusingResolver: DestinationResolver, @unchecked Sendable {
    private let asked = Mutex<[String]>([])

    func addresses(for hostname: String) async throws -> [IPAddress] {
        asked.withLock { $0.append(hostname) }
        throw DestinationFailure.noAddresses
    }

    var consulted: [String] {
        asked.withLock { $0 }
    }
}

/// In-memory mock byte kanálu pro transportní testy. Žádný socket.
final class MockChannel: ByteChannel, @unchecked Sendable {
    private struct State {
        var inbound: Data
        var outbound = Data()
        var closed = false
    }

    private let state: Mutex<State>

    init(inbound: Data) { state = Mutex(State(inbound: inbound)) }

    func receive(maximumBytes: Int) async throws -> Data {
        state.withLock { current in
            guard !current.inbound.isEmpty else { return Data() }
            let count = Swift.min(maximumBytes, current.inbound.count)
            let prefix = Data(current.inbound.prefix(count))
            current.inbound.removeFirst(count)
            return prefix
        }
    }

    func send(_ bytes: Data) async throws {
        state.withLock { $0.outbound.append(bytes) }
    }

    func close() {
        state.withLock { $0.closed = true }
    }

    var sent: Data { state.withLock { $0.outbound } }

    var inboundRemainingForTest: Int { state.withLock { $0.inbound.count } }

    var isClosed: Bool { state.withLock { $0.closed } }
}
