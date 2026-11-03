import Foundation
import Testing
@testable import SanjboxGatewayCore

private struct ResolverFixture: DestinationResolver {
    let values: [String]
    func addresses(for hostname: String) async throws -> [IPAddress] { try values.map(IPAddress.init) }
}

@Test(arguments: [
    "0.0.0.0", "0.1.2.3", "10.0.0.1", "100.64.0.1", "100.127.255.255", "127.0.0.2",
    "169.254.169.254", "172.16.0.1", "172.31.255.255", "192.168.1.1", "192.0.0.1",
    "192.0.2.1", "192.88.99.1", "198.18.0.1", "198.19.255.255", "198.51.100.1",
    "203.0.113.1", "224.0.0.1", "239.255.255.255", "255.255.255.255",
    "::", "::1", "::ffff:127.0.0.1", "::ffff:8.8.8.8", "::127.0.0.1", "fc00::1",
    "fd00::1", "fe80::1", "ff02::1", "64:ff9b::7f00:1", "2001::1", "2001:db8::1",
    "2002:7f00:1::", "3fff::1",
])
func unsafeDNSAnswersFailClosed(address: String) async throws {
    let policy = DestinationPolicy(hostAddresses: [])
    await #expect(throws: DestinationFailure.prohibitedAddress) {
        try await policy.approve(hostname: "registry.example", resolver: ResolverFixture(values: [address]))
    }
}

@Test(arguments: ["127.0.0.1", "127.1", "2130706433", "0177.0.0.1", "0x7f000001", "[::1]", "::1"])
func numericTargetsCannotBypassDNSPolicy(host: String) async throws {
    await #expect(throws: DestinationFailure.ipLiteral) {
        try await DestinationPolicy(hostAddresses: []).approve(hostname: host, resolver: ResolverFixture(values: ["8.8.8.8"]))
    }
}

@Test(arguments: ["localhost", "api.local", "api.localhost", "api.lan", "api.internal", "api.home", "api.example.",
                  "user@api.example", "api.example/a", "api.example%00", "api..example", "-api.example", "ápi.example"])
func ambiguousOrLocalNamesAreRejected(host: String) async throws {
    await #expect(throws: DestinationFailure.invalidHostname) {
        try await DestinationPolicy(hostAddresses: []).approve(hostname: host, resolver: ResolverFixture(values: ["8.8.8.8"]))
    }
}

@Test func publicAnswersArePinnedInPolicyResult() async throws {
    let approved = try await DestinationPolicy(hostAddresses: []).approve(
        hostname: "API.Example", resolver: ResolverFixture(values: ["8.8.8.8", "2606:4700:4700::1111"]))
    #expect(approved.hostname == "api.example")
    #expect(approved.port == 443)
    #expect(approved.addresses.count == 2)
}

@Test func mixedAnswersHostAddressesAndRebindingAreRejected() async throws {
    let hostV6 = try IPAddress("2606:4700:4700:0:0:0:0:1111")
    let policy = DestinationPolicy(hostAddresses: [try IPAddress("8.8.4.4"), hostV6])
    for answers in [["8.8.8.8", "10.1.1.1"], ["8.8.4.4"], ["2606:4700:4700::1111"]] {
        await #expect(throws: DestinationFailure.prohibitedAddress) {
            try await policy.approve(hostname: "api.example", resolver: ResolverFixture(values: answers))
        }
    }
    _ = try await policy.approve(hostname: "api.example", resolver: ResolverFixture(values: ["8.8.8.8"]))
    await #expect(throws: DestinationFailure.prohibitedAddress) {
        try await policy.approve(hostname: "api.example", resolver: ResolverFixture(values: ["127.0.0.1"]))
    }
    await #expect(throws: DestinationFailure.noAddresses) {
        try await policy.approve(hostname: "api.example", resolver: ResolverFixture(values: []))
    }
}

@Test func tlsECHAndPortPolicyFailBeforeResolution() async throws {
    let policy = DestinationPolicy(hostAddresses: [])
    let resolver = ResolverFixture(values: [])
    await #expect(throws: DestinationFailure.nonTLS) {
        try await policy.approve(scheme: "http", hostname: "api.example", resolver: resolver)
    }
    await #expect(throws: DestinationFailure.encryptedClientHello) {
        try await policy.approve(hostname: "api.example", encryptedClientHello: true, resolver: resolver)
    }
    await #expect(throws: DestinationFailure.invalidPort) {
        try await policy.approve(hostname: "api.example", port: 8443, resolver: resolver)
    }
}
