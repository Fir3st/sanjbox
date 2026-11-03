import Foundation
import Testing
@testable import SanjboxGatewayCore

let modelTestKey = "sanjbox-test-fixture-never-a-live-key-12345"
let modelTestName = "fixture-model"

func modelJSON(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
func modelRequest(_ body: Data? = nil, target: String = "/model/v1/messages", method: String = "POST",
                  headers: [String: String] = ["content-type": "application/json"]) throws -> HTTPRequest {
    HTTPRequest(method: method, target: target, headers: headers,
                body: try body ?? modelJSON(["model": modelTestName, "max_tokens": 32, "stream": true,
                                             "messages": [["role": "user", "content": "synthetic prompt"]]]))
}
func modelEvent(_ name: String, _ value: [String: Any]) throws -> SSEEvent {
    SSEEvent(data: String(decoding: try modelJSON(value), as: UTF8.self), event: name)
}
func modelFixture(_ text: [String] = ["synthetic answer"]) throws -> [SSEEvent] {
    var events = [try modelEvent("message_start", ["type": "message_start", "message": [
        "id": "msg_provider_fixture", "type": "message", "role": "assistant", "model": modelTestName,
        "content": [], "stop_reason": NSNull(), "stop_sequence": NSNull(), "usage": ["input_tokens": 4, "output_tokens": 1]]]),
        try modelEvent("content_block_start", ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]])]
    for text in text { events.append(try modelEvent("content_block_delta", ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text]])) }
    events += [try modelEvent("content_block_stop", ["type": "content_block_stop", "index": 0]),
               try modelEvent("message_delta", ["type": "message_delta", "delta": ["stop_reason": "end_turn", "stop_sequence": NSNull()], "usage": ["output_tokens": 8]]),
               try modelEvent("message_stop", ["type": "message_stop"])]
    return events
}
func modelWire(_ events: [SSEEvent], status: Int = 200, headers: String = "", finish: Bool = true) throws -> [String] {
    var parts = ["HTTP/1.1 \(status) Fixture\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\(headers)\r\n"]
    for event in events {
        let data = try event.encoded()
        parts.append(String(data.count, radix: 16) + "\r\n" + String(decoding: data, as: UTF8.self) + "\r\n")
    }
    if finish { parts.append("0\r\n\r\n") }
    return parts
}
struct ModelEmptyHosts: HostAddressProvider { func addresses() throws -> Set<IPAddress> { [] } }
func modelConfiguration(budget: UInt64 = 100, charge: UInt64 = 10) throws -> ModelAPIConfiguration {
    try ModelAPIConfiguration(zoneID: "zone-fixture", allowedModels: [modelTestName], budgetUnits: budget, chargePerRequest: charge)
}
func modelGateway(_ connection: any UpstreamConnection, configuration: ModelAPIConfiguration? = nil,
                  dns: SequenceDNS = SequenceDNS(Array(repeating: ["8.8.8.8"], count: 20))) throws -> ModelAPIGateway {
    try ModelAPIGateway(configuration: configuration ?? modelConfiguration(), testKey: ModelAPITestKey(modelTestKey),
                        upstream: UpstreamClient(resolver: dns, hostAddresses: ModelEmptyHosts(), dialer: RecordingDialer { _ in connection }))
}
func modelProducer(_ reply: GatewayReply) throws -> SSEProducer {
    guard case .events(let producer) = reply else { throw ModelAPIFailure.schema }
    return producer
}
actor ModelEvents {
    var events: [SSEEvent] = []
    func append(_ event: SSEEvent) { events.append(event) }
    var wire: String { events.map { $0.data }.joined(separator: "\n") }
    var text: String {
        events.compactMap { event in
            guard let root = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any],
                  let delta = root["delta"] as? [String: Any] else { return nil }
            return delta["text"] as? String
        }.joined()
    }
}

@Test func modelTypedStreamInjectsOnlyTrustedKeyAndReconstructsOutput() async throws {
    let connection = ScriptedConnection(try modelWire(modelFixture(), headers: "Set-Cookie: \(modelTestKey)\r\nX-Private: \(modelTestKey)\r\n"))
    let dns = SequenceDNS([["8.8.8.8"]]); let handler = try modelGateway(connection, dns: dns)
    let output = ModelEvents()
    let produce = try await modelProducer(handler.reply(to: modelRequest(headers: ["content-type": "application/json", "user-agent": "must-not-be-forwarded"])))
    #expect(await handler.remainingBudgetUnits() == 100)
    try await produce { await output.append($0) }
    let sent = String(decoding: connection.sent[0], as: UTF8.self)
    #expect(sent.hasPrefix("POST /v1/messages HTTP/1.1\r\nHost: api.anthropic.com\r\n"))
    #expect(sent.contains("x-api-key: \(modelTestKey)\r\n") && sent.contains("anthropic-version: 2023-06-01\r\n"))
    #expect(!sent.contains("must-not-be-forwarded"))
    #expect(await dns.names == ["api.anthropic.com"])
    #expect(await output.text == "synthetic answer")
    #expect(await output.events.last?.event == "message_stop")
    #expect(await !output.wire.contains(modelTestKey))
    #expect(await !output.wire.contains("msg_provider_fixture"))
    #expect(await handler.remainingBudgetUnits() == 90)
    #expect(await handler.auditRecords().map(\.outcome) == [.completed])
    #expect(connection.didCancel)
}

@Test func modelRequestsDenyForeignAuthRoutesModelsAndUnsupportedFieldsBeforeDial() async throws {
    let connection = ScriptedConnection([]); let handler = try modelGateway(connection)
    var requests: [HTTPRequest] = []
    for header in ["Authorization", "proxy-authorization", "cookie", "X-API-Key", "api-key", "x-zone-id", "anthropic-version", "anthropic-beta", "x-target", "proxy-connection", "x-http-method-override"] {
        requests.append(try modelRequest(headers: ["content-type": "application/json", header: "synthetic-client-value"]))
    }
    for method in ["GET", "PUT", "DELETE", "CONNECT"] { requests.append(try modelRequest(method: method)) }
    for target in ["/model/v1/messages?key=x", "/model/v1/messages#x", "/model/v1/messages/", "/model/v1/messages/count_tokens", "/model/https://evil.example", "/model/v1/%6dessages"] {
        requests.append(try modelRequest(target: target))
    }
    for change in [["model": "not-allowed"], ["stream": false], ["max_tokens": true], ["max_tokens": 0], ["max_tokens": 8193],
                   ["api_key": modelTestKey], ["tools": []], ["system": "unsupported"], ["target": "https://evil.example"],
                   ["messages": [["role": "user", "content": [["type": "image", "source": "url"]]]]],
                   ["messages": [["role": "assistant", "content": "prefill"]]]] as [[String: Any]] {
        var root = try JSONSerialization.jsonObject(with: modelRequest().body) as! [String: Any]
        root.merge(change) { _, new in new }; requests.append(try modelRequest(modelJSON(root)))
    }
    for request in requests {
        guard case .response(let response) = try await handler.reply(to: request) else { Issue.record("request accepted"); continue }
        #expect(response.status == 403)
    }
    #expect(connection.sent.isEmpty)
    #expect(await handler.auditRecords().isEmpty)
    #expect(await handler.remainingBudgetUnits() == 100)
}

@Test func modelJSONRejectsDuplicateEscapedKeysNumbersDepthAndOversize() async throws {
    let connection = ScriptedConnection([]); let handler = try modelGateway(connection)
    for body in [#"{"model":"fixture-model","\u006dodel":"other","messages":[],"max_tokens":32,"stream":true}"#,
                 #"{"model":"fixture-model","messages":[{"role":"user","role":"assistant","content":"x"}],"max_tokens":32,"stream":true}"#,
                 #"{"model":"fixture-model","messages":[],"max_tokens":1e309,"stream":true}"#,
                 String(repeating: "[", count: 18) + "0" + String(repeating: "]", count: 18),
                 String(repeating: " ", count: 32_769)] {
        guard case .response(let response) = try await handler.reply(to: modelRequest(Data(body.utf8))) else { Issue.record("bad JSON accepted"); continue }
        #expect([403, 413].contains(response.status))
    }
    #expect(connection.sent.isEmpty)
}

@Test func modelStreamDetectsKeyAcrossEverySplitAndUTF8WithoutPassingIt() async throws {
    for split in 1..<modelTestKey.count {
        let prefix = String(modelTestKey.prefix(split)), suffix = String(modelTestKey.dropFirst(split))
        let connection = ScriptedConnection(try modelWire(modelFixture([String(repeating: "ž🙂", count: 80), prefix, suffix])))
        let handler = try modelGateway(connection); let output = ModelEvents()
        let produce = try await modelProducer(handler.reply(to: modelRequest()))
        await #expect(throws: ModelAPIFailure.upstream) { try await produce { await output.append($0) } }
        #expect(await !output.text.contains(modelTestKey))
        #expect(await output.events.last?.event != "message_stop")
        #expect(await handler.auditRecords().map(\.outcome) == [.failed])
    }
    let text = String(repeating: "hé🙂ř", count: 500)
    let connection = ScriptedConnection(try modelWire(modelFixture([String(text.prefix(1001)), String(text.dropFirst(1001))])))
    let output = ModelEvents(); let handler = try modelGateway(connection)
    let produce = try await modelProducer(handler.reply(to: modelRequest()))
    try await produce { await output.append($0) }
    #expect(await output.text == text)
}

@Test func modelStreamNeverReflectsErrorsIDsUnknownJSONOrIncompleteSuccess() async throws {
    let fixture = try modelFixture()
    let error = try modelEvent("error", ["type": "error", "error": ["type": "test", "message": modelTestKey]])
    let keyInID = SSEEvent(data: fixture[0].data.replacingOccurrences(of: "msg_provider_fixture", with: modelTestKey), event: "message_start")
    let escaped = SSEEvent(data: #"{"type":"message_start","ty\u0070e":"error","message":""}"#, event: "message_start")
    let unknown = try modelEvent("content_block_delta", ["type": "content_block_delta", "index": 0,
                                                         "delta": ["type": "tool_use", "text": modelTestKey]])
    let reordered = [fixture[1], fixture[0]]
    for events in [[error], [keyInID], [escaped], [fixture[0], fixture[1], unknown], Array(fixture.dropLast()), fixture + [error], reordered] {
        let connection = ScriptedConnection(try modelWire(events)); let handler = try modelGateway(connection); let output = ModelEvents()
        let produce = try await modelProducer(handler.reply(to: modelRequest()))
        await #expect(throws: ModelAPIFailure.upstream) { try await produce { await output.append($0) } }
        #expect(await !output.wire.contains(modelTestKey))
        #expect(await !output.events.contains { $0.event == "message_stop" })
    }
    let truncated = ScriptedConnection(try modelWire(fixture, finish: false))
    let output = ModelEvents(); let handler = try modelGateway(truncated)
    let produce = try await modelProducer(handler.reply(to: modelRequest()))
    await #expect(throws: ModelAPIFailure.upstream) { try await produce { await output.append($0) } }
    #expect(await !output.events.contains { $0.event == "message_stop" })
}

@Test func modelUpstreamRedirectJSONErrorsAndRebindingNeverForwardKeyElsewhere() async throws {
    for status in [301, 302, 307, 308, 401, 429, 500] {
        let connection = ScriptedConnection(["HTTP/1.1 \(status) Fixture\r\nContent-Type: application/json\r\nLocation: https://evil.example/\r\nContent-Length: \(modelTestKey.utf8.count)\r\n\r\n\(modelTestKey)"])
        let dns = SequenceDNS([["8.8.8.8"]]); let handler = try modelGateway(connection, dns: dns); let output = ModelEvents()
        let produce = try await modelProducer(handler.reply(to: modelRequest()))
        await #expect(throws: ModelAPIFailure.upstream) { try await produce { await output.append($0) } }
        #expect(await output.events.isEmpty)
        #expect(await dns.names == ["api.anthropic.com"])
        #expect(connection.sent.count == 1)
    }
    let connection = ScriptedConnection(try modelWire(modelFixture()))
    let handler = try modelGateway(connection, dns: SequenceDNS([["127.0.0.1"]]))
    let produce = try await modelProducer(handler.reply(to: modelRequest()))
    await #expect(throws: ModelAPIFailure.upstream) { try await produce { _ in Issue.record("unsafe target emitted") } }
    #expect(connection.sent.isEmpty)
    #expect(await handler.remainingBudgetUnits() == 90) // uncertainty never grants a refund
}

@Test func modelLazySingleUseProducerCannotOrphanOrRepeatReservation() async throws {
    let connection = ScriptedConnection(try modelWire(modelFixture())); let handler = try modelGateway(connection)
    for _ in 0..<100 { _ = try await handler.reply(to: modelRequest()) }
    #expect(await handler.auditRecords().isEmpty)
    #expect(await handler.remainingBudgetUnits() == 100)
    let producer = try await modelProducer(handler.reply(to: modelRequest()))
    try await producer { _ in }
    await #expect(throws: ModelAPIFailure.replay) { try await producer { _ in } }
    #expect(connection.sent.count == 1)
    #expect(await handler.remainingBudgetUnits() == 90)
}

@Test func modelBackpressureHoldsReadAndConcurrentBudgetReservationCannotOverspend() async throws {
    let connection = ScriptedConnection(try modelWire(modelFixture()))
    let handler = try modelGateway(connection, configuration: modelConfiguration(budget: 10, charge: 10))
    let (ready, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let (release, resume) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { signal.finish(); resume.finish() }
    let produce = try await modelProducer(handler.reply(to: modelRequest()))
    let task = Task { try await produce { event in
        if event.event == "message_start" { signal.yield(()); for await _ in release { break }; try Task.checkCancellation() }
    } }
    var iterator = ready.makeAsyncIterator(); _ = await iterator.next()
    #expect(connection.readCount == 2) // HTTP head and first event only
    #expect(await handler.takeFinishedRecords().isEmpty)
    let second = try await modelProducer(handler.reply(to: modelRequest()))
    await #expect(throws: ModelAPIFailure.budget) { try await second { _ in } }
    #expect(await handler.remainingBudgetUnits() == 0)
    resume.yield(()); resume.finish(); try await task.value
    #expect(await handler.auditRecords().count == 1)
}

@Test func modelDisconnectAndTimeoutReleaseCapacityWithoutRefund() async throws {
    for timeout in [false, true] {
        let connection = ScriptedConnection(try modelWire(modelFixture()))
        let config = try ModelAPIConfiguration(zoneID: "zone-test", allowedModels: [modelTestName], budgetUnits: 100, chargePerRequest: 10,
                                              maximumConcurrent: 1, maximumRecords: 1, lifetime: timeout ? .milliseconds(30) : .seconds(2))
        let handler = try modelGateway(connection, configuration: config)
        let produce = try await modelProducer(handler.reply(to: modelRequest()))
        if timeout {
            await #expect(throws: ModelAPIFailure.upstream) { try await produce { _ in try await Task.sleep(for: .seconds(3)) } }
        } else {
            await #expect(throws: ModelAPIFailure.upstream) { try await produce { _ in throw UpstreamFailure.connectionFailed } }
        }
        #expect(connection.didCancel)
        #expect(await handler.remainingBudgetUnits() == 90)
        #expect(await handler.takeFinishedRecords().count == 1)
        // The next request reaches upstream (then fails: the fixture is consumed),
        // rather than a stuck active/audit slot. It incurs a second full debit.
        let next = try await modelProducer(handler.reply(to: modelRequest()))
        await #expect(throws: ModelAPIFailure.upstream) { try await next { _ in } }
        #expect(await handler.remainingBudgetUnits() == 80)
    }
}

@Test func modelActiveCapRefusesParallelDispatchBeforeDebitAndReleasesOnCancel() async throws {
    let connection = ScriptedConnection(try modelWire(modelFixture()))
    let config = try ModelAPIConfiguration(zoneID: "zone-cap", allowedModels: [modelTestName], budgetUnits: 100, chargePerRequest: 10, maximumConcurrent: 1)
    let handler = try modelGateway(connection, configuration: config)
    let (ready, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1)); defer { signal.finish() }
    let first = try await modelProducer(handler.reply(to: modelRequest()))
    let task = Task { try await first { _ in signal.yield(()); try await Task.sleep(for: .seconds(30)) } }
    var iterator = ready.makeAsyncIterator(); _ = await iterator.next()
    let second = try await modelProducer(handler.reply(to: modelRequest()))
    await #expect(throws: ModelAPIFailure.busy) { try await second { _ in } }
    #expect(connection.sent.count == 1)
    #expect(await handler.remainingBudgetUnits() == 90)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let third = try await modelProducer(handler.reply(to: modelRequest()))
    await #expect(throws: ModelAPIFailure.upstream) { try await third { _ in } }
    #expect(await handler.remainingBudgetUnits() == 80)
}

private final class ModelClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func get() -> ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}
@Test func modelRateBoundaryRollbackAuditCapacityAndCancellationFailClosed() async throws {
    let clock = ModelClock()
    let config = try ModelAPIConfiguration(zoneID: "trusted-zone", allowedModels: [modelTestName], budgetUnits: 100, chargePerRequest: 10,
                                          requestsPerWindow: 1, rateWindow: .seconds(60), maximumRecords: 1)
    let connection = ScriptedConnection(try modelWire(modelFixture()))
    let handler = try ModelAPIGateway(configuration: config, testKey: ModelAPITestKey(modelTestKey),
                                     upstream: UpstreamClient(resolver: SequenceDNS(Array(repeating: ["8.8.8.8"], count: 5)), hostAddresses: ModelEmptyHosts(), dialer: RecordingDialer { _ in connection }), now: { clock.get() })
    let first = try await modelProducer(handler.reply(to: modelRequest()))
    try await first { _ in }
    clock.advance(.seconds(59))
    let early = try await modelProducer(handler.reply(to: modelRequest()))
    await #expect(throws: ModelAPIFailure.rate) { try await early { _ in } }
    clock.advance(.seconds(1))
    let full = try await modelProducer(handler.reply(to: modelRequest()))
    await #expect(throws: ModelAPIFailure.busy) { try await full { _ in } }
    _ = await handler.takeFinishedRecords()
    let boundary = try await modelProducer(handler.reply(to: modelRequest()))
    await #expect(throws: ModelAPIFailure.upstream) { try await boundary { _ in } }
    #expect(await handler.remainingBudgetUnits() == 80)
    clock.advance(.seconds(-1))
    let backwards = try await modelProducer(handler.reply(to: modelRequest()))
    await #expect(throws: ModelAPIFailure.rate) { try await backwards { _ in } }
}

@Test func modelCallerCancellationClosesUpstreamAndFinalizesRecord() async throws {
    let connection = ScriptedConnection(try modelWire(modelFixture())); let handler = try modelGateway(connection)
    let (ready, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1)); defer { signal.finish() }
    let produce = try await modelProducer(handler.reply(to: modelRequest()))
    let task = Task { try await produce { _ in signal.yield(()); try await Task.sleep(for: .seconds(30)) } }
    var iterator = ready.makeAsyncIterator(); _ = await iterator.next(); task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(connection.didCancel)
    #expect(await handler.auditRecords().map(\.outcome) == [.cancelled])
    #expect(await handler.remainingBudgetUnits() == 90)
}

@Test func modelResponseEventAndByteLimitsTerminateWithoutSuccess() async throws {
    for config in [try ModelAPIConfiguration(zoneID: "z", allowedModels: [modelTestName], budgetUnits: 10, chargePerRequest: 10, maximumOutputBytes: 50),
                   try ModelAPIConfiguration(zoneID: "z", allowedModels: [modelTestName], budgetUnits: 10, chargePerRequest: 10, maximumEvents: 2)] {
        let handler = try modelGateway(ScriptedConnection(modelWire(modelFixture())), configuration: config)
        let output = ModelEvents(); let produce = try await modelProducer(handler.reply(to: modelRequest()))
        await #expect(throws: ModelAPIFailure.upstream) { try await produce { await output.append($0) } }
        #expect(await !output.events.contains { $0.event == "message_stop" })
        #expect(await handler.remainingBudgetUnits() == 0)
    }
}
