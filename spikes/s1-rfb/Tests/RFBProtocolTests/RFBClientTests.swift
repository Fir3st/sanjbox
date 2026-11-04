import XCTest
@testable import RFBProtocol

final class RFBClientTests: XCTestCase {
    private let format: [UInt8] = [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
    private let banner = Array("RFB 003.008\n".utf8)
    private func u16(_ n: Int) -> [UInt8] { [UInt8(n >> 8), UInt8(n & 255)] }
    private func u32(_ n: UInt32) -> [UInt8] {
        [UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]
    }
    private func serverInit(width: Int = 2, height: Int = 2, name: [UInt8] = []) -> [UInt8] {
        u16(width) + u16(height) + format + u32(UInt32(name.count)) + name
    }
    private func handshake(width: Int = 2, height: Int = 2) -> [UInt8] {
        banner + [1, 1, 0, 0, 0, 0] + serverInit(width: width, height: height)
    }
    private func ready(width: Int = 2, height: Int = 2) throws -> RFBClient {
        var client = RFBClient(authenticationPolicy: .syntheticNoneOnly)
        _ = try client.receive(handshake(width: width, height: height))
        return client
    }
    private func rect(x: Int = 0, y: Int = 0, width: Int = 2, height: Int = 2,
                      encoding: UInt32 = 0, pixels: [UInt8] = Array(0..<16)) -> [UInt8] {
        u16(x) + u16(y) + u16(width) + u16(height) + u32(encoding) + pixels
    }
    private func update(_ rectangles: [[UInt8]], padding: UInt8 = 0) -> [UInt8] {
        [0, padding] + u16(rectangles.count) + rectangles.flatMap { $0 }
    }
    private func assertFailure(_ expected: RFBClient.Failure, client: inout RFBClient,
                               bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try client.receive(bytes), file: file, line: line) {
            XCTAssertEqual($0 as? RFBClient.Failure, expected, file: file, line: line)
        }
        XCTAssertEqual(client.phase, .failed, file: file, line: line)
        XCTAssertEqual(client.failure, expected, file: file, line: line)
        XCTAssertEqual(client.bufferedByteCount, 0, file: file, line: line)
        XCTAssertNil(client.framebuffer, file: file, line: line)
        XCTAssertThrowsError(try client.receive(banner), file: file, line: line) {
            XCTAssertEqual($0 as? RFBClient.Failure, .terminal, file: file, line: line)
        }
    }

    func testOnlyExact38BannerIsAccepted() throws {
        for value in ["RFB 003.003\n", "RFB 003.007\n", "RFB 003.889\n", "RFB 003.009\n",
                      "RFB 004.008\n", "RFB 003.008\r", "RFB abc.def\n", "BAD 003.008\n"] {
            var client = RFBClient()
            assertFailure(.unsupportedVersion, client: &client, bytes: Array(value.utf8))
        }
        var client = RFBClient()
        XCTAssertEqual(try client.receive(banner), [.send(banner)])
        XCTAssertEqual(client.phase, .security)
    }

    func testDefaultStopsBeforeAuthenticationSelection() throws {
        var client = RFBClient()
        _ = try client.receive(banner)
        assertFailure(.authenticationNotImplemented, client: &client, bytes: [1, 1])
    }

    func testFixtureCannotDowngradeMixedOrUnsupportedAuthentication() throws {
        for offer: [UInt8] in [[1, 30], [30, 1], [2], [30], [33], [19], [0], [1, 1], [255]] {
            var client = RFBClient(authenticationPolicy: .syntheticNoneOnly)
            _ = try client.receive(banner)
            assertFailure(.unexpectedSecurityOffer, client: &client,
                          bytes: [UInt8(offer.count)] + offer)
        }
    }

    func testHandshakeOutputAndFragmentationAtEveryBoundary() throws {
        let bytes = handshake()
        let expected: [RFBClient.Event] = [
            .send(banner), .send([1]), .send([1]),
            .send([0, 0, 0, 0] + format), .send([2, 0, 0, 1, 0, 0, 0, 0]),
            .initialized(width: 2, height: 2),
        ]
        for split in 0...bytes.count {
            var client = RFBClient(authenticationPolicy: .syntheticNoneOnly)
            var events = try client.receive(Array(bytes.prefix(split)))
            events += try client.receive(Array(bytes.dropFirst(split)))
            XCTAssertEqual(events, expected, "split \(split)")
            XCTAssertEqual(client.phase, .ready)
            XCTAssertNil(client.framebuffer)
        }
        var client = RFBClient(authenticationPolicy: .syntheticNoneOnly)
        var events: [RFBClient.Event] = []
        for byte in bytes { events += try client.receive([byte]) }
        XCTAssertEqual(events, expected)
    }

    func test38RequiresSecurityResultBeforeClientInit() throws {
        var client = RFBClient(authenticationPolicy: .syntheticNoneOnly)
        _ = try client.receive(banner + [1, 1])
        XCTAssertEqual(try client.receive([0, 0, 0]), [])
        XCTAssertEqual(client.phase, .securityResult)
        XCTAssertEqual(try client.receive([0]), [.send([1])])
        XCTAssertEqual(client.phase, .serverInit)
    }

    func testRejectionReasonsAreBoundedAndNeverExposed() throws {
        for prefix in [banner + [0], banner + [1, 1, 0, 0, 0, 1]] {
            let payload: [UInt8] = [0x1b, 0x5b, 0x32, 0x4a, 0xff]
            var client = RFBClient(authenticationPolicy: .syntheticNoneOnly)
            _ = try client.receive(prefix)
            _ = try client.receive(u32(UInt32(payload.count)) + Array(payload.dropLast()))
            assertFailure(.serverRejected, client: &client, bytes: [payload.last!])
            var oversized = RFBClient(authenticationPolicy: .syntheticNoneOnly)
            _ = try oversized.receive(prefix)
            assertFailure(.oversizedText, client: &oversized, bytes: u32(UInt32.max))
        }
        var client = RFBClient(authenticationPolicy: .syntheticNoneOnly)
        _ = try client.receive(banner + [0])
        assertFailure(.serverRejected, client: &client, bytes: [0, 0, 0, 0])
    }

    func testUnknownSecurityStatusIsTerminal() throws {
        for status: UInt32 in [2, 3, UInt32.max] {
            var client = RFBClient(authenticationPolicy: .syntheticNoneOnly)
            _ = try client.receive(banner + [1, 1])
            assertFailure(.invalidSecurityResult, client: &client, bytes: u32(status))
        }
    }

    func testInitDimensionsFormatAndNameLimitsBeforeAllocation() throws {
        for (width, height) in [(0, 2), (2, 0), (1025, 1), (65535, 65535)] {
            var client = RFBClient(authenticationPolicy: .syntheticNoneOnly)
            _ = try client.receive(banner + [1, 1, 0, 0, 0, 0])
            assertFailure(.invalidDimensions, client: &client, bytes: serverInit(width: width, height: height))
        }
        for index in 4..<17 {
            var initBytes = serverInit()
            initBytes[index] ^= 1
            var client = RFBClient(authenticationPolicy: .syntheticNoneOnly)
            _ = try client.receive(banner + [1, 1, 0, 0, 0, 0])
            assertFailure(.unsupportedPixelFormat, client: &client, bytes: initBytes)
        }
        var oversized = RFBClient(authenticationPolicy: .syntheticNoneOnly)
        _ = try oversized.receive(banner + [1, 1, 0, 0, 0, 0])
        assertFailure(.oversizedText, client: &oversized, bytes: [0, 2, 0, 2] + format + u32(UInt32.max))
        var client = RFBClient(authenticationPolicy: .syntheticNoneOnly)
        // Name is opaque (including invalid UTF-8/terminal controls), bounded, then discarded.
        var initBytes = serverInit(name: Array(repeating: 0xff, count: 4096))
        initBytes[17] = 99; initBytes[18] = 88; initBytes[19] = 77
        _ = try client.receive(banner + [1, 1, 0, 0, 0, 0] + initBytes)
        XCTAssertEqual(client.phase, .ready)
    }

    func testRawUpdateFragmentationAndExplicitRequests() throws {
        let bytes = update([rect()], padding: 255)
        for split in 0...bytes.count {
            var client = try ready()
            XCTAssertEqual(try client.requestFramebufferUpdate(), [3, 0, 0, 0, 0, 0, 0, 2, 0, 2])
            var events = try client.receive(Array(bytes.prefix(split)))
            if split > 0 && split < bytes.count { XCTAssertNil(client.framebuffer) }
            events += try client.receive(Array(bytes.dropFirst(split)))
            XCTAssertEqual(events, [.framebufferUpdated])
            XCTAssertEqual(client.framebuffer, Array(0..<16))
            XCTAssertEqual(client.bufferedByteCount, 0)
        }
        var client = try ready()
        _ = try client.requestFramebufferUpdate()
        for byte in bytes { _ = try client.receive([byte]) }
        XCTAssertEqual(client.framebuffer, Array(0..<16))
    }

    func testRectanglesCompositeRowsAndOverlapsInWireOrder() throws {
        var client = try ready(width: 3, height: 2)
        _ = try client.requestFramebufferUpdate()
        _ = try client.receive(update([
            rect(width: 3, height: 2, pixels: Array(repeating: 7, count: 24)),
            rect(x: 1, width: 1, height: 2, pixels: [1, 2, 3, 0, 4, 5, 6, 0]),
            rect(x: 1, y: 1, width: 2, height: 1, pixels: Array(repeating: 8, count: 8)),
        ]))
        XCTAssertEqual(client.framebuffer, [7,7,7,7, 1,2,3,0, 7,7,7,7, 7,7,7,7, 8,8,8,8, 8,8,8,8])
        XCTAssertEqual(try client.requestFramebufferUpdate(incremental: true), [3, 1, 0, 0, 0, 0, 0, 3, 0, 2])
        _ = try client.receive(update([rect(width: 1, height: 1, pixels: [9,9,9,0])]))
        XCTAssertEqual(client.framebuffer?.prefix(8), [9,9,9,0, 1,2,3,0])
    }

    func testInvalidRectanglesAndUnsupportedEncodingsFailClosed() throws {
        for rectangle in [rect(x: 2, width: 1), rect(y: 2, height: 1), rect(width: 3),
                          rect(height: 3), rect(width: 0), rect(height: 0), rect(x: 65535)] {
            var client = try ready()
            _ = try client.requestFramebufferUpdate()
            assertFailure(.invalidRectangle, client: &client, bytes: update([rectangle]))
        }
        for encoding: UInt32 in [1, 5, 16, UInt32.max, 0xffffff21] {
            var client = try ready()
            _ = try client.requestFramebufferUpdate()
            assertFailure(.unsupportedEncoding, client: &client, bytes: update([rect(encoding: encoding)]))
        }
    }

    func testPartialUpdateIsHiddenAndFailureErasesPixels() throws {
        var client = try ready()
        _ = try client.requestFramebufferUpdate()
        _ = try client.receive(update([rect()]))
        _ = try client.requestFramebufferUpdate(incremental: true)
        let prefix = [UInt8(0), 0, 0, 2] + rect(width: 1, height: 1, pixels: [99,99,99,0])
        XCTAssertEqual(try client.receive(prefix), [])
        XCTAssertNil(client.framebuffer)
        assertFailure(.invalidRectangle, client: &client, bytes: rect(x: 3, width: 1))
    }

    func testClipboardAndUnknownServerMessagesHaveNoHostEffects() throws {
        var client = try ready()
        XCTAssertEqual(try client.receive([2, 2, 2]), [])
        assertFailure(.clipboardDisabled, client: &client, bytes: [3])
        for type: UInt8 in [1, 4, 127, 255] {
            var other = try ready()
            assertFailure(.unsupportedMessage, client: &other, bytes: [type])
        }
    }

    func testOneOutstandingRequestAndNoUnsolicitedFrame() throws {
        var initial = RFBClient()
        XCTAssertThrowsError(try initial.requestFramebufferUpdate())
        XCTAssertEqual(initial.phase, .version)
        var client = try ready()
        XCTAssertThrowsError(try client.requestFramebufferUpdate(incremental: true))
        _ = try client.requestFramebufferUpdate()
        XCTAssertThrowsError(try client.requestFramebufferUpdate())
        XCTAssertEqual(client.phase, .ready)
        _ = try client.receive(update([]))
        XCTAssertEqual(client.framebuffer, Array(repeating: 0, count: 16))
        assertFailure(.unsolicitedUpdate, client: &client, bytes: update([]))
    }

    func testEOFAtEveryIncompleteHandshakeAndUpdateBoundary() throws {
        let handshakeBytes = handshake()
        for count in 0..<handshakeBytes.count {
            var client = RFBClient(authenticationPolicy: .syntheticNoneOnly)
            _ = try client.receive(Array(handshakeBytes.prefix(count)))
            XCTAssertThrowsError(try client.finish()) {
                XCTAssertEqual($0 as? RFBClient.Failure, .truncated, "handshake prefix \(count)")
            }
            XCTAssertEqual(client.phase, .failed)
        }
        let updateBytes = update([rect()])
        for count in 0..<updateBytes.count {
            var client = try ready()
            _ = try client.requestFramebufferUpdate()
            _ = try client.receive(Array(updateBytes.prefix(count)))
            XCTAssertThrowsError(try client.finish()) {
                XCTAssertEqual($0 as? RFBClient.Failure, .truncated, "update prefix \(count)")
            }
            XCTAssertNil(client.framebuffer)
        }
        var client = try ready()
        try client.finish()
        XCTAssertEqual(client.phase, .closed)
        XCTAssertThrowsError(try client.receive([]))
    }

    func testCancellationAndDeadlineAreTerminal() throws {
        var client = try ready()
        client.expire()
        XCTAssertEqual(client.failure, .deadlineExceeded)
        XCTAssertThrowsError(try client.requestFramebufferUpdate())
        client.cancel()
        XCTAssertEqual(client.phase, .failed)
        var other = try ready()
        other.cancel()
        other.expire()
        XCTAssertEqual(other.phase, .closed)
        XCTAssertNil(other.failure)
    }

    func testChunkRectangleMessageAndRequestBudgets() throws {
        var oversized = RFBClient()
        assertFailure(.resourceLimit, client: &oversized,
                      bytes: Array(repeating: 0, count: RFBClient.Limits.chunkBytes + 1))
        var rectangles = try ready()
        _ = try rectangles.requestFramebufferUpdate()
        assertFailure(.resourceLimit, client: &rectangles, bytes: [0, 0, 1, 1])
        var messages = try ready()
        _ = try messages.receive(Array(repeating: 2, count: RFBClient.Limits.serverMessages))
        assertFailure(.resourceLimit, client: &messages, bytes: [2])
        var requests = try ready()
        for _ in 0..<RFBClient.Limits.updateRequests {
            _ = try requests.requestFramebufferUpdate()
            _ = try requests.receive(update([]))
        }
        XCTAssertThrowsError(try requests.requestFramebufferUpdate()) {
            XCTAssertEqual($0 as? RFBClient.Failure, .resourceLimit)
        }
        XCTAssertEqual(requests.phase, .failed)
    }

    func testMaximumFrameAndCumulativeRectangleBudget() throws {
        var client = try ready(width: 1024, height: 1024)
        _ = try client.requestFramebufferUpdate()
        // Header only: a second rectangle would exceed the update's cumulative pixel budget.
        let header: [UInt8] = [0, 0, 0, 2] + rect(width: 1024, height: 1024, pixels: [])
        _ = try client.receive(header)
        let pixels = Array(repeating: UInt8(37), count: RFBClient.Limits.chunkBytes)
        for _ in 0..<64 { _ = try client.receive(pixels) }
        XCTAssertNil(client.framebuffer)
        assertFailure(.resourceLimit, client: &client,
                      bytes: rect(width: 1, height: 1, pixels: []))
        var maximum = try ready(width: 1024, height: 1024)
        _ = try maximum.requestFramebufferUpdate()
        _ = try maximum.receive([0, 0, 0, 1] + rect(width: 1024, height: 1024, pixels: []))
        for _ in 0..<64 { _ = try maximum.receive(pixels) }
        XCTAssertEqual(maximum.framebuffer?.count, RFBClient.Limits.framebufferBytes)
        XCTAssertEqual(maximum.framebuffer?.first, 37)
        XCTAssertEqual(maximum.framebuffer?.last, 37)
    }

    func testDeterministicMalformedCorpusDoesNotEscapeBounds() throws {
        // 1,000 deterministic mutations; a regression corpus, not a fuzzing-coverage claim.
        var seed: UInt64 = 0xa3_2026_1103
        let baseline = handshake()
        for _ in 0..<1000 {
            seed = seed &* 6364136223846793005 &+ 1
            var mutated = baseline
            let index = Int(seed % UInt64(mutated.count))
            mutated[index] = UInt8(truncatingIfNeeded: seed >> 24)
            var client = RFBClient(authenticationPolicy: .syntheticNoneOnly)
            do {
                for byte in mutated { _ = try client.receive([byte]) }
                try client.finish()
            } catch { XCTAssertTrue(error is RFBClient.Failure) }
            XCTAssertLessThanOrEqual(client.bufferedByteCount, RFBClient.Limits.bufferedBytes)
            XCTAssertTrue(client.phase == .closed || client.phase == .failed)
        }
    }

    func testCoalescedMessagesAndMultiRectangleFragmentation() throws {
        let bytes: [UInt8] = [2] + update([
            rect(width: 1, height: 2, pixels: [1,2,3,0, 4,5,6,0]),
            rect(x: 1, width: 1, height: 2, pixels: [7,8,9,0, 10,11,12,0]),
        ]) + [2]
        for split in 0...bytes.count {
            var client = try ready()
            _ = try client.requestFramebufferUpdate()
            var events = try client.receive(Array(bytes.prefix(split)))
            events += try client.receive(Array(bytes.dropFirst(split)))
            XCTAssertEqual(events, [.framebufferUpdated])
            XCTAssertEqual(client.framebuffer, [1,2,3,0, 7,8,9,0, 4,5,6,0, 10,11,12,0])
        }
        var client = try ready()
        _ = try client.requestFramebufferUpdate()
        // A late violation in the same call invalidates the entire returned batch.
        assertFailure(.clipboardDisabled, client: &client, bytes: update([rect()]) + [3])
    }

    func testTotalWireBudgetIncludesHeadersAndNeverResetsPerFrame() throws {
        var client = try ready(width: 1024, height: 1024)
        let pixels = Array(repeating: UInt8(0), count: RFBClient.Limits.chunkBytes)
        for _ in 0..<7 {
            _ = try client.requestFramebufferUpdate()
            _ = try client.receive([0, 0, 0, 1] + rect(width: 1024, height: 1024, pixels: []))
            for _ in 0..<64 { _ = try client.receive(pixels) }
        }
        _ = try client.requestFramebufferUpdate()
        _ = try client.receive([0, 0, 0, 1] + rect(width: 1024, height: 1024, pixels: []))
        for _ in 0..<63 { _ = try client.receive(pixels) }
        assertFailure(.resourceLimit, client: &client, bytes: pixels)
    }
}
