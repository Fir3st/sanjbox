import Darwin
import Testing
@testable import S1Forward

/// Own sockets only; no serving threads, VNC service, process inventory or GUI probes.
@Suite(.serialized)
struct ForwarderLifecycleTests {
    @Test func rejectsExplicitSelfTargetAndReleasesPort() throws {
        let (fd, port) = try boundSocket()
        try #require(close(fd) == 0)
        expectFailure("self-target 127.0.0.1:\(port)") {
            try LoopbackForwarder(listenPort: port, targetPort: port)
        }
        let replacement = try LoopbackForwarder(listenPort: port, targetPort: 0)
        #expect(replacement.listenPort == port)
    }

    @Test func rejectsActualEphemeralSelfTargetAndClosesDescriptor() throws {
        // bind(0) chooses the real port; no guessed port or allocator race is involved.
        let (fd, port) = try boundSocket()
        expectFailure("self-target 127.0.0.1:\(port)") {
            try LoopbackForwarder(boundListener: fd, targetPort: port)
        }
        let replacement = try LoopbackForwarder(listenPort: port, targetPort: 0)
        #expect(replacement.listenPort == port)
    }

    @Test func getsocknameFailureClosesOwnedDescriptor() throws {
        var pipeFDs: [Int32] = [-1, -1]
        try #require(pipe(&pipeFDs) == 0)
        defer { close(pipeFDs[1]) }
        var original = stat()
        try #require(fstat(pipeFDs[0], &original) == 0)
        expectFailure("getsockname") {
            try LoopbackForwarder(boundListener: pipeFDs[0], targetPort: 0)
        }
        expectClosedOrReused(pipeFDs[0], original: original)
    }

    @Test func listenFailureClosesOwnedDescriptor() throws {
        let (fd, port) = try boundSocket(type: SOCK_DGRAM)
        expectFailure("listen") {
            try LoopbackForwarder(boundListener: fd, targetPort: 0)
        }
        let (replacement, reboundPort) = try boundSocket(type: SOCK_DGRAM, port: port)
        defer { close(replacement) }
        #expect(reboundPort == port)
    }

    @Test func deinitReleasesListenerPort() throws {
        let (fd, port) = try boundSocket()
        var forwarder: LoopbackForwarder? = try LoopbackForwarder(boundListener: fd, targetPort: 0)
        #expect(forwarder?.listenPort == port)
        forwarder = nil
        let replacement = try LoopbackForwarder(listenPort: port, targetPort: 0)
        #expect(replacement.listenPort == port)
    }

    @Test func repeatedlyReleasedInstancesLeavePortsReusable() throws {
        func releaseOne() throws -> UInt16 {
            let forwarder = try LoopbackForwarder(listenPort: 0, targetPort: 0)
            return forwarder.listenPort
        }
        for _ in 0..<16 {
            let port = try releaseOne()
            let replacement = try LoopbackForwarder(listenPort: port, targetPort: 0)
            #expect(replacement.listenPort == port)
        }
    }
}

/// Ownership of the returned bound socket transfers to the caller, including failed init tests.
private func boundSocket(type: Int32 = SOCK_STREAM, port: UInt16 = 0) throws -> (Int32, UInt16) {
    let fd = socket(AF_INET, type, 0)
    try #require(fd >= 0)
    var transferred = false
    defer { if !transferred { close(fd) } }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    try #require(bound == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    try #require(named == 0)
    transferred = true
    return (fd, UInt16(bigEndian: address.sin_port))
}

// Other suites may open a new object using the closed descriptor number. Pipes have a
// distinct inode on Darwin; allow reuse rather than requiring the number to stay invalid.
private func expectClosedOrReused(_ fd: Int32, original: stat) {
    var current = stat()
    let result = fstat(fd, &current)
    let code = errno
    let reused = current.st_dev != original.st_dev || current.st_ino != original.st_ino
        || current.st_mode != original.st_mode
    #expect((result == -1 && code == EBADF) || (result == 0 && reused))
}

private func expectFailure(_ operation: String, _ body: () throws -> LoopbackForwarder) {
    do {
        _ = try body()
        Issue.record("Expected failure in \(operation)")
    } catch {
        #expect(String(describing: error).hasPrefix("\(operation) failed:"))
    }
}
