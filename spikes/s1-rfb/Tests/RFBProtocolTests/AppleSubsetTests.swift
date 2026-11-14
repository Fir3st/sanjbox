import XCTest
@testable import RFBProtocol

/// Synthetic bytes, never captures. S4 auth remains mocked; S5 records use the pinned
/// client layout. No allowed-command mask here is asserted to mean "virtual permitted".
enum AppleFixtures {
    static let format: [UInt8] = [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
    static let banner = Array("RFB 003.889\n".utf8)
    static func u16(_ n: Int) -> [UInt8] { [UInt8(n >> 8), UInt8(n & 255)] }
    static func u32(_ n: UInt32) -> [UInt8] {
        [UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]
    }
    static let credential: [UInt8] = Array(repeating: 0xA5, count: 128)
        + Array(repeating: 0x5A, count: 8)
    static func challenge(keyLength: Int = 8, generator: Int = 2) -> [UInt8] {
        let modulus = (0..<keyLength).map { UInt8(truncatingIfNeeded: 0x80 + $0) }
        let serverKey = (0..<keyLength).map { UInt8(truncatingIfNeeded: 0x40 + $0) }
        return u16(generator) + u16(keyLength) + modulus + serverKey
    }
    static func challengeHeader(keyLength: Int = 8, generator: Int = 2) -> [UInt8] {
        u16(generator) + u16(keyLength)
    }
    static func metadata(flags: UInt32 = 4, secondMarker: UInt8 = 0) -> [UInt8] {
        [0, secondMarker] + u32(flags) + Array(0..<16) + [0] + Array("SYNTHETIC".utf8)
    }
    static func serverInit(width: Int = 2, height: Int = 2,
                           name: [UInt8] = metadata()) -> [UInt8] {
        u16(width) + u16(height) + format + u32(UInt32(name.count)) + name
    }
    static func sessionInfo(mask: UInt32 = 0x12345678, username: [UInt8] = [115, 121, 110, 0],
                            version: Int = 1) -> [UInt8] {
        let body = u16(version) + u32(mask) + [0xA1, 0xB2, 0xC3, 0xD4] + username
        return u16(body.count) + body
    }
    static func sessionResult(_ status: UInt32, reserved: [UInt8] = Array(repeating: 0, count: 74),
                              version: Int = 1) -> [UInt8] {
        let body = u16(version) + u32(status) + reserved
        return u16(body.count) + body
    }
    static let throughClientInit = banner + [1, 30] + challenge() + u32(0)
    static let prefixSelection = throughClientInit + serverInit()
    static let prefixEvents: [RFBClient.Event] = [
        .send(banner), .send([30]), .send(credential), .send([0xC1]),
    ]
}

/// MOCK credential provider: records the challenge and returns constant bytes.
/// It performs no key agreement, hashing or encryption and holds no credential material.
final class MockAppleCredentialProvider: AppleCredentialProvider, @unchecked Sendable {
    private(set) var challenges: [AppleDHChallenge] = []
    private let response: [UInt8]
    private let failure: RFBClient.Failure?

    init(response: [UInt8] = AppleFixtures.credential, failure: RFBClient.Failure? = nil) {
        self.response = response
        self.failure = failure
    }

    func credentialResponse(for challenge: AppleDHChallenge) throws -> [UInt8] {
        challenges.append(challenge)
        if let failure { throw failure }
        return response
    }
}

final class AppleSubsetTests: XCTestCase {
    private func client(_ provider: MockAppleCredentialProvider? = MockAppleCredentialProvider())
        -> RFBClient {
        RFBClient(authenticationPolicy: .syntheticAppleSubset, appleCredentialProvider: provider)
    }

    /// Consumed the challenge and the ServerInit; the next server message is SessionInfo.
    private func preSelection() throws -> RFBClient {
        var client = client()
        _ = try client.receive(AppleFixtures.prefixSelection)
        return client
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
        XCTAssertThrowsError(try client.receive(AppleFixtures.banner), file: file, line: line) {
            XCTAssertEqual($0 as? RFBClient.Failure, .terminal, file: file, line: line)
        }
    }

    // MARK: - Version and security offers (S1, S5, S4)

    func testAppleBannerIsPolicyScoped() throws {
        var apple = client()
        XCTAssertEqual(try apple.receive(AppleFixtures.banner), [.send(AppleFixtures.banner)])
        XCTAssertEqual(apple.phase, .security)
        // The standard banner is not a fallback inside the Apple fixture policy.
        for policy in [RFBClient.AuthenticationPolicy.syntheticAppleSubset,
                       .syntheticNoneOnly, .rejectAll] {
            let wrong = policy == .syntheticAppleSubset
                ? Array("RFB 003.008\n".utf8) : AppleFixtures.banner
            var rejected = RFBClient(authenticationPolicy: policy,
                                     appleCredentialProvider: MockAppleCredentialProvider())
            assertFailure(.unsupportedVersion, client: &rejected, bytes: wrong)
        }
    }

    func testSecurityOfferMustBeExactlyArd30() throws {
        for offer: [UInt8] in [[30, 1], [1, 30], [33], [30, 30], [1], [19], [2], [255]] {
            var client = client()
            _ = try client.receive(AppleFixtures.banner)
            assertFailure(.unexpectedSecurityOffer, client: &client,
                          bytes: [UInt8(offer.count)] + offer)
        }
        var empty = client()
        _ = try empty.receive(AppleFixtures.banner)
        // Zero offers moves to the rejection-reason path, never to a default auth type.
        XCTAssertThrowsError(try empty.receive([0, 0, 0, 0, 0])) {
            XCTAssertEqual($0 as? RFBClient.Failure, .serverRejected)
        }
        XCTAssertEqual(empty.failure, .serverRejected)

        // Exactly one ARD offer is the only accepted case, and the client answers with 30.
        var accepted = client()
        XCTAssertEqual(try accepted.receive(AppleFixtures.banner + [1, 30]),
                       [.send(AppleFixtures.banner), .send([30])])
        XCTAssertEqual(accepted.phase, .appleChallenge)
    }

    // MARK: - S4 challenge bounds and the fail-closed crypto seam

    func testChallengeBoundsRejectBeforePayload() throws {
        for (generator, keyLength) in [(0, 8), (1, 8), (2, 0), (2, 1_000), (2, 65_535)] {
            var client = client()
            _ = try client.receive(AppleFixtures.banner + [1, 30])
            assertFailure(.invalidAppleChallenge, client: &client,
                          bytes: AppleFixtures.challengeHeader(keyLength: keyLength,
                                                              generator: generator))
        }
        // The largest permitted key length is still framing-accepted and reaches the seam.
        let response = Array(repeating: UInt8(0xA5), count: 128 + 512)
        let provider = MockAppleCredentialProvider(response: response)
        var large = client(provider)
        _ = try large.receive(AppleFixtures.banner + [1, 30])
        XCTAssertEqual(try large.receive(AppleFixtures.challenge(keyLength: 512, generator: 3)),
                       [.send(response)])
        XCTAssertEqual(provider.challenges.first?.modulus.count, 512)
        XCTAssertEqual(provider.challenges.first?.serverPublicKey.count, 512)
    }

    func testHandshakeStopsWithoutCredentialProvider() throws {
        // The seam is empty on purpose: no DH/AES implementation exists in this package.
        var client = RFBClient(authenticationPolicy: .syntheticAppleSubset)
        let events = try client.receive(AppleFixtures.banner + [1, AppleFixtureFraming.ardSecurityType])
        XCTAssertEqual(events, [.send(AppleFixtures.banner),
                                .send([AppleFixtureFraming.ardSecurityType])])
        XCTAssertThrowsError(try client.receive(AppleFixtures.challenge())) {
            XCTAssertEqual($0 as? RFBClient.Failure, .authenticationNotImplemented)
        }
        XCTAssertEqual(client.phase, .failed)
        XCTAssertEqual(client.session, .notOffered)
        XCTAssertNil(client.framebuffer)
        XCTAssertEqual(client.bufferedByteCount, 0)
        // The two events above are the whole output: no credential bytes, no ClientInit
        // 0xC1 and no session choice can have been produced.
        XCTAssertThrowsError(try client.receive([0, 0, 0, 0])) {
            XCTAssertEqual($0 as? RFBClient.Failure, .terminal)
        }
    }

    func testMockProviderSeesExactChallengeAndBytesAreSentVerbatim() throws {
        let provider = MockAppleCredentialProvider()
        var client = client(provider)
        let prefix = AppleFixtures.banner + [1, AppleFixtureFraming.ardSecurityType]
            + AppleFixtures.challenge(keyLength: 8, generator: 2)
        let events = try client.receive(prefix)
        XCTAssertEqual(events.last, .send(AppleFixtures.credential))
        XCTAssertEqual(provider.challenges,
                       [AppleDHChallenge(generator: 2,
                                         modulus: (0..<8).map { UInt8(truncatingIfNeeded: 0x80 + $0) },
                                         serverPublicKey: (0..<8).map { UInt8(truncatingIfNeeded: 0x40 + $0) })])
        XCTAssertEqual(client.phase, .securityResult)
    }

    func testProviderFailuresAreFailClosed() throws {
        for (response, failure, expected) in [
            ([UInt8](), nil, RFBClient.Failure.authenticationNotImplemented),
            ([UInt8](repeating: 0, count: RFBClient.Limits.appleCredentialBytes + 1), nil,
             RFBClient.Failure.resourceLimit),
            (AppleFixtures.credential, RFBClient.Failure.resourceLimit,
             RFBClient.Failure.authenticationNotImplemented),
        ] as [([UInt8], RFBClient.Failure?, RFBClient.Failure)] {
            let provider = MockAppleCredentialProvider(response: response, failure: failure)
            var client = client(provider)
            _ = try client.receive(AppleFixtures.banner + [1, AppleFixtureFraming.ardSecurityType])
            assertFailure(expected, client: &client, bytes: AppleFixtures.challenge())
            XCTAssertEqual(client.session, .notOffered)
        }
    }

    func testProviderResponseMustMatchTheChallengeRecordLength() throws {
        // A nonempty blob is not enough: the seam promises a 128-byte block followed by
        // a public key of the negotiated width. No cryptographic validity is asserted.
        for keyLength in [1, 8, 512] {
            let expectedLength = 128 + keyLength
            for length in [1, 127, 128, expectedLength - 1, expectedLength + 1, 4096] {
                let provider = MockAppleCredentialProvider(response: Array(repeating: 0xA5, count: length))
                var client = client(provider)
                _ = try client.receive(AppleFixtures.banner + [1, 30])
                XCTAssertThrowsError(try client.receive(AppleFixtures.challenge(keyLength: keyLength))) {
                    XCTAssertEqual($0 as? RFBClient.Failure, .invalidAppleCredentialResponse)
                }
                XCTAssertEqual(client.phase, .failed, "key \(keyLength), response \(length)")
                XCTAssertEqual(client.session, .notOffered)
                XCTAssertEqual(client.bufferedByteCount, 0)
                XCTAssertNil(client.framebuffer)
                XCTAssertThrowsError(try client.receive(AppleFixtures.u32(0)))
            }
            let response = Array(repeating: UInt8(0xA5), count: expectedLength)
            var valid = client(MockAppleCredentialProvider(response: response))
            _ = try valid.receive(AppleFixtures.banner + [1, 30])
            XCTAssertEqual(try valid.receive(AppleFixtures.challenge(keyLength: keyLength)), [.send(response)])
            XCTAssertEqual(valid.phase, .securityResult)
        }
    }

    // MARK: - Exact S5 codecs, without unproven mask interpretation

    func testGoldenSessionInfoAndVirtualCommandBytes() throws {
        // Independent literal: body 14, version 1, opaque mask/reserved, "syn\0".
        let literal: [UInt8] = [0, 14, 0, 1, 0x12, 0x34, 0x56, 0x78,
                                0xA1, 0xB2, 0xC3, 0xD4, 115, 121, 110, 0]
        XCTAssertEqual(AppleFixtures.sessionInfo(), literal)
        let info = try AppleSessionRecordCodec.info(literal)
        XCTAssertEqual(info.allowedCommands, 0x12345678)
        XCTAssertEqual(info.consoleUserBytes, [115, 121, 110])
        let command = AppleSessionRecordCodec.virtualCommand(for: info)
        XCTAssertEqual(command, [0, 72, 0, 1, 0, 0, 0, 0, 2, 0, 115, 121, 110]
                       + Array(repeating: 0, count: 61))
        XCTAssertEqual(command.count, 74)
        // This encoder has no argument permitting a console command (0 or 1).
        XCTAssertEqual(command[8], 2)
    }

    func testUsernameConversionMatchesPinnedClientIncludingByteTruncation() throws {
        for (input, expected): ([UInt8], [UInt8]) in [
            ([], []), ([0, 65], []), ([65, 0, 66], [65]), ([65, 66], [65, 66]),
            ([0xE9, 0xFF, 0], [0xC3, 0xA9, 0xC3, 0xBF]),
            (Array(repeating: 65, count: 64), Array(repeating: 65, count: 63)),
            (Array(repeating: 65, count: 62) + [0xE9], Array(repeating: 65, count: 62) + [0xC3]),
        ] {
            let info = try AppleSessionRecordCodec.info(AppleFixtures.sessionInfo(username: input))
            let command = AppleSessionRecordCodec.virtualCommand(for: info)
            XCTAssertEqual(Array(command[10..<74]), expected + Array(repeating: 0, count: 64 - expected.count))
            XCTAssertEqual(command.count, 74)
            XCTAssertEqual(command[73], 0)
        }
    }

    func testExtendedMetadataLayoutAndOpaqueBitmap() throws {
        for marker: UInt8 in [0, 1, 255] {
            let parsed = try AppleSessionRecordCodec.serverMetadata(
                AppleFixtures.metadata(flags: 7, secondMarker: marker))
            XCTAssertEqual(parsed.flags, 7)
            XCTAssertEqual(parsed.capabilityBitmap, Array(0..<16))
        }
        let minimum: [UInt8] = [0, 255, 0, 0, 0, 4] + Array(repeating: 255, count: 16)
        XCTAssertEqual(try AppleSessionRecordCodec.serverMetadata(minimum).flags, 4)
        XCTAssertEqual(try AppleSessionRecordCodec.serverMetadata(
            minimum + Array(repeating: 65, count: 4074)).flags, 4)
        XCTAssertThrowsError(try AppleSessionRecordCodec.serverMetadata(
            minimum + Array(repeating: 65, count: 4075)))
        for size in 0..<22 {
            XCTAssertThrowsError(try AppleSessionRecordCodec.serverMetadata(Array(minimum.prefix(size))))
        }
        var wrong = minimum; wrong[0] = 1
        XCTAssertThrowsError(try AppleSessionRecordCodec.serverMetadata(wrong))
        for flag: UInt32 in [16, 0x100, 0x10000, 0x80000000, .max] {
            XCTAssertThrowsError(try AppleSessionRecordCodec.serverMetadata(AppleFixtures.metadata(flags: flag)))
        }
    }

    func testResultStatusesAndVariableReservedLength() throws {
        for status in Array(UInt32(0)...255) + [0x12345678, UInt32.max] {
            for count in [0, 1, 74, 4090] {
                let bytes = AppleFixtures.sessionResult(status, reserved: Array(repeating: 0xFE, count: count))
                let result = try AppleSessionRecordCodec.result(bytes)
                XCTAssertEqual(result.status, status)
                let expected: AppleSessionRecordCodec.Outcome = [0, 4].contains(status) ? .granted
                    : [2, 3].contains(status) ? .pending : .denied
                XCTAssertEqual(result.outcome, expected)
            }
        }
        // Minimal literal, independent of the fixture generator: body=6/version=1/status=4.
        XCTAssertEqual(try AppleSessionRecordCodec.result([0, 6, 0, 1, 0, 0, 0, 4]).outcome, .granted)
    }

    func testRecordLengthsVersionsTruncationAndTrailingBytesAreStrict() throws {
        let cases: [(Int, [UInt8], ([UInt8]) throws -> Void)] = [
            (10, AppleFixtures.sessionInfo(), { _ = try AppleSessionRecordCodec.info($0) }),
            (6, AppleFixtures.sessionResult(0), { _ = try AppleSessionRecordCodec.result($0) }),
        ]
        for (minimum, good, parse) in cases {
            for count in 0..<good.count { XCTAssertThrowsError(try parse(Array(good.prefix(count)))) }
            XCTAssertThrowsError(try parse(good + [0]))
            for size in Array(0..<minimum) + [4097, 65535] {
                XCTAssertThrowsError(try parse(AppleFixtures.u16(size) + Array(good.dropFirst(2))))
            }
            for version in [0, 2, 255, 256, 65535] {
                var wrong = good; wrong.replaceSubrange(2..<4, with: AppleFixtures.u16(version))
                XCTAssertThrowsError(try parse(wrong))
            }
        }
        let maximum = AppleFixtures.sessionInfo(username: Array(repeating: 65, count: 4086))
        XCTAssertEqual(maximum.count, 4098)
        XCTAssertEqual(try AppleSessionRecordCodec.info(maximum).consoleUserBytes.count, 4086)
        XCTAssertEqual(AppleSessionRecordCodec.virtualCommand(for: try AppleSessionRecordCodec.info(maximum)).count, 74)
        XCTAssertThrowsError(try AppleSessionRecordCodec.info(
            AppleFixtures.sessionInfo(username: Array(repeating: 65, count: 4087))))
        XCTAssertThrowsError(try AppleSessionRecordCodec.result(
            AppleFixtures.sessionResult(0, reserved: Array(repeating: 0, count: 4091))))
    }

    // MARK: - Integrated source-backed input, conservative policy refusal

    func testNoAllowedMaskCanAuthorizeSelectionWithoutEvidence() throws {
        for mask in [UInt32(0), 3, 6, 7, .max] + (0..<32).map({ UInt32(1) << $0 }) {
            var client = try preSelection()
            assertFailure(.unverifiedSelectionPolicy, client: &client,
                          bytes: AppleFixtures.sessionInfo(mask: mask))
            XCTAssertEqual(client.session, .unverified)
            XCTAssertThrowsError(try client.requestFramebufferUpdate())
        }
    }

    func testS5InputAtEverySplitAndBytewiseStopsBeforeChoice() throws {
        let prefix = AppleFixtures.prefixSelection
        for split in 0...prefix.count {
            var client = client()
            var events = try client.receive(Array(prefix.prefix(split)))
            events += try client.receive(Array(prefix.dropFirst(split)))
            XCTAssertEqual(events, AppleFixtures.prefixEvents)
            XCTAssertEqual(client.phase, .session)
            XCTAssertEqual(client.session, .notOffered)
        }
        let info = AppleFixtures.sessionInfo()
        for split in 0..<info.count {
            var client = try preSelection()
            XCTAssertEqual(try client.receive(Array(info.prefix(split))), [])
            XCTAssertNil(client.framebuffer)
            assertFailure(.unverifiedSelectionPolicy, client: &client, bytes: Array(info.dropFirst(split)))
        }
        var bytewise = client()
        var events: [RFBClient.Event] = []
        for byte in prefix + info.dropLast() { events += try bytewise.receive([byte]) }
        XCTAssertEqual(events, AppleFixtures.prefixEvents)
        assertFailure(.unverifiedSelectionPolicy, client: &bytewise, bytes: [info.last!])
        XCTAssertEqual(bytewise.session, .unverified)
    }

    func testInvalidInfoLengthIsRejectedBeforeBodyAndBadVersionsNeverChoose() throws {
        for length in Array(0..<10) + [4097, 65535] {
            var client = try preSelection()
            assertFailure(.invalidSelectionMessage, client: &client, bytes: AppleFixtures.u16(length))
            XCTAssertEqual(client.session, .notOffered)
        }
        for version in [0, 2, 65535] {
            var client = try preSelection()
            assertFailure(.invalidSelectionMessage, client: &client,
                          bytes: AppleFixtures.sessionInfo(version: version))
        }
        var maximum = try preSelection()
        assertFailure(.unverifiedSelectionPolicy, client: &maximum,
                      bytes: AppleFixtures.sessionInfo(username: Array(repeating: 65, count: 4086)))
    }

    func testMissingOrForbiddenSelectionCapabilityNeverInitializes() throws {
        for flags: UInt32 in [0, 1, 2, 3, 8, 12, 15] {
            var client = client()
            _ = try client.receive(AppleFixtures.throughClientInit)
            assertFailure(.sessionUnavailable, client: &client,
                          bytes: AppleFixtures.serverInit(name: AppleFixtures.metadata(flags: flags)))
            XCTAssertEqual(client.session, .unavailable)
        }
        for name: [UInt8] in [[], Array("SYNTHETIC".utf8), Array(repeating: 0, count: 21),
                             AppleFixtures.metadata(flags: 0x10)] {
            var client = client()
            _ = try client.receive(AppleFixtures.throughClientInit)
            assertFailure(.invalidSelectionMessage, client: &client,
                          bytes: AppleFixtures.serverInit(name: name))
        }
    }

    func testNoSurfaceBeforeOrAfterUnverifiedPolicyAndNoResultSmuggling() throws {
        var client = client()
        XCTAssertEqual(try client.receive(AppleFixtures.prefixSelection), AppleFixtures.prefixEvents)
        XCTAssertThrowsError(try client.requestFramebufferUpdate()) {
            XCTAssertEqual($0 as? RFBClient.Failure, .invalidState)
        }
        // Even an apparent grant concatenated to the unverified offer cannot initialize.
        assertFailure(.unverifiedSelectionPolicy, client: &client,
                      bytes: AppleFixtures.sessionInfo() + AppleFixtures.sessionResult(0) + [2])
        XCTAssertNil(client.framebuffer)
        // Old package-local kind/count records cannot grant anything through the new parser.
        var old = try preSelection()
        _ = try old.receive([1, 0, 1, 2, 1, 3, 0])
        XCTAssertThrowsError(try old.finish())
        XCTAssertNil(old.framebuffer)
    }

    func testEOFCancelAndDeadlineAtEveryIncompleteS5Boundary() throws {
        let transcript = AppleFixtures.prefixSelection + AppleFixtures.sessionInfo()
        for count in 0..<transcript.count {
            var client = client()
            _ = try client.receive(Array(transcript.prefix(count)))
            XCTAssertThrowsError(try client.finish()) {
                XCTAssertEqual($0 as? RFBClient.Failure, .truncated, "prefix \(count)")
            }
            XCTAssertEqual(client.phase, .failed)
            XCTAssertNil(client.framebuffer)
            XCTAssertEqual(client.bufferedByteCount, 0)
        }
        var timeout = try preSelection()
        _ = try timeout.receive([0, 14, 0, 1])
        timeout.expire()
        XCTAssertEqual(timeout.failure, .deadlineExceeded)
        XCTAssertEqual(timeout.bufferedByteCount, 0)
        var cancelled = try preSelection()
        cancelled.cancel()
        XCTAssertEqual(cancelled.phase, .closed)
        XCTAssertThrowsError(try cancelled.receive(AppleFixtures.sessionInfo()))
    }

    func testServerInitDimensionAndPixelChecksRemainStrict() throws {
        var dimensions = client()
        _ = try dimensions.receive(AppleFixtures.throughClientInit)
        assertFailure(.invalidDimensions, client: &dimensions, bytes: AppleFixtures.serverInit(width: 0))
        var format = client()
        _ = try format.receive(AppleFixtures.throughClientInit)
        var wrong = AppleFixtures.serverInit(); wrong[4] ^= 1
        assertFailure(.unsupportedPixelFormat, client: &format, bytes: wrong)
    }

    func testAppleChunkBudgetAndDeterministicCorpusNeverGrant() throws {
        var oversized = client()
        assertFailure(.resourceLimit, client: &oversized,
                      bytes: Array(repeating: 0, count: RFBClient.Limits.chunkBytes + 1))
        var seed: UInt64 = 0xa3_2026_1114_a3
        let baseline = AppleFixtures.prefixSelection + AppleFixtures.sessionInfo()
        for _ in 0..<1000 {
            seed = seed &* 6364136223846793005 &+ 1
            var mutated = baseline
            mutated[Int(seed % UInt64(mutated.count))] = UInt8(truncatingIfNeeded: seed >> 24)
            var client = client()
            var sent: [RFBClient.Event] = []
            do {
                for byte in mutated { sent += try client.receive([byte]) }
                try client.finish()
                XCTFail("No Apple transcript may reach a clean, granted state")
            } catch { XCTAssertTrue(error is RFBClient.Failure) }
            XCTAssertEqual(client.phase, .failed)
            XCTAssertNotNil(client.failure)
            XCTAssertEqual(client.bufferedByteCount, 0)
            XCTAssertNil(client.framebuffer)
            for event in sent { XCTAssertTrue(AppleFixtures.prefixEvents.contains(event)) }
        }
    }
}
