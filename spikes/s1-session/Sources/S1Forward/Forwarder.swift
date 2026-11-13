import Darwin
import Foundation

/// TCP forwarder between two loopback ports.
///
/// Screen Sharing.app refuses to connect to its own Mac's VNC server directly, but accepts the
/// same server behind another local port. This replaces the SSH tunnel of PLAN S1, so Remote
/// Login stays off. Both ends are fixed to 127.0.0.1: the forwarder can never expose the VNC
/// server beyond this Mac.
public final class LoopbackForwarder: Sendable {
    public let listenPort: UInt16
    public let targetPort: UInt16
    private let listener: Int32

    /// Binds `127.0.0.1:listenPort` (0 picks a free port, see `listenPort`).
    /// The target must differ from the actual bound port, including when requesting port 0.
    public convenience init(listenPort: UInt16, targetPort: UInt16) throws {
        try self.init(boundListener: bindLoopback(listenPort), targetPort: targetPort)
    }

    /// Takes ownership of an already bound socket, also on failure. Keeping this boundary
    /// internal lets tests exercise an OS-assigned ephemeral self-target deterministically.
    init(boundListener fd: Int32, targetPort: UInt16) throws {
        var transferred = false
        defer { if !transferred { close(fd) } }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw ForwarderError("getsockname", errno) }
        guard length == MemoryLayout<sockaddr_in>.size,
              actual.sin_family == AF_INET, actual.sin_port != 0,
              actual.sin_addr.s_addr == inet_addr("127.0.0.1")
        else { throw ForwarderError("bound loopback address", EINVAL) }
        let port = UInt16(bigEndian: actual.sin_port)
        guard port != targetPort else {
            throw ForwarderError("self-target 127.0.0.1:\(port)", EINVAL)
        }
        guard listen(fd, SOMAXCONN) == 0 else { throw ForwarderError("listen", errno) }
        listener = fd
        self.listenPort = port
        self.targetPort = targetPort
        transferred = true
    }

    deinit { close(listener) }

    /// Accepts connections forever, one pair of copy threads per connection.
    /// `report` receives one line per finished connection.
    public func serve(report: @escaping @Sendable (String) -> Void) -> Never {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            Thread { self.relay(client, report: report) }.start()
        }
    }

    private func relay(_ client: Int32, report: @Sendable (String) -> Void) {
        defer { close(client) }
        let target = socket(AF_INET, SOCK_STREAM, 0)
        guard target >= 0 else {
            report("\(ForwarderError("target socket", errno))")
            return
        }
        defer { close(target) }
        for fd in [client, target] {
            var on: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                report("\(ForwarderError("setsockopt SO_NOSIGPIPE", errno))")
                return
            }
        }
        var address = loopback(targetPort)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(target, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            report("cannot connect to 127.0.0.1:\(targetPort): \(String(cString: strerror(errno)))")
            return
        }
        let upstream = DispatchSemaphore(value: 0)
        let sent = Copied()
        Thread {
            sent.bytes = copy(from: client, to: target)
            upstream.signal()
        }.start()
        let received = copy(from: target, to: client)
        upstream.wait()
        report("connection closed: \(sent.bytes) bytes to target, \(received) bytes back")
    }
}

/// Byte count handed from the upstream copy thread; read only after its semaphore signal.
private final class Copied: @unchecked Sendable {
    var bytes = 0
}

/// Copies until EOF or error, then half-closes the destination so the other side sees EOF too.
private func copy(from source: Int32, to destination: Int32) -> Int {
    var buffer = [UInt8](repeating: 0, count: 64 << 10)
    var total = 0
    copying: while true {
        let count = read(source, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { break }
        var offset = 0
        while offset < count {
            let written = buffer[offset..<count].withUnsafeBytes { write(destination, $0.baseAddress, $0.count) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { break copying }
            offset += written
        }
        total += count
    }
    shutdown(destination, SHUT_WR)
    return total
}

/// Returns a bound descriptor whose ownership must immediately transfer to the initializer.
private func bindLoopback(_ port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ForwarderError("socket", errno) }
    var transferred = false
    defer { if !transferred { close(fd) } }
    var on: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw ForwarderError("setsockopt SO_REUSEADDR", errno)
    }
    var address = loopback(port)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { throw ForwarderError("bind 127.0.0.1:\(port)", errno) }
    transferred = true
    return fd
}

private func loopback(_ port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return address
}

public struct ForwarderError: Error, CustomStringConvertible {
    public var description: String
    init(_ operation: String, _ code: Int32) { description = "\(operation) failed: \(String(cString: strerror(code)))" }
}
