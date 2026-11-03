import Foundation

public struct UpstreamLimits: Sendable {
    public let headerBytes: Int
    public let responseBytes: Int
    public let streamBytes: Int
    public let eventBytes: Int
    public let connectTimeout: Duration
    public let idleTimeout: Duration
    public let lifetime: Duration

    public init(headerBytes: Int = 16_384, responseBytes: Int = 4_194_304,
                streamBytes: Int = 33_554_432, eventBytes: Int = 65_536,
                connectTimeout: Duration = .seconds(10), idleTimeout: Duration = .seconds(15),
                lifetime: Duration = .seconds(120)) {
        precondition(headerBytes > 0 && responseBytes >= 0 && streamBytes > 0 && eventBytes > 0)
        precondition(connectTimeout > .zero && idleTimeout > .zero && lifetime > .zero)
        self.headerBytes = headerBytes
        self.responseBytes = responseBytes
        self.streamBytes = streamBytes
        self.eventBytes = eventBytes
        self.connectTimeout = connectTimeout
        self.idleTimeout = idleTimeout
        self.lifetime = lifetime
    }
}

/// Share one client among typed handlers to share its fail-fast concurrency cap.
/// Each operation resolves again, takes a fresh host snapshot, dials a numeric IP
/// and verifies TLS for the configured hostname. There is no connection/DNS cache,
/// retry, redirect following or client-selected authority.
public struct UpstreamClient: Sendable {
    private let resolver: any DestinationResolver
    private let hostAddresses: any HostAddressProvider
    private let dialer: any UpstreamDialer
    private let limits: UpstreamLimits
    private let capacity: Capacity

    public init(resolver: any DestinationResolver = SystemDestinationResolver(),
                hostAddresses: any HostAddressProvider = SystemHostAddresses(),
                limits: UpstreamLimits = UpstreamLimits(), maximumConnections: Int = 8) {
        self.init(resolver: resolver, hostAddresses: hostAddresses, dialer: PinnedTLSDialer(),
                  limits: limits, maximumConnections: maximumConnections)
    }

    init(resolver: any DestinationResolver, hostAddresses: any HostAddressProvider,
         dialer: any UpstreamDialer, limits: UpstreamLimits = UpstreamLimits(), maximumConnections: Int = 8) {
        self.resolver = resolver
        self.hostAddresses = hostAddresses
        self.dialer = dialer
        self.limits = limits
        capacity = Capacity(maximumConnections)
    }

    public func response(for request: UpstreamRequest, isolation: isolated (any Actor)? = #isolation) async throws -> UpstreamResponse {
        var body = Data()
        let head = try await exchange(request, streaming: false) { part in body.append(part) }
        return UpstreamResponse(head: head, body: body)
    }

    /// onEvent is awaited before another network read; consumers must propagate
    /// cancellation and avoid unbounded background work. Non-200/non-SSE is an error.
    public func events(for request: UpstreamRequest, isolation: isolated (any Actor)? = #isolation,
                       onEvent: (SSEEvent) async throws -> Void) async throws -> UpstreamResponseHead {
        var decoder = SSEDecoder(maximumEventBytes: limits.eventBytes)
        let head = try await exchange(request, streaming: true) { part in
            for event in try decoder.append(part) {
                try Task.checkCancellation()
                try await onEvent(event)
            }
        }
        try decoder.finish()
        return head
    }

    private func exchange(_ request: UpstreamRequest, streaming: Bool,
                          isolation: isolated (any Actor)? = #isolation,
                          onBody: (Data) async throws -> Void) async throws -> UpstreamResponseHead {
        try Task.checkCancellation()
        guard capacity.acquire() else { throw UpstreamFailure.busy }
        defer { capacity.release() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limits.lifetime)
        let approved = try await boundedOperation(timeout: limits.lifetime) { [self] in
            try await DestinationPolicy(hostAddressProvider: hostAddresses).approve(
                hostname: request.hostname, resolver: resolver)
        }
        try Task.checkCancellation()
        guard clock.now < deadline else { throw UpstreamFailure.timedOut }
        let connection = try dialer.connection(to: approved)
        defer { connection.cancel() }
        return try await withTaskCancellationHandler {
            try await connection.start(timeout: min(limits.connectTimeout, clock.now.duration(to: deadline)))
            try await connection.send(request.encoded(), timeout: min(limits.idleTimeout, clock.now.duration(to: deadline)))
            var parser = UpstreamResponseDecoder(maximumHeaderBytes: limits.headerBytes,
                                                maximumBodyBytes: streaming ? limits.streamBytes : limits.responseBytes)
            var checkedHead = false
            while !parser.isComplete {
                try Task.checkCancellation()
                let received = try await connection.receive(timeout: min(limits.idleTimeout, clock.now.duration(to: deadline)))
                let parts = try parser.append(received.data)
                if let head = parser.head, !checkedHead {
                    if streaming {
                        let contentType = head.headers["content-type"]?.lowercased()
                            .split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
                        guard head.status == 200, contentType == "text/event-stream" else {
                            throw UpstreamFailure.unexpectedSSE
                        }
                    }
                    checkedHead = true
                }
                for part in parts {
                    try Task.checkCancellation()
                    guard clock.now < deadline else { throw UpstreamFailure.timedOut }
                    try await onBody(part)
                }
                if received.endOfStream { try parser.finish(); break }
            }
            try Task.checkCancellation()
            guard clock.now < deadline else { throw UpstreamFailure.timedOut }
            try parser.finish()
            guard let head = parser.head else { throw UpstreamFailure.malformedResponse }
            return head
        } onCancel: { connection.cancel() }
    }
}
