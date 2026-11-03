import Foundation
import Testing
@testable import SanjboxGatewayCore

private func decode(_ text: String) throws -> HTTPRequest {
    var decoder = HTTPRequestDecoder()
    let request = try decoder.append(Data(text.utf8))
    return try #require(request)
}

@Test func requestSurvivesEveryByteBoundary() throws {
    let wire = Data("POST /api/messages?q=1 HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nContent-Length: 5\r\n\r\nhello".utf8)
    for boundary in 1..<wire.count {
        var decoder = HTTPRequestDecoder()
        #expect(try decoder.append(Data(wire.prefix(boundary))) == nil)
        let complete = try decoder.append(Data(wire.dropFirst(boundary)))
        let request = try #require(complete)
        #expect(request.method == "POST")
        #expect(request.target == "/api/messages?q=1")
        #expect(request.body == Data("hello".utf8))
    }
}

@Test(arguments: [
    "GET http://example.com/a HTTP/1.1\r\nHost: x\r\n\r\n",
    "CONNECT example.com:443 HTTP/1.1\r\nHost: x\r\n\r\n",
    "GET //example.com/a HTTP/1.1\r\nHost: x\r\n\r\n",
    "GET /a HTTP/1.0\r\nHost: x\r\n\r\n",
    "GET / HTTP/1.1\r\n\r\n",
    "GET / HTTP/1.1\r\nHost: x\r\nhost: y\r\n\r\n",
    "GET / HTTP/1.1\r\nHost : x\r\n\r\n",
    "GET / HTTP/1.1\r\nHost: x\r\n folded: yes\r\n\r\n",
    "GET / HTTP/1.1\r\nHost: x\r\nBad: x\ny\r\n\r\n",
    "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: +1\r\n\r\na",
    "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\na",
    "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n",
    "GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n\r\n",
    "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\n\r\n",
    "GET / HTTP/1.1\r\nHost: x\r\nConnection: Authorization\r\n\r\n",
    "GET /api/%2e%2e/a HTTP/1.1\r\nHost: x\r\n\r\n",
    "GET /api/%0d%0aX HTTP/1.1\r\nHost: x\r\n\r\n",
    "GET /api/%zz HTTP/1.1\r\nHost: x\r\n\r\n",
    "GET / HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n",
])
func unsafeRequestsAreRejected(wire: String) {
    #expect(throws: HTTPFailure.self) { try decode(wire) }
}

@Test func limitsAreAppliedBeforeBodyAndHeaderAccumulation() throws {
    var header = HTTPRequestDecoder(maximumHeaderBytes: 32)
    #expect(throws: HTTPFailure.tooLarge) { try header.append(Data(repeating: 65, count: 33)) }
    var body = HTTPRequestDecoder(maximumBodyBytes: 3)
    #expect(throws: HTTPFailure.tooLarge) {
        try body.append(Data("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\n".utf8))
    }
}

@Test func typedRoutingDoesNotFallBackToPassthrough() async throws {
    let router = try TypedRouter(routes: [TypedRoute(mount: "/npm", methods: ["GET"]) { _ in
        .response(HTTPResponse(body: Data("mock packument".utf8)))
    }])
    for (method, target, header, status) in [
        ("GET", "/npm/@scope%2fname", "", 200),
        ("GET", "/npmish/pkg", "", 404),
        ("GET", "/unknown", "", 404),
        ("PUT", "/npm/pkg", "", 403),
        ("DELETE", "/npm/pkg", "", 403),
        ("POST", "/npm/pkg", "", 403),
        ("CONNECT", "/npm/pkg", "", 403),
        ("GET", "/npm/pkg", "Authorization: Bearer synthetic\r\n", 403),
        ("GET", "/npm/pkg", "Proxy-Authorization: synthetic\r\n", 403),
        ("GET", "/npm/pkg", "Cookie: synthetic=value\r\n", 403),
        ("GET", "/npm/pkg", "X-API-Key: synthetic\r\n", 403),
    ] {
        let request = try decode("\(method) \(target) HTTP/1.1\r\nHost: x\r\n\(header)\r\n")
        let reply = try await router.reply(to: request)
        guard case .response(let response) = reply else { Issue.record("expected response"); continue }
        #expect(response.status == status)
    }
}

@Test func conflictingRoutesFailAtConfigurationTime() throws {
    let route = TypedRoute(mount: "/api", methods: ["POST"]) { _ in .response(.error(404)) }
    #expect(throws: RouteFailure.self) { try TypedRouter(routes: [route, route]) }
    #expect(throws: RouteFailure.self) {
        try TypedRouter(routes: [TypedRoute(mount: "/", methods: ["GET"], handle: route.handle)])
    }
    #expect(throws: RouteFailure.self) {
        try TypedRouter(routes: [TypedRoute(mount: "/api", methods: ["CONNECT"], handle: route.handle)])
    }
}

@Test func sseEncodesMultilineDataAndRejectsMetadataInjection() throws {
    let event = SSEEvent(data: "one\r\ntwo\rthree\n", event: "message", id: "7")
    #expect(String(decoding: try event.encoded(), as: UTF8.self) ==
            "event: message\nid: 7\ndata: one\ndata: two\ndata: three\ndata: \n\n")
    #expect(throws: HTTPFailure.malformed) { try SSEEvent(data: "safe", id: "x\nid: bad").encoded() }
    #expect(throws: HTTPFailure.tooLarge) { try SSEEvent(data: "oversized").encoded(maximumBytes: 4) }
    #expect(throws: HTTPFailure.malformed) {
        try HTTPResponse(contentType: "text/plain\r\nInjected: true", body: Data()).encoded()
    }
}
