import Darwin
import Foundation

public struct SocketAddress {
    var storage = sockaddr_storage()
    var length: socklen_t
    public init(_ endpoint: NetworkEndpoint) throws {
        if endpoint.host.contains(":") {
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let valid = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                    p.pointee.sin6_len = UInt8(length); p.pointee.sin6_family = sa_family_t(AF_INET6)
                    p.pointee.sin6_port = endpoint.port.bigEndian
                    return inet_pton(AF_INET6, endpoint.host, &p.pointee.sin6_addr) == 1
                }
            }
            guard valid else { throw ProvenanceError("invalid IPv6") }
        } else {
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let valid = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                    p.pointee.sin_len = UInt8(length); p.pointee.sin_family = sa_family_t(AF_INET)
                    p.pointee.sin_port = endpoint.port.bigEndian
                    return inet_pton(AF_INET, endpoint.host, &p.pointee.sin_addr) == 1
                }
            }
            guard valid else { throw ProvenanceError("invalid IPv4") }
        }
    }
    public mutating func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        let count = length
        return withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, count) } }
    }
    func endpoint() throws -> NetworkEndpoint { var copy = storage; return try NetworkIO.decode(&copy, length: length) }
}
public enum NetworkIO {
    public static func openSocket(_ registration: NetworkRegistration) throws -> Int32 {
        let family = registration.endpoint.family == "ipv4" ? AF_INET : AF_INET6
        let fd = socket(family, registration.transport == .tcp ? SOCK_STREAM : SOCK_DGRAM, 0)
        guard fd >= 0 else { throw ProvenanceError("socket errno \(errno)") }
        do {
            try configure(fd)
            if family == AF_INET6 {
                var one: Int32 = 1
                guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw ProvenanceError("v6-only errno \(errno)") }
            }
            return fd
        } catch { close(fd); throw error }
    }
    public static func configure(_ fd: Int32) throws {
        var one: Int32 = 1
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw ProvenanceError("socket configuration errno \(errno)") }
    }
    /// Absolute monotonic deadline, also checked after EINTR. No unbounded retries.
    public static func wait(_ fd: Int32, events: Int16, until deadline: UInt64) throws -> Bool {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(min((deadline - now + 999_999) / 1_000_000, 10_000))
            let result = poll(&descriptor, 1, milliseconds)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw ProvenanceError("poll errno \(errno)") }
            if result == 0 { continue }
            guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw ProvenanceError("invalid socket") }
            return true // Caller handles HUP/ERR with recv or SO_ERROR; data is never silently discarded.
        }
    }
    public static func endpoint(_ fd: Int32, peer: Bool = false) throws -> NetworkEndpoint {
        var storage = sockaddr_storage(); var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &storage) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { peer ? getpeername(fd, $0, &length) : getsockname(fd, $0, &length) }
        }
        guard rc == 0 else { throw ProvenanceError("socket endpoint errno \(errno)") }
        return try decode(&storage, length: length)
    }
    static func decode(_ storage: inout sockaddr_storage, length: socklen_t) throws -> NetworkEndpoint {
        guard [AF_INET, AF_INET6].contains(Int32(storage.ss_family)) else { throw ProvenanceError("unsupported socket family") }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST)); var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let rc = withUnsafePointer(to: &storage) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getnameinfo($0, length, &host, socklen_t(host.count), &service, socklen_t(service.count), NI_NUMERICHOST | NI_NUMERICSERV)
        } }
        guard rc == 0, let port = service.withUnsafeBufferPointer({ UInt16(String(cString: $0.baseAddress!)) }) else { throw ProvenanceError("numeric endpoint unavailable") }
        return .init(host: host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }, port: port)
    }
}
