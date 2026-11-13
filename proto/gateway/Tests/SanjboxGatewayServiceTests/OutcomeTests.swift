import Foundation
import Synchronization
import XCTest
@testable import SanjboxGatewayCore
@testable import SanjboxGatewayService

final class OutcomeTests: XCTestCase {
    func testArtifactTransportFinalizesRealNPMAndPyPIAuditsOnSuccessAndFailure() async throws {
        for pypi in [false, true] {
            for fail in [false, true] {
                let upstream = try artifactUpstream(pypi: pypi)
                let service = try GatewayService(policy: Fixture.policy([pypi ? Fixture.pypi() : Fixture.npm()]),
                                                 upstream: upstream.client)
                let target = pypi ? "/pypi/files/fixture/" + wheelFilename : "/npm/fixture/-/fixture-1.0.0.tgz"
                let channel = MockChannel(inbound: requestWire("GET", target), failSendAt: fail ? 1 : nil)
                do {
                    try await LoopbackConnection(channel: channel).serve(serving: service)
                    XCTAssertFalse(fail)
                } catch {
                    XCTAssertTrue(fail)
                    XCTAssertEqual(error as? ConnectionFailure, .sendFailed)
                }
                XCTAssertTrue(channel.isClosed)
                XCTAssertEqual(upstream.calls.count, 3, "metadata, artifact, fresh metadata")
                if !fail { XCTAssertTrue(channel.sent.suffix(artifactBytes.count).elementsEqual(artifactBytes)) }
                let states: [String]
                if pypi { states = await service.pypiDownloadRecords().map { $0.state.rawValue } }
                else { states = await service.npmDownloadRecords().map { $0.state.rawValue } }
                XCTAssertEqual(states, [fail ? "sendFailed" : "transportAccepted"])
                let decisions = await service.auditRecords()
                XCTAssertEqual(decisions.count, 1)
                XCTAssertEqual(decisions[0].decision, .routed, "request decision is distinct from artifact transport state")
            }
        }
    }

    func testResponseCompletionCannotOverwriteRealArtifactStateThroughCopyOrReplay() async throws {
        let upstream = try artifactUpstream(pypi: false)
        let service = try GatewayService(policy: Fixture.policy([Fixture.npm()]), upstream: upstream.client)
        guard case .response(let response) = try await service.dispatch(request("GET", "/npm/fixture/-/fixture-1.0.0.tgz")) else {
            return XCTFail("expected artifact")
        }
        let copy = response
        await response.completeTransport(true)
        await copy.completeTransport(false)
        await response.completeTransport(true)
        let records = await service.npmDownloadRecords()
        XCTAssertEqual(records.map(\.state), [.transportAccepted])
    }

    func testModelBudgetRateAndRecordCapacityRefuseBeforeStreamWithExactAuditReason() async throws {
        let cases: [(ModelRule, Int, DenialReason)] = [
            (ModelRule(allowedModels: ["fixture-model"], budgetUnits: 1), 403, .modelBudget),
            (ModelRule(allowedModels: ["fixture-model"], budgetUnits: 100, requestsPerWindow: 1), 429, .modelRate),
            (ModelRule(allowedModels: ["fixture-model"], budgetUnits: 100, maximumRecords: 1), 503, .handlerCapacity),
        ]
        let wire = try modelStreamWire()
        for (rule, status, reason) in cases {
            let upstream = OfflineUpstream { _ in wire }
            let service = try GatewayService(policy: Fixture.policy([.model(rule)]), upstream: upstream.client)
            for attempt in 1...2 {
                let channel = MockChannel(inbound: requestWire("POST", "/model/v1/messages", body: try encodeModelRequest()))
                try await LoopbackConnection(channel: channel).serve(serving: service)
                let sent = String(decoding: channel.sent, as: UTF8.self)
                XCTAssertTrue(sent.hasPrefix("HTTP/1.1 \(attempt == 1 ? 200 : status) "), sent)
                if attempt == 1 { XCTAssertTrue(sent.hasSuffix("0\r\n\r\n")) }
                else { XCTAssertFalse(sent.contains("text/event-stream")) }
                XCTAssertTrue(channel.isClosed)
            }
            XCTAssertEqual(upstream.calls.count, 1, "rejected request cannot dial or consume budget")
            let records = await service.auditRecords()
            XCTAssertEqual(records.map(\.decision), [.routed, .deniedByHandler])
            XCTAssertEqual(records.map(\.reason), ["", reason.rawValue])
            XCTAssertEqual(records.map(\.status), [200, status])
        }
    }

    func testModelFailureBeforeAndAfterFirstEventHasFinalFailureAudit() async throws {
        for afterFirst in [false, true] {
            let wire = try modelStreamWire(failAfterFirstEvent: true)
            let upstream = OfflineUpstream { _ in afterFirst ? wire : responseWire(Data(), status: 503) }
            let service = try GatewayService(policy: Fixture.policy([Fixture.model()]), upstream: upstream.client)
            let channel = MockChannel(inbound: requestWire("POST", "/model/v1/messages", body: try encodeModelRequest()))
            try await LoopbackConnection(channel: channel).serve(serving: service)
            let sent = String(decoding: channel.sent, as: UTF8.self)
            XCTAssertTrue(sent.hasPrefix("HTTP/1.1 \(afterFirst ? 200 : 502) "), sent)
            XCTAssertEqual(sent.components(separatedBy: "HTTP/1.1").count - 1, 1)
            if afterFirst {
                XCTAssertTrue(sent.contains("message_start"))
                XCTAssertFalse(sent.hasSuffix("0\r\n\r\n"))
            }
            let records = await service.auditRecords()
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records[0].decision, .failed)
            XCTAssertEqual(records[0].reason, "streamFailed")
            XCTAssertEqual(records[0].status, 502)
        }
    }

    func testUnusedAndRunningStreamConsumeAuditCapacityAndFinalizeExactlyOnce() async throws {
        let modelWire = try modelStreamWire()
        let modelUpstream = OfflineUpstream { _ in modelWire }
        let service = try GatewayService(policy: Fixture.policy([Fixture.model()], auditCapacity: 1),
                                         upstream: modelUpstream.client)
        guard case .events(let produce) = try await service.dispatch(request("POST", "/model/v1/messages",
            headers: ["content-type": "application/json"], body: encodeModelRequest())) else { return XCTFail("stream") }
        let pending = await service.auditRecords()
        XCTAssertEqual(pending.map(\.decision), [.pending])
        XCTAssertEqual(pending.map(\.status), [0])
        XCTAssertEqual(modelUpstream.calls.count, 0)
        let saturated = try await service.dispatch(request("POST", "/model/v1/messages",
            headers: ["content-type": "application/json"], body: encodeModelRequest()))
        XCTAssertEqual(status(of: saturated), 503)
        try await produce { _ in }
        let finished = await service.auditRecords()
        XCTAssertEqual(finished.map(\.decision), [.routed])
        XCTAssertEqual(finished.map(\.sequence), [1])
        do { try await produce { _ in }; XCTFail("single use") }
        catch { XCTAssertEqual(error as? ModelAPIFailure, .replay) }
        let afterReplay = await service.auditRecords()
        XCTAssertEqual(afterReplay, finished)
        XCTAssertEqual(modelUpstream.calls.count, 1)
    }

    func testNPMConcurrentCapacityIsTypedDenialButUpstream503IsNot() async throws {
        let (entered, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (release, resume) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { signal.finish(); resume.finish() }
        let resolver = HeldResolver(entered: signal, release: release)
        let service = try GatewayService(policy: Fixture.policy([Fixture.npm(operations: 1)]),
                                         upstream: UpstreamClient(resolver: resolver))
        let first = Task { try await service.dispatch(request("GET", "/npm/fixture")) }
        var iterator = entered.makeAsyncIterator(); _ = await iterator.next()
        let second = try await service.dispatch(request("GET", "/npm/fixture"))
        XCTAssertEqual(status(of: second), 503)
        let during = await service.auditRecords()
        XCTAssertEqual(during.map(\.decision), [.deniedByHandler])
        XCTAssertEqual(during.map(\.reason), ["handlerCapacity"])
        resume.yield(()); resume.finish(); _ = try await first.value

        let backend = OfflineUpstream { _ in responseWire(Data(), status: 503) }
        let other = try GatewayService(policy: Fixture.policy([Fixture.npm()]), upstream: backend.client)
        let reply = try await other.dispatch(request("GET", "/npm/fixture"))
        XCTAssertEqual(status(of: reply), 502)
        let audit = await other.auditRecords()
        XCTAssertNotEqual(audit.first?.reason, "handlerCapacity")
        XCTAssertNil(GatewayService.handlerDenial(for: .error(503)), "raw upstream status carries no local refusal")
    }

    func testModelConcurrentCapacityAndCancellationFinalizePendingRecords() async throws {
        let (entered, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (release, resume) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { signal.finish(); resume.finish() }
        let service = try GatewayService(policy: Fixture.policy([.model(ModelRule(
            allowedModels: ["fixture-model"], budgetUnits: 100, maximumConcurrent: 1))]),
            upstream: UpstreamClient(resolver: HeldResolver(entered: signal, release: release)))
        let firstChannel = MockChannel(inbound: requestWire("POST", "/model/v1/messages", body: try encodeModelRequest()))
        let first = Task { try await LoopbackConnection(channel: firstChannel).serve(serving: service) }
        var iterator = entered.makeAsyncIterator(); _ = await iterator.next()
        let secondChannel = MockChannel(inbound: requestWire("POST", "/model/v1/messages", body: try encodeModelRequest()))
        try await LoopbackConnection(channel: secondChannel).serve(serving: service)
        XCTAssertTrue(String(decoding: secondChannel.sent, as: UTF8.self).hasPrefix("HTTP/1.1 503 "))
        let pending = await service.auditRecords()
        XCTAssertEqual(pending.map(\.decision), [.pending, .deniedByHandler])
        XCTAssertEqual(pending.last?.reason, "handlerCapacity")
        first.cancel()
        do { try await first.value; XCTFail("cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        let final = await service.auditRecords()
        XCTAssertEqual(final.map(\.decision), [.cancelled, .deniedByHandler])
        XCTAssertEqual(final.map(\.sequence), [1, 2])
        XCTAssertTrue(firstChannel.isClosed)
    }
    func testSSESendFailureFinalizesAuditAndNeverWritesASecondResponse() async throws {
        let wire = try modelStreamWire()
        for failureAt in [1, 2] {
            let upstream = OfflineUpstream { _ in wire }
            let service = try GatewayService(policy: Fixture.policy([Fixture.model()]), upstream: upstream.client)
            let channel = MockChannel(inbound: requestWire("POST", "/model/v1/messages", body: try encodeModelRequest()),
                                      failSendAt: failureAt)
            try await LoopbackConnection(channel: channel).serve(serving: service)
            let sent = String(decoding: channel.sent, as: UTF8.self)
            XCTAssertEqual(sent.components(separatedBy: "HTTP/1.1").count - 1, failureAt == 1 ? 0 : 1)
            XCTAssertFalse(sent.hasSuffix("0\r\n\r\n"))
            let records = await service.auditRecords()
            XCTAssertEqual(records.map(\.decision), [.failed])
            XCTAssertEqual(records.map(\.reason), ["streamFailed"])
            XCTAssertTrue(channel.isClosed)
        }
    }

    func testRunningStreamHoldsLastAuditSlotUntilCancellationFinalizesIt() async throws {
        let (entered, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (release, resume) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { signal.finish(); resume.finish() }
        let service = try GatewayService(policy: Fixture.policy([Fixture.model()], auditCapacity: 1),
            upstream: UpstreamClient(resolver: HeldResolver(entered: signal, release: release)))
        let channel = MockChannel(inbound: requestWire("POST", "/model/v1/messages", body: try encodeModelRequest()))
        let running = Task { try await LoopbackConnection(channel: channel).serve(serving: service) }
        var iterator = entered.makeAsyncIterator(); _ = await iterator.next()
        let rejected = try await service.dispatch(request("POST", "/model/v1/messages",
            headers: ["content-type": "application/json"], body: encodeModelRequest()))
        XCTAssertEqual(status(of: rejected), 503)
        let before = await service.auditRecords()
        XCTAssertEqual(before.map(\.decision), [.pending])
        let saturation = await service.auditSaturationCount()
        XCTAssertEqual(saturation, 1)
        running.cancel()
        do { try await running.value; XCTFail("cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        let after = await service.auditRecords()
        XCTAssertEqual(after.map(\.decision), [.cancelled])
        XCTAssertEqual(after.map(\.sequence), [1])
    }

    func testModelOutputLimitAfterFirstEventIsAuditedAndTruncatesTheStream() async throws {
        let wire = try modelStreamWire()
        let upstream = OfflineUpstream { _ in wire }
        let policy = try Fixture.policy([.model(ModelRule(allowedModels: ["fixture-model"],
                                                          budgetUnits: 100, maximumEvents: 1))])
        let service = try GatewayService(policy: policy, upstream: upstream.client)
        let channel = MockChannel(inbound: requestWire("POST", "/model/v1/messages", body: try encodeModelRequest()))
        try await LoopbackConnection(channel: channel).serve(serving: service)
        let sent = String(decoding: channel.sent, as: UTF8.self)
        XCTAssertTrue(sent.hasPrefix("HTTP/1.1 200 "))
        XCTAssertTrue(sent.contains("message_start"))
        XCTAssertFalse(sent.contains("content_block_start"))
        XCTAssertFalse(sent.hasSuffix("0\r\n\r\n"))
        let records = await service.auditRecords()
        XCTAssertEqual(records.map(\.decision), [.failed])
        XCTAssertEqual(records.map(\.reason), ["streamFailed"])
        XCTAssertTrue(channel.isClosed)
    }

}
