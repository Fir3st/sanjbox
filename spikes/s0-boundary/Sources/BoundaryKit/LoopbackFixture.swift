import Darwin
import Foundation

enum LoopbackFixture {
    /// A real TCP round trip between two sockets created here. No host/port input, wildcard bind,
    /// DNS, external connection or negative cross-UID claim. Both endpoints close on every exit.
    static func run() throws -> [String: String] {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        let listener = try socket()
        defer { close(listener) }
        var bound = address(port: 0)
        let status = withUnsafePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard status == 0, listen(listener, 1) == 0 else { throw BoundaryError.invalid("owned loopback listener setup failed") }
        bound = try localAddress(listener)
        let client = try socket()
        defer { close(client) }
        let connected = withUnsafePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 || errno == EINPROGRESS else { throw BoundaryError.invalid("owned loopback connect failed") }
        try ready(client, events: Int16(POLLOUT), deadline: deadline)
        var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(client, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0
        else { throw BoundaryError.invalid("owned loopback connect incomplete") }
        let ownClient = try localAddress(client)
        try ready(listener, events: Int16(POLLIN), deadline: deadline)
        var peer = sockaddr_in(), peerSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let accepted = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &peerSize) }
        }
        guard accepted >= 0 else { throw BoundaryError.invalid("owned loopback accept failed") }
        defer { close(accepted) }
        try configure(accepted)
        // Reject an unrelated local peer before reading any bytes. No traffic content is logged.
        guard peer.sin_family == sa_family_t(AF_INET), peer.sin_addr.s_addr == ownClient.sin_addr.s_addr,
              peer.sin_port == ownClient.sin_port else { throw BoundaryError.invalid("unexpected peer on fixture listener") }
        let canary = Data(("SANJBOX-CANARY-A4-" + UUID().uuidString).utf8)
        try send(canary, to: client, deadline: deadline)
        let received = try receive(canary.count, from: accepted, deadline: deadline)
        guard received == canary else { throw BoundaryError.invalid("loopback positive control content mismatch") }
        let acknowledgment = Data("ACK:".utf8) + received
        try send(acknowledgment, to: accepted, deadline: deadline)
        guard try receive(acknowledgment.count, from: client, deadline: deadline) == acknowledgment
        else { throw BoundaryError.invalid("loopback acknowledgment mismatch") }
        return ["bind": "127.0.0.1:ephemeral", "canaryReceivedByServer": "true", "acknowledgedByClient": "true",
                "scope": "owned same-process TCP only; no ingress isolation verdict"]
    }
    private static func socket() throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BoundaryError.invalid("fixture socket creation failed") }
        do { try configure(fd); return fd } catch { close(fd); throw error }
    }
    private static func configure(_ fd: Int32) throws {
        var yes: Int32 = 1
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw BoundaryError.invalid("fixture socket configuration failed") }
    }
    private static func address(port: UInt16) -> sockaddr_in {
        var value = sockaddr_in()
        value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        value.sin_family = sa_family_t(AF_INET)
        value.sin_addr.s_addr = inet_addr("127.0.0.1")
        value.sin_port = port.bigEndian
        return value
    }
    private static func localAddress(_ fd: Int32) throws -> sockaddr_in {
        var value = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &value) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard result == 0, value.sin_addr.s_addr == inet_addr("127.0.0.1"), value.sin_port != 0
        else { throw BoundaryError.invalid("unexpected loopback socket address") }
        return value
    }
    private static func ready(_ fd: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw BoundaryError.invalid("loopback fixture deadline exceeded") }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let remaining = Int32(min((deadline - now) / 1_000_000 + 1, 2000))
            let status = poll(&item, 1, remaining)
            if status < 0 && errno == EINTR { continue }
            guard status > 0, item.revents & events != 0,
                  item.revents & Int16(POLLERR | POLLNVAL) == 0
            else { throw BoundaryError.invalid("loopback I/O unavailable or timed out") }
            return
        }
    }
    private static func send(_ bytes: Data, to fd: Int32, deadline: UInt64) throws {
        var offset = 0
        while offset < bytes.count {
            try ready(fd, events: Int16(POLLOUT), deadline: deadline)
            let count = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset, 0) }
            if count < 0 && [EAGAIN, EINTR].contains(errno) { continue }
            guard count > 0 else { throw BoundaryError.invalid("loopback send failed") }
            offset += count
        }
    }
    private static func receive(_ count: Int, from fd: Int32, deadline: UInt64) throws -> Data {
        var result = Data()
        while result.count < count {
            try ready(fd, events: Int16(POLLIN), deadline: deadline)
            var bytes = [UInt8](repeating: 0, count: count - result.count)
            let received = recv(fd, &bytes, bytes.count, 0)
            if received < 0 && [EAGAIN, EINTR].contains(errno) { continue }
            guard received > 0 else { throw BoundaryError.invalid("loopback closed before positive control completed") }
            result.append(contentsOf: bytes.prefix(received))
        }
        return result
    }
}
