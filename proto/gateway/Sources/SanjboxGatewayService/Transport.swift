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
}

/// Minimální obousměrný byte kanál. Testy používají in-memory mock, takže CI
/// neotevírá žádný port; `POSIXChannel` je jen doplněk pro explicitní `--listen`.
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
        } catch let error as ConnectionFailure {
            throw error
        } catch let error as HTTPFailure {
            throw (error == .tooLarge ? ConnectionFailure.requestTooLarge : ConnectionFailure.malformedRequest)
        } catch {
            throw ConnectionFailure.malformedRequest
        }
        guard let request else { throw ConnectionFailure.incompleteRequest }
        let reply = try await service.dispatch(request)
        switch reply {
        case .response(let response): try await write(response)
        case .events(let producer): try await write(events: producer)
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
    private func write(events: SSEProducer) async throws {
        let writer = EventWriter(channel: channel, maximumEventBytes: maximumEventBytes)
        do {
            try await events { try await writer.send($0) }
            try await writer.finish()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if await !writer.started {
                // Admission failure before the first event is an ordinary error
                // response. Never send a second response after partial SSE.
                try await write(.error(StreamOutcome.failure(error).status))
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

/// Reálný loopback listener. Není součástí prototypu: konstruuje se jen na
/// explicitní `--listen 127.0.0.1:<port>` a žádný test ho nespouští.
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

    public init(address: Address) {
        self.address = address
    }

    /// Blokující accept smyčka; každé spojení obslouží jeden Task. Blokující
    /// syscall v async kontextu je vědomé omezení prototypu, ne produkční vzor.
    public func run(serving service: GatewayService) async throws {
        let descriptor = try Self.open(port: address.port)
        defer { Darwin.close(descriptor) }
        while true {
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(descriptor, $0, &length)
                }
            }
            if client < 0 {
                if errno == EINTR { continue }
                throw ConnectionFailure.acceptFailed
            }
            let channel = POSIXChannel(descriptor: client)
            Task {
                try? await LoopbackConnection(channel: channel).serve(serving: service)
                channel.close()
            }
            try Task.checkCancellation()
        }
    }

    static func open(port: UInt16) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ConnectionFailure.socketFailed }
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

final class POSIXChannel: ByteChannel, @unchecked Sendable {
    private let descriptor: Int32
    private let state = Mutex(false)

    init(descriptor: Int32) {
        self.descriptor = descriptor
        var one: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one,
                       socklen_t(MemoryLayout<Int32>.size))
    }

    func receive(maximumBytes: Int) async throws -> Data {
        var buffer = [UInt8](repeating: 0, count: max(1, Swift.min(maximumBytes, 65_536)))
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { return Data(buffer[0..<count]) }
            if count == 0 { return Data() }
            if errno == EINTR { continue }
            throw ConnectionFailure.receiveFailed
        }
    }

    func send(_ bytes: Data) async throws {
        try state.withLock { closed in
            guard !closed else { throw ConnectionFailure.sendFailed }
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    guard let base = raw.baseAddress else { throw ConnectionFailure.sendFailed }
                    let written = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                    if written > 0 {
                        offset += written
                        continue
                    }
                    if written < 0, errno == EINTR { continue }
                    throw ConnectionFailure.sendFailed
                }
            }
        }
    }

    func close() {
        state.withLock { closed in
            guard !closed else { return }
            closed = true
            Darwin.close(descriptor)
        }
    }
}
