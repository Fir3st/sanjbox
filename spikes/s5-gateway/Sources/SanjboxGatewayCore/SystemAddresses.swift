import Darwin
import Foundation

public enum SystemAddressFailure: Error, Equatable, Sendable {
    case lookupFailed, interfaceSnapshotFailed, invalidSocketAddress, tooManyAddresses
}

public protocol HostAddressProvider: Sendable {
    /// Fresh, complete AF_INET/AF_INET6 snapshot, including inactive interfaces.
    func addresses() throws -> Set<IPAddress>
}

struct FixedHostAddresses: HostAddressProvider {
    let values: Set<IPAddress>
    func addresses() throws -> Set<IPAddress> { values }
}

/// A bounded pool of blocking libc lookups. Timeout/cancellation releases the
/// caller immediately, but does not pretend getaddrinfo itself can be cancelled.
public final class SystemDestinationResolver: DestinationResolver, Sendable {
    private let capacity: Capacity
    private let timeout: Duration
    private let lookup: @Sendable (String) throws -> [IPAddress]
    private let queue = DispatchQueue(label: "sanjbox.gateway.dns", attributes: .concurrent)

    public convenience init(maximumConcurrentLookups: Int = 8, timeout: Duration = .seconds(5)) {
        self.init(maximumConcurrentLookups: maximumConcurrentLookups, timeout: timeout, lookup: Self.lookup)
    }

    init(maximumConcurrentLookups: Int, timeout: Duration,
         lookup: @escaping @Sendable (String) throws -> [IPAddress]) {
        precondition(timeout > .zero)
        capacity = Capacity(maximumConcurrentLookups)
        self.timeout = timeout
        self.lookup = lookup
    }

    public func addresses(for hostname: String) async throws -> [IPAddress] {
        // Do not pass unvalidated names (especially embedded NUL) to libc.
        let name = try DestinationPolicy.validatedHostname(hostname)
        try Task.checkCancellation()
        // Acquire inside the I/O start callback, so cancellation before boundedIO
        // begins cannot leak a slot. Once acquired, only the worker releases it.
        return try await boundedIO(timeout: timeout) { [self] result in
            guard capacity.acquire() else { result.finish(.failure(UpstreamFailure.busy)); return }
            queue.async { [self] in
                let value = Result { try lookup(name) }
                capacity.release()
                result.finish(value)
            }
        }
    }

    static func lookup(_ hostname: String) throws -> [IPAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var first: UnsafeMutablePointer<addrinfo>?
        // The trailing root dot prevents DNS search suffixes selecting another
        // authority. The TLS/HTTP hostname remains the validated, undotted name.
        guard getaddrinfo(hostname + ".", nil, &hints, &first) == 0, let first else {
            throw SystemAddressFailure.lookupFailed
        }
        defer { freeaddrinfo(first) }
        var result: [IPAddress] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            let info = current.pointee
            guard let address = info.ai_addr else { throw SystemAddressFailure.invalidSocketAddress }
            let ip = try socketAddress(address, length: Int(info.ai_addrlen))
            if !result.contains(ip) { result.append(ip) }
            guard result.count <= 64 else { throw SystemAddressFailure.tooManyAddresses }
            node = info.ai_next
        }
        guard !result.isEmpty else { throw DestinationFailure.noAddresses }
        return result
    }
}

public struct SystemHostAddresses: HostAddressProvider {
    public init() {}
    public func addresses() throws -> Set<IPAddress> {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { throw SystemAddressFailure.interfaceSnapshotFailed }
        defer { freeifaddrs(first) }
        var result = Set<IPAddress>()
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let current = node {
            defer { node = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr else { continue }
            if address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6) {
                result.insert(try socketAddress(address, length: Int(address.pointee.sa_len)))
            }
        }
        guard !result.isEmpty else { throw SystemAddressFailure.interfaceSnapshotFailed }
        return result
    }
}

func socketAddress(_ address: UnsafePointer<sockaddr>, length: Int) throws -> IPAddress {
    let family = Int32(address.pointee.sa_family)
    guard (family == AF_INET && length >= MemoryLayout<sockaddr_in>.size)
        || (family == AF_INET6 && length >= MemoryLayout<sockaddr_in6>.size) else {
        throw SystemAddressFailure.invalidSocketAddress
    }
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    let success: Bool = {
        // Copy out the address instead of exposing sockaddr padding or scope IDs.
        if family == AF_INET {
            var value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            return inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)) != nil
        } else {
            var value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
            return inet_ntop(AF_INET6, &value, &buffer, socklen_t(buffer.count)) != nil
        }
    }()
    guard success else { throw SystemAddressFailure.invalidSocketAddress }
    return try IPAddress(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
}
