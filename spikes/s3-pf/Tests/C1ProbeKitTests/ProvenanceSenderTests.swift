import Foundation
import XCTest
@testable import C1ProbeKit

final class ProvenanceSenderTests: XCTestCase {
    struct Failure: Error {}
    func testPartialTCPFailurePreservesAcceptedBytes() {
        var accepted = 0, calls = 0
        var progress: [Int] = []
        XCTAssertThrowsError(try ProvenanceSender.transfer(Data(repeating: 1, count: 10), datagram: false,
            accepted: &accepted, wait: {}, write: { _ in calls += 1; if calls == 2 { throw Failure() }; return 3 }, progress: { progress.append($0) }))
        XCTAssertEqual(accepted, 3); XCTAssertEqual(progress, [3])
    }
    func testProgressFailureCannotEraseKernelAcceptance() {
        var accepted = 0
        XCTAssertThrowsError(try ProvenanceSender.transfer(Data(repeating: 1, count: 10), datagram: false,
            accepted: &accepted, wait: {}, write: { _ in 4 }, progress: { _ in throw Failure() }))
        XCTAssertEqual(accepted, 4)
    }
    func testDatagramPartialIsIncompleteWithoutRetry() {
        var accepted = 0, calls = 0
        XCTAssertThrowsError(try ProvenanceSender.transfer(Data(repeating: 1, count: 10), datagram: true,
            accepted: &accepted, wait: {}, write: { _ in calls += 1; return 4 }, progress: { _ in }))
        XCTAssertEqual(accepted, 4); XCTAssertEqual(calls, 1)
    }
    func testRetriesRemainUnderAbsoluteWaitDeadline() {
        var accepted = 0, waits = 0
        XCTAssertThrowsError(try ProvenanceSender.transfer(Data([1]), datagram: false,
            accepted: &accepted, wait: { waits += 1; if waits == 3 { throw Failure() } }, write: { _ in 0 }, progress: { _ in }))
        XCTAssertEqual(accepted, 0); XCTAssertEqual(waits, 3)
    }
    func testSplitWritesCoverExactFrame() throws {
        let bytes = Data([1,2,3,4,5]); var accepted = 0; var written = Data()
        try ProvenanceSender.transfer(bytes, datagram: false, accepted: &accepted, wait: {}, write: { remainder in
            let chunk = remainder.prefix(2); written.append(chunk); return chunk.count
        }, progress: { _ in })
        XCTAssertEqual(written, bytes); XCTAssertEqual(accepted, bytes.count)
    }
}
