import Foundation
import SanjboxGatewayFixtures
@testable import SanjboxGatewayCore

/// Inputs are bytes and finite transport scripts, never RedirectFixture.expectation.
struct RedirectWireStep: Sendable {
    let hostname: String
    let target: String
    let response: Data
}

enum RedirectEvent: Sendable, Equatable {
    case dns(String)
    case answers(String, [String])
    case hostSnapshot([String])
    case dial(Int, String, UInt16, [String])
    case start(Int)
    case send(Int, Data)
    case receive(Int, Data, Bool)
    case cancel(Int)
}

/// Bounded journal records attempted actions BEFORE checking the script. Unexpected
/// requests cannot disappear into NPMGateway's generic error response.
final class RedirectJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [RedirectEvent] = []
    private var overflow = false
    func append(_ event: RedirectEvent) {
        lock.withLock {
            guard entries.count < 1_024 else { overflow = true; return }
            entries.append(event)
        }
    }
    func events() throws -> [RedirectEvent] {
        try lock.withLock {
            guard !overflow else { throw FixtureFailure.limit }
            return entries
        }
    }
}

private struct RedirectDNS: DestinationResolver {
    let script: ScriptedResolver?
    let journal: RedirectJournal
    func addresses(for hostname: String) async throws -> [SanjboxGatewayCore.IPAddress] {
        journal.append(.dns(hostname))
        guard let script else { throw FixtureFailure.exhausted }
        let addresses = try await script.addresses(for: hostname)
        journal.append(.answers(hostname, addresses.map(\.text)))
        return addresses
    }
}

private struct RedirectHosts: HostAddressProvider {
    let script: ScriptedHostAddresses?
    let journal: RedirectJournal
    func addresses() throws -> Set<SanjboxGatewayCore.IPAddress> {
        guard let script else { throw FixtureFailure.exhausted }
        let addresses = try script.addresses()
        journal.append(.hostSnapshot(addresses.map(\.text).sorted()))
        return addresses
    }
}

/// Never creates a socket. Even a wrongly approved destination is journaled; script
/// validation is not a substitute for checking that the real policy prevented a dial.
private final class RedirectTransport: UpstreamDialer, @unchecked Sendable {
    private let lock = NSLock()
    private let script: [RedirectWireStep]
    private var cursor = 0
    private var connections: [RedirectConnection] = []
    private var invalid = false
    let journal: RedirectJournal

    init(_ script: [RedirectWireStep], journal: RedirectJournal) throws {
        guard script.count <= 32, script.allSatisfy({ $0.response.count <= 65_536 }) else { throw FixtureFailure.limit }
        self.script = script; self.journal = journal
    }
    func connection(to destination: ApprovedDestination) throws -> any UpstreamConnection {
        try lock.withLock {
            let id = connections.count
            journal.append(.dial(id, destination.hostname, destination.port, destination.addresses.map(\.text)))
            guard cursor < script.count else { invalid = true; throw FixtureFailure.exhausted }
            let step = script[cursor]
            cursor += 1
            guard destination.hostname == step.hostname else { invalid = true; throw FixtureFailure.unexpectedRequest }
            let connection = RedirectConnection(id: id, step: step, journal: journal)
            connections.append(connection)
            return connection
        }
    }
    func assertConsumed() throws {
        let snapshot = try lock.withLock {
            guard !invalid, cursor == script.count else { throw FixtureFailure.incomplete }
            return connections
        }
        for connection in snapshot { try connection.assertConsumed() }
    }
}

private final class RedirectConnection: UpstreamConnection, @unchecked Sendable {
    private let lock = NSLock()
    private let id: Int
    private let step: RedirectWireStep
    private let journal: RedirectJournal
    private var pending: Data
    private var started = false
    private var sent = false
    private var cancelled = false
    private var invalid = false

    init(id: Int, step: RedirectWireStep, journal: RedirectJournal) {
        self.id = id; self.step = step; self.journal = journal; pending = step.response
    }
    func start(timeout: Duration) async throws {
        try Task.checkCancellation()
        try lock.withLock {
            journal.append(.start(id))
            guard !started, !cancelled else { invalid = true; throw FixtureFailure.unexpectedRequest }
            started = true
        }
    }
    func send(_ bytes: Data, timeout: Duration) async throws {
        try Task.checkCancellation()
        try lock.withLock {
            journal.append(.send(id, bytes))
            guard started, !sent, !cancelled else { invalid = true; throw FixtureFailure.unexpectedRequest }
            sent = true
            do {
                var decoder = HTTPRequestDecoder()
                guard let request = try decoder.append(bytes), request.method == "GET", request.target == step.target,
                      request.headers["host"] == step.hostname, request.body.isEmpty else {
                    throw FixtureFailure.unexpectedRequest
                }
            } catch { invalid = true; throw error }
        }
    }
    func receive(timeout: Duration) async throws -> ReceivedBytes {
        try Task.checkCancellation()
        return try lock.withLock {
            guard sent, !cancelled, !pending.isEmpty else { invalid = true; throw FixtureFailure.unexpectedRequest }
            // Exercise the real HTTP parser with fragmented metadata/archive responses.
            let chunk = Data(pending.prefix(257))
            pending.removeFirst(chunk.count)
            let eof = pending.isEmpty
            journal.append(.receive(id, chunk, eof))
            return ReceivedBytes(data: chunk, endOfStream: eof)
        }
    }
    func cancel() {
        lock.withLock {
            if !cancelled { journal.append(.cancel(id)) }
            cancelled = true
        }
    }
    func assertConsumed() throws {
        try lock.withLock {
            guard !invalid, started, sent, pending.isEmpty, cancelled else { throw FixtureFailure.incomplete }
        }
    }
}

struct RedirectHandlerReceipt: Sendable {
    let exchange: ArtifactExchange
    let events: [RedirectEvent]
    let downloads: [NPMDownloadRecord]

    /// Generic errors convey no reason. No status or refusal cause comes from input.
    var observation: ArtifactObservation {
        get throws {
            try ArtifactObservation(outcome: exchange.status == 200 ? .delivered(exchange.responseBody) : .denied(.other),
                exchanges: [exchange], downloadAudits: downloads.map { try PackageKey(name: $0.package, version: $0.version) },
                complete: true, accessEvidence: .directURL)
        }
    }
}

/// Reusable session permits normal seed/download/cache requests without cache setters.
/// Calls the real handler directly: completion is deliberately never synthesized.
@MainActor final class RedirectHandlerAdapter {
    let handler: NPMGateway
    private let resolver: ScriptedResolver?
    private let hosts: ScriptedHostAddresses?
    private let transport: RedirectTransport
    private let journal = RedirectJournal()

    init(steps: [RedirectWireStep], dns: [DNSAnswer], hostSnapshots: [[String]?],
         maximumRedirects: Int = 3) throws {
        resolver = try dns.isEmpty ? nil : ScriptedResolver(dns)
        hosts = try hostSnapshots.isEmpty ? nil : ScriptedHostAddresses(hostSnapshots)
        transport = try RedirectTransport(steps, journal: journal)
        let upstream = UpstreamClient(resolver: RedirectDNS(script: resolver, journal: journal),
            hostAddresses: RedirectHosts(script: hosts, journal: journal), dialer: transport,
            limits: UpstreamLimits(lifetime: .seconds(5)))
        handler = NPMGateway(configuration: try NPMConfiguration(registryHostname: "registry.fixture.invalid",
            artifactHostnames: ["cdn.fixture.invalid"], publicOrigin: "http://127.0.0.1:12345",
            cooldown: Double(RegistryFixtures.cooldown), maximumRedirects: maximumRedirects, lifetime: .seconds(5)),
            upstream: upstream, now: { Date(timeIntervalSince1970: Double(RegistryFixtures.now)) })
    }

    func request(_ key: PackageKey, headers: [String: String] = [:]) async throws -> RedirectHandlerReceipt {
        let start = try journal.events().count
        let auditStart = await handler.downloadRecords().count
        let reply = try await handler.response(to: HTTPRequest(method: "GET", target: key.tarballTarget,
                                                               headers: headers, body: Data()))
        return RedirectHandlerReceipt(exchange: try ArtifactExchange(sequence: 0, method: "GET", target: key.tarballTarget,
            status: reply.status, responseBody: reply.body), events: Array(try journal.events().dropFirst(start)),
            downloads: Array(await handler.downloadRecords().dropFirst(auditStart)))
    }
    func assertConsumed() async throws {
        try await resolver?.assertConsumed()
        try hosts?.assertConsumed()
        try transport.assertConsumed()
        let events = try journal.events()
        if resolver == nil, events.contains(where: { if case .dns = $0 { true } else { false } }) {
            throw FixtureFailure.incomplete
        }
    }
}
