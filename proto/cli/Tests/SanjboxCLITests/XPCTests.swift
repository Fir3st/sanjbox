import XCTest
import SanjboxContracts
@testable import SanjboxCLI

let shellRequest = HelperMessage.shell(.init(zoneID: "a1b2", workingRootID: "project"))

func assertCLIError(_ expected: CLIError, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
        XCTAssertEqual(error as? CLIError, expected, file: file, line: line)
    }
}

/// Every server here uses a real anonymous NSXPCListener and NSXPCConnection on macOS.
final class XPCTests: XCTestCase {
    func testAllFiveCommandsCrossXPCAndDecodeAtReceiver() throws {
        let vectors: [(HelperMessage, MockPhase)] = [
            (shellRequest, .running),
            (.run(.init(zoneID: "a1b2", workingRootID: "project", executableRootID: "tools", executablePath: "bin/probe", arguments: ["", "$(no)", "x y", "--", "a\nb"])), .running),
            (.pauseZone(.init(zoneID: "a1b2")), .running),
            (.snapshot(.init(zoneID: "a1b2", snapshotID: "new", rollbackUnitID: "full-state")), .paused),
            (.rollback(.init(zoneID: "a1b2", snapshotID: "baseline", rollbackUnitID: "full-state")), .stopped),
        ]
        for (request, phase) in vectors {
            let helper = MockHelper(phase: phase)
            let live = MockXPCServer(helper: helper)
            defer { live.invalidate() }
            let reply = try HelperClient(transport: XPCTransport(endpoint: live.endpoint)).send(request)
            XCTAssertEqual(helper.observe().received, [request])
            XCTAssertEqual(live.acceptedConnections, 1)
            if request.kind == .shell || request.kind == .run {
                XCTAssertEqual(reply.outcome, .accepted)
                XCTAssertEqual(reply.executionID, "mock-exec-1")
                XCTAssertEqual(helper.observe().handles["mock-exec-1"], request)
                XCTAssertTrue(HelperClient.render(reply).contains("process completion unknown"))
            } else { XCTAssertEqual(reply.outcome, .completed) }
        }
    }
    private func rejectReply(_ reply: Data, expected: CLIError = .invalidReply) {
        let server = MockXPCServer(responder: { _ in .reply(reply) })
        defer { server.invalidate() }
        assertCLIError(expected) { _ = try HelperClient(transport: XPCTransport(endpoint: server.endpoint)).send(shellRequest) }
        XCTAssertEqual(server.acceptedConnections, 1)
    }
    func testWrongKindReplyRejected() throws {
        rejectReply(try HelperReply(requestKind: .run, zoneID: "a1b2", outcome: .accepted, executionID: "mock-1").encoded())
    }
    func testWrongZoneReplyRejected() throws {
        rejectReply(try HelperReply(requestKind: .shell, zoneID: "b2c3", outcome: .accepted, executionID: "mock-1").encoded())
    }
    func testMalformedReplyRejected() { rejectReply(Data("not-json".utf8)) }
    func testRequestMasqueradingAsReplyRejected() throws { rejectReply(try shellRequest.encoded()) }
    func testReplyUnknownFieldAndCompletedExecutionRejected() throws {
        for body in [
            #"{"requestKind":"zone.shell","zoneID":"a1b2","outcome":"accepted","executionID":"h","extra":true}"#,
            #"{"requestKind":"zone.shell","zoneID":"a1b2","outcome":"completed"}"#,
            #"{"requestKind":"zone.shell","zoneID":"a1b2","outcome":"accepted"}"#,
            #"{"requestKind":"zone.shell","zoneID":"a1b2","zoneID":"a1b2","outcome":"accepted","executionID":"h"}"#,
        ] { rejectReply(try XPCEnvelope(kind: "helper.reply", body: Data(body.utf8)).encoded()) }
    }
    func testOversizedReplyRejected() { rejectReply(Data(repeating: 65, count: XPCEnvelope.maxBytes + 1)) }
    func testHelperFailurePreservedAfterCorrelation() throws {
        rejectReply(try HelperReply(requestKind: .shell, zoneID: "a1b2", outcome: .failed, errorCode: .invalidState).encoded(), expected: .helperFailed(.invalidState))
        rejectReply(try HelperReply(requestKind: .shell, zoneID: "b2c3", outcome: .failed, errorCode: .unauthorized).encoded())
    }
    func testMalformedRequestsDisconnectBeforeMockMutation() throws {
        let helper = MockHelper(), server = MockXPCServer(helper: helper)
        defer { server.invalidate() }
        let invalidBodies = [
            #"{"zoneID":"a1b2","zoneID":"a1b2"}"#,
            #"{"zoneID":"a1b2","uid":0}"#,
            #"{"zoneID":"../x"}"#,
        ]
        let bytes = try invalidBodies.map { try XPCEnvelope(kind: "zone.pause", body: Data($0.utf8)).encoded() }
            + [Data("{".utf8), try HelperReply(requestKind: .pauseZone, zoneID: "a1b2", outcome: .completed).encoded()]
        for request in bytes {
            assertCLIError(.connectionLost) { _ = try XPCTransport(endpoint: server.endpoint).exchange(request) }
        }
        XCTAssertTrue(helper.observe().received.isEmpty)
        XCTAssertEqual(helper.observe().phase, .running)
        XCTAssertEqual(server.acceptedConnections, bytes.count)
    }
    func testDisconnectDuringRequestIsFailureWithoutRetry() {
        let server = MockXPCServer(responder: { _ in .disconnect })
        defer { server.invalidate() }
        assertCLIError(.connectionLost) { _ = try HelperClient(transport: XPCTransport(endpoint: server.endpoint)).send(shellRequest) }
        XCTAssertEqual(server.acceptedConnections, 1)
    }
    func testLostReplyLeavesAdmissionUnknownWithoutRetry() {
        let helper = MockHelper()
        let server = MockXPCServer(responder: { request in
            _ = try helper.exchange(request)
            return .disconnect
        })
        defer { server.invalidate() }
        assertCLIError(.connectionLost) { _ = try HelperClient(transport: XPCTransport(endpoint: server.endpoint)).send(shellRequest) }
        XCTAssertEqual(helper.observe().handles.count, 1)
        XCTAssertEqual(helper.observe().received, [shellRequest])
        XCTAssertEqual(server.acceptedConnections, 1)
        XCTAssertTrue(CLIError.connectionLost.diagnostic.contains("outcome unknown"))
    }
    func testInvalidTypedRequestNeverReachesXPC() {
        let helper = MockHelper()
        let server = MockXPCServer(helper: helper)
        defer { server.invalidate() }
        let request = HelperMessage.run(.init(zoneID: "a1b2", workingRootID: "project", executableRootID: "tools", executablePath: "../outside"))
        assertCLIError(.invalidInput) { _ = try HelperClient(transport: XPCTransport(endpoint: server.endpoint)).send(request) }
        XCTAssertEqual(server.acceptedConnections, 0)
        XCTAssertTrue(helper.observe().received.isEmpty)
    }
    func testClosedListenerFailsWithoutRetry() {
        let server = MockXPCServer(helper: MockHelper())
        let transport = XPCTransport(endpoint: server.endpoint, timeout: 0.2)
        server.invalidate(); server.invalidate()
        XCTAssertThrowsError(try HelperClient(transport: transport).send(shellRequest)) { error in
            XCTAssertTrue(error as? CLIError == .connectionLost || error as? CLIError == .timeout)
        }
        XCTAssertEqual(server.acceptedConnections, 0)
    }
    func testSilentPeerHasBoundedDeadline() {
        let server = MockXPCServer(responder: { _ in .silent })
        defer { server.invalidate() }
        let start = DispatchTime.now().uptimeNanoseconds
        assertCLIError(.timeout) { _ = try HelperClient(transport: XPCTransport(endpoint: server.endpoint, timeout: 0.15)).send(shellRequest) }
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - start, 2_000_000_000)
        XCTAssertEqual(server.acceptedConnections, 1)
    }
    func testLatchFailureCannotBeRevivedByLateReply() {
        let latch = ReplyLatch(timeout: 1)
        XCTAssertTrue(latch.finish(.failure(.connectionLost)))
        XCTAssertFalse(latch.finish(.success(Data("late".utf8))))
        assertCLIError(.connectionLost) { _ = try latch.wait() }
    }
    func testLatchLateCallbackAndLateConsumerFailClosed() {
        let expired = ReplyLatch(timeout: 1, now: { UInt64.max })
        expired.finish(.success(Data("late".utf8)))
        assertCLIError(.timeout) { _ = try expired.wait() }
        final class Clock: @unchecked Sendable {
            private let lock = NSLock(); private var value: UInt64 = 0
            func read() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
            func expire() { lock.lock(); defer { lock.unlock() }; value = .max }
        }
        let clock = Clock(), lateConsumer = ReplyLatch(timeout: 1, now: { clock.read() })
        lateConsumer.finish(.success(Data()))
        clock.expire()
        assertCLIError(.timeout) { _ = try lateConsumer.wait() }
    }
}
