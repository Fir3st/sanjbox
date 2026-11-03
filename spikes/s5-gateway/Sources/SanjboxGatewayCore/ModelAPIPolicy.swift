import Foundation

public enum ModelAPIFailure: Error, Sendable, Equatable {
    case configuration, forbidden, schema, limit, rate, budget, busy, replay, upstream, secretEcho
}

/// Deliberately accepts synthetic laboratory values only. Live credential
/// custody/scopes are not implemented by D3 and cannot silently be enabled here.
public struct ModelAPITestKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String
    public init(_ value: String) throws {
        guard value.hasPrefix("sanjbox-test-"), (24...128).contains(value.utf8.count),
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else { throw ModelAPIFailure.configuration }
        self.value = value
    }
    public var description: String { "<synthetic model API key>" }
    public var debugDescription: String { description }
}

public struct ModelAPIConfiguration: Sendable {
    public let zoneID: String
    public let allowedModels: Set<String>
    public let budgetUnits: UInt64
    public let chargePerRequest: UInt64
    public let requestsPerWindow: Int
    public let rateWindow: Duration
    public let maximumConcurrent: Int
    public let maximumRecords: Int
    public let maximumInputBytes: Int
    public let maximumOutputTokens: Int
    public let maximumOutputBytes: Int
    public let maximumEvents: Int
    public let lifetime: Duration

    public init(zoneID: String, allowedModels: Set<String>, budgetUnits: UInt64, chargePerRequest: UInt64,
                requestsPerWindow: Int = 10, rateWindow: Duration = .seconds(60), maximumConcurrent: Int = 2,
                maximumRecords: Int = 1024, maximumInputBytes: Int = 32_768, maximumOutputTokens: Int = 1024,
                maximumOutputBytes: Int = 262_144, maximumEvents: Int = 4096, lifetime: Duration = .seconds(60)) throws {
        func identifier(_ value: String) -> Bool {
            (1...128).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || "-_.".utf8.contains($0) }
        }
        guard identifier(zoneID), !allowedModels.isEmpty, allowedModels.count <= 32, allowedModels.allSatisfy(identifier),
              budgetUnits > 0, chargePerRequest > 0, chargePerRequest <= budgetUnits,
              (1...1000).contains(requestsPerWindow), rateWindow > .zero, rateWindow <= .seconds(86_400),
              (1...32).contains(maximumConcurrent), (1...10_000).contains(maximumRecords),
              (1...65_536).contains(maximumInputBytes), (1...8192).contains(maximumOutputTokens),
              (1...1_048_576).contains(maximumOutputBytes), (1...16_384).contains(maximumEvents),
              lifetime > .zero, lifetime <= .seconds(120) else { throw ModelAPIFailure.configuration }
        self.zoneID = zoneID; self.allowedModels = allowedModels
        self.budgetUnits = budgetUnits; self.chargePerRequest = chargePerRequest
        self.requestsPerWindow = requestsPerWindow; self.rateWindow = rateWindow
        self.maximumConcurrent = maximumConcurrent; self.maximumRecords = maximumRecords
        self.maximumInputBytes = maximumInputBytes; self.maximumOutputTokens = maximumOutputTokens
        self.maximumOutputBytes = maximumOutputBytes; self.maximumEvents = maximumEvents; self.lifetime = lifetime
    }
}

struct ModelAPIRequest: Sendable {
    let model: String
    let maximumTokens: Int
    let body: Data
    init(_ request: HTTPRequest, configuration: ModelAPIConfiguration) throws {
        // Allowlisting headers prevents aliases, beta routing and client-selected
        // accounts/proxies from entering the trusted operation.
        let allowed: Set<String> = ["host", "content-length", "content-type", "accept", "user-agent", "connection"]
        var headers: [String: String] = [:]
        for (key, value) in request.headers {
            let key = key.lowercased()
            guard allowed.contains(key), headers[key] == nil else { throw ModelAPIFailure.forbidden }
            headers[key] = value
        }
        guard request.method == "POST", request.target == "/model/v1/messages",
              headers["content-type"]?.lowercased() == "application/json" else { throw ModelAPIFailure.forbidden }
        let input = try ModelJSON.parse(request.body, maximumBytes: configuration.maximumInputBytes)
        let object = try modelObject(input, required: ["model", "messages", "max_tokens", "stream"])
        guard let model = object["model"]?.string, configuration.allowedModels.contains(model),
              object["stream"] == .bool(true), let tokens = object["max_tokens"]?.integer,
              (1...configuration.maximumOutputTokens).contains(tokens),
              let messages = object["messages"]?.array, (1...64).contains(messages.count) else { throw ModelAPIFailure.forbidden }
        for (index, message) in messages.enumerated() {
            let fields = try modelObject(message, required: ["role", "content"])
            guard fields["role"] == .string(index % 2 == 0 ? "user" : "assistant"),
                  let content = fields["content"]?.string, !content.isEmpty else { throw ModelAPIFailure.forbidden }
        }
        // Do not permit assistant-prefill for this subset.
        guard messages.count % 2 == 1 else { throw ModelAPIFailure.forbidden }
        self.model = model; maximumTokens = tokens
        body = try input.encoded()
    }
}
