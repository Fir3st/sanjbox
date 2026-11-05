import Darwin
import Foundation
import XCTest
@testable import BoundaryKit

final class XPCFixtureTests: XCTestCase {
    let run = "6FD11621-FAD4-4E67-A170-51B66D311E71"
    var peer: XPCPeerCredentials { .init(effectiveUID: 501, effectiveGID: 20, auditSessionID: 100001) }
    var policy: XPCOperationPolicy { .init(peer: peer, runID: run) }
    func testPolicyRejectsEveryCredentialMismatchAndUnknown() {
        XCTAssertTrue(policy.accepts(peer))
        for wrong in [XPCPeerCredentials(effectiveUID: 502, effectiveGID: 20, auditSessionID: 100001),
                      .init(effectiveUID: 501, effectiveGID: 21, auditSessionID: 100001),
                      .init(effectiveUID: 501, effectiveGID: 20, auditSessionID: 100002),
                      .init(effectiveUID: 0, effectiveGID: 20, auditSessionID: 0)] {
            XCTAssertFalse(policy.accepts(wrong))
        }
        XCTAssertFalse(XPCOperationPolicy(peer: .init(effectiveUID: 501, effectiveGID: 20, auditSessionID: 0), runID: run)
            .accepts(.init(effectiveUID: 501, effectiveGID: 20, auditSessionID: 0)))
    }
    func testFixedOperationRejectsCrossRunClaimsUnknownAndOversize() {
        XCTAssertTrue(policy.permits(Data("read-canary:\(run)".utf8)))
        for text in ["", "read-canary:\(UUID().uuidString)", "write-canary:\(run)",
                     "read-canary:\(run);uid=501;asid=100001", "{\"uid\":501,\"runID\":\"\(run)\"}",
                     String(repeating: "a", count: 4097)] {
            XCTAssertFalse(policy.permits(Data(text.utf8)))
        }
    }
    func testCodeHashRequirementIsExactAndCannotInjectSyntax() throws {
        let hash = String(repeating: "a", count: 40)
        XCTAssertEqual(try XPCFixtureExpectation.requirement(hash), "cdhash H\"\(hash)\"")
        for text in ["", String(repeating: "A", count: 40), hash + " or true", String(repeating: "a", count: 39)] {
            XCTAssertThrowsError(try XPCFixtureExpectation.requirement(text))
        }
        XCTAssertNoThrow(try XPCFixtureExpectation(runID: run, clientCodeHash: hash, serviceCodeHash: hash).validate())
        XCTAssertThrowsError(try XPCFixtureExpectation(runID: run.lowercased(), clientCodeHash: hash, serviceCodeHash: hash).validate())
    }
    func testCancellationIsTerminalAndLateReplyDoesNotRevive() {
        let latch = XPCReplyLatch(); latch.cancel()
        XCTAssertFalse(latch.finish(.success(Data("canary".utf8))))
        XCTAssertThrowsError(try latch.result()) { XCTAssertEqual(String(describing: $0), "owned XPC request cancelled") }
    }
    func testDeadlineIsTerminalAndLateReplyDoesNotRevive() {
        let latch = XPCReplyLatch(deadline: .now())
        XCTAssertThrowsError(try latch.result()) {
            XCTAssertEqual(String(describing: $0), "owned XPC reply deadline exceeded")
        }
        XCTAssertFalse(latch.finish(.success(Data("canary".utf8))))
    }
    func testQueuedSuccessCannotEscapeAbsoluteDeadline() {
        final class Clock: @unchecked Sendable {
            let lock = NSLock(); var late = false
            func read() -> UInt64 { lock.lock(); defer { lock.unlock() }; return late ? UInt64.max : 0 }
            func advance() { lock.lock(); late = true; lock.unlock() }
        }
        let clock = Clock(), latch = XPCReplyLatch(now: { clock.read() })
        XCTAssertTrue(latch.finish(.success(Data("queued".utf8))))
        clock.advance()
        XCTAssertThrowsError(try latch.result()) { XCTAssertEqual(String(describing: $0), "owned XPC reply deadline exceeded") }
        XCTAssertFalse(latch.finish(.success(Data("late".utf8))))
    }
    func testFirstReplyWinsAndDuplicateCannotReplaceIt() throws {
        let latch = XPCReplyLatch()
        XCTAssertTrue(latch.finish(.success(Data("first".utf8))))
        XCTAssertFalse(latch.finish(.success(Data("second".utf8))))
        XCTAssertEqual(try latch.result(), Data("first".utf8))
    }
}
