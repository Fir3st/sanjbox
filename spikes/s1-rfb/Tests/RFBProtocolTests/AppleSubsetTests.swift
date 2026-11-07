import XCTest
@testable import RFBProtocol

/// Synthetic transcripts for the Apple security/selection fixture framing.
///
/// These are **fixtures, not captures**: no byte here came from a macOS server, and the
/// selection layout is the package-local framing documented in `AppleSubset.swift`, not
/// Apple's wire format. The credential block is a mock placeholder — no DH, MD5 or AES
/// value is produced or checked anywhere in this package.
enum AppleFixtures {
    static let format: [UInt8] = [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
    static let banner = Array("RFB 003.889\n".utf8)

    static func u16(_ n: Int) -> [UInt8] { [UInt8(n >> 8), UInt8(n & 255)] }
    static func u32(_ n: UInt32) -> [UInt8] {
        [UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]
    }

    /// Stand-in for S4's "encrypted credential block + client public key".
    /// MOCK: constant bytes, deliberately not the output of any DH/AES computation.
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

    static func serverInit(width: Int = 2, height: Int = 2, name: [UInt8] = []) -> [UInt8] {
        u16(width) + u16(height) + format + u32(UInt32(name.count)) + name
    }

    /// SessionInfo: fixture kind 1, u16 count, then (command, availability) pairs.
    static func sessionInfo(_ offers: [(UInt8, UInt8)]) -> [UInt8] {
        [AppleFixtureFraming.sessionInfoKind] + u16(offers.count)
            + offers.flatMap { [$0.0, $0.1] }
    }

    static func sessionResult(_ outcome: UInt8) -> [UInt8] {
        [AppleFixtureFraming.sessionResultKind, outcome]
    }

    /// Everything up to (excluding) SessionInfo: banner, ARD offer, challenge, SecurityResult
    /// success, ClientInit 0xC1 and the standard ServerInit. A server grants no surface yet.
    static let prefixSelection = banner + [1, AppleFixtureFraming.ardSecurityType] + challenge()
        + u32(0) + serverInit()

    /// Full happy path: both commands offered, virtual desktop available, granted.
    static let grantedTranscript = prefixSelection
        + sessionInfo([(AppleFixtureFraming.consoleCommand, AppleFixtureFraming.availableState),
                       (AppleFixtureFraming.virtualDesktopCommand, AppleFixtureFraming.availableState)])
        + sessionResult(AppleFixtureFraming.outcomeGranted)

    static let grantedEvents: [RFBClient.Event] = [
        .send(banner),
        .send([AppleFixtureFraming.ardSecurityType]),
        .send(credential),
        .send([AppleFixtureFraming.appleClientInit]),
        .send([AppleFixtureFraming.sessionInfoChoiceKind,
               AppleFixtureFraming.virtualDesktopCommand]),
        .send([0, 0, 0, 0] + format),
        .send([2, 0, 0, 1, 0, 0, 0, 0]),
        .initialized(width: 2, height: 2),
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
        let provider = MockAppleCredentialProvider()
        var large = client(provider)
        _ = try large.receive(AppleFixtures.banner + [1, 30])
        XCTAssertEqual(try large.receive(AppleFixtures.challenge(keyLength: 512, generator: 3)),
                       [.send(AppleFixtures.credential)])
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

    // MARK: - Selection framing and the forbidden console fallback

    func testGrantedSelectionFullTranscriptAndFragmentation() throws {
        let bytes = AppleFixtures.grantedTranscript
        for split in 0...bytes.count {
            let provider = MockAppleCredentialProvider()
            var client = client(provider)
            var events = try client.receive(Array(bytes.prefix(split)))
            events += try client.receive(Array(bytes.dropFirst(split)))
            XCTAssertEqual(events, AppleFixtures.grantedEvents, "split \(split)")
            XCTAssertEqual(client.session, .granted, "split \(split)")
            XCTAssertEqual(client.phase, .ready, "split \(split)")
            XCTAssertNil(client.framebuffer, "split \(split)")
        }
        let provider = MockAppleCredentialProvider()
        var bytewise = client(provider)
        var events: [RFBClient.Event] = []
        for byte in bytes { events += try bytewise.receive([byte]) }
        XCTAssertEqual(events, AppleFixtures.grantedEvents)
        XCTAssertEqual(bytewise.session, .granted)
        XCTAssertNil(bytewise.framebuffer)
        try bytewise.finish()
        XCTAssertEqual(bytewise.phase, .closed)
        XCTAssertEqual(bytewise.session, .granted)
        XCTAssertThrowsError(try bytewise.requestFramebufferUpdate()) {
            XCTAssertEqual($0 as? RFBClient.Failure, .terminal)
        }
        // A granted session behaves like the standard ready state: explicit request only.
        var pixel = client(MockAppleCredentialProvider())
        _ = try pixel.receive(AppleFixtures.grantedTranscript)
        XCTAssertEqual(try pixel.requestFramebufferUpdate(), [3, 0, 0, 0, 0, 0, 0, 2, 0, 2])
        XCTAssertThrowsError(try pixel.requestFramebufferUpdate()) {
            XCTAssertEqual($0 as? RFBClient.Failure, .invalidState)
        }
        _ = try pixel.receive([0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 2, 0, 0, 0, 0]
            + Array(0..<16))
        XCTAssertEqual(pixel.framebuffer, Array(0..<16))
    }

    func testConsoleOnlyOfferIsNeverSelected() throws {
        var client = try preSelection()
        // Only the host console is offered. There is no API to ask for it, and no fallback.
        assertFailure(.consoleFallbackForbidden, client: &client, bytes: AppleFixtures.sessionInfo([
            (AppleFixtureFraming.consoleCommand, AppleFixtureFraming.availableState),
        ]))
        XCTAssertEqual(client.session, .consoleOnly)
    }

    func testSessionInfoClassificationIsIndependentOfCommandAndAvailability() throws {
        // Cartesian product of (command 1/2) × (available/unavailable). Neither the console
        // command nor an unavailable entry may be classified as "console offer"; only an
        // *available* console is a console-only offer, and an unavailable virtual desktop is
        // always `unavailable` — never the console.
        let console = AppleFixtureFraming.consoleCommand
        let virtual = AppleFixtureFraming.virtualDesktopCommand
        let up = AppleFixtureFraming.availableState
        let down = AppleFixtureFraming.unavailableState
        let consoleOnly: RFBClient.Failure? = .consoleFallbackForbidden
        let unavailable: RFBClient.Failure? = .sessionUnavailable
        let singles: [(String, (UInt8, UInt8), AppleSession, RFBClient.Failure?)] = [
            ("console/available", (console, up), .consoleOnly, consoleOnly),
            ("console/unavailable", (console, down), .unavailable, unavailable),
            ("virtual/available", (virtual, up), .virtualReady, nil),
            ("virtual/unavailable", (virtual, down), .unavailable, unavailable),
        ]
        for (label, offer, expectedSession, expectedFailure) in singles {
            var client = try preSelection()
            if let expectedFailure {
                assertFailure(expectedFailure, client: &client,
                              bytes: AppleFixtures.sessionInfo([offer]))
            } else {
                XCTAssertEqual(try client.receive(AppleFixtures.sessionInfo([offer])),
                               [.send([AppleFixtureFraming.sessionInfoChoiceKind, virtual])], label)
                XCTAssertNil(client.failure, label)
                XCTAssertEqual(client.phase, .session, label)
            }
            XCTAssertEqual(client.session, expectedSession, label)
        }
        // Both commands present, in both wire orders: `consoleOnly` must not appear unless the
        // console really is available and the virtual desktop really is absent.
        let pairs: [(String, [(UInt8, UInt8)], AppleSession, RFBClient.Failure?)] = [
            ("console up, virtual up", [(console, up), (virtual, up)], .virtualReady, nil),
            ("virtual up, console up", [(virtual, up), (console, up)], .virtualReady, nil),
            ("console down, virtual up", [(console, down), (virtual, up)], .virtualReady, nil),
            ("console up, virtual down", [(console, up), (virtual, down)], .unavailable, unavailable),
            ("virtual down, console up", [(virtual, down), (console, up)], .unavailable, unavailable),
            ("console down, virtual down", [(console, down), (virtual, down)], .unavailable,
             unavailable),
        ]
        for (label, offers, expectedSession, expectedFailure) in pairs {
            var client = try preSelection()
            if let expectedFailure {
                assertFailure(expectedFailure, client: &client,
                              bytes: AppleFixtures.sessionInfo(offers))
            } else {
                XCTAssertEqual(try client.receive(AppleFixtures.sessionInfo(offers)),
                               [.send([AppleFixtureFraming.sessionInfoChoiceKind, virtual])], label)
                XCTAssertNil(client.failure, label)
            }
            XCTAssertEqual(client.session, expectedSession, label)
        }
    }

    func testUnavailableVirtualDesktopIsTerminalNotConsole() throws {
        for offers: [(UInt8, UInt8)] in [
            [(AppleFixtureFraming.virtualDesktopCommand, AppleFixtureFraming.unavailableState)],
            [(AppleFixtureFraming.consoleCommand, AppleFixtureFraming.availableState),
             (AppleFixtureFraming.virtualDesktopCommand, AppleFixtureFraming.unavailableState)],
        ] {
            var client = try preSelection()
            assertFailure(.sessionUnavailable, client: &client,
                          bytes: AppleFixtures.sessionInfo(offers))
            XCTAssertEqual(client.session, .unavailable)
        }
        // An empty offer offers nothing at all.
        var empty = try preSelection()
        assertFailure(.invalidSelectionMessage, client: &empty,
                      bytes: [AppleFixtureFraming.sessionInfoKind, 0, 0])
    }

    func testSessionDeniedIsTerminal() throws {
        var client = try preSelection()
        let choice = AppleFixtures.sessionInfo([
            (AppleFixtureFraming.virtualDesktopCommand, AppleFixtureFraming.availableState)])
        XCTAssertEqual(try client.receive(choice),
                       [.send([AppleFixtureFraming.sessionInfoChoiceKind,
                               AppleFixtureFraming.virtualDesktopCommand])])
        XCTAssertEqual(client.phase, .session)
        assertFailure(.sessionDenied, client: &client,
                      bytes: AppleFixtures.sessionResult(AppleFixtureFraming.outcomeDenied))
        XCTAssertEqual(client.session, .denied)
    }

    func testPendingSelectionWaitsForResultAndDeadline() throws {
        let offers = AppleFixtures.sessionInfo([
            (AppleFixtureFraming.virtualDesktopCommand, AppleFixtureFraming.availableState)])
        var client = try preSelection()
        _ = try client.receive(offers + AppleFixtures.sessionResult(AppleFixtureFraming.outcomePending))
        XCTAssertEqual(client.phase, .sessionPending)
        XCTAssertEqual(client.session, .pending)
        // Pending is not ready: no pixel request and no unsolicited publication.
        XCTAssertThrowsError(try client.requestFramebufferUpdate()) {
            XCTAssertEqual($0 as? RFBClient.Failure, .invalidState)
        }
        XCTAssertNil(client.framebuffer)
        XCTAssertEqual(try client.receive([]), [])
        XCTAssertEqual(try client.receive(AppleFixtures.sessionResult(AppleFixtureFraming.outcomeGranted)),
                       [.send([0, 0, 0, 0] + AppleFixtures.format),
                        .send([2, 0, 0, 1, 0, 0, 0, 0]),
                        .initialized(width: 2, height: 2)])
        XCTAssertEqual(client.session, .granted)

        // A pending state whose result never arrives is a transport deadline, not a retry.
        var stalled = try preSelection()
        _ = try stalled.receive(offers + AppleFixtures.sessionResult(AppleFixtureFraming.outcomePending))
        stalled.expire()
        XCTAssertEqual(stalled.failure, .deadlineExceeded)
        XCTAssertEqual(stalled.phase, .failed)
        XCTAssertEqual(stalled.session, .pending)

        // Denial after pending is equally terminal.
        var denied = try preSelection()
        _ = try denied.receive(offers + AppleFixtures.sessionResult(AppleFixtureFraming.outcomePending))
        assertFailure(.sessionDenied, client: &denied,
                      bytes: AppleFixtures.sessionResult(AppleFixtureFraming.outcomeDenied))
        XCTAssertEqual(denied.session, .denied)

        // Anything other than a SessionResult while pending is a deterministic refusal.
        var unexpected = try preSelection()
        _ = try unexpected.receive(offers + AppleFixtures.sessionResult(AppleFixtureFraming.outcomePending))
        assertFailure(.invalidSelectionMessage, client: &unexpected, bytes: [0, 0])
    }

    func testPendingSessionResultConsumesTheServerMessageBudget() throws {
        // The pending branch must charge the shared server-message budget, otherwise a peer can
        // keep the parser in `sessionPending` forever without any other message being counted.
        let offers = AppleFixtures.sessionInfo([
            (AppleFixtureFraming.virtualDesktopCommand, AppleFixtureFraming.availableState)])
        let pending = AppleFixtures.sessionResult(AppleFixtureFraming.outcomePending)
        var client = try preSelection()
        _ = try client.receive(offers + pending)
        XCTAssertEqual(client.session, .pending)
        XCTAssertEqual(client.phase, .sessionPending)
        // One message is already charged; the remaining budget is served one message per call.
        for _ in 0..<(RFBClient.Limits.serverMessages - 1) {
            XCTAssertEqual(try client.receive(pending), [])
            XCTAssertEqual(client.phase, .sessionPending)
        }
        XCTAssertEqual(client.session, .pending)
        // The next SessionResult exceeds `messages < Limits.serverMessages` and is terminal.
        assertFailure(.resourceLimit, client: &client, bytes: pending)
        XCTAssertEqual(client.session, .pending)
        XCTAssertNil(client.framebuffer)
    }

    func testUnknownSelectionKindsCommandsAndStatesAreRejected() throws {
        let good = (AppleFixtureFraming.virtualDesktopCommand, AppleFixtureFraming.availableState)
        let badMessages: [(String, [UInt8])] = [
            ("SessionInfo kind 0", [0, 0, 1, good.0, good.1]),
            ("SessionInfo kind 2", [2, 0, 1, good.0, good.1]),
            ("SessionInfo kind 4", [4, 0, 1, good.0, good.1]),
            ("SessionResult as SessionInfo", [3, 0, 0]),
            ("count above limit", [AppleFixtureFraming.sessionInfoKind, 0,
                                   UInt8(RFBClient.Limits.appleSessionChoices + 1)]),
            ("unknown command", [AppleFixtureFraming.sessionInfoKind, 0, 1, 3, 1]),
            ("console command 0", [AppleFixtureFraming.sessionInfoKind, 0, 1, 0, 1]),
            ("availability 2", [AppleFixtureFraming.sessionInfoKind, 0, 1, good.0, 2]),
            ("duplicate virtual", [AppleFixtureFraming.sessionInfoKind, 0, 2,
                                   good.0, good.1, good.0, good.1]),
            ("duplicate console", [AppleFixtureFraming.sessionInfoKind, 0, 2,
                                   1, 1, 1, 1]),
        ]
        for (label, bytes) in badMessages {
            var client = try preSelection()
            assertFailure(.invalidSelectionMessage, client: &client, bytes: bytes)
            XCTAssertEqual(client.session, .notOffered, label)
        }
        // The SessionResult message itself is also strictly validated.
        var wrongKind = try preSelection()
        _ = try wrongKind.receive(AppleFixtures.sessionInfo([good]))
        assertFailure(.invalidSelectionMessage, client: &wrongKind,
                      bytes: [1, AppleFixtureFraming.outcomeGranted])
        var wrongOutcome = try preSelection()
        _ = try wrongOutcome.receive(AppleFixtures.sessionInfo([good]))
        assertFailure(.invalidSelectionMessage, client: &wrongOutcome,
                      bytes: AppleFixtures.sessionResult(3))
    }

    func testNoPixelFormatOrSurfaceBeforeGrantedSelection() throws {
        var client = try preSelection()
        XCTAssertEqual(client.phase, .session)
        // ServerInit alone grants nothing: no SetPixelFormat, no SetEncodings, no initialized.
        XCTAssertThrowsError(try client.requestFramebufferUpdate()) {
            XCTAssertEqual($0 as? RFBClient.Failure, .invalidState)
        }
        // A framebuffer update cannot be smuggled in where SessionInfo belongs.
        assertFailure(.invalidSelectionMessage, client: &client, bytes: [0, 0, 1, 1, 0, 0, 0, 0])
    }

    func testServerInitValidationIsUnchangedInTheApplePath() throws {
        func throughClientInit() -> [UInt8] {
            AppleFixtures.banner + [1, AppleFixtureFraming.ardSecurityType]
                + AppleFixtures.challenge() + AppleFixtures.u32(0)
        }
        var dimensions = RFBClient(authenticationPolicy: .syntheticAppleSubset,
                                   appleCredentialProvider: MockAppleCredentialProvider())
        _ = try dimensions.receive(throughClientInit())
        assertFailure(.invalidDimensions, client: &dimensions,
                      bytes: AppleFixtures.u16(0) + AppleFixtures.u16(2)
                          + AppleFixtures.format + AppleFixtures.u32(0))
        var formatClient = RFBClient(authenticationPolicy: .syntheticAppleSubset,
                                     appleCredentialProvider: MockAppleCredentialProvider())
        _ = try formatClient.receive(throughClientInit())
        var badFormat = AppleFixtures.serverInit()
        badFormat[4] ^= 1
        assertFailure(.unsupportedPixelFormat, client: &formatClient, bytes: badFormat)
    }

    // MARK: - Truncation, budgets and the deterministic corpus

    func testEOFAtEveryAppleBoundaryFailsClosed() throws {
        let transcript = AppleFixtures.grantedTranscript
        for count in 0..<transcript.count {
            var client = client()
            _ = try client.receive(Array(transcript.prefix(count)))
            XCTAssertThrowsError(try client.finish()) {
                XCTAssertEqual($0 as? RFBClient.Failure, .truncated, "prefix \(count)")
            }
            XCTAssertEqual(client.phase, .failed, "prefix \(count)")
            XCTAssertNil(client.framebuffer, "prefix \(count)")
        }
        // Clean EOF only after a granted, idle session.
        var complete = client()
        _ = try complete.receive(transcript)
        try complete.finish()
        XCTAssertEqual(complete.phase, .closed)
    }

    func testAppleChunkAndCredentialBudgets() throws {
        var oversized = client()
        assertFailure(.resourceLimit, client: &oversized,
                      bytes: Array(repeating: 0, count: RFBClient.Limits.chunkBytes + 1))
        // A provider cannot smuggle an unbounded response past the challenge stage.
        var bounded = client(MockAppleCredentialProvider(
            response: Array(repeating: 1, count: RFBClient.Limits.appleCredentialBytes)))
        _ = try bounded.receive(AppleFixtures.banner + [1, AppleFixtureFraming.ardSecurityType])
        XCTAssertEqual(try bounded.receive(AppleFixtures.challenge()).count, 1)
    }

    func testDeterministicAppleCorpusStaysBounded() throws {
        // 500 deterministic single-byte mutations of the granted transcript. A regression
        // corpus, not a fuzzing-coverage or security-audit claim.
        var seed: UInt64 = 0xa3_2026_1103_a3
        let baseline = AppleFixtures.grantedTranscript
        for _ in 0..<500 {
            seed = seed &* 6364136223846793005 &+ 1
            var mutated = baseline
            mutated[Int(seed % UInt64(mutated.count))] = UInt8(truncatingIfNeeded: seed >> 24)
            var client = client()
            var sent: [RFBClient.Event] = []
            do {
                for byte in mutated { sent += try client.receive([byte]) }
                try client.finish()
            } catch { XCTAssertTrue(error is RFBClient.Failure) }
            // Tightened oracle: a terminal state that agrees with `failure`, an empty buffer, and
            // no forbidden console choice. `closed` is only reachable through a granted
            // selection, so a clean close without `granted` is a defect, not a tolerated outcome.
            XCTAssertTrue(client.phase == .closed || client.phase == .failed)
            XCTAssertEqual(client.failure == nil, client.phase == .closed)
            XCTAssertEqual(client.session == .granted, client.phase == .closed)
            XCTAssertEqual(client.bufferedByteCount, 0)
            // No forbidden console choice is ever emitted, even for a mutation that leaves only
            // the console on offer.
            for event in sent {
                XCTAssertNotEqual(event, .send([AppleFixtureFraming.sessionInfoChoiceKind,
                                                AppleFixtureFraming.consoleCommand]))
            }
        }
    }
}
