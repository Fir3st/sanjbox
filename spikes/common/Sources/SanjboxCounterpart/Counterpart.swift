import Darwin
import Foundation
import SanjboxProbeKit
import Synchronization

/// Independent receiving side of network leak tests (WP0.4, PLAN S3/S5/S7).
///
/// Listens on TCP and UDP ports of a controlled host and records every connection, datagram,
/// byte count and canary that the application layer receives, independently of the pf rules
/// and gateway under test. A negative test passes on this side only when a complete run shows
/// no contact at all (see `CounterpartReport`).
///
/// One thread per listener and per TCP connection: the counterpart serves a handful of test
/// flows, and blocking reads keep the receive path easy to audit.
public final class Counterpart: Sendable {
    public struct Configuration: Sendable {
        public var bindAddress: String
        public var tcpPorts: [UInt16]
        public var udpPorts: [UInt16]
        /// Event log; must not exist yet, so one log always describes exactly one run.
        public var logURL: URL
        /// Raw captures; must be new or empty, for the same reason as the log.
        public var rawDirectory: URL
        /// Registered canaries are reported by token; any other canary by its prefix.
        public var canaries: [Canary]

        public init(
            bindAddress: String, tcpPorts: [UInt16], udpPorts: [UInt16], logURL: URL, rawDirectory: URL,
            canaries: [Canary]
        ) {
            self.bindAddress = bindAddress
            self.tcpPorts = tcpPorts
            self.udpPorts = udpPorts
            self.logURL = logURL
            self.rawDirectory = rawDirectory
            self.canaries = canaries
        }
    }

    /// Raw bytes kept per flow; byte counts and canary scanning continue past it.
    public static let rawLimit = 1 << 20
    /// Upper bound for draining one flow on stop, so a sender that never pauses cannot block it.
    static let drainLimit = 16 << 20

    /// Bound listeners with their actual ports (port 0 in the configuration picks a free one).
    public let listeners: [Listener]
    private let sockets: [Int32]
    private let output: CounterpartOutput
    private let scanner: CanaryScanner
    /// Self-pipe: one byte written on stop makes every poll in every loop return.
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let state = Mutex(State())
    private let logLock = Mutex(())
    private let threads = DispatchGroup()

    private struct State {
        var nextFlowID = 1
        var stopping = false
    }

    private init(
        configuration: Configuration, output: CounterpartOutput, sockets: [Int32], listeners: [Listener],
        wakeRead: Int32, wakeWrite: Int32
    ) {
        self.output = output
        self.sockets = sockets
        self.listeners = listeners
        self.wakeRead = wakeRead
        self.wakeWrite = wakeWrite
        scanner = CanaryScanner(canaries: configuration.canaries, matchAnyCanary: true)
    }

    /// Binds every listener, writes the `started` event and starts receiving.
    public static func start(_ configuration: Configuration) throws -> Counterpart {
        let output = try CounterpartOutput(log: configuration.logURL, raw: configuration.rawDirectory)

        var sockets: [Int32] = []
        var listeners: [Listener] = []
        var pipeFDs: [Int32] = [0, 0]
        do {
            let requested = configuration.tcpPorts.map { (CounterpartEvent.Transport.tcp, $0) }
                + configuration.udpPorts.map { (CounterpartEvent.Transport.udp, $0) }
            for (transport, port) in requested {
                let (fd, endpoint) = try bindSocket(transport, host: configuration.bindAddress, port: port)
                sockets.append(fd)
                listeners.append(Listener(transport: transport, endpoint: endpoint))
            }
            guard pipe(&pipeFDs) == 0 else { throw CounterpartError.system("pipe", errno: errno) }
        } catch {
            sockets.forEach { close($0) }
            output.close()  // Retain created evidence; a pathname may now name someone else’s file.
            throw error
        }

        let counterpart = Counterpart(
            configuration: configuration, output: output, sockets: sockets, listeners: listeners,
            wakeRead: pipeFDs[0], wakeWrite: pipeFDs[1]
        )
        counterpart.record(CounterpartEvent(kind: .started, listeners: listeners))
        for (fd, listener) in zip(sockets, listeners) {
            counterpart.spawn {
                switch listener.transport {
                case .tcp: counterpart.acceptLoop(fd, listener: listener)
                case .udp: counterpart.datagramLoop(fd, listener: listener)
                }
            }
        }
        return counterpart
    }

    /// Wakes every loop, drains what the kernel already received, closes all flows and writes
    /// `stopped`. Idempotent.
    public func stop() {
        let first = state.withLock { state in
            defer { state.stopping = true }
            return !state.stopping
        }
        guard first else { return }
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
        threads.wait()
        sockets.forEach { close($0) }
        close(wakeRead)
        close(wakeWrite)
        record(CounterpartEvent(kind: .stopped))
        output.close()
    }

    // MARK: - Receive loops

    private func acceptLoop(_ fd: Int32, listener: Listener) {
        while waitReadable(fd) {
            let (connection, remote) = capturingAddress { accept(fd, $0, $1) }
            guard connection >= 0 else { continue }  // EINTR, or the peer gave up before accept
            spawn { self.serve(connection, remote: remote, listener: listener) }
        }
        // Connections the kernel already completed did reach the counterpart: record them too.
        setNonBlocking(fd)
        while true {
            let (connection, remote) = capturingAddress { accept(fd, $0, $1) }
            if connection >= 0 {
                serve(connection, remote: remote, listener: listener)
            } else if errno != EINTR {
                return
            }
        }
    }

    private func serve(_ fd: Int32, remote: Endpoint?, listener: Listener) {
        defer { close(fd) }
        let flow = nextFlowID()
        let (_, local) = capturingAddress { getsockname(fd, $0, $1) }
        record(CounterpartEvent(kind: .accepted, flowID: flow, transport: .tcp, local: local, remote: remote))

        var capture = RawCapture(directory: output.raw, name: "\(flow)-tcp-\(listener.endpoint.port).bin")
        var stream = CanaryStreamScanner(scanner: scanner)
        var bytes = 0
        let endReason = receive(fd) { chunk in
            bytes += chunk.count
            stream.feed(chunk)
            capture.write(chunk)
        }
        capture.close()
        record(CounterpartEvent(
            kind: .closed, flowID: flow, transport: .tcp, local: local, remote: remote, bytes: bytes,
            findings: sorted(stream.findings), rawFile: capture.fileName, rawTruncated: capture.truncated,
            endReason: endReason
        ))
    }

    /// Reads until the peer closes or the counterpart stops; on stop, drains what is already buffered.
    private func receive(_ fd: Int32, _ consume: (Data) -> Void) -> String {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while waitReadable(fd) {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                consume(Data(buffer[..<count]))
            } else if count == 0 {
                return "peerClosed"
            } else if errno != EINTR && errno != EAGAIN {
                return "read errno \(errno)"
            }
        }
        setNonBlocking(fd)
        var drained = 0
        while drained < Self.drainLimit {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                consume(Data(buffer[..<count]))
                drained += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return count == 0 ? "peerClosed" : "counterpartStopped"
            }
        }
        return "counterpartStopped (drain limit reached)"
    }

    private func datagramLoop(_ fd: Int32, listener: Listener) {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        /// Receives and records one datagram; `nil` when nothing is pending.
        func receiveOne() -> Int? {
            let (count, remote) = capturingAddress { recvfrom(fd, &buffer, buffer.count, 0, $0, $1) }
            guard count >= 0 else { return errno == EINTR ? 0 : nil }
            recordDatagram(Data(buffer[..<count]), remote: remote, listener: listener)
            return count
        }
        while waitReadable(fd) { _ = receiveOne() }
        setNonBlocking(fd)
        var drained = 0
        while drained < Self.drainLimit, let count = receiveOne() { drained += count }
    }

    private func recordDatagram(_ data: Data, remote: Endpoint?, listener: Listener) {
        let flow = nextFlowID()
        var capture = RawCapture(directory: output.raw, name: "\(flow)-udp-\(listener.endpoint.port).bin")
        capture.write(data)
        capture.close()
        var findings = Set(scanner.findings(in: data))
        if let labels = DNSQuestion.joinedLabels(in: data) {
            findings.formUnion(scanner.findings(in: labels).map {
                CanaryScanner.Finding(token: $0.token, encoding: "dns-qname-\($0.encoding)")
            })
        }
        record(CounterpartEvent(
            kind: .datagram, flowID: flow, transport: .udp, local: listener.endpoint, remote: remote,
            bytes: data.count, findings: sorted(findings), rawFile: capture.fileName, rawTruncated: capture.truncated
        ))
    }

    // MARK: - Plumbing

    /// Blocks until `fd` is readable (true) or the counterpart is stopping (false).
    private func waitReadable(_ fd: Int32) -> Bool {
        var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0), pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
        while poll(&fds, 2, -1) < 0 {
            guard errno == EINTR else { fatalError("poll failed: errno \(errno)") }
        }
        return fds[1].revents == 0
    }

    private func spawn(_ body: @escaping @Sendable () -> Void) {
        threads.enter()
        Thread { [threads] in
            body()
            threads.leave()
        }.start()
    }

    private func nextFlowID() -> Int {
        state.withLock { state in
            defer { state.nextFlowID += 1 }
            return state.nextFlowID
        }
    }

    /// Losing an event would make the log claim less contact than happened, so a write failure
    /// aborts: the log then lacks `stopped` and the report marks the run invalid.
    private func record(_ event: CounterpartEvent) {
        logLock.withLock { _ in
            do { try output.record(event) } catch {
                fatalError("cannot write event log: \(error)")
            }
        }
    }

    private func sorted(_ findings: Set<CanaryScanner.Finding>) -> [CanaryScanner.Finding] {
        findings.sorted { ($0.token, $0.encoding) < ($1.token, $1.encoding) }
    }

    private static func bindSocket(
        _ transport: CounterpartEvent.Transport, host: String, port: UInt16
    ) throws -> (Int32, Endpoint) {
        var (storage, length) = try socketAddress(host, port: port)
        let family = Int32(storage.ss_family)
        let fd = socket(family, transport == .tcp ? SOCK_STREAM : SOCK_DGRAM, 0)
        guard fd >= 0 else { throw CounterpartError.system("socket", errno: errno) }
        var on: Int32 = 1
        var off: Int32 = 0
        let optionSize = socklen_t(MemoryLayout<Int32>.size)
        if transport == .tcp { setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, optionSize) }
        // `::` then also receives IPv4, reported as `::ffff:a.b.c.d`.
        if family == AF_INET6 { setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, optionSize) }
        let bound = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0, transport == .udp || listen(fd, SOMAXCONN) == 0 else {
            let error = CounterpartError.system("bind \(transport) \(host) port \(port)", errno: errno)
            close(fd)
            throw error
        }
        let (_, endpoint) = capturingAddress { getsockname(fd, $0, $1) }
        guard let endpoint else {
            close(fd)
            throw CounterpartError.system("getsockname", errno: errno)
        }
        return (fd, endpoint)
    }

    private static func socketAddress(_ host: String, port: UInt16) throws -> (sockaddr_storage, socklen_t) {
        var storage = sockaddr_storage()
        let isIPv6 = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { address in
                address.pointee.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                address.pointee.sin6_family = sa_family_t(AF_INET6)
                address.pointee.sin6_port = port.bigEndian
                return inet_pton(AF_INET6, host, &address.pointee.sin6_addr) == 1
            }
        }
        if isIPv6 { return (storage, socklen_t(MemoryLayout<sockaddr_in6>.size)) }

        storage = sockaddr_storage()
        let isIPv4 = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { address in
                address.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.pointee.sin_family = sa_family_t(AF_INET)
                address.pointee.sin_port = port.bigEndian
                return inet_pton(AF_INET, host, &address.pointee.sin_addr) == 1
            }
        }
        if isIPv4 { return (storage, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        throw CounterpartError.invalidAddress(host)
    }
}

public enum CounterpartError: Error, CustomStringConvertible {
    case invalidAddress(String)
    case rawDirectoryNotEmpty(String)
    case system(String, errno: Int32)

    public var description: String {
        switch self {
        case .invalidAddress(let host): "not a numeric IPv4 or IPv6 address: \(host)"
        case .rawDirectoryNotEmpty(let path): "raw directory is not empty: \(path)"
        case .system(let operation, let code): "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Runs a socket call that reports an address (accept, recvfrom, getsockname) and decodes it.
private func capturingAddress<Result>(
    _ call: (UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) -> Result
) -> (Result, Endpoint?) {
    var storage = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let result = withUnsafeMutablePointer(to: &storage) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { call($0, &length) }
    }
    guard storage.ss_family != 0 else { return (result, nil) }

    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
    let status = withUnsafePointer(to: &storage) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getnameinfo($0, length, &host, socklen_t(host.count), &service, socklen_t(service.count), NI_NUMERICHOST | NI_NUMERICSERV)
        }
    }
    guard status == 0 else { return (result, nil) }
    let hostName = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    let serviceName = service.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    return (result, Endpoint(host: hostName, port: UInt16(serviceName) ?? 0))
}

private func setNonBlocking(_ fd: Int32) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
}
