/// An offline, bounded RFB 3.8 protocol experiment, not an Apple session client.
/// There is deliberately no transport, credential implementation, input, or clipboard API.
/// Opted-in Apple selection uses pinned S5 records but stops before unverified identity.
public struct RFBClient: Sendable {
    public enum AuthenticationPolicy: Sendable {
        /// Default: stop at the authentication boundary without selecting a type.
        case rejectAll
        /// ONLY for owned synthetic fixtures offering exactly one type: None (1).
        /// This is not a policy for a live server, even on localhost.
        case syntheticNoneOnly
        /// ONLY for owned synthetic fixtures offering exactly one type: ARD (30), per S4.
        /// Accepts S5 records with a separately opted-in local selection policy; contains no
        /// cryptography and is not a policy for a live server.
        case syntheticAppleSubset
    }

    public enum Phase: String, Sendable {
        case version, security, securityResult, serverInit, ready, update, failed, closed
        /// S4 type-30 DH challenge is being consumed.
        case appleChallenge
        /// S5 length-framed SessionInfo/SessionResult; never implies a verified session.
        case session
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
        /// The default policy declined to authorize a synthetic virtual choice.
        case unverifiedSelectionPolicy
        /// Peer denied the requested virtual selection; never retry or choose the console.
        case sessionDenied
        /// A peer grant cannot authenticate the expected non-console UID/audit session.
        case unverifiedSessionIdentity
        /// Explicit fixture instants moved backwards during selection.
        case invalidClock
        /// Unsupported metadata, record version or malformed/budget-exceeding length.
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
        public static let appleSelectionBodyBytes = AppleSessionRecordCodec.maximumBodyBytes
        /// Fixed TOTAL result-wait budget; pending records never extend it.
        public static let appleSelectionWait: Duration = .seconds(30)
    }

    private enum State: Sendable {
        case version, securityCount, securityTypes(Int), securityResult
        case appleChallengeHeader, appleModulus(keyLength: Int, generator: Int)
        case appleServerKey(keyLength: Int, generator: Int, modulus: [UInt8])
        case rejectionLength, rejectionBody(Int), serverInitHeader, serverName(Int)
        case sessionInfoHeader, sessionInfoBody(Int)
        case sessionResultHeader, sessionResultBody(Int)
        case ready, updateHeader, rectangleHeader, pixels(Rectangle), failed, closed
    }

    private struct Rectangle: Sendable {
        let x: Int, y: Int, width: Int, height: Int
        var byteCount: Int { width * height * 4 }
    }

    private let authenticationPolicy: AuthenticationPolicy
    private let appleCredentialProvider: (any AppleCredentialProvider)?
    private let appleSelectionPolicy: AppleSelectionPolicy
    private var selectionDeadline: ContinuousClock.Instant?
    private var selectionLastInstant: ContinuousClock.Instant?
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
    /// Last observed selection state survives failure/close; never proof of identity.
    public private(set) var session: AppleSession = .notOffered

    /// `appleCredentialProvider` is the only seam where S4's DH/AES exchange could live.
    /// No provider is installed by default; without explicit injection the Apple handshake stops
    /// before sending a credential response or ClientInit. See AppleSubset.swift.
    public init(authenticationPolicy: AuthenticationPolicy = .rejectAll,
                appleCredentialProvider: (any AppleCredentialProvider)? = nil,
                appleSelectionPolicy: AppleSelectionPolicy = .rejectAll) {
        self.authenticationPolicy = authenticationPolicy
        self.appleCredentialProvider = appleCredentialProvider
        self.appleSelectionPolicy = appleSelectionPolicy
    }

    private var apple: Bool { authenticationPolicy == .syntheticAppleSubset }

    public var phase: Phase {
        switch state {
        case .version: .version
        case .securityCount, .securityTypes: .security
        case .securityResult, .rejectionLength, .rejectionBody: .securityResult
        case .serverInitHeader, .serverName: .serverInit
        case .appleChallengeHeader, .appleModulus, .appleServerKey: .appleChallenge
        case .sessionInfoHeader, .sessionInfoBody, .sessionResultHeader, .sessionResultBody: .session
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
    /// `now` defaults to the monotonic ContinuousClock; explicit instants are a fixture seam.
    /// Call with an empty chunk to check the result deadline during silence. There is no timer.
    public mutating func receive(_ bytes: [UInt8],
                                 at now: ContinuousClock.Instant = .now) throws -> [Event] {
        guard phase != .failed, phase != .closed else { throw Failure.terminal }
        do {
            if let deadline = selectionDeadline, let previous = selectionLastInstant {
                guard now >= previous else { throw Failure.invalidClock }
                guard now < deadline else { throw Failure.deadlineExceeded }
                selectionLastInstant = now
            }
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
            while try step(events: &events, at: now) {}
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

    /// A future transport must schedule wakeups and impose handshake/idle deadlines itself.
    /// This also terminates the S5 result wait; the parser has no timer, retry or reconnect.
    public mutating func expire() {
        guard phase != .failed, phase != .closed else { return }
        fail(.deadlineExceeded)
    }

    public mutating func cancel() {
        guard phase != .failed else { return }
        erase()
        state = .closed
    }

    private mutating func step(events: inout [Event], at now: ContinuousClock.Instant) throws -> Bool {
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
            if apple {
                let metadata = try AppleSessionRecordCodec.serverMetadata(
                    Array(buffer[cursor..<(cursor + length)]))
                cursor += length
                guard metadata.flags & AppleSessionRecordCodec.sessionSelectFlag != 0,
                      metadata.flags & AppleSessionRecordCodec.noVirtualDisplayFlag == 0 else {
                    session = .unavailable
                    throw Failure.sessionUnavailable
                }
                state = .sessionInfoHeader
                break
            }
            cursor += length
            storage = Array(repeating: 0, count: width * height * 4)
            events.append(.send([0, 0, 0, 0] + Self.pixelFormat))
            events.append(.send([2, 0, 0, 1, 0, 0, 0, 0])) // advertise Raw only
            events.append(.initialized(width: width, height: height))
            state = .ready
        case .sessionInfoHeader:
            // S5 u16 body length, not a message-kind byte. Validate before waiting/copying.
            guard available(2) else { return false }
            try consumeServerMessage()
            let bodyLength = read16()
            guard bodyLength >= 10, bodyLength <= Limits.appleSelectionBodyBytes else {
                throw Failure.invalidSelectionMessage
            }
            state = .sessionInfoBody(bodyLength)
        case .sessionInfoBody(let bodyLength):
            guard available(bodyLength) else { return false }
            let record = Self.u16(bodyLength) + Array(buffer[cursor..<(cursor + bodyLength)])
            let info = try AppleSessionRecordCodec.info(record)
            cursor += bodyLength
            guard appleSelectionPolicy != .rejectAll else {
                session = .unverified
                throw Failure.unverifiedSelectionPolicy
            }
            guard appleSelectionPolicy.permitsVirtualCommand(mask: info.allowedCommands) else {
                session = .unavailable
                throw Failure.sessionUnavailable
            }
            events.append(.send(AppleSessionRecordCodec.virtualCommand(for: info)))
            session = .requestedVirtual
            selectionDeadline = now.advanced(by: Limits.appleSelectionWait)
            selectionLastInstant = now
            state = .sessionResultHeader
        case .sessionResultHeader:
            guard available(2) else { return false }
            // SessionInfo, every pending/final result, and standard server messages all
            // debit one instance-wide counter. Fragmentation cannot reset or double debit it.
            try consumeServerMessage()
            let bodyLength = read16()
            guard bodyLength >= 6, bodyLength <= Limits.appleSelectionBodyBytes else {
                throw Failure.invalidSelectionMessage
            }
            state = .sessionResultBody(bodyLength)
        case .sessionResultBody(let bodyLength):
            guard available(bodyLength) else { return false }
            let record = Self.u16(bodyLength) + Array(buffer[cursor..<(cursor + bodyLength)])
            let result = try AppleSessionRecordCodec.result(record)
            cursor += bodyLength
            switch result.outcome {
            case .pending:
                session = .pendingVirtual
                state = .sessionResultHeader // no resend, retry or deadline reset
            case .denied:
                session = .denied
                throw Failure.sessionDenied
            case .granted:
                // S2 explicitly permits visible-screen sharing in some circumstances.
                // A mask/command/status cannot prove non-console UID/audit identity.
                session = .grantedUnverified
                throw Failure.unverifiedSessionIdentity
            }
        case .ready:
            guard available(1) else { return false }
            try consumeServerMessage()
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

    private mutating func consumeServerMessage() throws {
        guard messages < Limits.serverMessages else { throw Failure.resourceLimit }
        messages += 1
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
        selectionDeadline = nil
        selectionLastInstant = nil
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
