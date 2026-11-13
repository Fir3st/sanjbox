/// An offline, bounded RFB 3.8 protocol experiment, not an Apple session client.
/// There is deliberately no transport, credential implementation, input, or clipboard API.
/// The Apple security/selection subset is a synthetic fixture framing; see AppleSubset.swift.
public struct RFBClient: Sendable {
    public enum AuthenticationPolicy: Sendable {
        /// Default: stop at the authentication boundary without selecting a type.
        case rejectAll
        /// ONLY for owned synthetic fixtures offering exactly one type: None (1).
        /// This is not a policy for a live server, even on localhost.
        case syntheticNoneOnly
        /// ONLY for owned synthetic fixtures offering exactly one type: ARD (30), per S4.
        /// Accepts the candidate Apple banner and the fixture selection framing; contains no
        /// cryptography and is not a policy for a live server.
        case syntheticAppleSubset
    }

    public enum Phase: String, Sendable {
        case version, security, securityResult, serverInit, ready, update, failed, closed
        /// S4 type-30 DH challenge is being consumed.
        case appleChallenge
        /// Fixture SessionInfo / choice / SessionResult exchange.
        case session
        /// S5 pending state: waiting for a later SessionResult, never polling or retrying.
        case sessionPending
    }

    public enum Failure: String, Error, Equatable, Sendable {
        case unsupportedVersion, authenticationNotImplemented, unexpectedSecurityOffer
        case serverRejected, invalidSecurityResult, oversizedText, unsupportedPixelFormat
        case invalidDimensions, invalidRectangle, unsupportedEncoding, unsupportedMessage
        case clipboardDisabled, unsolicitedUpdate, resourceLimit, truncated, deadlineExceeded
        case terminal, invalidState
        /// S4 challenge framing is out of range (generator, key length, payload).
        case invalidAppleChallenge
        /// The provider did not return a 128-byte credential block plus a key of the negotiated width.
        case invalidAppleCredentialResponse
        /// The virtual desktop was absent or offered as unavailable: no fallback exists.
        case sessionUnavailable
        /// SessionResult denied the virtual desktop choice: terminal, never the console.
        case sessionDenied
        /// Only the host console was offered. Selecting it automatically is forbidden (S5).
        case consoleFallbackForbidden
        /// Unknown message kind/command/state, duplicate offer or bad selection length.
        case invalidSelectionMessage
    }

    public enum Event: Equatable, Sendable {
        /// Protocol output only. A caller must not attach a live transport to this prototype.
        case send([UInt8])
        /// Peer-controlled name bytes are deliberately not exposed.
        case initialized(width: Int, height: Int)
        /// All rectangles of one update were checked and applied. This does not prove
        /// coverage of every requested pixel, surface identity, or presentation.
        case framebufferUpdated
    }

    /// Fixed research budgets, not tunable by a peer or command-line input.
    public enum Limits {
        public static let chunkBytes = 65_536
        public static let dimension = 1_024
        public static let framebufferBytes = 4 * 1_024 * 1_024
        public static let textBytes = 4_096
        public static let rectanglesPerUpdate = 256
        public static let updatePixelBytes = framebufferBytes
        public static let sessionWireBytes = 32 * 1_024 * 1_024
        public static let serverMessages = 1_024
        public static let updateRequests = 64
        public static let bufferedBytes = framebufferBytes + chunkBytes
        // Package-local research budgets, not upstream maximums from S4/S5. The sources
        // describe record lengths, but do not prescribe these limits for this parser.
        public static let appleKeyBytes = 512
        public static let appleCredentialBytes = 4_096
        public static let appleSessionChoices = 8
    }

    private enum State: Sendable {
        case version, securityCount, securityTypes(Int), securityResult
        case appleChallengeHeader, appleModulus(keyLength: Int, generator: Int)
        case appleServerKey(keyLength: Int, generator: Int, modulus: [UInt8])
        case rejectionLength, rejectionBody(Int), serverInitHeader, serverName(Int)
        case sessionInfoHeader, sessionInfoEntries(Int), sessionResult, sessionPending
        case ready, updateHeader, rectangleHeader, pixels(Rectangle), failed, closed
    }

    private struct Rectangle: Sendable {
        let x: Int, y: Int, width: Int, height: Int
        var byteCount: Int { width * height * 4 }
    }

    private let authenticationPolicy: AuthenticationPolicy
    private let appleCredentialProvider: (any AppleCredentialProvider)?
    private var state: State = .version
    private var buffer: [UInt8] = []
    private var cursor = 0
    private var storage: [UInt8] = []
    private var width = 0
    private var height = 0
    private var wireBytes = 0
    private var messages = 0
    private var requests = 0
    private var pendingRequest = false
    private var rectanglesRemaining = 0
    private var updateBytes = 0
    private var completedUpdate = false
    public private(set) var failure: Failure?
    /// Last selection outcome. Survives failure/close so `denied`/`unavailable`/`consoleOnly`
    /// stay observable; none of them is ever retried against the console.
    public private(set) var session: AppleSession = .notOffered

    /// `appleCredentialProvider` is the only seam where S4's DH/AES exchange could live.
    /// This package ships no implementation; without a provider the Apple handshake stops
    /// before sending a credential response or ClientInit. See AppleSubset.swift.
    public init(authenticationPolicy: AuthenticationPolicy = .rejectAll,
                appleCredentialProvider: (any AppleCredentialProvider)? = nil) {
        self.authenticationPolicy = authenticationPolicy
        self.appleCredentialProvider = appleCredentialProvider
    }

    private var apple: Bool { authenticationPolicy == .syntheticAppleSubset }

    public var phase: Phase {
        switch state {
        case .version: .version
        case .securityCount, .securityTypes: .security
        case .securityResult, .rejectionLength, .rejectionBody: .securityResult
        case .serverInitHeader, .serverName: .serverInit
        case .appleChallengeHeader, .appleModulus, .appleServerKey: .appleChallenge
        case .sessionInfoHeader, .sessionInfoEntries, .sessionResult: .session
        case .sessionPending: .sessionPending
        case .ready: .ready
        case .updateHeader, .rectangleHeader, .pixels: .update
        case .failed: .failed
        case .closed: .closed
        }
    }

    /// BGRX bytes at 32 bpp. No partially received update is observable.
    /// Never-updated pixels stay zero; this accessor is not a completeness oracle.
    /// Nil before the first complete update, while updating, and after any failure/close.
    public var framebuffer: [UInt8]? {
        guard phase == .ready, completedUpdate else { return nil }
        return storage
    }

    public var bufferedByteCount: Int { buffer.count - cursor }

    /// Incremental parser: chunks may end at any byte, and may contain multiple messages.
    /// A protocol failure is terminal, discards buffered/pixel data, and returns no events
    /// from this call. Events already returned by earlier calls cannot be retracted.
    public mutating func receive(_ bytes: [UInt8]) throws -> [Event] {
        guard phase != .failed, phase != .closed else { throw Failure.terminal }
        do {
            guard bytes.count <= Limits.chunkBytes,
                  bytes.count <= Limits.sessionWireBytes - wireBytes,
                  bytes.count <= Limits.bufferedBytes - bufferedByteCount else {
                throw Failure.resourceLimit
            }
            wireBytes += bytes.count
            // Compact at most once per feed, not once per parsed field/rectangle.
            if cursor > 0 {
                buffer.removeFirst(cursor)
                cursor = 0
            }
            buffer.append(contentsOf: bytes)
            var events: [Event] = []
            while try step(events: &events) {}
            if cursor == buffer.count {
                buffer.removeAll(keepingCapacity: true)
                cursor = 0
            }
            return events
        } catch let error as Failure {
            fail(error)
            throw error
        }
    }

    /// An explicit request for the whole framebuffer; there is no automatic polling loop.
    /// Local API misuse throws without mutating the parser. Exhaustion is terminal.
    public mutating func requestFramebufferUpdate(incremental: Bool = false) throws -> [UInt8] {
        guard phase != .failed, phase != .closed else { throw Failure.terminal }
        guard phase == .ready, !pendingRequest, bufferedByteCount == 0,
              !incremental || completedUpdate else { throw Failure.invalidState }
        guard requests < Limits.updateRequests else {
            fail(.resourceLimit)
            throw Failure.resourceLimit
        }
        requests += 1
        pendingRequest = true
        return [3, incremental ? 1 : 0, 0, 0, 0, 0]
            + Self.u16(width) + Self.u16(height)
    }

    /// EOF is clean only at an idle message boundary with no outstanding request.
    public mutating func finish() throws {
        guard phase != .failed, phase != .closed else { throw Failure.terminal }
        guard phase == .ready, !pendingRequest, bufferedByteCount == 0 else {
            fail(.truncated)
            throw Failure.truncated
        }
        cancel()
    }

    /// A future transport must impose a monotonic total/idle deadline itself and call this.
    /// The offline parser has no clock, waits, retries, reconnects, or timeout claim.
    public mutating func expire() {
        guard phase != .failed, phase != .closed else { return }
        fail(.deadlineExceeded)
    }

    public mutating func cancel() {
        guard phase != .failed else { return }
        erase()
        state = .closed
    }

    private mutating func step(events: inout [Event]) throws -> Bool {
        switch state {
        case .version:
            guard available(12) else { return false }
            // S1: the client echoes the version it negotiated. The Apple banner is accepted
            // only under the fixture policy; its exact literal is cited to S5 in AppleSubset.swift.
            let expected = apple ? AppleFixtureFraming.appleBanner : Self.standardBanner
            guard Array(buffer[cursor..<(cursor + 12)]) == expected else {
                throw Failure.unsupportedVersion
            }
            cursor += 12
            events.append(.send(expected))
            state = .securityCount
        case .securityCount:
            guard available(1) else { return false }
            let count = read8()
            state = count == 0 ? .rejectionLength : .securityTypes(count)
        case .securityTypes(let count):
            guard available(count) else { return false }
            switch authenticationPolicy {
            case .rejectAll:
                throw Failure.authenticationNotImplemented
            case .syntheticNoneOnly:
                // A mixed list is NOT a reason to fall back from Apple/VNC/TLS to None.
                guard count == 1, buffer[cursor] == 1 else { throw Failure.unexpectedSecurityOffer }
                cursor += count
                events.append(.send([1]))
                state = .securityResult
            case .syntheticAppleSubset:
                // S4: type 30 is the ARD DH/credential exchange. Exactly one offer, no
                // fallback to None/VNC/TLS and no type-33 tunnel (left unimplemented).
                guard count == 1, buffer[cursor] == AppleFixtureFraming.ardSecurityType else {
                    throw Failure.unexpectedSecurityOffer
                }
                cursor += 1
                events.append(.send([AppleFixtureFraming.ardSecurityType]))
                state = .appleChallengeHeader
            }
        case .appleChallengeHeader:
            // S4: two-byte generator, two-byte key length, then equal-length modulus and
            // server public key. Bounds are checked before copying either field from the
            // independently chunk-bounded receive buffer.
            guard available(4) else { return false }
            let generator = read16()
            let keyLength = read16()
            guard generator > 1, keyLength > 0, keyLength <= Limits.appleKeyBytes else {
                throw Failure.invalidAppleChallenge
            }
            state = .appleModulus(keyLength: keyLength, generator: generator)
        case .appleModulus(let keyLength, let generator):
            guard available(keyLength) else { return false }
            let modulus = Array(buffer[cursor..<(cursor + keyLength)])
            cursor += keyLength
            state = .appleServerKey(keyLength: keyLength, generator: generator, modulus: modulus)
        case .appleServerKey(let keyLength, let generator, let modulus):
            guard available(keyLength) else { return false }
            let challenge = AppleDHChallenge(
                generator: UInt16(generator), modulus: modulus,
                serverPublicKey: Array(buffer[cursor..<(cursor + keyLength)]))
            cursor += keyLength
            // Fail-closed seam: with no injected provider there is no DH, no AES and no
            // credential block, so nothing is sent and no ClientInit/selection happens.
            guard let provider = appleCredentialProvider else {
                throw Failure.authenticationNotImplemented
            }
            let response: [UInt8]
            do { response = try provider.credentialResponse(for: challenge) }
            catch { throw Failure.authenticationNotImplemented }
            guard !response.isEmpty else { throw Failure.authenticationNotImplemented }
            guard response.count <= Limits.appleCredentialBytes else { throw Failure.resourceLimit }
            // Validate the seam's record shape even for a trusted injected provider. This
            // checks only framing, not the encrypted block or the DH public key's validity.
            guard response.count == 128 + keyLength else { throw Failure.invalidAppleCredentialResponse }
            events.append(.send(response))
            state = .securityResult
        case .securityResult:
            guard available(4) else { return false }
            switch read32() {
            case 0:
                // S5: the Apple path answers with ClientInit 0xC1 instead of shared=1.
                events.append(.send([apple ? AppleFixtureFraming.appleClientInit : 1]))
                state = .serverInitHeader
            case 1: state = .rejectionLength
            default: throw Failure.invalidSecurityResult
            }
        case .rejectionLength:
            guard available(4) else { return false }
            let length = Int(read32())
            guard length <= Limits.textBytes else { throw Failure.oversizedText }
            state = .rejectionBody(length)
        case .rejectionBody(let length):
            guard available(length) else { return false }
            // Never reflect a peer's failure text into the terminal or application UI.
            cursor += length
            throw Failure.serverRejected
        case .serverInitHeader:
            guard available(24) else { return false }
            width = read16()
            height = read16()
            guard width > 0, height > 0,
                  width <= Limits.dimension, height <= Limits.dimension,
                  width * height * 4 <= Limits.framebufferBytes else {
                throw Failure.invalidDimensions
            }
            // Narrow fixture format; ignore three padding bytes as required by RFB.
            guard Array(buffer[cursor..<(cursor + 13)]) == Array(Self.pixelFormat.prefix(13)) else {
                throw Failure.unsupportedPixelFormat
            }
            cursor += 16
            let nameLength = Int(read32())
            guard nameLength <= Limits.textBytes else { throw Failure.oversizedText }
            state = .serverName(nameLength)
        case .serverName(let length):
            guard available(length) else { return false }
            cursor += length
            if apple {
                // Only standard ServerInit is modeled. S5 ard-patch.js lines 331–348
                // describes extended metadata inside the name field; this parser deliberately
                // discards that field as opaque. Following bytes use the separate package-local
                // selection framing. Nothing is allocated or published before grant.
                state = .sessionInfoHeader
                break
            }
            storage = Array(repeating: 0, count: width * height * 4)
            events.append(.send([0, 0, 0, 0] + Self.pixelFormat))
            events.append(.send([2, 0, 0, 1, 0, 0, 0, 0])) // advertise Raw only
            events.append(.initialized(width: width, height: height))
            state = .ready
        case .sessionInfoHeader:
            // Package-local fixture framing: kind 1, then u16 count (AppleSubset.swift).
            guard available(3) else { return false }
            guard read8() == Int(AppleFixtureFraming.sessionInfoKind) else {
                throw Failure.invalidSelectionMessage
            }
            let count = read16()
            guard count > 0, count <= Limits.appleSessionChoices else {
                throw Failure.invalidSelectionMessage
            }
            state = .sessionInfoEntries(count)
        case .sessionInfoEntries(let count):
            guard available(count * 2) else { return false }
            var consoleState: Int?
            var virtualState: Int?
            for _ in 0..<count {
                let command = read8()
                let availability = read8()
                guard availability <= Int(AppleFixtureFraming.availableState) else {
                    throw Failure.invalidSelectionMessage
                }
                switch command {
                case Int(AppleFixtureFraming.consoleCommand):
                    guard consoleState == nil else { throw Failure.invalidSelectionMessage }
                    consoleState = availability
                case Int(AppleFixtureFraming.virtualDesktopCommand):
                    guard virtualState == nil else { throw Failure.invalidSelectionMessage }
                    virtualState = availability
                default:
                    throw Failure.invalidSelectionMessage
                }
            }
            guard let availability = virtualState else {
                // S5 assigns command 1 to the console. Choosing it automatically is forbidden
                // by this package: an offer without the virtual desktop is terminal.
                // Only an *available* console offer is a console-only offer (S5 availability
                // flag is package-local): a named-but-unavailable console offers nothing, so it
                // is reported as unavailable instead of claiming a console alternative exists.
                let availableConsole = consoleState == Int(AppleFixtureFraming.availableState)
                session = availableConsole ? .consoleOnly : .unavailable
                throw availableConsole ? Failure.consoleFallbackForbidden
                    : Failure.sessionUnavailable
            }
            guard availability == Int(AppleFixtureFraming.availableState) else {
                session = .unavailable
                throw Failure.sessionUnavailable
            }
            session = .virtualReady
            // Only the virtual desktop may be chosen; there is no API to ask for command 1.
            events.append(.send([AppleFixtureFraming.sessionInfoChoiceKind,
                                 AppleFixtureFraming.virtualDesktopCommand]))
            state = .sessionResult
        case .sessionResult, .sessionPending:
            guard available(2) else { return false }
            // All result outcomes share the ready-message budget. Grant must not bypass
            // exhaustion and publish a surface after the pending limit has been reached.
            guard messages < Limits.serverMessages else { throw Failure.resourceLimit }
            messages += 1
            guard read8() == Int(AppleFixtureFraming.sessionResultKind) else {
                throw Failure.invalidSelectionMessage
            }
            switch read8() {
            case Int(AppleFixtureFraming.outcomeGranted):
                grantSession(events: &events)
            case Int(AppleFixtureFraming.outcomeDenied):
                session = .denied
                throw Failure.sessionDenied
            case Int(AppleFixtureFraming.outcomePending):
                // S5 pending state. No polling, no retry, no console: the transport owns the
                // deadline and must call expire(). The message budget still applies.
                session = .pending
                state = .sessionPending
            default:
                throw Failure.invalidSelectionMessage
            }
        case .ready:
            guard available(1) else { return false }
            guard messages < Limits.serverMessages else { throw Failure.resourceLimit }
            messages += 1
            switch read8() {
            case 0:
                guard pendingRequest else { throw Failure.unsolicitedUpdate }
                state = .updateHeader
            case 2: break // Bell is consumed, but has no host effect.
            case 3: throw Failure.clipboardDisabled
            default: throw Failure.unsupportedMessage
            }
        case .updateHeader:
            guard available(3) else { return false }
            cursor += 1 // padding need not be zero
            rectanglesRemaining = read16()
            guard rectanglesRemaining <= Limits.rectanglesPerUpdate else { throw Failure.resourceLimit }
            updateBytes = 0
            if rectanglesRemaining == 0 { completeUpdate(events: &events) }
            else { state = .rectangleHeader }
        case .rectangleHeader:
            guard available(12) else { return false }
            let rect = Rectangle(x: read16(), y: read16(), width: read16(), height: read16())
            let encoding = read32()
            guard encoding == 0 else { throw Failure.unsupportedEncoding }
            guard rect.width > 0, rect.height > 0,
                  rect.x <= width, rect.y <= height,
                  rect.width <= width - rect.x, rect.height <= height - rect.y else {
                throw Failure.invalidRectangle
            }
            guard rect.byteCount <= Limits.updatePixelBytes - updateBytes else { throw Failure.resourceLimit }
            updateBytes += rect.byteCount
            state = .pixels(rect)
        case .pixels(let rect):
            guard available(rect.byteCount) else { return false }
            for row in 0..<rect.height {
                let target = ((rect.y + row) * width + rect.x) * 4
                let source = cursor + row * rect.width * 4
                storage.replaceSubrange(target..<(target + rect.width * 4),
                                        with: buffer[source..<(source + rect.width * 4)])
            }
            cursor += rect.byteCount
            rectanglesRemaining -= 1
            if rectanglesRemaining == 0 { completeUpdate(events: &events) }
            else { state = .rectangleHeader }
        case .failed, .closed: throw Failure.terminal
        }
        return true
    }

    private mutating func completeUpdate(events: inout [Event]) {
        pendingRequest = false
        completedUpdate = true
        state = .ready
        events.append(.framebufferUpdated)
    }

    /// Selection granted: only now are pixel format/encodings sent and the surface published.
    private mutating func grantSession(events: inout [Event]) {
        session = .granted
        storage = Array(repeating: 0, count: width * height * 4)
        events.append(.send([0, 0, 0, 0] + Self.pixelFormat))
        events.append(.send([2, 0, 0, 1, 0, 0, 0, 0])) // advertise Raw only
        events.append(.initialized(width: width, height: height))
        state = .ready
    }

    private mutating func fail(_ error: Failure) {
        erase()
        failure = error
        state = .failed
    }

    private mutating func erase() {
        buffer = []
        cursor = 0
        storage = []
        pendingRequest = false
        completedUpdate = false
    }

    private func available(_ count: Int) -> Bool { count <= buffer.count - cursor }
    private mutating func read8() -> Int {
        defer { cursor += 1 }
        return Int(buffer[cursor])
    }
    private mutating func read16() -> Int { (read8() << 8) | read8() }
    private mutating func read32() -> UInt32 {
        (UInt32(read8()) << 24) | (UInt32(read8()) << 16) | (UInt32(read8()) << 8) | UInt32(read8())
    }
    private static func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 255)] }

    // 32-bit BGRX, 24 significant bits, little endian, true colour.
    private static let pixelFormat: [UInt8] = [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
    private static let standardBanner = Array("RFB 003.008\n".utf8)
}
