import Foundation
import Network
import Security
import Testing
@testable import SanjboxGatewayCore

/// A distinct root CA and localhost leaf on every construction. Everything is
/// generated in an owned 0700 temporary directory and imported memory-only.
/// No live identity, system Keychain or installed trust store is used.
@MainActor private struct ModelTLSMaterial {
    let configuration: GatewayTLSConfiguration
    let root: SecCertificate
    init() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sanjbox-model-ca-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        func openssl(_ args: [String]) async throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.currentDirectoryURL = directory; process.arguments = args
            process.environment = ["PATH": "/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            guard try await runUntilExit(process) == 0 else { throw ModelAPIFailure.configuration }
        }
        try await openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca-key.pem", "-out", "ca.pem", "-days", "1",
                     "-subj", "/CN=synthetic-zone-ca", "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign"])
        try await openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "leaf-key.pem", "-out", "leaf.csr", "-subj", "/CN=127.0.0.1"])
        let extensions = "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\n"
        try Data(extensions.utf8).write(to: directory.appendingPathComponent("leaf.ext"))
        try await openssl(["x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca-key.pem", "-set_serial", "1", "-days", "1", "-extfile", "leaf.ext", "-out", "leaf.pem"])
        try await openssl(["pkcs12", "-export", "-inkey", "leaf-key.pem", "-in", "leaf.pem", "-certfile", "ca.pem", "-out", "identity.p12", "-passout", "pass:synthetic-fixture"])
        try await openssl(["x509", "-in", "ca.pem", "-outform", "der", "-out", "ca.der"])
        configuration = try GatewayTLSConfiguration(pkcs12: Data(contentsOf: directory.appendingPathComponent("identity.p12")), passphrase: "synthetic-fixture")
        guard let root = SecCertificateCreateWithData(nil, try Data(contentsOf: directory.appendingPathComponent("ca.der")) as CFData) else { throw ModelAPIFailure.configuration }
        self.root = root
    }
}

private func modelTLSClient(port: UInt16, root: SecCertificate?, hostname: String = "127.0.0.1") throws -> PinnedTLSConnection {
    try PinnedTLSConnection(destination: ApprovedDestination(hostname: hostname, port: port, addresses: [SanjboxGatewayCore.IPAddress("127.0.0.1")]),
                            testTrustAnchors: root.map { [$0] })
}
private func modelHTTP(_ request: HTTPRequest, port: UInt16) -> Data {
    Data("\(request.method) \(request.target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nContent-Length: \(request.body.count)\r\nConnection: close\r\n\r\n".utf8) + request.body
}
private func modelReadAll(_ connection: PinnedTLSConnection) async throws -> Data {
    var result = Data()
    while true {
        let part = try await connection.receive(timeout: .seconds(3))
        result.append(part.data)
        guard result.count <= 1_048_576 else { throw ModelAPIFailure.limit }
        if part.endOfStream { return result }
    }
}

private final class ModelWaitingConnection: UpstreamConnection, @unchecked Sendable {
    private let prefix: ScriptedConnection
    private let lock = NSLock()
    private var reads = 0
    init() throws { prefix = ScriptedConnection(Array(try modelWire(modelFixture()).prefix(2))) }
    func start(timeout: Duration) async throws { try await prefix.start(timeout: timeout) }
    func send(_ data: Data, timeout: Duration) async throws { try await prefix.send(data, timeout: timeout) }
    func receive(timeout: Duration) async throws -> ReceivedBytes {
        let waiting = lock.withLock { reads += 1; return reads > 2 }
        if waiting { try await Task.sleep(for: .seconds(30)) }
        return try await prefix.receive(timeout: timeout)
    }
    func cancel() { prefix.cancel() }
    var cancelled: Bool { prefix.didCancel }
}

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct ModelAPITLSTests {
    @Test func modelHTTPSUsesZoneCAAndRejectsWrongRootNameUntrustedAndPlainHTTP() async throws {
        let material = try await ModelTLSMaterial(), other = try await ModelTLSMaterial()
        let upstream = ScriptedConnection(try modelWire(modelFixture()))
        let handler = try modelGateway(upstream)
        let server = GatewayServer(router: try TypedRouter(routes: [handler.route()]), tls: material.configuration)
        let port = try await server.start(); defer { server.stop() }
        for (root, hostname) in [(other.root as SecCertificate?, "127.0.0.1"), (nil, "127.0.0.1"), (material.root, "wrong.example")] {
            let client = try modelTLSClient(port: port, root: root, hostname: hostname); defer { client.cancel() }
            await #expect(throws: UpstreamFailure.tlsFailed) { try await client.start(timeout: .seconds(3)) }
        }
        let plain = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        plain.start(queue: DispatchQueue(label: "sanjbox.model.plain-negative")); defer { plain.cancel() }
        do {
            try await boundedIO(timeout: .seconds(2), cancel: { plain.cancel() }) { (result: IOResult<Void>) in
                plain.send(content: modelHTTP(try! modelRequest(), port: port), completion: .contentProcessed { error in
                    if error != nil { result.finish(.failure(UpstreamFailure.connectionFailed)) } else { result.finish(.success(())) }
                })
            }
            let response: Data = try await boundedIO(timeout: .seconds(2), cancel: { plain.cancel() }) { result in
                plain.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, error in
                    if error != nil { result.finish(.failure(UpstreamFailure.connectionFailed)) } else { result.finish(.success(data ?? Data())) }
                }
            }
            #expect(!String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        } catch { /* handshake rejection / close / timeout are all fail-closed */ }
        #expect(upstream.sent.isEmpty)
        #expect(await handler.remainingBudgetUnits() == 100)

        let client = try modelTLSClient(port: port, root: material.root); defer { client.cancel() }
        try await client.start(timeout: .seconds(3))
        try await client.send(modelHTTP(modelRequest(), port: port), timeout: .seconds(3))
        let response = String(decoding: try await modelReadAll(client), as: UTF8.self)
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.contains("event: message_stop\n") && response.hasSuffix("0\r\n\r\n"))
        #expect(response.contains("synthetic answer") && !response.contains(modelTestKey))
        #expect(upstream.sent.count == 1)
        #expect(await handler.auditRecords().map(\.outcome) == [.completed])
    }

    @Test func modelHTTPSRejectsInvalidPKCS12WithoutInstallingIdentity() throws {
        #expect(throws: ModelAPIFailure.configuration) { _ = try GatewayTLSConfiguration(pkcs12: Data("invalid synthetic archive".utf8), passphrase: "synthetic") }
        #expect(throws: ModelAPIFailure.limit) { _ = try GatewayTLSConfiguration(pkcs12: Data(repeating: 0, count: 65_537), passphrase: "synthetic") }
    }

    @Test func modelHTTPSPeerDisconnectCancelsWaitingUpstreamAndKeepsDebit() async throws {
        let material = try await ModelTLSMaterial(), upstream = try ModelWaitingConnection()
        let handler = try modelGateway(upstream)
        let server = GatewayServer(router: try TypedRouter(routes: [handler.route()]), tls: material.configuration)
        let port = try await server.start(); defer { server.stop() }
        let client = try modelTLSClient(port: port, root: material.root); defer { client.cancel() }
        try await client.start(timeout: .seconds(3))
        try await client.send(modelHTTP(modelRequest(), port: port), timeout: .seconds(3))
        var first = Data()
        while !String(decoding: first, as: UTF8.self).contains("event: message_start\n") {
            first.append(try await client.receive(timeout: .seconds(3)).data)
            guard first.count < 16_384 else { throw ModelAPIFailure.limit }
        }
        #expect(await handler.auditRecords().map(\.outcome) == [.running])
        client.cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await handler.auditRecords().contains(where: { $0.outcome == .running }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(upstream.cancelled)
        #expect(await handler.auditRecords().map(\.outcome) == [.cancelled])
        #expect(await handler.remainingBudgetUnits() == 90)
        #expect(await handler.takeFinishedRecords().count == 1)
    }
}
