// Offline S4/S5 record research. Sources and exact scope: SOURCES.md.
// These are pinned CLIENT implementation contracts, not an Apple specification.

/// S4 type-30 challenge. Equal-width modulus and server public key follow a u16 generator.
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

/// S4 credential exchange seam; no provider is installed by default.
/// The explicit offline SyntheticAppleCredentialProvider uses the approved backend.
/// Constant mocks remain framing-only. A provider returns a 128-byte encrypted block + public key;
/// the parser checks only length, not cryptographic validity, identity or confidentiality.
public protocol AppleCredentialProvider: Sendable {
    func credentialResponse(for challenge: AppleDHChallenge) throws -> [UInt8]
}

/// Local policy for owned synthetic transcripts only; never server authorization or identity.
public enum AppleSelectionPolicy: Sendable {
    /// Preserve the default terminal refusal before any choice.
    case rejectAll
    /// S5 describes one bit per command but skips checking the virtual bit. This stricter
    /// LOCAL policy requires bit 2 and rejects unknown command bits. It only authorizes
    /// generating command 2 in an offline fixture, never exposing a surface.
    case syntheticVirtualOnly

    func permitsVirtualCommand(mask: UInt32) -> Bool {
        // S5 ard-constants.js: commands 0=request-console, 1=console, 2=virtual.
        // Extra known alternatives do not select them. Zero/unknown masks never fall back.
        self == .syntheticVirtualOnly && mask & (1 << 2) != 0 && mask & ~UInt32(0x07) == 0
    }
}

/// Last observed selection outcome; none of these states authenticates a session.
public enum AppleSession: String, Equatable, Sendable {
    case notOffered
    /// ServerInit does not offer the required virtual-selection path.
    case unavailable
    /// The default policy declined to interpret SessionInfo.
    case unverified
    case requestedVirtual, pendingVirtual, denied
    /// The peer reported a grant. Independent UID/audit-session evidence is still absent;
    /// this is terminal and never grants a surface, retries, or falls back to the console.
    case grantedUnverified
}

/// S4/S5 constants. No package-local selection message kinds remain.
public enum AppleFixtureFraming {
    public static let ardSecurityType: UInt8 = 30 // S4 _negotiateARDAuth
    public static let appleClientInit: UInt8 = 0xC1 // S5 ard-constants.js:78
    public static let virtualDesktopCommand: UInt8 = 2 // S5 ard-constants.js:91
    public static let appleBanner = Array("RFB 003.889\n".utf8) // S5 ard-patch.js:214
}

/// Internal, offline codecs. Caller supplies the complete length-prefixed record.
/// No network API, automatic command selection or console-command encoder exists here.
/// S5: ard-patch.js:331–348, 779–797, 839–867, 2510–2523; ard-constants.js:75–97.
/// Stricter local policy: version 1 only, 4096-byte body budget, known ServerInit flags.
/// Reserved bytes and the capability bitmap are opaque, as in S5; they confer no authority.
enum AppleSessionRecordCodec {
    static let maximumBodyBytes = 4096 // Local budget, not an upstream limit.
    static let sessionSelectFlag: UInt32 = 0x04
    static let noVirtualDisplayFlag: UInt32 = 0x08
    static let knownServerFlags: UInt32 = 0x0f

    struct ServerMetadata: Equatable, Sendable {
        let flags: UInt32
        let capabilityBitmap: [UInt8]
    }

    struct Info: Equatable, Sendable {
        let allowedCommands: UInt32
        // S5 treats incoming bytes as Latin-1 code units, stopping at the first NUL.
        // Kept private to this module; RFBClient never publishes or logs a peer username.
        let consoleUserBytes: [UInt8]
    }

    enum Outcome: Equatable, Sendable { case granted, pending, denied }

    struct Result: Equatable, Sendable {
        let status: UInt32
        var outcome: Outcome {
            switch status {
            case 0, 4: .granted
            case 2, 3: .pending
            default: .denied
            }
        }
    }

    static func serverMetadata(_ name: [UInt8]) throws -> ServerMetadata {
        // Only the FIRST marker byte is constrained by S5; byte 1 may be nonzero.
        guard name.count >= 22, name.count <= maximumBodyBytes, name[0] == 0 else {
            throw RFBClient.Failure.invalidSelectionMessage
        }
        let flags = u32(name, 2)
        guard flags & ~knownServerFlags == 0 else {
            throw RFBClient.Failure.invalidSelectionMessage
        }
        return ServerMetadata(flags: flags, capabilityBitmap: Array(name[6..<22]))
    }

    static func info(_ record: [UInt8]) throws -> Info {
        try validate(record, minimumBodyBytes: 10)
        // u16 version, u32 allowed mask, u32 opaque reserved, remaining username bytes.
        let username = record.dropFirst(12).prefix { $0 != 0 }
        return Info(allowedCommands: u32(record, 4), consoleUserBytes: Array(username))
    }

    static func result(_ record: [UInt8]) throws -> Result {
        // S5's comment mentions 74 reserved bytes, but the parser accepts ANY bounded
        // remainder after the 6-byte version/status header. No fixed 80-byte claim.
        try validate(record, minimumBodyBytes: 6)
        return Result(status: u32(record, 4))
    }

    /// Exact S5 74-byte command record; always command 2. RFBClient calls this only after
    /// its explicitly opted-in local synthetic policy accepts the mask.
    /// Reproduce S5's Latin-1 decode -> UTF-8 encode -> 63-byte truncation, including a
    /// possible split UTF-8 sequence. No credential username or peer name is inferred here.
    static func virtualCommand(for info: Info) -> [UInt8] {
        let scalars = info.consoleUserBytes.map { UnicodeScalar(Int($0))! }
        let encoded = Array(String(String.UnicodeScalarView(scalars)).utf8.prefix(63))
        return [0, 72, 0, 1, 0, 0, 0, 0, 2, 0]
            + encoded + Array(repeating: 0, count: 64 - encoded.count)
    }

    private static func validate(_ record: [UInt8], minimumBodyBytes: Int) throws {
        guard record.count >= 4 else { throw RFBClient.Failure.invalidSelectionMessage }
        let bodyBytes = Int(record[0]) << 8 | Int(record[1])
        guard bodyBytes >= minimumBodyBytes, bodyBytes <= maximumBodyBytes,
              record.count == bodyBytes + 2, record[2] == 0, record[3] == 1 else {
            throw RFBClient.Failure.invalidSelectionMessage
        }
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }
}
