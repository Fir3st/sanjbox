import Darwin
import Foundation

public struct LiveAuthorization {
    public let identity: Identity
    public let signature: SignatureReport
    private init(identity: Identity, signature: SignatureReport) { self.identity = identity; self.signature = signature }
    public static func verify(expected: Identity) throws -> LiveAuthorization {
        // The first measurement is identity, then own code signature. No sockets/files before these checks.
        try expected.validate()
        let identity = try OwnIdentity.capture(expected: expected)
        let signature = try SignatureReport.own()
        guard signature.permitsLive else { throw IngressError("invalid measurement: hardened runtime/entitlement prerequisite missing; no sockets opened") }
        return .init(identity: identity, signature: signature)
    }
}
public struct SmokeEvent: Codable, Sendable {
    public var family: IPFamily
    public var operation: String
    public var elapsedMs: Int
    public var port: UInt16
    public var errnoValue: Int32?
    public var bytes: Int
}
public struct FamilySmoke: Codable, Sendable {
    public var family: IPFamily
    public var status: String
    public var events: [SmokeEvent]
    public var problem: String?
}
public struct SmokeReport: Codable, Sendable {
    public var schemaVersion = 1
    public var runID: UUID
    public var scope = "measured same-process/UID loopback transport control; no independent oracle; no same-zone or S3b proof"
    public var portBasis = "ephemeralFixture"
    public var gate = "S3b unverified"
    public var identity: Identity
    public var signature: SignatureReport
    public var families: [FamilySmoke]
    public var socketCleanup = "all owned descriptors closed before report"
}
private struct SocketError: Error {
    var operation: String
    var code: Int32
}
private final class OwnedSocket {
    private(set) var fd: Int32
    init(_ family: IPFamily) throws {
        fd = Darwin.socket(family == .ipv4 ? AF_INET : AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(operation: "socket", code: errno) }
        do {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw SocketError(operation: "nonblock", code: errno) }
            var one: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw SocketError(operation: "nosigpipe", code: errno) }
            if family == .ipv6 {
                guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw SocketError(operation: "ipv6only", code: errno) }
            }
        } catch { close(); throw error }
    }
    init(accepted: Int32) throws {
        fd = accepted
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { close(); throw SocketError(operation: "acceptedNonblock", code: errno) }
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { close(); throw SocketError(operation: "acceptedNoSIGPIPE", code: errno) }
    }
    func close() { if fd >= 0 { _ = Darwin.close(fd); fd = -1 } }
    deinit { close() }
}
private func address<T>(_ family: IPFamily, _ port: UInt16, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) rethrows -> T {
    if family == .ipv4 {
        var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian; a.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)
        return try withUnsafePointer(to: &a) { p in try p.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    }
    var a = sockaddr_in6(); a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); a.sin6_family = sa_family_t(AF_INET6)
    a.sin6_port = port.bigEndian; a.sin6_addr = in6addr_loopback
    return try withUnsafePointer(to: &a) { p in try p.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
}
private func boundPort(_ socket: OwnedSocket, _ family: IPFamily) throws -> UInt16 {
    if family == .ipv4 {
        var a = sockaddr_in(); var n = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &a) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket.fd, $0, &n) } }
        guard result == 0, a.sin_addr.s_addr == UInt32(0x7f000001).bigEndian else { throw IngressError("unexpected bound IPv4 endpoint") }
        return UInt16(bigEndian: a.sin_port)
    }
    var a = sockaddr_in6(); var n = socklen_t(MemoryLayout<sockaddr_in6>.size)
    let result = withUnsafeMutablePointer(to: &a) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket.fd, $0, &n) } }
    var loop = in6addr_loopback
    let same = withUnsafeBytes(of: &a.sin6_addr) { lhs in withUnsafeBytes(of: &loop) { rhs in lhs.elementsEqual(rhs) } }
    guard result == 0, same else { throw IngressError("unexpected bound IPv6 endpoint") }
    return UInt16(bigEndian: a.sin6_port)
}
private func ready(_ fd: Int32, _ events: Int32, until deadline: Double) throws {
    while true {
        let left = deadline - ProcessInfo.processInfo.systemUptime
        guard left > 0 else { throw IngressError("socket phase deadline exceeded") }
        var p = pollfd(fd: fd, events: Int16(events), revents: 0)
        let rc = poll(&p, 1, Int32(min(100, max(1, left * 1000))))
        if rc < 0 && errno == EINTR { continue }
        guard rc >= 0 else { throw SocketError(operation: "poll", code: errno) }
        if rc == 0 { continue }
        if Int32(p.revents) & (POLLNVAL | POLLERR) != 0 { throw IngressError("socket poll error") }
        if Int32(p.revents) & (events | POLLHUP) != 0 { return }
    }
}
private func transfer(_ fd: Int32, bytes: [UInt8], until deadline: Double) throws {
    var sent = 0
    while sent < bytes.count {
        try ready(fd, POLLOUT, until: deadline)
        let n = bytes.withUnsafeBytes { p in Darwin.send(fd, p.baseAddress!.advanced(by: sent), bytes.count - sent, 0) }
        if n < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
        guard n > 0 else { throw SocketError(operation: "send", code: errno) }
        sent += n
    }
}
private func receive(_ fd: Int32, count: Int, until deadline: Double) throws -> [UInt8] {
    var result: [UInt8] = []; result.reserveCapacity(count)
    while result.count < count {
        try ready(fd, POLLIN, until: deadline)
        var buffer = [UInt8](repeating: 0, count: count - result.count)
        let n = recv(fd, &buffer, buffer.count, 0)
        if n < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
        guard n > 0 else { throw IngressError("unexpected EOF/receive failure") }
        result.append(contentsOf: buffer.prefix(n))
    }
    return result
}

public enum LoopbackSmoke {
    /// The sole live socket producer. No public address/port/command inputs exist.
    public static func run(authorization: LiveAuthorization, runID: UUID) -> SmokeReport {
        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + 8 // both families share one finite socket-phase budget
        let families = IPFamily.allCases.map { family in measure(family, runID: runID, start: start, deadline: deadline) }
        return SmokeReport(runID: runID, identity: authorization.identity, signature: authorization.signature, families: families)
    }
    private static func measure(_ family: IPFamily, runID: UUID, start: Double, deadline: Double) -> FamilySmoke {
        var events: [SmokeEvent] = []
        var port: UInt16 = 0
        func record(_ operation: String, _ code: Int32? = nil, bytes: Int = 0) {
            events.append(.init(family: family, operation: operation, elapsedMs: Int((ProcessInfo.processInfo.systemUptime - start) * 1000), port: port, errnoValue: code, bytes: bytes))
        }
        do {
            let listener = try OwnedSocket(family); defer { listener.close() }
            let bindResult = address(family, 0) { Darwin.bind(listener.fd, $0, $1) }
            guard bindResult == 0 else { throw SocketError(operation: "bindLoopback", code: errno) }
            port = try boundPort(listener, family)
            guard port > 0, listen(listener.fd, 1) == 0 else { throw SocketError(operation: "listen", code: errno) }
            record("boundAndListening")
            try roundtrip(listener, family: family, port: port, nonce: "C3:\(runID.uuidString):before", deadline: deadline) { op, bytes in record("before.\(op)", bytes: bytes) }
            let collision = try OwnedSocket(family); defer { collision.close() }
            let rc = address(family, port) { Darwin.bind(collision.fd, $0, $1) }
            let code = rc == 0 ? 0 : errno
            record("heldPortCollision", code)
            guard rc == -1, code == EADDRINUSE else { throw IngressError("held own endpoint did not produce EADDRINUSE") }
            collision.close(); listener.close(); record("originalListenerClosed")
            let recovery = try OwnedSocket(family); defer { recovery.close() }
            guard address(family, port, { Darwin.bind(recovery.fd, $0, $1) }) == 0, listen(recovery.fd, 1) == 0 else { throw SocketError(operation: "rebindAfterClose", code: errno) }
            record("reboundAndListening")
            try roundtrip(recovery, family: family, port: port, nonce: "C3:\(runID.uuidString):after", deadline: deadline) { op, bytes in record("after.\(op)", bytes: bytes) }
            recovery.close(); record("allFamilySocketsClosed")
            return .init(family: family, status: "transportControlObserved", events: events, problem: nil)
        } catch let error as SocketError {
            record(error.operation, error.code)
            let unsupported = family == .ipv6 && ((error.operation == "socket" && [EAFNOSUPPORT, EPROTONOSUPPORT].contains(error.code)) || (error.operation == "bindLoopback" && error.code == EADDRNOTAVAIL))
            return .init(family: family, status: unsupported ? "missingIPv6Unsupported" : "transportControlFailed", events: events, problem: "\(error.operation) errno=\(error.code); all owned descriptors closed")
        } catch {
            return .init(family: family, status: "transportControlFailed", events: events, problem: "\(error); all owned descriptors closed")
        }
    }
    private static func roundtrip(_ listener: OwnedSocket, family: IPFamily, port: UInt16, nonce: String,
                                  deadline: Double, record: (String, Int) -> Void) throws {
        let payload = Array(nonce.utf8)
        guard payload.count <= 128 else { throw IngressError("payload bound") }
        let client = try OwnedSocket(family); defer { client.close() }
        let rc = address(family, port) { Darwin.connect(client.fd, $0, $1) }
        if rc != 0 && errno != EINPROGRESS { throw SocketError(operation: "connect", code: errno) }
        try ready(client.fd, POLLOUT, until: deadline)
        var code: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(client.fd, SOL_SOCKET, SO_ERROR, &code, &length) == 0, code == 0 else { throw SocketError(operation: "connectCompletion", code: code) }
        try ready(listener.fd, POLLIN, until: deadline)
        let acceptedFD = accept(listener.fd, nil, nil)
        guard acceptedFD >= 0 else { throw SocketError(operation: "accept", code: errno) }
        let receiver = try OwnedSocket(accepted: acceptedFD); defer { receiver.close() }
        record("accepted", 0) // acceptance is recorded even if no payload were to arrive
        try transfer(client.fd, bytes: payload, until: deadline)
        let received = try receive(receiver.fd, count: payload.count, until: deadline)
        guard received == payload else { throw IngressError("receiver nonce mismatch") }
        record("receiverNonce", received.count)
        try transfer(receiver.fd, bytes: received, until: deadline)
        guard try receive(client.fd, count: payload.count, until: deadline) == payload else { throw IngressError("echo nonce mismatch") }
        record("clientEcho", payload.count)
        // Client initiates FIN, so the test listener can be rebound without SO_REUSEADDR.
        guard shutdown(client.fd, SHUT_WR) == 0 else { throw SocketError(operation: "clientShutdown", code: errno) }
        try ready(receiver.fd, POLLIN, until: deadline)
        var byte: UInt8 = 0
        guard recv(receiver.fd, &byte, 1, 0) == 0 else { throw IngressError("receiver EOF missing") }
        receiver.close()
        try ready(client.fd, POLLIN, until: deadline)
        guard recv(client.fd, &byte, 1, 0) == 0 else { throw IngressError("client EOF missing") }
        client.close(); record("flowClosed", 0)
    }
}
