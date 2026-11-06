import Darwin
import Foundation
import Network
import Security
import Testing
@testable import SanjboxGatewayCore

/// Created afresh with the system LibreSSL, imported into process memory only.
/// No test identity is committed, installed as a trust root or stored in Keychain.
/// Unchecked: both references are immutable Security objects, safe to share.
private struct SyntheticTLSMaterial: @unchecked Sendable {
    let identity: SecIdentity
    let certificate: SecCertificate
    init() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sanjbox-synthetic-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        func openssl(_ arguments: [String]) async throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.currentDirectoryURL = directory
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard try await runUntilExit(process) == 0 else { throw UpstreamFailure.tlsFailed }
        }
        try await openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ephemeral.pem", "-out", "leaf.pem",
                     "-days", "2", "-subj", "/CN=api.example", "-addext", "subjectAltName=DNS:api.example",
                     "-addext", "basicConstraints=critical,CA:FALSE", "-addext", "extendedKeyUsage=serverAuth"])
        try await openssl(["pkcs12", "-export", "-inkey", "ephemeral.pem", "-in", "leaf.pem", "-out", "identity.p12",
                     "-passout", "pass:synthetic-fixture"])
        try await openssl(["x509", "-in", "leaf.pem", "-outform", "der", "-out", "leaf.der"])
        let archive = try Data(contentsOf: directory.appendingPathComponent("identity.p12"))
        let options: [CFString: Any] = [kSecImportExportPassphrase: "synthetic-fixture", kSecImportToMemoryOnly: true]
        var items: CFArray?
        guard SecPKCS12Import(archive as CFData, options as CFDictionary, &items) == errSecSuccess,
              let records = items as? [[String: Any]], let value = records.first?[kSecImportItemIdentity as String] else {
            throw UpstreamFailure.tlsFailed
        }
        identity = value as! SecIdentity
        let der = try Data(contentsOf: directory.appendingPathComponent("leaf.der"))
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw UpstreamFailure.tlsFailed }
        self.certificate = certificate
    }
}

private func tlsSend(_ data: Data, connection: NWConnection) async throws {
    try await boundedIO(timeout: .seconds(3), cancel: { connection.cancel() }) { (result: IOResult<Void>) in
        connection.send(content: data, completion: .contentProcessed { error in
            if error != nil { result.finish(.failure(UpstreamFailure.connectionFailed)) }
            else { result.finish(.success(())) }
        })
    }
}

@MainActor private final class SyntheticTLSServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "sanjbox.gateway.synthetic-tls")
    private var connections: [NWConnection] = []
    private var tasks: [Task<Void, Never>] = []
    private let serve: @Sendable (NWConnection) async throws -> Void
    private(set) var requests: [String] = []
    private(set) var serverNames: [String] = []

    init(material: SyntheticTLSMaterial, serve: @escaping @Sendable (NWConnection) async throws -> Void) throws {
        self.serve = serve
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(material.identity)!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        let listener = self.listener
        let began = Diag.now()
        defer { Diag.trace("synthetic listener start returned after \(Int((Diag.now() - began) * 1000))ms") }
        return try await boundedIO(timeout: .seconds(3), cancel: { listener.cancel() }) { [queue, listener] result in
            listener.stateUpdateHandler = { [weak listener] state in
                Diag.trace("synthetic listener state=\(state) +\(Int((Diag.now() - began) * 1000))ms port=\(listener?.port?.rawValue ?? 0)")
                switch state {
                case .ready: result.finish(.success(listener?.port?.rawValue ?? 0))
                case .failed, .cancelled: result.finish(.failure(UpstreamFailure.connectionFailed))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        for task in tasks { task.cancel() }
        for connection in connections { connection.cancel() }
        listener.newConnectionHandler = nil
    }

    private func accept(_ connection: NWConnection) {
        Diag.trace("synthetic accept \(connection.endpoint)")
        connection.stateUpdateHandler = { state in Diag.trace("synthetic conn state=\(state)") }
        connections.append(connection)
        connection.start(queue: queue)
        tasks.append(Task { [weak self, serve] in
            do {
                var input = Data()
                while input.range(of: Data("\r\n\r\n".utf8)) == nil {
                    let part: ReceivedBytes = try await boundedIO(timeout: .seconds(3), cancel: { connection.cancel() }) { result in
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, eof, error in
                            if error != nil { result.finish(.failure(UpstreamFailure.connectionFailed)) }
                            else { result.finish(.success(ReceivedBytes(data: data ?? Data(), endOfStream: eof))) }
                        }
                    }
                    input.append(part.data)
                    guard input.count <= 32_768, !part.endOfStream else { throw UpstreamFailure.truncatedResponse }
                }
                self?.requests.append(String(decoding: input, as: UTF8.self))
                if #available(macOS 15.5, *),
                   let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
                   let name = sec_protocol_metadata_copy_server_name(metadata.securityProtocolMetadata) {
                    self?.serverNames.append(String(cString: name))
                    free(UnsafeMutableRawPointer(mutating: name))
                }
                try await serve(connection)
            } catch { connection.cancel() }
        })
    }
}

private struct LocalTLSDialer: UpstreamDialer {
    let port: UInt16
    let certificate: SecCertificate
    func connection(to destination: ApprovedDestination) throws -> any UpstreamConnection {
        // Internal test seam only: policy still sees public mock DNS; the real TLS
        // socket is redirected to our synthetic loopback listener, never the LAN.
        try PinnedTLSConnection(destination: ApprovedDestination(hostname: destination.hostname, port: port,
                                                                 addresses: [SanjboxGatewayCore.IPAddress("127.0.0.1")]),
                                testTrustAnchors: [certificate])
    }
}
private struct NoHostAddresses: HostAddressProvider {
    func addresses() throws -> Set<SanjboxGatewayCore.IPAddress> { [] }
}

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct TLSTransportTests {
    private static let material = Task { try await SyntheticTLSMaterial() }

    @Test func numericDialPreservesSNIHostAndVerifiesSyntheticIdentity() async throws {
        let material = try await Self.material.value
        let server = try SyntheticTLSServer(material: material) { connection in
            try await tlsSend(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8), connection: connection)
        }
        let port = try await server.start()
        defer { server.stop() }
        let client = UpstreamClient(resolver: SequenceDNS([["8.8.8.8"]]), hostAddresses: NoHostAddresses(),
                                    dialer: LocalTLSDialer(port: port, certificate: material.certificate))
        let response = try await client.response(for: UpstreamRequest(hostname: "api.example", target: "/status"))
        #expect(response.body == Data("hello".utf8))
        #expect(server.requests.first?.contains("Host: api.example\r\n") == true)
        #expect(server.serverNames == ["api.example"])
        let connection = try PinnedTLSConnection(destination: ApprovedDestination(hostname: "api.example", port: port,
                                                                                addresses: [SanjboxGatewayCore.IPAddress("127.0.0.1")]))
        defer { connection.cancel() }
        if case .hostPort(.ipv4(let ip), let endpointPort) = connection.endpoint {
            #expect(ip == IPv4Address("127.0.0.1"))
            #expect(endpointPort.rawValue == port)
        } else { Issue.record("TLS endpoint must contain a numeric IP, never a DNS name") }
    }

    @Test func untrustedCertificateAndWrongHostnameFailBeforeHTTPRequest() async throws {
        let material = try await Self.material.value
        let server = try SyntheticTLSServer(material: material) { _ in Issue.record("unverified TLS reached HTTP handler") }
        let port = try await server.start()
        defer { server.stop() }
        for (name, anchors) in [("api.example", nil as [SecCertificate]?), ("wrong.example", [material.certificate])] {
            let connection = try PinnedTLSConnection(destination: ApprovedDestination(hostname: name, port: port,
                                                                                     addresses: [SanjboxGatewayCore.IPAddress("127.0.0.1")]),
                                                    testTrustAnchors: anchors)
            defer { connection.cancel() }
            await #expect(throws: UpstreamFailure.tlsFailed) { try await connection.start(timeout: .seconds(3)) }
        }
        #expect(server.requests.isEmpty)
    }

    @Test func realTLSStreamsBeforeUpstreamCompletion() async throws {
        let material = try await Self.material.value
        let (release, resume) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { resume.finish() }
        let server = try SyntheticTLSServer(material: material) { connection in
            try await tlsSend(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\nd\r\ndata: first\n\n\r\n".utf8), connection: connection)
            for await _ in release { break }
            try await tlsSend(Data("e\r\ndata: second\n\n\r\n0\r\n\r\n".utf8), connection: connection)
        }
        let port = try await server.start()
        defer { server.stop() }
        let client = UpstreamClient(resolver: SequenceDNS([["8.8.8.8"]]), hostAddresses: NoHostAddresses(),
                                    dialer: LocalTLSDialer(port: port, certificate: material.certificate))
        var events: [String] = []
        _ = try await client.events(for: UpstreamRequest(hostname: "api.example", target: "/events")) { event in
            events.append(event.data)
            if events.count == 1 { resume.yield(()); resume.finish() }
        }
        #expect(events == ["first", "second"])
    }

    @Test func realTLSDisconnectAndIdleDeadlineNeverReturnPartialSuccess() async throws {
        let material = try await Self.material.value
        for disconnect in [true, false] {
            let server = try SyntheticTLSServer(material: material) { connection in
                try await tlsSend(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nno".utf8), connection: connection)
                if disconnect { connection.cancel() }
                else { try await Task.sleep(for: .seconds(10)) }
            }
            let port = try await server.start()
            defer { server.stop() }
            let client = UpstreamClient(resolver: SequenceDNS([["8.8.8.8"]]), hostAddresses: NoHostAddresses(),
                                        dialer: LocalTLSDialer(port: port, certificate: material.certificate),
                                        limits: UpstreamLimits(idleTimeout: .milliseconds(200)))
            await #expect(throws: (any Error).self) {
                _ = try await client.response(for: UpstreamRequest(hostname: "api.example", target: "/"))
            }
        }
    }

    @Test func cancelledTLSReadReturnsPromptlyAndClosesSocket() async throws {
        let material = try await Self.material.value
        let (ready, notice) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { notice.finish() }
        let server = try SyntheticTLSServer(material: material) { _ in
            notice.yield(())
            try await Task.sleep(for: .seconds(10))
        }
        let port = try await server.start()
        defer { server.stop() }
        let client = UpstreamClient(resolver: SequenceDNS([["8.8.8.8"]]), hostAddresses: NoHostAddresses(),
                                    dialer: LocalTLSDialer(port: port, certificate: material.certificate))
        let task = Task { try await client.response(for: UpstreamRequest(hostname: "api.example", target: "/")) }
        var iterator = ready.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
    @Test func wholeTLSStreamLifetimeIsBoundedDespiteHeartbeats() async throws {
        let material = try await Self.material.value
        let server = try SyntheticTLSServer(material: material) { connection in
            try await tlsSend(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".utf8), connection: connection)
            for _ in 0..<100 {
                try await tlsSend(Data("3\r\n:\n\n\r\n".utf8), connection: connection)
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let client = UpstreamClient(resolver: SequenceDNS([["8.8.8.8"]]), hostAddresses: NoHostAddresses(),
                                    dialer: LocalTLSDialer(port: port, certificate: material.certificate),
                                    limits: UpstreamLimits(idleTimeout: .seconds(2), lifetime: .milliseconds(400)))
        await #expect(throws: UpstreamFailure.timedOut) {
            _ = try await client.events(for: UpstreamRequest(hostname: "api.example", target: "/events")) { _ in
                Issue.record("heartbeat must not become data event")
            }
        }
    }

    @Test func typedHandlerRelaysRealTLSUpstreamAsLocalSSE() async throws {
        let material = try await Self.material.value
        let probe = MainLagProbe(), began = Diag.now()
        var phase = "begin"
        defer {
            Diag.log("relay began=\(String(format: "%.3f", began)) elapsed=\(Int((Diag.now() - began) * 1000))ms phase=\(phase) \(probe.stop())")
            if phase != "done" { for line in DiagTrace.shared.dump(since: began - 1) { print("DIAG TRACE " + line) } }
        }
        let upstreamServer = try SyntheticTLSServer(material: material) { connection in
            try await tlsSend(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\nd\r\ndata: first\n\n\r\n0\r\n\r\n".utf8), connection: connection)
        }
        phase = "upstream-start"
        defer { Diag.trace("relay upstream requests=\(upstreamServer.requests.count) names=\(upstreamServer.serverNames)") }
        let upstreamPort = try await upstreamServer.start()
        phase = "gateway-start"
        defer { upstreamServer.stop() }
        let upstream = UpstreamClient(resolver: SequenceDNS([["8.8.8.8"]]), hostAddresses: NoHostAddresses(),
                                      dialer: LocalTLSDialer(port: upstreamPort, certificate: material.certificate))
        let router = try TypedRouter(routes: [TypedRoute(mount: "/api", methods: ["GET"]) { request in
            guard request.target == "/api/events" else { return .response(.error(404)) }
            let operation = try UpstreamRequest(hostname: "api.example", target: "/v1/events")
            return .events { emit in _ = try await upstream.events(for: operation, onEvent: emit) }
        }])
        let gateway = GatewayServer(router: router)
        let port = try await gateway.start()
        defer { gateway.stop() }
        phase = "client-connect"
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.stateUpdateHandler = { state in Diag.trace("relay client state=\(state)") }
        connection.start(queue: DispatchQueue(label: "sanjbox.gateway.relay-test"))
        defer { connection.cancel() }
        phase = "send"
        try await tlsSend(Data("GET /api/events HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8), connection: connection)
        phase = "receive-head upstreamRequests=\(upstreamServer.requests.count)"
        var wire = Data()
        while true {
            let part: ReceivedBytes = try await boundedIO(timeout: .seconds(3), cancel: { connection.cancel() }) { result in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, eof, error in
                    if error != nil { result.finish(.failure(UpstreamFailure.connectionFailed)) }
                    else { result.finish(.success(ReceivedBytes(data: data ?? Data(), endOfStream: eof))) }
                }
            }
            wire.append(part.data)
            phase = "receive bytes=\(wire.count) upstreamRequests=\(upstreamServer.requests.count)"
            guard wire.count < 65_536 else { throw HTTPFailure.tooLarge }
            if part.endOfStream { break }
        }
        phase = "done"
        let text = String(decoding: wire, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Type: text/event-stream\r\n"))
        #expect(text.hasSuffix("d\r\ndata: first\n\n\r\n0\r\n\r\n"))
        #expect(upstreamServer.requests.first?.hasPrefix("GET /v1/events HTTP/1.1\r\n") == true)
    }

}
