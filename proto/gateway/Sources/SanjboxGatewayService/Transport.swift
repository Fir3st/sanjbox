import Darwin
import Foundation
import SanjboxGatewayCore
import Synchronization

public enum ConnectionFailure: Error, Equatable, Sendable {
    case malformedRequest
    case requestTooLarge
    case incompleteRequest
    case socketFailed
    case bindFailed
    case acceptFailed
    case receiveFailed
    case sendFailed
    case timedOut
    case originMismatch
}

/// Bounded byte transport; fixtures use memory and listener tests use loopback only.
public protocol ByteChannel: Sendable {
    /// Prázdná data znamenají konec proudu (EOF).
    func receive(maximumBytes: Int) async throws -> Data
    func send(_ bytes: Data) async throws
    func close()
}

/// Přečte jeden požadavek z kanálu, nechá ho rozhodnout `GatewayService`
/// a zapíše jednu odpověď. Framing i limity jsou pevné; žádný chunked vstup.
public struct LoopbackConnection: Sendable {
    private let channel: any ByteChannel
    private let maximumHeaderBytes: Int
    private let maximumBodyBytes: Int
    private let receiveChunkBytes: Int
    private let maximumEventBytes: Int

    public init(channel: any ByteChannel, maximumHeaderBytes: Int = 16_384,
                maximumBodyBytes: Int = 1_048_576, receiveChunkBytes: Int = 8_192,
                maximumEventBytes: Int = 65_536) {
        self.channel = channel
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumBodyBytes = maximumBodyBytes
        self.receiveChunkBytes = receiveChunkBytes
        self.maximumEventBytes = maximumEventBytes
    }

    public func serve(serving service: GatewayService) async throws {
        defer { channel.close() }
        var decoder = HTTPRequestDecoder(maximumHeaderBytes: maximumHeaderBytes,
                                         maximumBodyBytes: maximumBodyBytes)
        var total = 0
        var request: HTTPRequest?
        do {
            while request == nil {
                let chunk = try await channel.receive(maximumBytes: receiveChunkBytes)
                if chunk.isEmpty { break }
                total += chunk.count
                guard total <= maximumHeaderBytes + maximumBodyBytes else {
                    throw ConnectionFailure.requestTooLarge
                }
                request = try decoder.append(chunk)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ConnectionFailure {
            throw error
        } catch let error as HTTPFailure {
            throw (error == .tooLarge ? ConnectionFailure.requestTooLarge : ConnectionFailure.malformedRequest)
        } catch {
            throw ConnectionFailure.malformedRequest
        }
        guard let request else { throw ConnectionFailure.incompleteRequest }
        let writer = EventWriter(channel: channel, maximumEventBytes: maximumEventBytes)
        let reply = try await service.dispatch(request, finishingStream: { try await writer.finish() })
        switch reply {
        case .response(let response): try await write(response)
        case .events(let producer): try await write(events: producer, writer: writer, service: service)
        }
    }

    private func write(_ response: HTTPResponse) async throws {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        do {
            try await channel.send(Data(head.utf8) + response.body)
            await response.completeTransport(true)
        } catch {
            await response.completeTransport(false)
            throw error
        }
    }

    /// SSE se posílá po chuncích. Selhání producenta ukončí spojení bez
    /// koncového chunku, takže klient pozná zkrácení místo tichého úspěchu.
    private func write(events: SSEProducer, writer: EventWriter, service: GatewayService) async throws {
        do {
            try await events { try await writer.send($0) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if await !writer.started {
                // Admission failure before the first event is an ordinary error
                // response. Never send a second response after partial SSE.
                try await write(service.errorResponse(StreamOutcome.failure(error).status))
            }
        }
    }

    /// Jeden chunk přenosu `Transfer-Encoding: chunked`; velikost je hex bajtů.
    static func chunked(_ payload: Data) -> Data {
        var chunk = Data("\(String(payload.count, radix: 16))\r\n".utf8)
        chunk.append(payload)
        chunk.append(Data("\r\n".utf8))
        return chunk
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 429: return "Too Many Requests"
        case 413: return "Content Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }
}

/// Keeps header state across asynchronous emits without accumulating the stream.
private actor EventWriter {
    let channel: any ByteChannel
    let maximumEventBytes: Int
    private(set) var started = false

    init(channel: any ByteChannel, maximumEventBytes: Int) {
        self.channel = channel
        self.maximumEventBytes = maximumEventBytes
    }

    private func start() async throws {
        guard !started else { return }
        // Mark before sending: even a failing send may have written partial headers.
        started = true
        try await channel.send(Data(("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
            + "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n").utf8))
    }

    func send(_ event: SSEEvent) async throws {
        let payload = try event.encoded(maximumBytes: maximumEventBytes)
        try await start()
        try await channel.send(LoopbackConnection.chunked(payload))
    }

    func finish() async throws {
        try await start()
        try await channel.send(Data("0\r\n\r\n".utf8))
    }
}

/// Rozhraní listeneru, aby CLI šlo otestovat bez otevření portu: testy podsunou
/// mock, který jen zaznamená, že se smyčka spustila.
public protocol ListenerRunner: Sendable {
    func run(serving service: GatewayService) async throws
}

/// Opt-in test listener, not a zone-authentication boundary. All syscalls are
/// nonblocking, children are structured and bounded, and cancellation drains them.
public struct LoopbackListener: ListenerRunner {
    public struct Address: Sendable, Equatable, CustomStringConvertible {
        public let port: UInt16

        public init?(port: UInt16) {
            guard port > 0 else { return nil }
            self.port = port
        }

        /// Přijímá jen kanonický tvar `127.0.0.1:<port>`: ASCII číslice, žádné
        /// znaménko, žádná úvodní nula a port 1...65535. `127.0.0.1:+80` ani
        /// `127.0.0.1:080` nejsou totéž co `127.0.0.1:80`.
        public init?(text: String) {
            let prefix = "127.0.0.1:"
            guard text.hasPrefix(prefix) else { return nil }
            let digits = text.dropFirst(prefix.count)
            guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
                  digits.first != "0", let port = UInt16(digits), port > 0 else { return nil }
            self.port = port
        }

        public var description: String { text }
        public var text: String { "127.0.0.1:\(port)" }
    }

    private let address: Address
    private let maximumConnections: Int
    private let ioTimeout: Duration
    private let lifetime: Duration
    private let ready: @Sendable () -> Void

    public init(address: Address, maximumConnections: Int = 16,
                ioTimeout: Duration = .seconds(10), lifetime: Duration = .seconds(120),
                ready: @escaping @Sendable () -> Void = {}) {
        precondition((1...64).contains(maximumConnections))
        precondition(ioTimeout > .zero && lifetime > .zero)
        self.address = address
        self.maximumConnections = maximumConnections
        self.ioTimeout = ioTimeout
        self.lifetime = lifetime
        self.ready = ready
    }

    public func run(serving service: GatewayService) async throws {
        try Task.checkCancellation()
        for rule in service.policy.enabledRules {
            let origin: String?
            switch rule {
            case .npm(let npm): origin = npm.publicOrigin
            case .pypi(let pypi): origin = pypi.publicOrigin
            default: origin = nil
            }
            guard origin == nil || origin == "http://\(address.text)" else {
                throw ConnectionFailure.originMismatch
            }
        }
        try await run(serving: service, descriptor: Self.open(port: address.port))
    }

    /// Takes ownership of a pre-bound descriptor; permits race-free ephemeral-port tests.
    func run(serving service: GatewayService, descriptor: Int32) async throws {
        defer { Darwin.close(descriptor) }
        ready() // bind/listen succeeded; never claim readiness before this point.
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            var outstanding = 0
            while true {
                try Task.checkCancellation()
                if outstanding == maximumConnections {
                    _ = try await group.next()
                    outstanding -= 1
                }
                let client = accept(descriptor, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        try await Task.sleep(for: .milliseconds(5))
                        continue
                    }
                    throw ConnectionFailure.acceptFailed
                }
                let channel: POSIXChannel
                do { channel = try POSIXChannel(descriptor: client, ioTimeout: ioTimeout, lifetime: lifetime) }
                catch { Darwin.close(client); throw error }
                outstanding += 1
                group.addTask {
                    // A malformed/idle/disconnected client ends only its own connection.
                    try? await LoopbackConnection(channel: channel).serve(serving: service)
                    channel.close()
                }
            }
        }
    }

    static func open(port: UInt16) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ConnectionFailure.socketFailed }
        do { try POSIXChannel.configure(descriptor) }
        catch { Darwin.close(descriptor); throw error }
        var reuse: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse,
                       socklen_t(MemoryLayout<Int32>.size))
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = port.bigEndian
        local.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 16) == 0 else {
            Darwin.close(descriptor)
            throw ConnectionFailure.bindFailed
        }
        return descriptor
    }
}

final class POSIXChannel: ByteChannel, Sendable {
    private let descriptor: Int32
    private let state = Mutex(false)
    private let ioTimeout: Duration
    private let deadline: ContinuousClock.Instant

    /// The caller owns the descriptor until construction succeeds.
    init(descriptor: Int32, ioTimeout: Duration = .seconds(10), lifetime: Duration = .seconds(120)) throws {
        try Self.configure(descriptor)
        self.descriptor = descriptor
        self.ioTimeout = ioTimeout
        deadline = ContinuousClock.now.advanced(by: lifetime)
    }

    static func configure(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        let fdFlags = fcntl(descriptor, F_GETFD)
        var one: Int32 = 1
        guard flags >= 0, fdFlags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, fdFlags | FD_CLOEXEC) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ConnectionFailure.socketFailed
        }
    }

    private func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw ConnectionFailure.timedOut }
    }

    func receive(maximumBytes: Int) async throws -> Data {
        let limit = min(deadline, ContinuousClock.now.advanced(by: ioTimeout))
        var buffer = [UInt8](repeating: 0, count: max(1, min(maximumBytes, 65_536)))
        while true {
            try check(limit)
            let result: Int? = try state.withLock { closed in
                guard !closed else { throw ConnectionFailure.receiveFailed }
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count >= 0 { return count }
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return nil }
                throw ConnectionFailure.receiveFailed
            }
            if let result { return Data(buffer.prefix(result)) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func send(_ bytes: Data) async throws {
        let limit = min(deadline, ContinuousClock.now.advanced(by: ioTimeout))
        var offset = 0
        while offset < bytes.count {
            try check(limit)
            let count: Int? = try state.withLock { closed in
                guard !closed else { throw ConnectionFailure.sendFailed }
                return try bytes.withUnsafeBytes { raw in
                    let written = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written > 0 { return written }
                    if written < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return nil }
                    throw ConnectionFailure.sendFailed
                }
            }
            if let count { offset += count }
            else { try await Task.sleep(for: .milliseconds(5)) }
        }
    }

    func close() {
        state.withLock { closed in
            guard !closed else { return }
            closed = true
            Darwin.close(descriptor)
        }
    }

    deinit { close() }
}
