import Darwin
import Foundation
import SanjboxContracts
import SanjboxGatewayCore
import Synchronization
import XCTest
@testable import SanjboxGatewayService

final class ListenerTests: XCTestCase {
    private func client(port: UInt16, timeout: Duration = .seconds(2)) throws -> POSIXChannel {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConnectionFailure.socketFailed }
        do {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else { throw ConnectionFailure.socketFailed }
            return try POSIXChannel(descriptor: fd, ioTimeout: timeout)
        } catch { Darwin.close(fd); throw error }
    }

    private func localAddress(_ fd: Int32) throws -> sockaddr_in {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard result == 0 else { throw ConnectionFailure.socketFailed }
        return address
    }

    private func readAll(_ client: POSIXChannel) async throws -> Data {
        var result = Data()
        while true {
            let bytes = try await client.receive(maximumBytes: 8192)
            if bytes.isEmpty { return result }
            result.append(bytes)
        }
    }

    func testRealListenerBindsLoopbackServesAndCancelsWithIdleClient() async throws {
        let fd = try LoopbackListener.open(port: 0)
        let address = try localAddress(fd)
        XCTAssertEqual(address.sin_addr.s_addr, inet_addr("127.0.0.1"))
        XCTAssertNotEqual(fcntl(fd, F_GETFL) & O_NONBLOCK, 0)
        XCTAssertNotEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0)
        let port = UInt16(bigEndian: address.sin_port)
        let service = try GatewayService(policy: Fixture.policy([Fixture.npm()]))
        let ready = Mutex(false)
        let listener = LoopbackListener(address: .init(port: port)!, ready: { ready.withLock { $0 = true } })
        let running = Task { try await listener.run(serving: service, descriptor: fd) }
        let idle = try client(port: port)
        let active = try client(port: port)
        defer { idle.close(); active.close(); running.cancel() }
        try await active.send(requestWire("GET", "/unknown"))
        let response = try await readAll(active)
        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 404 "))
        XCTAssertTrue(ready.withLock { $0 })
        let started = ContinuousClock.now
        running.cancel()
        do { try await running.value; XCTFail("must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        let eof = try await idle.receive(maximumBytes: 1)
        XCTAssertTrue(eof.isEmpty)
        let rebound = try LoopbackListener.open(port: port)
        Darwin.close(rebound)
    }

    func testIdleConnectionDeadlineReleasesTheOnlySlotForQueuedClient() async throws {
        let fd = try LoopbackListener.open(port: 0)
        let port = UInt16(bigEndian: try localAddress(fd).sin_port)
        let service = try GatewayService(policy: Fixture.policy([Fixture.npm()]))
        let listener = LoopbackListener(address: .init(port: port)!, maximumConnections: 1,
                                        ioTimeout: .milliseconds(250))
        let running = Task { try await listener.run(serving: service, descriptor: fd) }
        let idle = try client(port: port)
        let queued = try client(port: port, timeout: .milliseconds(70))
        defer { idle.close(); queued.close(); running.cancel() }
        // Connections enter the kernel accept queue in order; only the first may be serviced.
        try await queued.send(requestWire("GET", "/unknown"))
        do { _ = try await queued.receive(maximumBytes: 8192); XCTFail("connection cap bypassed") }
        catch { XCTAssertEqual(error as? ConnectionFailure, .timedOut) }
        try await Task.sleep(for: .milliseconds(240))
        let response = try await readAll(queued)
        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 404 "))
        let eof = try await idle.receive(maximumBytes: 1)
        XCTAssertTrue(eof.isEmpty)
        running.cancel()
        _ = try? await running.value
    }

    func testNoClientsCancellationClosesListeningDescriptor() async throws {
        let fd = try LoopbackListener.open(port: 0)
        let port = UInt16(bigEndian: try localAddress(fd).sin_port)
        let service = try GatewayService(policy: Fixture.policy([Fixture.npm()]))
        let listener = LoopbackListener(address: .init(port: port)!)
        let running = Task { try await listener.run(serving: service, descriptor: fd) }
        try await Task.sleep(for: .milliseconds(20))
        running.cancel()
        do { try await running.value; XCTFail("must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fcntl(fd, F_GETFD), -1)
        let rebound = try LoopbackListener.open(port: port)
        Darwin.close(rebound)
    }

    func testSocketWriteTimeoutCloseAndPeerResetAreBounded() async throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let sender = try POSIXChannel(descriptor: pair[0], ioTimeout: .milliseconds(50))
        defer { sender.close(); Darwin.close(pair[1]) }
        do { try await sender.send(Data(repeating: 65, count: 4_194_304)); XCTFail("must time out") }
        catch { XCTAssertEqual(error as? ConnectionFailure, .timedOut) }
        sender.close()
        do { _ = try await sender.receive(maximumBytes: 1); XCTFail("closed fd") }
        catch { XCTAssertEqual(error as? ConnectionFailure, .receiveFailed) }
        sender.close()
    }

    func testPeerCloseCannotTerminateProcessWithSIGPIPE() async throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let sender = try POSIXChannel(descriptor: pair[0])
        Darwin.close(pair[1])
        defer { sender.close() }
        do { try await sender.send(Data("fixture".utf8)); XCTFail("closed peer") }
        catch { XCTAssertEqual(error as? ConnectionFailure, .sendFailed) }
    }
    func testTotalChannelDeadlineSurvivesSuccessfulReads() async throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let receiver = try POSIXChannel(descriptor: pair[0], ioTimeout: .seconds(2), lifetime: .milliseconds(50))
        let sender = try POSIXChannel(descriptor: pair[1])
        defer { receiver.close(); sender.close() }
        try await sender.send(Data([65]))
        let first = try await receiver.receive(maximumBytes: 1)
        XCTAssertEqual(first, Data([65]))
        try await Task.sleep(for: .milliseconds(70))
        try await sender.send(Data([66]))
        do { _ = try await receiver.receive(maximumBytes: 1); XCTFail("lifetime must not renew") }
        catch { XCTAssertEqual(error as? ConnectionFailure, .timedOut) }
    }

    func testListenerCancellationDrainsActiveModelHandlerAndAuditsCancellation() async throws {
        let fd = try LoopbackListener.open(port: 0)
        let port = UInt16(bigEndian: try localAddress(fd).sin_port)
        let (entered, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (release, resume) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { signal.finish(); resume.finish() }
        let service = try GatewayService(policy: Fixture.policy([Fixture.model()]),
            upstream: UpstreamClient(resolver: HeldResolver(entered: signal, release: release)))
        let listener = LoopbackListener(address: .init(port: port)!)
        let running = Task { try await listener.run(serving: service, descriptor: fd) }
        let channel = try client(port: port)
        defer { running.cancel(); channel.close() }
        try await channel.send(requestWire("POST", "/model/v1/messages", body: encodeModelRequest()))
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        running.cancel()
        do { try await running.value; XCTFail("must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        let records = await service.auditRecords()
        XCTAssertEqual(records.map(\.decision), [.cancelled])
        let eof = try await channel.receive(maximumBytes: 8192)
        XCTAssertTrue(eof.isEmpty)
    }

    func testListenerRejectsMismatchedPublicOriginBeforeBinding() async throws {
        let ready = Mutex(false)
        let service = try GatewayService(policy: Fixture.policy([Fixture.npm()]))
        let listener = LoopbackListener(address: .init(port: 1)!, ready: { ready.withLock { $0 = true } })
        do { try await listener.run(serving: service); XCTFail("origin mismatch") }
        catch { XCTAssertEqual(error as? ConnectionFailure, .originMismatch) }
        XCTAssertFalse(ready.withLock { $0 })
    }

    func testRealListenerCompletesSyntheticArtifactAndPreservesHandlerAudit() async throws {
        let fd = try LoopbackListener.open(port: 0)
        let port = UInt16(bigEndian: try localAddress(fd).sin_port)
        let rule = GatewayRule.npm(NPMRule(publicOrigin: "http://127.0.0.1:\(port)",
                                           upstreamHostname: "registry.example"))
        let upstream = try artifactUpstream(pypi: false)
        let service = try GatewayService(policy: Fixture.policy([rule]), upstream: upstream.client)
        let listener = LoopbackListener(address: .init(port: port)!)
        let running = Task { try await listener.run(serving: service, descriptor: fd) }
        let channel = try client(port: port)
        defer { running.cancel(); channel.close() }
        try await channel.send(requestWire("GET", "/npm/fixture/-/fixture-1.0.0.tgz"))
        let response = try await readAll(channel)
        XCTAssertTrue(response.suffix(artifactBytes.count).elementsEqual(artifactBytes))
        let downloads = await service.npmDownloadRecords()
        XCTAssertEqual(downloads.map(\.state), [.transportAccepted])
        XCTAssertEqual(upstream.calls.count, 3)
        running.cancel()
        _ = try? await running.value
    }

    func testH1WirePolicyReachesRealListenerHandlerAndRejectsExcessBeforeUpstream() async throws {
        let fd = try LoopbackListener.open(port: 0)
        let port = UInt16(bigEndian: try localAddress(fd).sin_port)
        let policy = NetworkPolicy(zoneID: "a1b2", gates: [TypedGate(id: "registry-grant", type: .npm,
            upstream: "registry.example", requestBytesLimit: 1, responseBytesLimit: 4_096)])
        let rule = try GatewayRule.npm(NPMRule(mount: "/bound", publicOrigin: "http://127.0.0.1:\(port)",
            upstreamHostname: "registry.example", limits: RegistryRuleLimits(metadataBytes: 4_096, artifactBytes: 4_096)))
        let adapter = try H1GatewayAdapter.decode(policy.encoded(), configuration: H1GatewayConfiguration(
            auditCapacity: 8, rulesByGateID: ["registry-grant": rule]))
        let upstream = try artifactUpstream(pypi: false)
        let service = try GatewayService(adapting: adapter, upstreamFactory: { upstream.client(limits: $0) })
        let listener = LoopbackListener(address: .init(port: port)!)
        let running = Task { try await listener.run(serving: service, descriptor: fd) }
        defer { running.cancel() }
        for (target, input, expected) in [("/bound/fixture/-/fixture-1.0.0.tgz", Data(), 200),
                                           ("/bound/fixture", Data("xx".utf8), 413), ("/npm/fixture", Data(), 404)] {
            let channel = try client(port: port)
            defer { channel.close() }
            try await channel.send(requestWire("GET", target, body: input))
            let response = try await readAll(channel)
            XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 \(expected) "))
            if expected == 200 { XCTAssertTrue(response.suffix(artifactBytes.count).elementsEqual(artifactBytes)) }
            XCTAssertEqual(upstream.calls.count, 3, "denied requests cannot reach any upstream")
        }
        XCTAssertEqual(service.networkPolicy, policy)
        let downloads = await service.npmDownloadRecords()
        XCTAssertEqual(downloads.map(\.state), [.transportAccepted])
        let records = await service.auditRecords()
        XCTAssertEqual(records.map(\.decision), [.routed, .denied, .denied])
        XCTAssertEqual(records.map(\.reason), ["", "h1RequestLimit", "operationNotConfigured"])
        running.cancel()
        _ = try? await running.value
        let rebound = try LoopbackListener.open(port: port)
        Darwin.close(rebound)
    }

}
