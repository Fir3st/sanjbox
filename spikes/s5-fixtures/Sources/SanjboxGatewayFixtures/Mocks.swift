import Foundation
import SanjboxGatewayCore

public struct DNSAnswer: Sendable {
    public let hostname: String
    public let addresses: [IPAddress]?
    public init(hostname: String, addresses: [String]?) throws {
        try fixtureCheck(["registry.fixture.invalid", "cdn.fixture.invalid"].contains(hostname))
        try fixtureCheck((addresses?.count ?? 0) <= 16, .limit)
        self.hostname = hostname
        self.addresses = try addresses?.map { try IPAddress($0) }
    }
}

/// No real DNS; each call consumes exactly one answer. No repeat-last fallback.
public actor ScriptedResolver: DestinationResolver {
    private let script: [DNSAnswer]
    private var cursor = 0
    private var invalid = false
    public private(set) var requests: [String] = []
    public init(_ script: [DNSAnswer]) throws {
        try fixtureCheck(!script.isEmpty && script.count <= 32, .limit)
        self.script = script
    }
    public func addresses(for hostname: String) async throws -> [IPAddress] {
        try Task.checkCancellation()
        guard cursor < script.count else { invalid = true; throw FixtureFailure.exhausted }
        let step = script[cursor]
        cursor += 1
        requests.append(hostname)
        guard hostname == step.hostname else { invalid = true; throw FixtureFailure.unexpectedRequest }
        guard let addresses = step.addresses else { throw FixtureFailure.scriptedFailure }
        return addresses
    }
    public func assertConsumed() throws { try fixtureCheck(!invalid && cursor == script.count, .incomplete) }
}

/// A synchronized, finite fake interface provider. nil represents snapshot failure.
public final class ScriptedHostAddresses: HostAddressProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let script: [Set<IPAddress>?]
    private var cursor = 0
    private var invalid = false
    public init(_ script: [[String]?]) throws {
        try fixtureCheck(!script.isEmpty && script.count <= 32, .limit)
        self.script = try script.map { entry in
            try fixtureCheck((entry?.count ?? 0) <= 16, .limit)
            return try entry.map { Set(try $0.map { try IPAddress($0) }) }
        }
    }
    public func addresses() throws -> Set<IPAddress> {
        lock.lock(); defer { lock.unlock() }
        guard cursor < script.count else { invalid = true; throw FixtureFailure.exhausted }
        let result = script[cursor]
        cursor += 1
        guard let result else { throw FixtureFailure.scriptedFailure }
        return result
    }
    public func assertConsumed() throws {
        lock.lock(); defer { lock.unlock() }
        try fixtureCheck(!invalid && cursor == script.count, .incomplete)
    }
}

public struct MockRequest: Sendable, Equatable {
    public let method: String
    public let target: String
    public let status: Int
    public let bytes: Int
}

/// Upstream fixture server, intentionally serving NEW and UNKNOWN versions too.
/// It contains no cooldown or gateway authorization policy. Useful for real npm parsing.
public actor RegistryMock {
    private let fixtures: RegistryFixtures
    private let requestLimit: Int
    private var origin: FixtureOrigin?
    private var blocked: Set<PackageKey> = []
    private var requests: [MockRequest] = []
    private var overflow = false
    public init(fixtures: RegistryFixtures, requestLimit: Int = 64) throws {
        try fixtureCheck((1...256).contains(requestLimit), .limit)
        self.fixtures = fixtures
        self.requestLimit = requestLimit
    }
    public func configure(origin: FixtureOrigin, refuse: Set<PackageKey> = []) throws {
        try fixtureCheck(refuse.isSubset(of: Set(fixtures.artifacts.map(\.key))))
        self.origin = origin
        blocked = refuse
    }
    public nonisolated var route: TypedRoute {
        TypedRoute(mount: "/npm", methods: ["GET"]) { request in
            .response(try await self.reply(to: request))
        }
    }
    public func reply(to request: HTTPRequest) throws -> HTTPResponse {
        guard requests.count < requestLimit else { overflow = true; return .error(503) }
        guard let origin else { throw FixtureFailure.incomplete }
        let response: HTTPResponse
        if request.method != "GET" || !request.body.isEmpty { response = .error(403) }
        else if let artifact = fixtures.artifacts.first(where: { $0.key.tarballTarget == request.target }) {
            response = blocked.contains(artifact.key) ? .error(403) :
                HTTPResponse(contentType: "application/octet-stream", body: artifact.archive)
        } else if let artifact = fixtures.artifacts.first(where: {
            $0.key.packumentTarget == request.target ||
            $0.key.packumentTarget.replacingOccurrences(of: "%2f", with: "%2F") == request.target
        }) {
            response = HTTPResponse(body: try fixtures.packument(name: artifact.key.name, origin: origin))
        } else { response = .error(404) }
        requests.append(MockRequest(method: request.method, target: request.target,
                                    status: response.status, bytes: response.body.count))
        return response
    }
    public func transcript() throws -> [MockRequest] {
        try fixtureCheck(!overflow, .limit)
        return requests
    }
}

public struct RedirectFixture: Sendable {
    public let id: String
    public let location: String
    public let response: Data
    public let expectation: RedirectExpectation
    public enum RedirectExpectation: Sendable { case revalidateArtifactAndDestination, reject }
    private init(_ id: String, _ location: String, _ expectation: RedirectExpectation) {
        self.id = id; self.location = location; self.expectation = expectation
        response = Data("HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\n\r\n".utf8)
    }
    public static let standard: [RedirectFixture] = [
        .init("cdn", "https://cdn.fixture.invalid/fixture-bead-1.0.0.tgz", .revalidateArtifactAndDestination),
        .init("same-host-rebinding", "https://registry.fixture.invalid/again.tgz", .revalidateArtifactAndDestination),
        .init("loopback", "https://127.0.0.1/private.tgz", .reject),
        .init("downgrade", "http://cdn.fixture.invalid/fixture.tgz", .reject),
        .init("userinfo", "https://synthetic@cdn.fixture.invalid/fixture.tgz", .reject),
        .init("unapproved-origin", "https://other.fixture.invalid/fixture.tgz", .reject),
    ]
}
