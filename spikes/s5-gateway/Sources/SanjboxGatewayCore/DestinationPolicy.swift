import Darwin
import Foundation

public enum DestinationFailure: Error, Equatable, Sendable {
    case nonTLS, encryptedClientHello, invalidHostname, ipLiteral, invalidPort
    case noAddresses, prohibitedAddress, invalidAddress
}

/// Canonical address bytes prevent textual aliases bypassing host-address checks.
public struct IPAddress: Hashable, Sendable {
    fileprivate let bytes: [UInt8]
    public let text: String

    public init(_ text: String) throws {
        guard !text.utf8.contains(0) else { throw DestinationFailure.invalidAddress }
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            bytes = withUnsafeBytes(of: v4) { Array($0) }
            self.text = text
        } else if inet_pton(AF_INET6, text, &v6) == 1 {
            bytes = withUnsafeBytes(of: v6) { Array($0) }
            self.text = text
        } else { throw DestinationFailure.invalidAddress }
    }

    public static func == (lhs: IPAddress, rhs: IPAddress) -> Bool { lhs.bytes == rhs.bytes }
    public func hash(into hasher: inout Hasher) { hasher.combine(bytes) }

    fileprivate var isPublicUnicast: Bool {
        let b = bytes
        if b.count == 4 {
            // Conservative deny set includes special-purpose and documentation ranges.
            if b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 { return false }
            if b[0] == 100 && (64...127).contains(b[1]) { return false }
            if b[0] == 169 && b[1] == 254 { return false }
            if b[0] == 172 && (16...31).contains(b[1]) { return false }
            if b[0] == 192 && (b[1] == 168 || (b[1] == 0 && (b[2] == 0 || b[2] == 2))
                || (b[1] == 88 && b[2] == 99)) { return false }
            if b[0] == 198 && ((18...19).contains(b[1]) || (b[1] == 51 && b[2] == 100)) { return false }
            if b[0] == 203 && b[1] == 0 && b[2] == 113 { return false }
            return true
        }
        // Only native global unicast; deny mapped/compatible IPv4, NAT64, local,
        // multicast and transition ranges instead of trying to unwrap aliases.
        guard b[0] & 0xe0 == 0x20 else { return false }
        if b[0] == 0x20 && b[1] == 0x02 { return false } // 6to4
        if b[0] == 0x20 && b[1] == 0x01 {
            if b[2] < 2 { return false } // 2001::/23 special-purpose (conservative)
            if b[2] == 0x0d && b[3] == 0xb8 { return false }
        }
        if b[0] == 0x3f && b[1] == 0xff && b[2] < 0x10 { return false } // 3fff::/20 docs
        return true
    }
}

public protocol DestinationResolver: Sendable {
    /// All A/AAAA answers used for this attempt, not an unvalidated preferred answer.
    func addresses(for hostname: String) async throws -> [IPAddress]
}

/// A policy result, NOT an open connection. The eventual upstream transport must
/// dial one of these exact addresses while verifying TLS against `hostname`.
/// Never feed `hostname` to URLSession/NWConnection for a second DNS lookup.
public struct ApprovedDestination: Sendable {
    public let hostname: String
    public let port: UInt16
    public let addresses: [IPAddress]
    fileprivate init(hostname: String, port: UInt16, addresses: [IPAddress]) {
        self.hostname = hostname
        self.port = port
        self.addresses = addresses
    }
}

public struct DestinationPolicy: Sendable {
    private let hostAddresses: Set<IPAddress>

    /// Caller supplies a fresh, complete host-interface snapshot per attempt.
    /// Public addresses of the host are also forbidden upstream destinations.
    public init(hostAddresses: Set<IPAddress>) { self.hostAddresses = hostAddresses }

    public func approve(scheme: String = "https", hostname: String, port: UInt16 = 443,
                        encryptedClientHello: Bool = false,
                        resolver: any DestinationResolver) async throws -> ApprovedDestination {
        guard !encryptedClientHello else { throw DestinationFailure.encryptedClientHello }
        guard scheme == "https" else { throw DestinationFailure.nonTLS }
        guard port == 443 else { throw DestinationFailure.invalidPort }
        let name = try Self.hostname(hostname)
        let answers = try await resolver.addresses(for: name)
        guard !answers.isEmpty else { throw DestinationFailure.noAddresses }
        // Reject the entire set if even one answer is unsafe. Re-run for every
        // new connection and redirect; a successful earlier lookup grants no cache exemption.
        guard answers.allSatisfy({ $0.isPublicUnicast && !hostAddresses.contains($0) }) else {
            throw DestinationFailure.prohibitedAddress
        }
        return ApprovedDestination(hostname: name, port: port, addresses: answers)
    }

    private static func hostname(_ input: String) throws -> String {
        let name = input.lowercased()
        var legacy = in_addr()
        // inet_aton also recognizes shortened, integer, octal and hex IPv4 forms.
        if (try? IPAddress(name)) != nil || inet_aton(name, &legacy) == 1
            || name.contains(":") || name.contains("[") || name.contains("]") {
            throw DestinationFailure.ipLiteral
        }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard name.utf8.count <= 253, labels.count >= 2,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                      && label.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
              }), let last = labels.last,
              last.utf8.contains(where: { (97...122).contains($0) }),
              !["localhost", "local", "internal", "lan", "home"].contains(String(last)) else {
            throw DestinationFailure.invalidHostname
        }
        return name
    }
}
