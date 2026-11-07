import Foundation
import SanjboxGatewayCore
import XCTest

@testable import SanjboxGatewayService

final class TransportTests: XCTestCase {
    private func wire(_ method: String, _ target: String,
                      headers: [String: String] = [:], body: Data = Data()) -> Data {
        var head = "\(method) \(target) HTTP/1.1\r\nHost: gateway.test\r\nConnection: close\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(key): \(value)\r\n"
        }
        if !body.isEmpty { head += "Content-Length: \(body.count)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }

    func testServesOneResponseOverInMemoryChannel() async throws {
        let channel = MockChannel(inbound: wire("GET", "/nope"))
        let service = try GatewayService(policy: try Fixture.policy([Fixture.npm()]))
        try await LoopbackConnection(channel: channel).serve(serving: service)

        let sent = String(decoding: channel.sent, as: UTF8.self)
        XCTAssertEqual(sent, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n"
                       + "Content-Length: 14\r\nConnection: close\r\n\r\n{\"error\":404}\n")
        XCTAssertEqual(channel.inboundRemainingForTest, 0)
        XCTAssertTrue(channel.isClosed)
    }

    func testOversizedRequestIsRefusedBeforeDispatch() async throws {
        let channel = MockChannel(inbound: Data(repeating: 0x41, count: 4_096))
        let service = try GatewayService(policy: try Fixture.policy([Fixture.npm()]))
        let connection = LoopbackConnection(channel: channel, maximumHeaderBytes: 64, maximumBodyBytes: 64)
        do {
            try await connection.serve(serving: service)
            XCTFail("oversized request must not be served")
        } catch let error as ConnectionFailure {
            XCTAssertEqual(error, .requestTooLarge)
        }
        let records = await service.auditRecords()
        XCTAssertTrue(records.isEmpty)
        XCTAssertFalse(channel.isClosed)
    }

    func testPlainEOFIsIncompleteRequest() async throws {
        let channel = MockChannel(inbound: Data())
        let service = try GatewayService(policy: try Fixture.policy([Fixture.npm()]))
        do {
            try await LoopbackConnection(channel: channel).serve(serving: service)
            XCTFail("empty stream must not be served")
        } catch let error as ConnectionFailure {
            XCTAssertEqual(error, .incompleteRequest)
        }
    }

    func testMalformedRequestIsRefused() async throws {
        let channel = MockChannel(inbound: Data("not a request line\r\n\r\n".utf8))
        let service = try GatewayService(policy: try Fixture.policy([Fixture.npm()]))
        do {
            try await LoopbackConnection(channel: channel).serve(serving: service)
            XCTFail("malformed request must not be served")
        } catch let error as ConnectionFailure {
            XCTAssertEqual(error, .malformedRequest)
        }
    }

    func testFailedStreamIsTruncatedInsteadOfCompleted() async throws {
        // Modelový handler vrátí SSE producenta; mock resolver ho odmítne, takže
        // přenos skončí bez koncového chunku a klient pozná zkrácení.
        let resolver = RefusingResolver()
        let service = try GatewayService(policy: try Fixture.policy([Fixture.model()]),
                                         upstream: UpstreamClient(resolver: resolver))
        let body = try encodeModelRequest()
        let channel = MockChannel(inbound: wire("POST", "/model/v1/messages",
                                               headers: ["content-type": "application/json"], body: body))
        try await LoopbackConnection(channel: channel).serve(serving: service)

        let sent = String(decoding: channel.sent, as: UTF8.self)
        XCTAssertTrue(sent.hasPrefix("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"), sent)
        XCTAssertTrue(sent.contains("Transfer-Encoding: chunked\r\n"))
        XCTAssertFalse(sent.hasSuffix("\r\n0\r\n\r\n"), "truncated stream must not be completed")
        XCTAssertEqual(resolver.consulted, ["api.anthropic.com"])
        XCTAssertTrue(channel.isClosed)

        let records = await service.auditRecords()
        XCTAssertEqual(records.first?.decision, .routed)
        XCTAssertEqual(records.first?.status, 200)
    }

    func testChunkFramingUsesHexLength() {
        XCTAssertEqual(LoopbackConnection.chunked(Data("data: x\n\n".utf8)),
                       Data("9\r\ndata: x\n\n\r\n".utf8))
        XCTAssertEqual(LoopbackConnection.chunked(Data()), Data("0\r\n\r\n".utf8))
        XCTAssertEqual(LoopbackConnection.reason(413), "Content Too Large")
        XCTAssertEqual(LoopbackConnection.reason(418), "Unknown")
    }

    func testListenerAddressOnlyAcceptsExplicitLoopback() {
        XCTAssertEqual(LoopbackListener.Address(text: "127.0.0.1:18765")?.text, "127.0.0.1:18765")
        XCTAssertNil(LoopbackListener.Address(text: "0.0.0.0:18765"))
        XCTAssertNil(LoopbackListener.Address(text: "localhost:18765"))
        XCTAssertNil(LoopbackListener.Address(text: "127.0.0.1:0"))
        XCTAssertNil(LoopbackListener.Address(text: "127.0.0.1:65536"))
        XCTAssertNil(LoopbackListener.Address(text: "[::1]:18765"))
        XCTAssertNil(LoopbackListener.Address(port: 0))
    }
}
