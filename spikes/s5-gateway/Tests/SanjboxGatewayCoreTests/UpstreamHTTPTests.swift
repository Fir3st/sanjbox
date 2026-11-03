import Foundation
import Testing
@testable import SanjboxGatewayCore

@Test(arguments: [false, true])
func upstreamResponseSurvivesEveryFragmentBoundary(chunked: Bool) throws {
    let wire = Data((chunked
        ? "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: text/plain\r\n\r\n2\r\nhe\r\n3\r\nllo\r\n0\r\n\r\n"
        : "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello").utf8)
    for boundary in 0...wire.count {
        var parser = UpstreamResponseDecoder()
        let first = try parser.append(Data(wire.prefix(boundary)))
        let rest = try parser.append(Data(wire.dropFirst(boundary)))
        let body = (first + rest).reduce(into: Data()) { $0.append($1) }
        try parser.finish()
        #expect(parser.head?.status == 200)
        #expect(String(decoding: body, as: UTF8.self) == "hello")
    }
}

@Test(arguments: [
    "HTTP/1.1 100 Continue\r\n\r\n",
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n",
    "HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n",
    "HTTP/1.1 200 OK\r\n\r\nclose-delimited",
    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: +1\r\n\r\nx",
    "HTTP/1.1 200 OK\r\nContent-Length : 0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n folded: value\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nX: a\nb\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Encoding: gzip\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: Content-Length\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\n\r\n",
    "HTTP/1.1 204 No Content\r\nContent-Length: 1\r\n\r\nx",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1;ext=x\r\nx\r\n0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-1\r\n",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nffffffffffffffff\r\n",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nxXX",
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX: trailer\r\n\r\n",
])
func ambiguousUpstreamResponsesAreRejected(wire: String) {
    var parser = UpstreamResponseDecoder()
    #expect(throws: (any Error).self) { _ = try parser.append(Data(wire.utf8)) }
}

@Test func upstreamLimitsAndTruncationFailClosed() throws {
    for wire in ["HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhe",
                 "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhe",
                 "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n",
                 "HTTP/1.1 200 OK\r\nContent-Length:"] {
        var parser = UpstreamResponseDecoder()
        _ = try parser.append(Data(wire.utf8))
        #expect(throws: UpstreamFailure.truncatedResponse) { try parser.finish() }
    }
    var smallHead = UpstreamResponseDecoder(maximumHeaderBytes: 16)
    #expect(throws: HTTPFailure.tooLarge) { _ = try smallHead.append(Data(repeating: 65, count: 17)) }
    for framing in ["Content-Length: 4\r\n\r\ntest", "Transfer-Encoding: chunked\r\n\r\n4\r\ntest\r\n0\r\n\r\n"] {
        var parser = UpstreamResponseDecoder(maximumBodyBytes: 3)
        #expect(throws: HTTPFailure.tooLarge) { _ = try parser.append(Data("HTTP/1.1 200 OK\r\n\(framing)".utf8)) }
    }
    var frames = UpstreamResponseDecoder(maximumHeaderBytes: 64, maximumBodyBytes: 100)
    _ = try frames.append(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
    #expect(throws: HTTPFailure.tooLarge) {
        for _ in 0..<100 { _ = try frames.append(Data("1\r\nx\r\n".utf8)) }
    }
}

@Test func typedUpstreamRequestOwnsAuthorityAndFraming() throws {
    let request = try UpstreamRequest(hostname: "API.Example", method: "POST", target: "/v1?x=1",
                                      headers: ["Authorization": "Bearer synthetic", "Content-Type": "application/json"],
                                      body: Data("{}".utf8))
    let wire = String(decoding: request.encoded(), as: UTF8.self)
    #expect(wire.contains("Host: api.example\r\n"))
    #expect(wire.contains("Content-Length: 2\r\n"))
    #expect(wire.contains("Accept-Encoding: identity\r\n"))
    #expect(wire.contains("authorization: Bearer synthetic\r\n"))
    for header in ["Host", "Transfer-Encoding", "Content-Length", "Connection", "Accept-Encoding", "Proxy-Authorization", "Upgrade"] {
        #expect(throws: UpstreamFailure.invalidRequest) {
            _ = try UpstreamRequest(hostname: "api.example", target: "/", headers: [header: "x"])
        }
    }
    for target in ["https://evil.example/", "//evil.example/", "/x\r\nHost: evil", "/%2e%2e/a", "/%00", "/%zz"] {
        #expect(throws: UpstreamFailure.invalidRequest) { _ = try UpstreamRequest(hostname: "api.example", target: target) }
    }
    #expect(throws: UpstreamFailure.invalidRequest) {
        _ = try UpstreamRequest(hostname: "api.example", target: "/", headers: ["X": "one", "x": "two"])
    }
    #expect(throws: UpstreamFailure.invalidRequest) {
        _ = try UpstreamRequest(hostname: "api.example", target: "/", headers: ["X": "a\r\nb"])
    }
    #expect(throws: UpstreamFailure.invalidRequest) { _ = try UpstreamRequest(hostname: "api.example", method: "CONNECT", target: "/") }
    #expect(throws: UpstreamFailure.invalidRequest) { _ = try UpstreamRequest(hostname: "api.example", target: "/", body: Data([1])) }
}

@Test func upstreamSSESurvivesUTF8AndAllLineBoundaries() throws {
    let wire = Data("\u{feff}: ping\r\nid: 12\revent: delta\ndata: žluťoučký\r\ndata: world\r\n\r\ndata: next\n\nid:\n\ndata: final\n\n".utf8)
    for boundary in 0...wire.count {
        var parser = SSEDecoder()
        let first = try parser.append(Data(wire.prefix(boundary)))
        let last = try parser.append(Data(wire.dropFirst(boundary)))
        let events = first + last
        try parser.finish()
        #expect(events.count == 3)
        #expect(events.first?.data == "žluťoučký\nworld")
        #expect(events.first?.event == "delta")
        #expect(events.first?.id == "12")
        #expect(events[1].event == nil)
        #expect(events[1].id == "12")
        #expect(events[2].id == "")
    }
    var byteParser = SSEDecoder()
    var byteEvents: [SSEEvent] = []
    for byte in wire { byteEvents += try byteParser.append(Data([byte])) }
    try byteParser.finish()
    #expect(byteEvents.count == 3)
}

@Test func upstreamSSERejectsOversizeMalformedAndIncompleteEvents() throws {
    var small = SSEDecoder(maximumEventBytes: 8)
    #expect(throws: HTTPFailure.tooLarge) { _ = try small.append(Data("data: long\n\n".utf8)) }
    var comments = SSEDecoder(maximumEventBytes: 8)
    #expect(throws: HTTPFailure.tooLarge) { _ = try comments.append(Data(":123\n:456\n".utf8)) }
    var malformed = SSEDecoder()
    #expect(throws: UpstreamFailure.unexpectedSSE) { _ = try malformed.append(Data([0xff, 10])) }
    for wire in ["data: incomplete", "data: incomplete\n", "event: incomplete\n"] {
        var parser = SSEDecoder()
        _ = try parser.append(Data(wire.utf8))
        #expect(throws: UpstreamFailure.truncatedResponse) { try parser.finish() }
    }
}
