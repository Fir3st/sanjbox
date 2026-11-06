import Foundation
import Network

public struct GatewayLimits: Sendable {
    public let headerBytes: Int
    public let bodyBytes: Int
    public let responseBytes: Int
    public let connections: Int
    public let requestTimeout: Duration
    public let lifetime: Duration

    public init(headerBytes: Int = 16_384, bodyBytes: Int = 1_048_576,
                responseBytes: Int = 4_194_304, connections: Int = 32,
                requestTimeout: Duration = .seconds(10), lifetime: Duration = .seconds(120)) {
        precondition(headerBytes > 0 && bodyBytes >= 0 && responseBytes > 0 && connections > 0)
        precondition(requestTimeout > .zero && lifetime > .zero)
        self.headerBytes = headerBytes
        self.bodyBytes = bodyBytes
        self.responseBytes = responseBytes
        self.connections = connections
        self.requestTimeout = requestTimeout
        self.lifetime = lifetime
    }
}

public enum GatewayServerFailure: Error { case alreadyStarted, unavailable }

/// Unprivileged loopback-only laboratory listener. The main actor owns lifecycle
/// state; Network callbacks hop to it before accessing mutable state.
@MainActor public final class GatewayServer {
    private let router: TypedRouter
    private let limits: GatewayLimits
    private let tls: GatewayTLSConfiguration?
    private let queue = DispatchQueue(label: "sanjbox.gateway.network")
    private var listener: NWListener?
    private var sessions: [UUID: Session] = [:]
    public private(set) var port: UInt16?

    public init(router: TypedRouter, limits: GatewayLimits = GatewayLimits(), tls: GatewayTLSConfiguration? = nil) {
        self.router = router
        self.limits = limits
        self.tls = tls
    }

    /// No wildcard bind and no LAN mode. Port zero requests an ephemeral port.
    public func start(port requestedPort: UInt16 = 0) async throws -> UInt16 {
        guard listener == nil else { throw GatewayServerFailure.alreadyStarted }
        let parameters = tls?.parameters() ?? NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: requestedPort)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            diag("gateway newConnection \(connection.endpoint)")
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        do {
            let actualPort: UInt16 = try await boundedIO(timeout: limits.requestTimeout,
                                                         cancel: { listener.cancel() }) { [queue, listener] gate in
                listener.stateUpdateHandler = { [weak listener] state in
                    switch state {
                    case .ready: gate.finish(.success(listener?.port?.rawValue ?? 0))
                    case .failed: gate.finish(.failure(GatewayServerFailure.unavailable))
                    case .cancelled: gate.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
            try Task.checkCancellation()
            guard self.listener === listener else { throw CancellationError() }
            guard actualPort != 0 else { throw GatewayServerFailure.unavailable }
            port = actualPort
            return actualPort
        } catch {
            if self.listener === listener { stop() } else { listener.cancel() }
            throw error
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        let active = Array(sessions.values)
        sessions.removeAll()
        for session in active { session.close() }
    }

    private func accept(_ connection: NWConnection) {
        guard let port, listener != nil, sessions.count < limits.connections else {
            connection.cancel()
            return
        }
        let id = UUID()
        let session = Session(connection: connection, router: router, limits: limits, port: port) { [weak self] in
            self?.sessions.removeValue(forKey: id)
        }
        sessions[id] = session
        session.start(queue: queue)
    }
}

@MainActor private final class Session {
    let connection: NWConnection
    let router: TypedRouter
    let limits: GatewayLimits
    let port: UInt16
    let onClose: @MainActor () -> Void
    var decoder: HTTPRequestDecoder
    var closed = false
    var requestTimer: Task<Void, Never>?
    var lifetimeTimer: Task<Void, Never>?
    var work: Task<Void, Never>?

    init(connection: NWConnection, router: TypedRouter, limits: GatewayLimits, port: UInt16,
         onClose: @escaping @MainActor () -> Void) {
        self.connection = connection
        self.router = router
        self.limits = limits
        self.port = port
        self.onClose = onClose
        decoder = HTTPRequestDecoder(maximumHeaderBytes: limits.headerBytes, maximumBodyBytes: limits.bodyBytes)
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }
        connection.start(queue: queue)
        requestTimer = Task { [weak self, limits] in
            do { try await Task.sleep(for: limits.requestTimeout) } catch { return }
            self?.close()
        }
        lifetimeTimer = Task { [weak self, limits] in
            do { try await Task.sleep(for: limits.lifetime) } catch { return }
            self?.close()
        }
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        requestTimer?.cancel()
        lifetimeTimer?.cancel()
        work?.cancel()
        connection.cancel()
        onClose()
    }

    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, eof, error in
            Task { @MainActor in self?.received(data, eof: eof, failed: error != nil) }
        }
    }

    func received(_ data: Data?, eof: Bool, failed: Bool) {
        diag("gateway received \(data?.count ?? -1) eof=\(eof) failed=\(failed) closed=\(closed)")
        guard !closed else { return }
        guard !failed else { close(); return }
        do {
            if let request = try decoder.append(data ?? Data()) {
                diag("gateway request \(request.target)")
                requestTimer?.cancel()
                // Exact local authority prevents DNS-rebinding/browser Host tricks.
                guard request.headers["host"]?.lowercased() == "127.0.0.1:\(port)" else {
                    respond(.error(403))
                    return
                }
                work = Task { [self] in
                    defer { close() }
                    var started = false
                    do {
                        let reply = try await router.reply(to: request)
                        switch reply {
                        case .response(let response):
                            do {
                                guard response.body.count <= limits.responseBytes else { throw HTTPFailure.tooLarge }
                                let wire = try response.encoded()
                                started = true
                                try await send(wire)
                                await response.completion?(true)
                            } catch {
                                await response.completion?(false)
                                throw error
                            }
                        case .events(let produce):
                            started = true
                            diag("gateway sending SSE head")
                            try await send(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n".utf8))
                            // Each event is one chunk, no response accumulation. Network
                            // send completion is awaited before the producer can emit again.
                            try await produce { [self] event in try await sendEvent(event) }
                            try await send(Data("0\r\n\r\n".utf8))
                        }
                    } catch {
                        diag("gateway work error \(error) started=\(started)")
                        if !started, !closed { try? await send(HTTPResponse.error(500).encoded()) }
                        // No second response after partial headers/SSE. Cancel the stream.
                        // Handler errors are not reflected (may contain private upstream data).
                    }
                }
                monitorPeer()
            } else if eof { close() } else { receive() }
        } catch {
            respond(.error(error as? HTTPFailure == .tooLarge ? 413 : 400))
        }
    }

    /// The one request is complete. Only observe EOF/error or prohibited extra
    /// bytes; never parse a second request or accumulate a body. This propagates
    /// client disconnect while a producer is waiting on its upstream.
    func monitorPeer() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, eof, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if eof || error != nil || data?.isEmpty == false { self.close() }
                else { self.monitorPeer() }
            }
        }
    }

    func respond(_ response: HTTPResponse) {
        work = Task { [self] in
            defer { close() }
            try? await send(response.encoded())
        }
    }

    func sendEvent(_ event: SSEEvent) async throws {
        let payload = try event.encoded()
        var chunk = Data("\(String(payload.count, radix: 16))\r\n".utf8)
        chunk.append(payload)
        chunk.append(Data("\r\n".utf8))
        try await send(chunk)
    }

    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
