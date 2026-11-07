import Darwin
import Foundation
import Testing
@testable import SanjboxGatewayCore

@Test func interfaceSnapshotAndSockaddrConversionUseCanonicalAddresses() throws {
    let snapshot = try SystemHostAddresses().addresses()
    #expect(snapshot.contains(try IPAddress("127.0.0.1")))
    var v6 = sockaddr_in6()
    v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    v6.sin6_family = UInt8(AF_INET6)
    #expect(inet_pton(AF_INET6, "2606:4700:4700::1111", &v6.sin6_addr) == 1)
    let converted = try withUnsafePointer(to: &v6) { ptr in
        try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            try socketAddress($0, length: MemoryLayout<sockaddr_in6>.size)
        }
    }
    #expect(converted == (try IPAddress("2606:4700:4700:0:0:0:0:1111")))
    _ = withUnsafePointer(to: &v6) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
            #expect(throws: SystemAddressFailure.invalidSocketAddress) { _ = try socketAddress(address, length: 1) }
        }
    }
}

private struct FailingHostAddresses: HostAddressProvider {
    func addresses() throws -> Set<IPAddress> { throw SystemAddressFailure.interfaceSnapshotFailed }
}
private struct PublicDNS: DestinationResolver {
    func addresses(for hostname: String) async throws -> [IPAddress] { [try IPAddress("8.8.8.8")] }
}

@Test func systemLookupAndSnapshotFailuresArePropagated() async throws {
    // The lookup fails immediately; the generous timeout only absorbs worker
    // scheduling delay on a loaded runner, where 1 s produced .timedOut/.busy.
    let resolver = SystemDestinationResolver(maximumConcurrentLookups: 1, timeout: .seconds(30)) { _ in
        throw SystemAddressFailure.lookupFailed
    }
    await #expect(throws: SystemAddressFailure.lookupFailed) { _ = try await resolver.addresses(for: "api.example") }
    // A failed lookup releases its worker slot.
    await #expect(throws: SystemAddressFailure.lookupFailed) { _ = try await resolver.addresses(for: "api.example") }
    await #expect(throws: DestinationFailure.invalidHostname) { _ = try await resolver.addresses(for: "api.example\0evil") }
    await #expect(throws: SystemAddressFailure.interfaceSnapshotFailed) {
        _ = try await DestinationPolicy(hostAddressProvider: FailingHostAddresses()).approve(hostname: "api.example", resolver: PublicDNS())
    }
}

@Test func dnsTimeoutRetainsBoundedWorkerUntilLibcReturns() async throws {
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let resolver = SystemDestinationResolver(maximumConcurrentLookups: 1, timeout: .milliseconds(100)) { _ in
        _ = release.wait(timeout: .now() + 5)
        return [try IPAddress("8.8.8.8")]
    }
    await #expect(throws: UpstreamFailure.timedOut) { _ = try await resolver.addresses(for: "api.example") }
    await #expect(throws: UpstreamFailure.busy) { _ = try await resolver.addresses(for: "api.example") }
    release.signal()
}

@Test func cancelledDNSCallerDoesNotWaitForBlockingLookup() async throws {
    let release = DispatchSemaphore(value: 0)
    let (started, notice) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { release.signal(); notice.finish() }
    let resolver = SystemDestinationResolver(maximumConcurrentLookups: 1, timeout: .seconds(2)) { _ in
        notice.yield(())
        _ = release.wait(timeout: .now() + 5)
        return [try IPAddress("8.8.8.8")]
    }
    let task = Task { try await resolver.addresses(for: "api.example") }
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    await #expect(throws: UpstreamFailure.busy) { _ = try await resolver.addresses(for: "api.example") }
    release.signal()
}

@Test func libcResolverConvertsLocalhostAnswers() throws {
    // Exercise the real libc traversal without contacting a public DNS service.
    let answers = try SystemDestinationResolver.lookup("localhost")
    let loopback: Set<IPAddress> = [try IPAddress("127.0.0.1"), try IPAddress("::1")]
    #expect(!answers.isEmpty)
    #expect(answers.allSatisfy { loopback.contains($0) })
}
