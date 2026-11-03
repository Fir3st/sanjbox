import Foundation

/// Compiled fixture data only. There is intentionally no JSON decoder for identity or grants.
/// These values are NOT broker-authenticated principals or real OAuth assertions.
public struct MockPrincipal: Sendable {
    public let provider: String
    public let account: String
    public let zone: String
    public init(provider: String, account: String, zone: String) throws {
        try fixtureCheck([provider, account, zone].allSatisfy { identifier($0) })
        self.provider = provider; self.account = account; self.zone = zone
    }
}
public struct MockGrant: Sendable {
    public let scopes: Set<String>
    public let resources: Set<String>
    public let expiresAt: Int64
    public let revoked: Bool
    public init(scopes: [String], resources: [String], expiresAt: Int64, revoked: Bool = false) throws {
        try fixtureCheck(scopes.count <= 16 && resources.count <= 16, .limit)
        try fixtureCheck(Set(scopes).count == scopes.count && Set(resources).count == resources.count, .duplicate)
        try fixtureCheck(scopes.allSatisfy { ["repo:read", "repo:write", "account:admin"].contains($0) }
                         && resources.allSatisfy { identifier($0) } && (0...4_102_444_800).contains(expiresAt))
        self.scopes = Set(scopes); self.resources = Set(resources); self.expiresAt = expiresAt; self.revoked = revoked
    }
}
public enum MockOperation: Sendable { case readRepository, writeRepository, accountAPI, opaquePassthrough }
public struct OAuthInput: Sendable {
    public let principal: MockPrincipal?
    public let grant: MockGrant
    public let resource: String
    public let operation: MockOperation
    /// Adversary-controlled claim. Evaluator must never use it as transport identity.
    public let claimedZone: String?
    public let now: Int64
    public init(principal: MockPrincipal?, grant: MockGrant, resource: String,
                operation: MockOperation, claimedZone: String? = nil, now: Int64 = RegistryFixtures.now) throws {
        try fixtureCheck(identifier(resource) && (claimedZone == nil || identifier(claimedZone!))
                         && (0...4_102_444_800).contains(now))
        self.principal = principal; self.grant = grant; self.resource = resource
        self.operation = operation; self.claimedZone = claimedZone; self.now = now
    }
}
public enum MockAuthorization: Sendable, Equatable {
    case allow, noIdentity, wrongProvider, wrongAccount, wrongZone, revoked, expired
    case unsupportedOperation, excessiveScope, missingScope, wrongResource
}

/// Mock model for fixture rehearsals, NOT a production authenticator or OAuth implementation.
/// Identity is supplied out of band by test code. No token parsing, login, issuer lookup, or network.
public struct MockAuthorizationPolicy: Sendable {
    public let expected: MockPrincipal
    public let resource: String
    public init(expected: MockPrincipal, resource: String) throws {
        try fixtureCheck(identifier(resource))
        self.expected = expected; self.resource = resource
    }
    public func evaluate(_ input: OAuthInput) -> MockAuthorization {
        guard let principal = input.principal else { return .noIdentity }
        guard principal.provider == expected.provider else { return .wrongProvider }
        guard principal.account == expected.account else { return .wrongAccount }
        guard principal.zone == expected.zone else { return .wrongZone }
        guard !input.grant.revoked else { return .revoked }
        guard input.grant.expiresAt > input.now else { return .expired }
        guard input.operation == .readRepository else { return .unsupportedOperation }
        guard input.grant.scopes.isSubset(of: ["repo:read"]) else { return .excessiveScope }
        guard input.grant.scopes.contains("repo:read") else { return .missingScope }
        guard input.resource == resource, input.grant.resources == [resource] else { return .wrongResource }
        return .allow
    }
}

public struct OAuthScenario: Sendable {
    public let id: String
    public let input: OAuthInput
    public let expected: MockAuthorization

    public static func standard() throws -> [OAuthScenario] {
        let identity = try MockPrincipal(provider: "provider-a", account: "account-a", zone: "zone-a")
        let narrow = try MockGrant(scopes: ["repo:read"], resources: ["project-a"], expiresAt: RegistryFixtures.now + 1)
        var results: [OAuthScenario] = []
        func add(_ id: String, _ expected: MockAuthorization, principal: MockPrincipal? = identity,
                 grant: MockGrant = narrow, resource: String = "project-a",
                 operation: MockOperation = .readRepository, claimedZone: String? = nil) throws {
            results.append(OAuthScenario(id: id, input: try OAuthInput(principal: principal, grant: grant,
                resource: resource, operation: operation, claimedZone: claimedZone), expected: expected))
        }
        try add("narrow", .allow)
        try add("untrusted-zone-claim-ignored", .allow, claimedZone: "zone-b")
        try add("no-transport-identity", .noIdentity, principal: nil, claimedZone: "zone-a")
        try add("wrong-provider", .wrongProvider,
                principal: MockPrincipal(provider: "provider-b", account: "account-a", zone: "zone-a"))
        try add("same-provider-wrong-account", .wrongAccount,
                principal: MockPrincipal(provider: "provider-a", account: "account-b", zone: "zone-a"))
        try add("wrong-zone-with-spoofed-claim", .wrongZone,
                principal: MockPrincipal(provider: "provider-a", account: "account-a", zone: "zone-b"), claimedZone: "zone-a")
        try add("broad-account-scope", .excessiveScope,
                grant: MockGrant(scopes: ["repo:read", "account:admin"], resources: ["project-a"], expiresAt: RegistryFixtures.now + 1))
        try add("missing-read-scope", .missingScope,
                grant: MockGrant(scopes: [], resources: ["project-a"], expiresAt: RegistryFixtures.now + 1))
        try add("other-project", .wrongResource, resource: "project-b")
        try add("broad-resource-grant", .wrongResource,
                grant: MockGrant(scopes: ["repo:read"], resources: ["project-a", "project-b"], expiresAt: RegistryFixtures.now + 1))
        try add("expired-at-boundary", .expired,
                grant: MockGrant(scopes: ["repo:read"], resources: ["project-a"], expiresAt: RegistryFixtures.now))
        try add("revoked", .revoked,
                grant: MockGrant(scopes: ["repo:read"], resources: ["project-a"], expiresAt: RegistryFixtures.now + 1, revoked: true))
        try add("write-via-alternative-api", .unsupportedOperation, operation: .writeRepository)
        try add("account-api-same-provider", .unsupportedOperation, operation: .accountAPI)
        try add("same-host-passthrough", .unsupportedOperation, operation: .opaquePassthrough)
        return results
    }
}
