import CryptoKit
import Foundation
import Synchronization
@testable import SanjboxGatewayCore

/// A real UpstreamClient over a fixture dialer: no DNS, interfaces or sockets.
final class OfflineUpstream: UpstreamDialer, Sendable {
    typealias Responder = @Sendable (HTTPRequest) throws -> [Data]
    private let responder: Responder
    private let requests = Mutex<[HTTPRequest]>([])

    init(_ responder: @escaping Responder) { self.responder = responder }
    var calls: [HTTPRequest] { requests.withLock { $0 } }
    var client: UpstreamClient {
        client(limits: UpstreamLimits())
    }
    func client(limits: UpstreamLimits) -> UpstreamClient {
        UpstreamClient(resolver: OfflineDNS(), hostAddresses: OfflineHosts(), dialer: self, limits: limits)
    }
    func connection(to destination: ApprovedDestination) throws -> any UpstreamConnection {
        OfflineConnection { [self] request in
            requests.withLock { $0.append(request) }
            return try responder(request)
        }
    }
}

private struct OfflineDNS: DestinationResolver {
    func addresses(for hostname: String) async throws -> [IPAddress] { [try IPAddress("8.8.8.8")] }
}
private struct OfflineHosts: HostAddressProvider {
    func addresses() throws -> Set<IPAddress> { [] }
}
private final class OfflineConnection: UpstreamConnection, Sendable {
    private let responder: OfflineUpstream.Responder
    private let pending = Mutex<[Data]>([])
    init(_ responder: @escaping OfflineUpstream.Responder) { self.responder = responder }
    func start(timeout: Duration) async throws { try Task.checkCancellation() }
    func send(_ bytes: Data, timeout: Duration) async throws {
        var decoder = HTTPRequestDecoder()
        guard let request = try decoder.append(bytes) else { throw HTTPFailure.malformed }
        let response = try responder(request)
        pending.withLock { $0 = response }
    }
    func receive(timeout: Duration) async throws -> ReceivedBytes {
        try Task.checkCancellation()
        return pending.withLock { parts in
            guard !parts.isEmpty else { return ReceivedBytes(data: Data(), endOfStream: true) }
            return ReceivedBytes(data: parts.removeFirst(), endOfStream: false)
        }
    }
    func cancel() {}
}

func responseWire(_ data: Data, type: String = "application/json", status: Int = 200) -> [Data] {
    [Data("HTTP/1.1 \(status) Fixture\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\n\r\n".utf8) + data]
}
func requestWire(_ method: String, _ target: String, body: Data = Data()) -> Data {
    Data("\(method) \(target) HTTP/1.1\r\nHost: fixture.test\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
}

let artifactBytes = Data("synthetic artifact, never executed".utf8)
let wheelFilename = "fixture-1.0.0-py3-none-any.whl"
func artifactUpstream(pypi: Bool, artifactHostname: String = "files.example") throws -> OfflineUpstream {
    let metadata: Data
    if pypi {
        let digest = SHA256.hash(data: artifactBytes).map { String(format: "%02x", $0) }.joined()
        metadata = try JSONSerialization.data(withJSONObject: [
            "meta": ["api-version": "1.4"], "name": "fixture", "files": [[
                "filename": wheelFilename, "url": "https://" + artifactHostname + "/packages/" + wheelFilename,
                "hashes": ["sha256": digest], "size": artifactBytes.count,
                "upload-time": "2020-01-01T00:00:00Z",
            ]],
        ])
    } else {
        let integrity = "sha512-" + Data(SHA512.hash(data: artifactBytes)).base64EncodedString()
        metadata = try JSONSerialization.data(withJSONObject: [
            "name": "fixture", "versions": ["1.0.0": ["name": "fixture", "version": "1.0.0", "dist": [
                "tarball": "https://registry.example/fixture/-/fixture-1.0.0.tgz", "integrity": integrity,
            ]]], "time": ["1.0.0": "2020-01-01T00:00:00Z"], "dist-tags": ["latest": "1.0.0"],
        ])
    }
    return OfflineUpstream { request in
        if request.target.contains("/-/") || request.target.hasPrefix("/packages/") {
            return responseWire(artifactBytes, type: "application/octet-stream")
        }
        return responseWire(metadata, type: pypi ? "application/vnd.pypi.simple.v1+json" : "application/json")
    }
}

func modelStreamWire(failAfterFirstEvent: Bool = false) throws -> [Data] {
    let objects: [(String, [String: Any])] = [
        ("message_start", ["type": "message_start", "message": [
            "id": "msg_fixture", "type": "message", "role": "assistant", "model": "fixture-model",
            "content": [], "stop_reason": NSNull(), "stop_sequence": NSNull(),
            "usage": ["input_tokens": 4, "output_tokens": 1],
        ]]),
        ("content_block_start", ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]),
        ("content_block_delta", ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "synthetic answer"]]),
        ("content_block_stop", ["type": "content_block_stop", "index": 0]),
        ("message_delta", ["type": "message_delta", "delta": ["stop_reason": "end_turn", "stop_sequence": NSNull()], "usage": ["output_tokens": 8]]),
        ("message_stop", ["type": "message_stop"]),
    ]
    var wire = [Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)]
    for (event, object) in objects {
        let data = try JSONSerialization.data(withJSONObject: object)
        let payload = try SSEEvent(data: String(decoding: data, as: UTF8.self), event: event).encoded()
        wire.append(Data("\(String(payload.count, radix: 16))\r\n".utf8) + payload + Data("\r\n".utf8))
        if failAfterFirstEvent { return wire } // EOF without the remaining protocol/chunks
    }
    wire.append(Data("0\r\n\r\n".utf8))
    return wire
}

/// Hold a real handler inside DNS policy until its concurrent-cap test releases it.
actor HeldResolver: DestinationResolver {
    private let entered: AsyncStream<Void>.Continuation
    private let release: AsyncStream<Void>
    init(entered: AsyncStream<Void>.Continuation, release: AsyncStream<Void>) {
        self.entered = entered; self.release = release
    }
    func addresses(for hostname: String) async throws -> [IPAddress] {
        entered.yield(())
        for await _ in release { break }
        try Task.checkCancellation()
        throw DestinationFailure.noAddresses
    }
}
