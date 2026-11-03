import Foundation
import Testing
@testable import SanjboxGatewayCore

actor SequenceDNS: DestinationResolver {
    private var answers: [[String]]
    private(set) var names: [String] = []
    init(_ answers: [[String]]) { self.answers = answers }
    func addresses(for hostname: String) async throws -> [IPAddress] {
        names.append(hostname)
        guard !answers.isEmpty else { throw DestinationFailure.noAddresses }
        return try answers.removeFirst().map(IPAddress.init)
    }
}

final class ScriptedConnection: UpstreamConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [ReceivedBytes]
    private var writes: [Data] = []
    private var reads = 0
    private var cancelled = false
    init(_ wire: [String]) { parts = wire.map { ReceivedBytes(data: Data($0.utf8), endOfStream: false) } }
    func start(timeout: Duration) async throws { try Task.checkCancellation() }
    func send(_ data: Data, timeout: Duration) async throws { lock.withLock { writes.append(data) } }
    func receive(timeout: Duration) async throws -> ReceivedBytes {
        try Task.checkCancellation()
        return lock.withLock {
            reads += 1
            return parts.isEmpty ? ReceivedBytes(data: Data(), endOfStream: true) : parts.removeFirst()
        }
    }
    func cancel() { lock.withLock { cancelled = true } }
    var readCount: Int { lock.withLock { reads } }
    var didCancel: Bool { lock.withLock { cancelled } }
    var sent: [Data] { lock.withLock { writes } }
}

final class RecordingDialer: UpstreamDialer, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [ApprovedDestination] = []
    private let make: @Sendable (ApprovedDestination) throws -> any UpstreamConnection
    init(_ make: @escaping @Sendable (ApprovedDestination) throws -> any UpstreamConnection) { self.make = make }
    func connection(to destination: ApprovedDestination) throws -> any UpstreamConnection {
        lock.withLock { calls.append(destination) }
        return try make(destination)
    }
    var destinations: [ApprovedDestination] { lock.withLock { calls } }
}

private struct EmptyHosts: HostAddressProvider {
    func addresses() throws -> Set<IPAddress> { [] }
}

@Test func upstreamPinsOneApprovalPerOperationAndRejectsRebindingAndMixedAnswers() async throws {
    let dns = SequenceDNS([["8.8.8.8"], ["127.0.0.1"], ["8.8.8.8", "10.0.0.1"]])
    let connection = ScriptedConnection(["HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"])
    let dialer = RecordingDialer { _ in connection }
    let client = UpstreamClient(resolver: dns, hostAddresses: EmptyHosts(), dialer: dialer)
    let request = try UpstreamRequest(hostname: "API.Example", target: "/status")
    let response = try await client.response(for: request)
    #expect(response.body == Data("ok".utf8))
    #expect(dialer.destinations.first?.hostname == "api.example")
    #expect(dialer.destinations.first?.addresses == [try IPAddress("8.8.8.8")])
    for _ in 0..<2 {
        await #expect(throws: DestinationFailure.prohibitedAddress) { _ = try await client.response(for: request) }
    }
    #expect(dialer.destinations.count == 1)
    #expect(await dns.names == ["api.example", "api.example", "api.example"])
    #expect(connection.didCancel)
}

private final class ChangingHosts: HostAddressProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var values = Set<IPAddress>()
    func set(_ values: Set<IPAddress>) { lock.withLock { self.values = values } }
    func addresses() throws -> Set<IPAddress> { lock.withLock { values } }
}
private struct ChangingInterfacesDNS: DestinationResolver {
    let hosts: ChangingHosts
    func addresses(for hostname: String) async throws -> [IPAddress] {
        let ip = try IPAddress("8.8.8.8")
        hosts.set([ip])
        return [ip]
    }
}

@Test func interfaceSnapshotIsCollectedAfterDNSAndFailuresNeverDial() async throws {
    let hosts = ChangingHosts()
    let dialer = RecordingDialer { _ in throw UpstreamFailure.connectionFailed }
    let client = UpstreamClient(resolver: ChangingInterfacesDNS(hosts: hosts), hostAddresses: hosts, dialer: dialer)
    await #expect(throws: DestinationFailure.prohibitedAddress) {
        _ = try await client.response(for: UpstreamRequest(hostname: "api.example", target: "/"))
    }
    #expect(dialer.destinations.isEmpty)
}

@Test func upstreamRedirectRequiresExplicitNewApprovalAndDoesNotRelayCredentials() async throws {
    let first = ScriptedConnection(["HTTP/1.1 302 Found\r\nContent-Length: 0\r\nLocation: https://cdn.example/file\r\n\r\n"])
    let dialer = RecordingDialer { _ in first }
    let dns = SequenceDNS([["8.8.8.8"], ["169.254.169.254"]])
    let client = UpstreamClient(resolver: dns, hostAddresses: EmptyHosts(), dialer: dialer)
    let response = try await client.response(for: UpstreamRequest(hostname: "registry.example", target: "/file",
                                                                headers: ["Authorization": "Bearer synthetic"]))
    #expect(response.head.status == 302)
    #expect(response.head.headers["location"] == "https://cdn.example/file")
    #expect(dialer.destinations.count == 1)
    #expect(await dns.names == ["registry.example"])
    // Simulate the handler's explicit redirect attempt. A new lookup still fails
    // closed; the first request's authorization is not part of the new request.
    let redirected = try UpstreamRequest(hostname: "cdn.example", target: "/file")
    #expect(redirected.headers["authorization"] == nil)
    await #expect(throws: DestinationFailure.prohibitedAddress) { _ = try await client.response(for: redirected) }
    #expect(dialer.destinations.count == 1)
}

@Test func upstreamTruncationAndNonSSEResponsesCloseConnection() async throws {
    for wire in ["HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nno",
                 "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nno\r\n"] {
        let connection = ScriptedConnection([wire])
        let client = UpstreamClient(resolver: SequenceDNS([["8.8.8.8"]]), hostAddresses: EmptyHosts(),
                                    dialer: RecordingDialer { _ in connection })
        await #expect(throws: UpstreamFailure.truncatedResponse) {
            _ = try await client.response(for: UpstreamRequest(hostname: "api.example", target: "/"))
        }
        #expect(connection.didCancel)
    }
    for head in ["HTTP/1.1 200 OK\r\nContent-Type: application/json", "HTTP/1.1 302 Found\r\nContent-Type: text/event-stream"] {
        let connection = ScriptedConnection([head + "\r\nContent-Length: 0\r\n\r\n"])
        let client = UpstreamClient(resolver: SequenceDNS([["8.8.8.8"]]), hostAddresses: EmptyHosts(),
                                    dialer: RecordingDialer { _ in connection })
        await #expect(throws: UpstreamFailure.unexpectedSSE) {
            _ = try await client.events(for: UpstreamRequest(hostname: "api.example", target: "/")) { _ in
                Issue.record("unexpected SSE body")
            }
        }
        #expect(connection.didCancel)
    }
}

@Test func upstreamSSEWaitsForConsumerBeforeReadingAndSharesConcurrencyLimit() async throws {
    let connection = ScriptedConnection([
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\nd\r\ndata: first\n\n\r\n",
        "e\r\ndata: second\n\n\r\n0\r\n\r\n",
    ])
    let client = UpstreamClient(resolver: SequenceDNS([["8.8.8.8"], ["8.8.4.4"]]), hostAddresses: EmptyHosts(),
                                dialer: RecordingDialer { _ in connection }, maximumConnections: 1)
    let (ready, notice) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let (release, resume) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { notice.finish(); resume.finish() }
    let request = try UpstreamRequest(hostname: "api.example", target: "/events")
    let task = Task {
        var events: [String] = []
        let head = try await client.events(for: request) { event in
            events.append(event.data)
            if events.count == 1 {
                notice.yield(())
                for await _ in release { break }
            }
        }
        return (head, events)
    }
    var iterator = ready.makeAsyncIterator()
    _ = await iterator.next()
    #expect(connection.readCount == 1)
    await #expect(throws: UpstreamFailure.busy) { _ = try await client.response(for: request) }
    resume.yield(())
    resume.finish()
    let (head, events) = try await task.value
    #expect(head.status == 200)
    #expect(events == ["first", "second"])
    #expect(connection.readCount == 2)
    #expect(connection.didCancel)
}

private struct SlowDNS: DestinationResolver {
    func addresses(for hostname: String) async throws -> [IPAddress] {
        try await Task.sleep(for: .seconds(5))
        return [try IPAddress("8.8.8.8")]
    }
}

@Test func wholeOperationDeadlineIncludesDNSAndReleasesConcurrencySlot() async throws {
    let dialer = RecordingDialer { _ in throw UpstreamFailure.connectionFailed }
    let client = UpstreamClient(resolver: SlowDNS(), hostAddresses: EmptyHosts(), dialer: dialer,
                                limits: UpstreamLimits(lifetime: .milliseconds(50)), maximumConnections: 1)
    for _ in 0..<2 {
        await #expect(throws: UpstreamFailure.timedOut) {
            _ = try await client.response(for: UpstreamRequest(hostname: "api.example", target: "/"))
        }
    }
    #expect(dialer.destinations.isEmpty)
}

@Test func upstreamBodyAndStreamLimitsApplyBeforeDelivery() async throws {
    for streaming in [false, true] {
        let connection = ScriptedConnection([
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 100\r\n\r\n",
        ])
        let client = UpstreamClient(resolver: SequenceDNS([["8.8.8.8"]]), hostAddresses: EmptyHosts(),
                                    dialer: RecordingDialer { _ in connection },
                                    limits: UpstreamLimits(responseBytes: 10, streamBytes: 10))
        let request = try UpstreamRequest(hostname: "api.example", target: "/")
        await #expect(throws: HTTPFailure.tooLarge) {
            if streaming { _ = try await client.events(for: request) { _ in Issue.record("oversize response delivered") } }
            else { _ = try await client.response(for: request) }
        }
        #expect(connection.didCancel)
    }
}
