import Foundation
import Network
import Security

struct ReceivedBytes: Sendable {
    let data: Data
    let endOfStream: Bool
}

protocol UpstreamConnection: Sendable {
    func start(timeout: Duration) async throws
    func send(_ data: Data, timeout: Duration) async throws
    func receive(timeout: Duration) async throws -> ReceivedBytes
    func cancel()
}

protocol UpstreamDialer: Sendable {
    func connection(to destination: ApprovedDestination) throws -> any UpstreamConnection
}

struct PinnedTLSDialer: UpstreamDialer {
    func connection(to destination: ApprovedDestination) throws -> any UpstreamConnection {
        try PinnedTLSConnection(destination: destination)
    }
}

/// No URLSession, ambient proxies, cookies, client identities or hostname lookup.
/// Test-only trust anchors are internal and never configurable through the listener.
final class PinnedTLSConnection: UpstreamConnection {
    let endpoint: NWEndpoint
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "sanjbox.gateway.upstream")

    init(destination: ApprovedDestination, testTrustAnchors: [SecCertificate]? = nil) throws {
        guard let address = destination.addresses.first,
              let port = NWEndpoint.Port(rawValue: destination.port) else { throw DestinationFailure.noAddresses }
        let host: NWEndpoint.Host
        if let v4 = IPv4Address(address.text) { host = .ipv4(v4) }
        else if let v6 = IPv6Address(address.text) { host = .ipv6(v6) }
        else { throw DestinationFailure.invalidAddress }
        endpoint = .hostPort(host: host, port: port)
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_tls_server_name(options, destination.hostname)
        sec_protocol_options_add_tls_application_protocol(options, "http/1.1")
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_set_tls_false_start_enabled(options, false)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        let hostname = destination.hostname
        // Explicit SSL policy ensures pinning the IP does not accidentally turn
        // certificate validation into an IP-name check or omit hostname validation.
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let trust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, hostname as CFString)) == errSecSuccess,
                  SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { complete(false); return }
            if let testTrustAnchors {
                guard SecTrustSetAnchorCertificates(trust, testTrustAnchors as CFArray) == errSecSuccess,
                      SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { complete(false); return }
            }
            complete(SecTrustEvaluateWithError(trust, nil))
        }, queue)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.preferNoProxies = true
        let privacy = NWParameters.PrivacyContext(description: "sanjbox.gateway.pinned-upstream")
        privacy.proxyConfigurations = []
        parameters.setPrivacyContext(privacy)
        connection = NWConnection(to: endpoint, using: parameters)
    }

    func start(timeout: Duration) async throws {
        let connection = self.connection
        try await boundedIO(timeout: timeout, cancel: { connection.cancel() }) { [queue] (result: IOResult<Void>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: result.finish(.success(()))
                case .failed(let error), .waiting(let error): result.finish(.failure(Self.failure(error)))
                case .cancelled: result.finish(.failure(CancellationError()))
                default: break
                }
            }
            connection.start(queue: queue)
        }
        // Waiting is a failed attempt: recovery requires fresh DNS/policy approval,
        // never an automatic Network.framework retry of an old approval.
    }

    func send(_ data: Data, timeout: Duration) async throws {
        let connection = self.connection
        try await boundedIO(timeout: timeout, cancel: { connection.cancel() }) { (result: IOResult<Void>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { result.finish(.failure(Self.failure(error))) }
                else { result.finish(.success(())) }
            })
        }
    }

    func receive(timeout: Duration) async throws -> ReceivedBytes {
        let connection = self.connection
        return try await boundedIO(timeout: timeout, cancel: { connection.cancel() }) { result in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, eof, error in
                if let error { result.finish(.failure(Self.failure(error))) }
                else { result.finish(.success(ReceivedBytes(data: data ?? Data(), endOfStream: eof))) }
            }
        }
    }

    func cancel() { connection.cancel() }

    private static func failure(_ error: NWError) -> UpstreamFailure {
        if case .tls = error { .tlsFailed } else { .connectionFailed }
    }
}
