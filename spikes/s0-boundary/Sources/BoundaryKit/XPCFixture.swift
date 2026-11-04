import Foundation

@objc protocol FixtureExchange {
    func exchange(_ request: Data, reply: @escaping (Data) -> Void)
}

/// The transport is real NSXPC; authorization is a mock with no audit-token, signature or session claim.
final class FixtureService: NSObject, FixtureExchange {
    let canary: Data
    init(canary: Data) { self.canary = canary }
    static func response(to request: Data, canary: Data) -> Data {
        guard request.count <= 128, request == Data("echo:".utf8) + canary else { return Data("denied".utf8) }
        return canary
    }
    func exchange(_ request: Data, reply: @escaping (Data) -> Void) {
        reply(Self.response(to: request, canary: canary))
    }
}

private final class FixtureListener: NSObject, NSXPCListenerDelegate {
    let service: FixtureService
    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []
    init(service: FixtureService) { self.service = service }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard connections.isEmpty else { return false }
        connection.exportedInterface = NSXPCInterface(with: FixtureExchange.self)
        connection.exportedObject = service
        connections.append(connection)
        connection.resume()
        return true
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        connections.forEach { $0.invalidate() }
        connections.removeAll()
    }
}

private final class ReplyLatch: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: Result<Data, BoundaryError>?
    func finish(_ value: Result<Data, BoundaryError>) {
        lock.lock(); defer { lock.unlock() }
        guard self.value == nil else { return }
        self.value = value
        semaphore.signal()
    }
    func result() throws -> Data {
        guard semaphore.wait(timeout: .now() + 2) == .success else { throw BoundaryError.invalid("owned XPC reply deadline exceeded") }
        lock.lock(); defer { lock.unlock() }
        guard let value else { throw BoundaryError.invalid("owned XPC reply missing") }
        return try value.get()
    }
}

enum XPCFixture {
    static func run() throws -> [String: String] {
        let canary = Data(("SANJBOX-CANARY-A4-" + UUID().uuidString).utf8)
        let delegate = FixtureListener(service: FixtureService(canary: canary))
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate(); delegate.close() }
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: FixtureExchange.self)
        connection.resume()
        defer { connection.invalidate() }
        func request(_ data: Data) throws -> Data {
            let latch = ReplyLatch()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                latch.finish(.failure(.invalid("owned XPC transport failed")))
            }) as? FixtureExchange else { throw BoundaryError.invalid("owned XPC proxy unavailable") }
            proxy.exchange(data) { reply in
                if reply.count <= 128 { latch.finish(.success(reply)) }
                else { latch.finish(.failure(.invalid("owned XPC reply limit"))) }
            }
            return try latch.result()
        }
        guard try request(Data("echo:".utf8) + canary) == canary
        else { throw BoundaryError.invalid("XPC positive control did not echo own canary") }
        guard try request(Data("forbidden-operation".utf8)) == Data("denied".utf8)
        else { throw BoundaryError.invalid("mock XPC denial control failed") }
        guard try request(Data("echo:".utf8) + canary) == canary
        else { throw BoundaryError.invalid("XPC post-denial positive control failed") }
        return ["transport": "anonymous NSXPCListener, same process", "positiveControls": "before and after denial",
                "authorization": "MOCK exact request match only", "globalServices": "not enumerated or contacted"]
    }
}
