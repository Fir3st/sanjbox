import Darwin
import Foundation
import Testing
@testable import S1Forward
@testable import S1Probe

// These run in the developer's own console session: they check that the probe's measurements
// work and verify themselves, not that any zone session passes S1.

@Test func offscreenWorkloadMatchesCPUReference() throws {
    let result = try OffscreenWorkload.run()
    #expect(result.mismatchedPixels == 0)
    #expect(result.verifiedPixels == 4096)
    #expect(result.gpuMillisecondsMedian > 0)
}

@Test func cpuReferenceDependsOnFrameAndIterations() {
    let base = OffscreenWorkload.expectedPixel(x: 10, y: 20, frame: 59, iterations: 512)
    #expect(base != OffscreenWorkload.expectedPixel(x: 10, y: 20, frame: 58, iterations: 512))
    #expect(base != OffscreenWorkload.expectedPixel(x: 10, y: 20, frame: 59, iterations: 511))
    #expect(base != OffscreenWorkload.expectedPixel(x: 11, y: 20, frame: 59, iterations: 512))
}

@Test func uidProcessesIncludeThisProcess() {
    let processes = UIDProcesses.capture(largest: .max)
    #expect(processes.uid == geteuid())
    let own = processes.largest.first { $0.pid == getpid() }
    #expect((own?.physicalFootprintBytes ?? 0) > 0)
    #expect(processes.physicalFootprintBytes >= own?.physicalFootprintBytes ?? 0)
}

@Test func consoleSessionHasADisplayAndMetalDevice() {
    let displays = DisplayInfo.online()
    #expect(displays.contains { $0.isMain && $0.pixelWidth > 0 && $0.scale >= 1 })
    #expect(MetalDeviceInfo.all().contains { $0.isSystemDefault })
}

@Test func percentileUsesNearestRank() {
    #expect(percentile([5, 1, 3, 2, 4], 0.5) == 3)
    #expect(percentile([5, 1, 3, 2, 4], 0.95) == 5)
    #expect(percentile([7], 0.95) == 7)
}

/// Echo server on loopback that answers each connection with its input, then closes.
private func startEchoServer() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    try #require(bound == 0 && listen(fd, 8) == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    Thread {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var received: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 4096)
            while case let count = read(client, &buffer, buffer.count), count > 0 { received += buffer[..<count] }
            _ = received.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            close(client)
        }
    }.start()
    return UInt16(bigEndian: address.sin_port)
}

@Test func forwarderRelaysBothDirectionsAndHalfCloses() throws {
    let echo = try startEchoServer()
    let forwarder = try LoopbackForwarder(listenPort: 0, targetPort: echo)
    Thread { forwarder.serve { _ in } }.start()

    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = forwarder.listenPort.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    try #require(connected == 0)

    // Larger than one copy buffer, so the relay loops; the echo answers only after our EOF.
    let payload = (0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
    let sent = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    try #require(sent == payload.count)
    shutdown(fd, SHUT_WR)

    var echoed: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 65536)
    while case let count = read(fd, &buffer, buffer.count), count > 0 { echoed += buffer[..<count] }
    #expect(echoed == payload)
}
