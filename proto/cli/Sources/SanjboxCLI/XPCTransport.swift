import Foundation
import SanjboxContracts

/// Transport framing only. The bytes in both directions are exactly the H1 envelopes.
@objc protocol HelperExchange {
    func exchange(_ request: Data, reply: @escaping (Data) -> Void)
}

/// One terminal result; deadline/connection failure cannot be undone by a late callback.
final class ReplyLatch: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private let deadline: DispatchTime
    private let now: @Sendable () -> UInt64
    private var value: Result<Data, CLIError>?

    init(timeout: TimeInterval, now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.deadline = .now() + timeout
        self.now = now
    }
    @discardableResult func finish(_ result: Result<Data, CLIError>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value == nil else { return false }
        value = now() < deadline.uptimeNanoseconds ? result : .failure(.timeout)
        ready.signal()
        return true
    }
    func wait() throws -> Data {
        if ready.wait(timeout: deadline) != .success { finish(.failure(.timeout)) }
        lock.lock(); defer { lock.unlock() }
        guard let value else { throw CLIError.timeout }
        if case .success = value, now() >= deadline.uptimeNanoseconds { throw CLIError.timeout }
        return try value.get()
    }
}

/// Each request owns one XPC connection/reply channel. No retries and no ambient service lookup.
/// Foundation endpoint is immutable; all connection state stays local to exchange().
public final class XPCTransport: HelperTransport, @unchecked Sendable {
    private let endpoint: NSXPCListenerEndpoint
    private let timeout: TimeInterval
    public init(endpoint: NSXPCListenerEndpoint, timeout: TimeInterval = 2) {
        self.endpoint = endpoint
        // A public caller cannot disable the bound through NaN, infinity or negative duration.
        self.timeout = timeout.isFinite && timeout > 0 && timeout <= 10 ? timeout : 2
    }
    public func exchange(_ request: Data) throws -> Data {
        guard request.count <= XPCEnvelope.maxBytes else { throw CLIError.invalidInput }
        let latch = ReplyLatch(timeout: timeout)
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperExchange.self)
        connection.interruptionHandler = { latch.finish(.failure(.connectionLost)) }
        connection.invalidationHandler = { latch.finish(.failure(.connectionLost)) }
        connection.resume()
        defer { connection.invalidate() }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            latch.finish(.failure(.connectionLost))
        }) as? HelperExchange else { throw CLIError.connectionLost }
        proxy.exchange(request) { bytes in
            guard bytes.count <= XPCEnvelope.maxBytes else {
                latch.finish(.failure(.invalidReply)); return
            }
            latch.finish(.success(bytes))
        }
        return try latch.wait()
    }
}

/// Private anonymous endpoint, retained in this process and never registered with launchd.
/// This is real NSXPC transport to a same-process mock, not an authentication/isolation proof.
public final class MockXPCServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    enum Response: Sendable { case reply(Data), disconnect, silent }
    typealias Responder = @Sendable (Data) throws -> Response
    private let listener = NSXPCListener.anonymous()
    private let lock = NSLock()
    private var connections: [UUID: NSXPCConnection] = [:]
    private var invalidated = false
    private var accepted = 0
    private let responder: Responder

    public convenience init(helper: MockHelper) {
        self.init(responder: { .reply(try helper.exchange($0)) })
    }
    init(responder: @escaping Responder) {
        self.responder = responder
        super.init()
        listener.delegate = self
        listener.resume()
    }
    public var endpoint: NSXPCListenerEndpoint { listener.endpoint }
    var acceptedConnections: Int {
        lock.lock(); defer { lock.unlock() }
        return accepted
    }
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Bounded fixture, not a product host-only authorization policy. This endpoint is local.
        guard !invalidated, connections.count < 16 else { return false }
        let id = UUID()
        let service = ExchangeService(responder: responder, connection: connection)
        connection.exportedInterface = NSXPCInterface(with: HelperExchange.self)
        connection.exportedObject = service
        connection.invalidationHandler = { [weak self] in self?.forget(id) }
        connections[id] = connection
        accepted += 1
        connection.resume()
        return true
    }
    private func forget(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        connections.removeValue(forKey: id)
    }
    public func invalidate() {
        lock.lock()
        invalidated = true
        let active = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        listener.invalidate()
        for connection in active { connection.invalidate() }
    }
    deinit { invalidate() }
}

private final class ExchangeService: NSObject, HelperExchange {
    private let responder: MockXPCServer.Responder
    private weak var connection: NSXPCConnection?
    init(responder: @escaping MockXPCServer.Responder, connection: NSXPCConnection) {
        self.responder = responder
        self.connection = connection
    }
    func exchange(_ request: Data, reply: @escaping (Data) -> Void) {
        do {
            switch try responder(request) {
            case .reply(let bytes): reply(bytes)
            case .disconnect: connection?.invalidate()
            case .silent: break // Deterministic test fault; the client deadline remains mandatory.
            }
        } catch {
            // Untrusted bytes cannot supply a trustworthy kind/zone for a failure reply.
            connection?.invalidate()
        }
    }
}
