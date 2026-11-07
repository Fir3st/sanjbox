// Apple security/selection subset for WP1.A3 — FIXTURE FRAMING ONLY.
//
// Citation key. These are the only sources this file is allowed to encode; every constant
// below names the one it comes from. Full URLs, pinned commits and SHA-256 values: SOURCES.md.
//
//   S4 = noVNC v1.6.0, core/rfb.js `_negotiateARDAuth` / `_negotiateARDAuthAsync`
//        (inspected lines 1798–1866). Records type-30 framing: a two-byte DH generator,
//        a two-byte key length, then the modulus and the server public key of that length;
//        the client replies with a 128-byte credential block encrypted with AES-ECB over an
//        MD5 of the DH shared value, followed by the client public key, then waits for
//        SecurityResult. S4 is evidence of one client's implementation, not an Apple contract.
//
//   S5 = peetinc/noVNC-ARD, `_initMsg` / `_negotiateServerInit` / `_ardSessionSelect`
//        (selection at inspected lines 776–875), ard-constants.js, session-select.js.
//        Records that the Apple path uses ClientInit 0xC1, extended ServerInit metadata,
//        then SessionInfo / a client choice / SessionResult, and that its constants assign
//        command 1 to the console and command 2 to the virtual desktop, with pending and
//        granted states. S5 is a client-side implementation claim, not a server contract.
//
// Deliberate omission: SOURCES.md records no Apple-published byte-level contract for these
// extensions and no pinned layout for the selection messages. The SessionInfo /
// SessionInfoChoice / SessionResult bytes below are therefore a *package-local fixture
// framing*. They are never a claim about Apple's wire format, and no real endpoint may be
// fed with them: the prototype has no transport at all.

/// S4: the two-length DH challenge a type-30 server sends before any credential.
/// `modulus` and `serverPublicKey` both have the pinned key length.
public struct AppleDHChallenge: Equatable, Sendable {
    public let generator: UInt16
    public let modulus: [UInt8]
    public let serverPublicKey: [UInt8]

    public init(generator: UInt16, modulus: [UInt8], serverPublicKey: [UInt8]) {
        self.generator = generator
        self.modulus = modulus
        self.serverPublicKey = serverPublicKey
    }
}

/// The seam where S4's DH/AES credential exchange would live.
///
/// There is deliberately **no** implementation in this package: no DH, MD5, AES, key
/// agreement or credential handling exists here, and no test supplies real material.
/// A provider must implement the whole S4 record itself (encrypted 128-byte credential
/// block followed by the client public key) under a separate reviewed package.
/// When no provider is injected the client stops at this seam — fail-closed, nothing sent.
public protocol AppleCredentialProvider: Sendable {
    /// Return the bytes to send after the challenge. Empty output is treated as
    /// "not implemented" and stops the handshake.
    func credentialResponse(for challenge: AppleDHChallenge) throws -> [UInt8]
}

/// Selection outcome. `pending`, `denied` and `unavailable` are final observables:
/// none of them ever turns into a console session.
public enum AppleSession: String, Equatable, Sendable {
    /// No SessionInfo was consumed yet.
    case notOffered
    /// The virtual desktop was offered as available and the client chose it.
    case virtualReady
    /// S5 records a pending state. The transport owns the deadline; nothing is retried here.
    case pending
    /// SessionResult granted the virtual desktop.
    case granted
    /// SessionResult denied the choice.
    case denied
    /// The virtual desktop was absent or offered as unavailable.
    case unavailable
    /// Only the host console was offered. Selecting it is forbidden, so this is terminal.
    case consoleOnly
}

/// Byte constants, each tagged with its citation or explicitly marked package-local.
public enum AppleFixtureFraming {
    // S1 (RFC 6143 §7.1.2): the client answers a security-type offer with one byte.
    // S4: the ARD type this package accepts. Exactly one offer, never a fallback.
    public static let ardSecurityType: UInt8 = 30

    // S5: ClientInit in the Apple path is the single byte 0xC1 (standard RFB uses shared=1).
    public static let appleClientInit: UInt8 = 0xC1

    // S5: command values of the session selection. Package policy: only the virtual
    // desktop may ever be chosen; the console command exists solely for validation.
    public static let consoleCommand: UInt8 = 1
    public static let virtualDesktopCommand: UInt8 = 2

    // PACKAGE-LOCAL: availability flag inside SessionInfo (0 = unavailable, 1 = available).
    // S5 only records that pending/granted states exist; it pins no codepoint.
    public static let unavailableState: UInt8 = 0
    public static let availableState: UInt8 = 1

    // PACKAGE-LOCAL: message kinds of the fixture framing (SessionInfo, choice, result).
    public static let sessionInfoKind: UInt8 = 1
    public static let sessionInfoChoiceKind: UInt8 = 2
    public static let sessionResultKind: UInt8 = 3

    // PACKAGE-LOCAL: SessionResult outcomes; `pending` stands for S5's pending state,
    // `granted`/`denied` for its granted state and its failure case.
    public static let outcomeGranted: UInt8 = 0
    public static let outcomeDenied: UInt8 = 1
    public static let outcomePending: UInt8 = 2

    /// Candidate Apple banner. PACKAGE-LOCAL and unre-verified: this literal is the one the
    /// earlier, reviewed revision of this package already treated as the Apple banner and
    /// rejected (README "Podporovaná podmnožina"). SOURCES.md records that S5 handles "Apple
    /// banner handling" but not its bytes, so this value is a fixture constant, not a claim.
    /// It is only accepted under `AuthenticationPolicy.syntheticAppleSubset`; the default
    /// policy still rejects it. Nothing here proves which banner a macOS server sends.
    public static let appleBanner = Array("RFB 003.889\n".utf8)
}
