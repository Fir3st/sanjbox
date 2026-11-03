import Foundation
import Network
import Testing
@testable import SanjboxGatewayCore

private func send(_ data: Data, on connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        })
    }
}

private func receive(on connection: NWConnection) async throws -> (Data, Bool) {
    try await withCheckedThrowingContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, eof, error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: (data ?? Data(), eof)) }
        }
    }
}

/// Uses a real TCP socket, not URLSession (no ambient proxies, cookies or credentials).
private func client(port: UInt16) -> (NWConnection, Task<Void, Never>) {
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    connection.start(queue: DispatchQueue(label: "sanjbox.gateway.test-client"))
    let deadline = Task {
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        connection.cancel()
    }
    return (connection, deadline)
}

private func readToEnd(_ connection: NWConnection) async throws -> Data {
    var result = Data()
    while true {
        let (data, eof) = try await receive(on: connection)
        result.append(data)
        guard result.count < 1_048_576 else { throw HTTPFailure.tooLarge }
        if eof { return result }
    }
}

@Test @MainActor func realListenerHandlesFragmentedRequestsAndClosesConnection() async throws {
    let router = try TypedRouter(routes: [TypedRoute(mount: "/mock", methods: ["POST"]) { request in
        .response(HTTPResponse(contentType: "text/plain", body: request.body))
    }])
    let server = GatewayServer(router: router)
    let port = try await server.start()
    defer { server.stop() }
    let (connection, deadline) = client(port: port)
    defer { deadline.cancel(); connection.cancel() }
    try await send(Data("POST /mock HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 5\r\n\r\nhe".utf8), on: connection)
    try await send(Data("llo".utf8), on: connection)
    let response = String(decoding: try await readToEnd(connection), as: UTF8.self)
    #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
    #expect(response.contains("Content-Length: 5\r\n"))
    #expect(response.hasSuffix("\r\n\r\nhello"))
}

@Test @MainActor func realListenerRejectsForeignHostCredentialsAndMalformedFraming() async throws {
    let router = try TypedRouter(routes: [TypedRoute(mount: "/mock", methods: ["GET"]) { _ in
        Issue.record("denied request reached the handler")
        return .response(.error(500))
    }])
    let server = GatewayServer(router: router)
    let port = try await server.start()
    defer { server.stop() }
    for (headers, status) in [
        ("Host: attacker.example\r\n", 403),
        ("Host: 127.0.0.1:\(port)\r\nAuthorization: synthetic\r\n", 403),
        ("Host: 127.0.0.1:\(port)\r\nTransfer-Encoding: chunked\r\n", 400),
    ] {
        let (connection, deadline) = client(port: port)
        defer { deadline.cancel(); connection.cancel() }
        try await send(Data("GET /mock HTTP/1.1\r\n\(headers)\r\n".utf8), on: connection)
        let response = String(decoding: try await readToEnd(connection), as: UTF8.self)
        #expect(response.hasPrefix("HTTP/1.1 \(status) "))
    }
}

@Test @MainActor func sseFirstEventArrivesBeforeProducerCompletes() async throws {
    let (release, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { continuation.finish() }
    let router = try TypedRouter(routes: [TypedRoute(mount: "/events", methods: ["GET"]) { _ in
        .events { emit in
            try await emit(SSEEvent(data: "first"))
            for await _ in release { break }
            try Task.checkCancellation()
            try await emit(SSEEvent(data: "second"))
        }
    }])
    let server = GatewayServer(router: router)
    let port = try await server.start()
    defer { server.stop() }
    let (connection, deadline) = client(port: port)
    defer { deadline.cancel(); connection.cancel() }
    try await send(Data("GET /events HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8), on: connection)
    var first = Data()
    while !String(decoding: first, as: UTF8.self).contains("data: first\n\n") {
        let (part, eof) = try await receive(on: connection)
        first.append(part)
        if eof { Issue.record("stream ended before first event"); return }
    }
    let prefix = String(decoding: first, as: UTF8.self)
    #expect(prefix.contains("Content-Type: text/event-stream\r\n"))
    #expect(prefix.contains("Transfer-Encoding: chunked\r\n"))
    #expect(prefix.hasSuffix("d\r\ndata: first\n\n\r\n"))
    #expect(!prefix.contains("second"))
    continuation.yield(())
    continuation.finish()
    let rest = String(decoding: try await readToEnd(connection), as: UTF8.self)
    #expect(rest == "e\r\ndata: second\n\n\r\n0\r\n\r\n")
}

@Test @MainActor func incompleteRequestsTimeOutAndListenerCanRestart() async throws {
    let router = try TypedRouter(routes: [])
    let server = GatewayServer(router: router, limits: GatewayLimits(requestTimeout: .milliseconds(150)))
    let port = try await server.start()
    defer { server.stop() }
    let (connection, deadline) = client(port: port)
    defer { deadline.cancel(); connection.cancel() }
    try await send(Data("GET / HTTP/1.1\r\n".utf8), on: connection)
    #expect(try await readToEnd(connection).isEmpty)
    server.stop()
    #expect(server.port == nil)
    // Lifecycle supports restarting without retaining the old listener.
    _ = try await server.start()
    server.stop()
}

@Test(arguments: [false, true]) @MainActor
func activeSSEIsCancelledByStopOrLifetime(useLifetime: Bool) async throws {
    let (notice, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let deadlineNotice = Task {
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        continuation.finish()
    }
    defer { deadlineNotice.cancel(); continuation.finish() }
    let router = try TypedRouter(routes: [TypedRoute(mount: "/events", methods: ["GET"]) { _ in
        .events { emit in
            try await emit(SSEEvent(data: "started"))
            do { try await Task.sleep(for: .seconds(30)) }
            catch {
                continuation.yield(())
                throw error
            }
        }
    }])
    let limits = GatewayLimits(lifetime: useLifetime ? .milliseconds(300) : .seconds(30))
    let server = GatewayServer(router: router, limits: limits)
    let port = try await server.start()
    defer { server.stop() }
    let (connection, deadline) = client(port: port)
    defer { deadline.cancel(); connection.cancel() }
    try await send(Data("GET /events HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8), on: connection)
    var first = Data()
    while !String(decoding: first, as: UTF8.self).contains("data: started\n\n") {
        let (part, eof) = try await receive(on: connection)
        first.append(part)
        if eof { Issue.record("missing first event"); return }
    }
    if !useLifetime { server.stop() }
    var iterator = notice.makeAsyncIterator()
    let cancelled = await iterator.next()
    #expect(cancelled != nil)
}

@Test @MainActor func handlerFailureDoesNotReflectPrivateErrorOrAppendSecondResponse() async throws {
    struct SyntheticPrivateError: Error { let message = "synthetic-private-value" }
    let router = try TypedRouter(routes: [
        TypedRoute(mount: "/early", methods: ["GET"]) { _ in throw SyntheticPrivateError() },
        TypedRoute(mount: "/late", methods: ["GET"]) { _ in
            .events { emit in
                try await emit(SSEEvent(data: "first"))
                throw SyntheticPrivateError()
            }
        },
    ])
    let server = GatewayServer(router: router)
    let port = try await server.start()
    defer { server.stop() }
    for path in ["/early", "/late"] {
        let (connection, deadline) = client(port: port)
        defer { deadline.cancel(); connection.cancel() }
        try await send(Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8), on: connection)
        let text = String(decoding: try await readToEnd(connection), as: UTF8.self)
        #expect(!text.contains("synthetic-private-value"))
        #expect(text.components(separatedBy: "HTTP/1.1").count == 2)
        #expect(text.hasPrefix(path == "/early" ? "HTTP/1.1 500 " : "HTTP/1.1 200 "))
        if path == "/late" { #expect(text.hasSuffix("d\r\ndata: first\n\n\r\n")) }
    }
}
