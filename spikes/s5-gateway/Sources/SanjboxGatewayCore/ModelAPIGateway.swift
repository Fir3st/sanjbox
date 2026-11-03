import Foundation

public struct ModelAPIRecord: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable { case running, completed, cancelled, failed }
    public let id: UUID
    public let zoneID: String
    public let model: String
    public let chargedUnits: UInt64
    public var outcome: Outcome
}

private final class ModelAPITicket: @unchecked Sendable {
    private let lock = NSLock()
    private var unused = true
    func consume() -> Bool { lock.withLock { defer { unused = false }; return unused } }
}

/// One handler/budget per trusted listener-zone binding. Requests never select a
/// zone, key, origin, endpoint or budget. This is not caller UID authentication.
public actor ModelAPIGateway {
    public nonisolated let configuration: ModelAPIConfiguration
    private let key: ModelAPITestKey
    private let upstream: UpstreamClient
    private let now: @Sendable () -> ContinuousClock.Instant
    private var lastClock: ContinuousClock.Instant?
    private var starts: [ContinuousClock.Instant] = []
    private var remaining: UInt64
    private var active = 0
    private var records: [ModelAPIRecord] = []

    public init(configuration: ModelAPIConfiguration, testKey: ModelAPITestKey, upstream: UpstreamClient) throws {
        try self.init(configuration: configuration, testKey: testKey, upstream: upstream, now: { ContinuousClock.now })
    }
    init(configuration: ModelAPIConfiguration, testKey: ModelAPITestKey, upstream: UpstreamClient,
         now: @escaping @Sendable () -> ContinuousClock.Instant) throws {
        guard !configuration.allowedModels.contains(where: { $0.contains(testKey.value) }), !configuration.zoneID.contains(testKey.value) else { throw ModelAPIFailure.configuration }
        self.configuration = configuration; key = testKey; self.upstream = upstream; self.now = now
        remaining = configuration.budgetUnits
    }

    public nonisolated func route() -> TypedRoute {
        TypedRoute(mount: "/model", methods: ["POST"]) { try await self.reply(to: $0) }
    }
    public func remainingBudgetUnits() -> UInt64 { remaining }
    public func auditRecords() -> [ModelAPIRecord] { records }
    public func takeFinishedRecords() -> [ModelAPIRecord] {
        let finished = records.filter { $0.outcome != .running }
        records.removeAll { $0.outcome != .running }
        return finished
    }

    public func reply(to request: HTTPRequest) throws -> GatewayReply {
        try Task.checkCancellation()
        do {
            let parsed = try ModelAPIRequest(request, configuration: configuration)
            let ticket = ModelAPITicket()
            // No reservation before the producer is invoked; unused responses
            // cannot orphan capacity. Invocation is single-use, even on failure.
            return .events { [self] emit in
                guard ticket.consume() else { throw ModelAPIFailure.replay }
                try await stream(parsed, emit: emit)
            }
        } catch ModelAPIFailure.limit { return .response(.error(413)) }
        catch is CancellationError { throw CancellationError() }
        catch { return .response(.error(403)) }
    }

    private func stream(_ request: ModelAPIRequest, emit: @escaping @Sendable (SSEEvent) async throws -> Void) async throws {
        try Task.checkCancellation()
        let instant = now()
        guard lastClock == nil || instant >= lastClock! else { throw ModelAPIFailure.rate }
        lastClock = instant
        starts.removeAll { $0.duration(to: instant) >= configuration.rateWindow }
        guard starts.count < configuration.requestsPerWindow else { throw ModelAPIFailure.rate }
        guard active < configuration.maximumConcurrent, records.count < configuration.maximumRecords else { throw ModelAPIFailure.busy }
        guard remaining >= configuration.chargePerRequest else { throw ModelAPIFailure.budget }
        let id = UUID()
        // Atomic actor commit, before the first await. Never refund an attempted
        // request: DNS, dispatch and provider billing cannot be rolled back here.
        remaining -= configuration.chargePerRequest; active += 1; starts.append(instant)
        records.append(ModelAPIRecord(id: id, zoneID: configuration.zoneID, model: request.model,
                                      chargedUnits: configuration.chargePerRequest, outcome: .running))
        var outcome = ModelAPIRecord.Outcome.failed
        defer {
            active -= 1
            if let index = records.firstIndex(where: { $0.id == id }) { records[index].outcome = outcome }
        }
        do {
            try await boundedOperation(timeout: configuration.lifetime) { [self] in
                try await relay(request, emit: emit)
            }
            try Task.checkCancellation()
            outcome = .completed
        } catch is CancellationError {
            outcome = .cancelled; throw CancellationError()
        } catch {
            // Never surface provider error messages, request headers or key text.
            throw ModelAPIFailure.upstream
        }
    }

    private func relay(_ request: ModelAPIRequest, emit: @escaping @Sendable (SSEEvent) async throws -> Void) async throws {
        var parser = ModelAPIStream(request: request, key: key, configuration: configuration)
        let operation = try UpstreamRequest(hostname: "api.anthropic.com", method: "POST", target: "/v1/messages",
                                            headers: ["x-api-key": key.value, "anthropic-version": "2023-06-01",
                                                      "content-type": "application/json", "accept": "text/event-stream"], body: request.body)
        _ = try await upstream.events(for: operation) { event in
            for safe in try parser.accept(event) {
                try Task.checkCancellation()
                try await emit(safe) // awaited all the way through D1 socket send
            }
        }
        try Task.checkCancellation()
        try await emit(parser.finish())
    }
}
