import XCTest
@testable import RFBProtocol

/// Local authorization and parser lifecycle only. Every credential byte and record is synthetic;
/// a grant deliberately terminates at missing identity evidence, never produces an Apple surface.
final class AppleSelectionLifecycleTests: XCTestCase {
    private let start = ContinuousClock.now
    private let command: [UInt8] = [0, 72, 0, 1, 0, 0, 0, 0, 2, 0, 115, 121, 110]
        + Array(repeating: 0, count: 61)

    private func client() -> RFBClient {
        RFBClient(authenticationPolicy: .syntheticAppleSubset,
                  appleCredentialProvider: MockAppleCredentialProvider(),
                  appleSelectionPolicy: .syntheticVirtualOnly)
    }

    private func preSelection() throws -> RFBClient {
        var c = client()
        XCTAssertEqual(try c.receive(AppleFixtures.prefixSelection, at: start), AppleFixtures.prefixEvents)
        return c
    }

    private func waiting() throws -> RFBClient {
        var c = try preSelection()
        XCTAssertEqual(try c.receive(AppleFixtures.sessionInfo(mask: 4), at: start), [.send(command)])
        XCTAssertEqual(c.session, .requestedVirtual)
        return c
    }

    private func assertFailure(_ expected: RFBClient.Failure, _ bytes: [UInt8],
                               client: inout RFBClient, at now: ContinuousClock.Instant? = nil,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try client.receive(bytes, at: now ?? start), file: file, line: line) {
            XCTAssertEqual($0 as? RFBClient.Failure, expected, file: file, line: line)
        }
        XCTAssertEqual(client.phase, .failed, file: file, line: line)
        XCTAssertEqual(client.failure, expected, file: file, line: line)
        XCTAssertEqual(client.bufferedByteCount, 0, file: file, line: line)
        XCTAssertNil(client.framebuffer, file: file, line: line)
        XCTAssertThrowsError(try client.requestFramebufferUpdate(), file: file, line: line)
        XCTAssertThrowsError(try client.receive([], at: start), file: file, line: line) {
            XCTAssertEqual($0 as? RFBClient.Failure, .terminal, file: file, line: line)
        }
    }

    func testExplicitLocalPolicyRequiresVirtualBitAndRejectsUnknownBits() throws {
        let masks: [UInt32] = Array(0...15) + [.max, 0x80000004]
            + (0..<32).map { UInt32(1) << $0 }
        for mask in masks {
            var c = try preSelection()
            if [UInt32(4), 5, 6, 7].contains(mask) {
                XCTAssertEqual(try c.receive(AppleFixtures.sessionInfo(mask: mask), at: start), [.send(command)])
                XCTAssertEqual(c.session, .requestedVirtual)
                XCTAssertEqual(c.phase, .session)
                XCTAssertNil(c.framebuffer)
            } else {
                assertFailure(.sessionUnavailable, AppleFixtures.sessionInfo(mask: mask), client: &c)
                XCTAssertEqual(c.session, .unavailable)
            }
        }
        // Every unknown bit must be refused even when the virtual bit is also present.
        for bit in 3..<32 {
            var c = try preSelection()
            assertFailure(.sessionUnavailable,
                          AppleFixtures.sessionInfo(mask: (UInt32(1) << bit) | 4), client: &c)
        }
    }

    func testConsoleUsernameNeverChangesLocalAuthorizationOrCommand() throws {
        for username: [UInt8] in [[], [0], [0, 65], Array("syn".utf8), [0xE9, 0xFF]] {
            for mask: UInt32 in [0, 1, 2, 3, 4, 5, 6, 7, .max] {
                var c = try preSelection()
                let info = AppleFixtures.sessionInfo(mask: mask, username: username)
                if [UInt32(4), 5, 6, 7].contains(mask) {
                    let events = try c.receive(info, at: start)
                    XCTAssertEqual(events.count, 1)
                    guard case .send(let bytes) = events[0] else { return XCTFail("No command") }
                    XCTAssertEqual(bytes.count, 74)
                    XCTAssertEqual(Array(bytes.prefix(10)), [0, 72, 0, 1, 0, 0, 0, 0, 2, 0])
                } else {
                    assertFailure(.sessionUnavailable, info, client: &c)
                }
            }
        }
    }

    func testIntegratedCommandAndPendingAtEverySplitAndBytewise() throws {
        let transcript = AppleFixtures.prefixSelection + AppleFixtures.sessionInfo(mask: 4)
            + AppleFixtures.sessionResult(2) + AppleFixtures.sessionResult(3, reserved: [255])
        for split in 0...transcript.count {
            var c = client()
            var events = try c.receive(Array(transcript.prefix(split)), at: start)
            events += try c.receive(Array(transcript.dropFirst(split)), at: start)
            XCTAssertEqual(events, AppleFixtures.prefixEvents + [.send(command)])
            XCTAssertEqual(c.session, .pendingVirtual)
            XCTAssertEqual(c.phase, .session)
            XCTAssertEqual(c.bufferedByteCount, 0)
            XCTAssertNil(c.framebuffer)
            XCTAssertThrowsError(try c.requestFramebufferUpdate()) {
                XCTAssertEqual($0 as? RFBClient.Failure, .invalidState)
            }
        }
        var c = client()
        var events: [RFBClient.Event] = []
        for byte in transcript { events += try c.receive([byte], at: start) }
        XCTAssertEqual(events, AppleFixtures.prefixEvents + [.send(command)])
        XCTAssertEqual(c.session, .pendingVirtual)
    }

    func testGrantedStatusesStopAtIdentityBoundaryAfterEitherPendingStatus() throws {
        for pending in [[], [UInt32(2)], [3], [2, 3, 2]] {
            for status: UInt32 in [0, 4] {
                for reservedCount in [0, 1, 74, 4090] {
                    var c = try waiting()
                    for value in pending {
                        XCTAssertEqual(try c.receive(AppleFixtures.sessionResult(value), at: start), [])
                        XCTAssertEqual(c.session, .pendingVirtual)
                    }
                    assertFailure(.unverifiedSessionIdentity,
                                  AppleFixtures.sessionResult(status, reserved: Array(repeating: 255, count: reservedCount)),
                                  client: &c)
                    XCTAssertEqual(c.session, .grantedUnverified)
                }
            }
        }
    }

    func testDenialAndUnknownStatusesNeverRetryOrChooseConsole() throws {
        for status in [UInt32(1), 5, 6, 255, 0x12345678, .max] {
            for pending in [false, true] {
                var c = try waiting()
                if pending { XCTAssertEqual(try c.receive(AppleFixtures.sessionResult(2), at: start), []) }
                assertFailure(.sessionDenied, AppleFixtures.sessionResult(status), client: &c)
                XCTAssertEqual(c.session, .denied)
            }
        }
    }

    func testCoalescedGrantAndPixelsNeverEscapeEvenAcrossEveryTranscriptSplit() throws {
        for mask: UInt32 in [0, 2, 4, 6, .max] {
            for status: UInt32 in [0, 4] {
                let transcript = AppleFixtures.prefixSelection + AppleFixtures.sessionInfo(mask: mask)
                    + AppleFixtures.sessionResult(2) + AppleFixtures.sessionResult(status)
                    // Apparent empty update and Bell after the grant must be erased.
                    + [0, 0, 0, 0, 2]
                for split in 0...transcript.count {
                    var c = client()
                    var events: [RFBClient.Event] = []
                    XCTAssertThrowsError(try {
                        events += try c.receive(Array(transcript.prefix(split)), at: start)
                        events += try c.receive(Array(transcript.dropFirst(split)), at: start)
                    }()) {
                        XCTAssertEqual($0 as? RFBClient.Failure,
                                       [4, 6].contains(mask) ? .unverifiedSessionIdentity : .sessionUnavailable)
                    }
                    XCTAssertTrue(events.allSatisfy { (AppleFixtures.prefixEvents + [.send(command)]).contains($0) })
                    XCTAssertLessThanOrEqual(events.filter { $0 == .send(command) }.count, 1)
                    XCTAssertEqual(c.phase, .failed)
                    XCTAssertEqual(c.bufferedByteCount, 0)
                    XCTAssertNil(c.framebuffer)
                }
            }
        }
    }

    func testResultLengthVersionAndDuplicateInfoAreTerminal() throws {
        for length in Array(0..<6) + [4097, 65535] {
            var c = try waiting()
            assertFailure(.invalidSelectionMessage, AppleFixtures.u16(length), client: &c)
        }
        for version in [0, 2, 255, 256, 65535] {
            var c = try waiting()
            assertFailure(.invalidSelectionMessage, AppleFixtures.sessionResult(0, version: version), client: &c)
        }
        var c = try waiting()
        // S5 records have no kind discriminator: a duplicate Info with mask 4 can look
        // exactly like a grant. The independent identity boundary must still prevent pixels.
        assertFailure(.unverifiedSessionIdentity, AppleFixtures.sessionInfo(mask: 4), client: &c)
    }

    func testEOFAtEveryIncompleteInfoPendingAndGrantBoundary() throws {
        let transcript = AppleFixtures.prefixSelection + AppleFixtures.sessionInfo(mask: 4)
            + AppleFixtures.sessionResult(2) + AppleFixtures.sessionResult(0)
        for length in 0..<transcript.count {
            var c = client()
            _ = try c.receive(Array(transcript.prefix(length)), at: start)
            XCTAssertThrowsError(try c.finish()) {
                XCTAssertEqual($0 as? RFBClient.Failure, .truncated, "prefix \(length)")
            }
            XCTAssertEqual(c.phase, .failed)
            XCTAssertEqual(c.bufferedByteCount, 0)
            XCTAssertNil(c.framebuffer)
        }
    }

    func testDeadlineIsTotalMonotonicAndNotExtendedByPendingOrFragments() throws {
        XCTAssertEqual(RFBClient.Limits.appleSelectionWait, .seconds(30))
        for pendingStatus: UInt32 in [2, 3] {
            var c = try waiting()
            XCTAssertEqual(try c.receive(AppleFixtures.sessionResult(pendingStatus),
                                         at: start.advanced(by: .seconds(29))), [])
            let grant = AppleFixtures.sessionResult(0)
            XCTAssertEqual(try c.receive(Array(grant.prefix(3)),
                                         at: start.advanced(by: .milliseconds(29_999))), [])
            assertFailure(.deadlineExceeded, Array(grant.dropFirst(3)), client: &c,
                          at: start.advanced(by: .seconds(30)))
            XCTAssertEqual(c.session, .pendingVirtual)
        }
        var before = try waiting()
        assertFailure(.unverifiedSessionIdentity, AppleFixtures.sessionResult(0), client: &before,
                      at: start.advanced(by: .milliseconds(29_999)))
        for delay in [30, 31, 1000] {
            var silent = try waiting()
            assertFailure(.deadlineExceeded, [], client: &silent,
                          at: start.advanced(by: .seconds(delay)))
        }
        var backwards = try waiting()
        XCTAssertEqual(try backwards.receive([], at: start.advanced(by: .seconds(1))), [])
        assertFailure(.invalidClock, [], client: &backwards, at: start)
    }

    func testDeadlineCancelAndExpiryAtEveryPartialResultBoundary() throws {
        let result = AppleFixtures.sessionResult(2)
        for count in 0...result.count {
            var c = try waiting()
            _ = try c.receive(Array(result.prefix(count)), at: start)
            c.expire()
            XCTAssertEqual(c.failure, .deadlineExceeded)
            XCTAssertEqual(c.bufferedByteCount, 0)
            XCTAssertNil(c.framebuffer)
            XCTAssertThrowsError(try c.receive(AppleFixtures.sessionResult(0), at: start))
            c = try waiting()
            _ = try c.receive(Array(result.prefix(count)), at: start)
            c.cancel()
            XCTAssertEqual(c.phase, .closed)
            XCTAssertEqual(c.bufferedByteCount, 0)
            XCTAssertNil(c.framebuffer)
            XCTAssertThrowsError(try c.receive(AppleFixtures.sessionResult(0), at: start))
        }
    }

    func testSessionInfoAndAllResultsShareOneMessageBudget() throws {
        let pending = AppleFixtures.sessionResult(2, reserved: [])
        // One Info + 1022 pending + one final = exactly 1024 server messages.
        var boundary = try waiting()
        for index in 0..<(RFBClient.Limits.serverMessages - 2) {
            // Fragment one half of the records so counting bytes/feeds would fail this test.
            if index % 2 == 0 {
                for byte in pending { XCTAssertEqual(try boundary.receive([byte], at: start), []) }
            } else {
                XCTAssertEqual(try boundary.receive(pending, at: start), [])
            }
        }
        assertFailure(.unverifiedSessionIdentity, AppleFixtures.sessionResult(4), client: &boundary)

        var exhausted = try waiting()
        let flood = Array(repeating: pending, count: RFBClient.Limits.serverMessages - 1).flatMap { $0 }
        XCTAssertEqual(try exhausted.receive(flood, at: start), [])
        // No budget remains for even a result header; check before waiting for its body.
        assertFailure(.resourceLimit, [0, 6], client: &exhausted)
        XCTAssertEqual(exhausted.session, .pendingVirtual)
    }

    func testUnavailableMetadataCannotBeOverriddenByOptInOrBufferedGrant() throws {
        for flags: UInt32 in [0, 1, 2, 3, 8, 12, 15] {
            var c = client()
            _ = try c.receive(AppleFixtures.throughClientInit, at: start)
            assertFailure(.sessionUnavailable,
                          AppleFixtures.serverInit(name: AppleFixtures.metadata(flags: flags))
                            + AppleFixtures.sessionInfo(mask: 4) + AppleFixtures.sessionResult(0), client: &c)
            XCTAssertEqual(c.session, .unavailable)
        }
        var absentProvider = RFBClient(authenticationPolicy: .syntheticAppleSubset,
                                      appleSelectionPolicy: .syntheticVirtualOnly)
        assertFailure(.authenticationNotImplemented,
                      AppleFixtures.prefixSelection + AppleFixtures.sessionInfo(mask: 4), client: &absentProvider)
        XCTAssertEqual(absentProvider.session, .notOffered)
    }
}
