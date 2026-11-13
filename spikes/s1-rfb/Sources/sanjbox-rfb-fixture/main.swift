import Foundation
import RFBProtocol

// No files, sockets, environment variables, live credentials, or screen APIs.
guard CommandLine.arguments == [CommandLine.arguments[0], "--demo"] else {
    print("Usage: sanjbox-rfb-fixture --demo")
    print("Replays embedded synthetic RFB transcripts entirely in memory.")
    print("Scenario 1: standard RFB 3.8 + one Raw 2x2 framebuffer.")
    print("Scenario 2: Apple type-30 fixture framing, package-local selection, granted virtual desktop.")
    exit(CommandLine.arguments.count == 1 || CommandLine.arguments.dropFirst() == ["--help"] ? 0 : 2)
}

let format: [UInt8] = [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
let name = Array("SYNTHETIC".utf8)

func feed(_ client: inout RFBClient, _ bytes: [UInt8], sent: inout Int) throws {
    for byte in bytes {
        for event in try client.receive([byte]) {
            if case .send(let output) = event { sent += output.count }
        }
    }
}

/// MOCK: constant stand-in for S4's encrypted credential block plus client public key.
/// No DH, MD5, AES or credential material exists in this program.
struct DemoCredentialProvider: AppleCredentialProvider {
    static let response: [UInt8] = Array(repeating: 0xA5, count: 128)
        + Array(repeating: 0x5A, count: 8)
    func credentialResponse(for challenge: AppleDHChallenge) throws -> [UInt8] { Self.response }
}

func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 255)] }

do {
    var client = RFBClient(authenticationPolicy: .syntheticNoneOnly)
    var sent = 0
    let handshake = Array("RFB 003.008\n".utf8) + [1, 1, 0, 0, 0, 0]
        + [0, 2, 0, 2] + format + [0, 0, 0, UInt8(name.count)] + name
    try feed(&client, handshake, sent: &sent)
    sent += try client.requestFramebufferUpdate().count
    let pixels: [UInt8] = [0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0]
    let update: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 2, 0, 0, 0, 0] + pixels
    try feed(&client, update, sent: &sent)
    guard client.framebuffer == pixels else {
        print("Synthetic fixture failed: pixel mismatch")
        exit(1)
    }
    try client.finish()
    print("MOCK ONLY: 2x2 Raw framebuffer matched all 16 expected bytes.")
    print("Generated \(sent) protocol bytes in memory; network bytes sent: 0.")

    // Scenario 2 — Apple security/selection fixture framing. Synthetic bytes only.
    var apple = RFBClient(authenticationPolicy: .syntheticAppleSubset,
                          appleCredentialProvider: DemoCredentialProvider())
    var appleSent = 0
    let generator = 2
    let keyLength = 8
    let modulus = (0..<keyLength).map { UInt8(truncatingIfNeeded: 0x80 + $0) }
    let serverKey = (0..<keyLength).map { UInt8(truncatingIfNeeded: 0x40 + $0) }
    let challenge = u16(generator) + u16(keyLength) + modulus + serverKey
    let virtual = AppleFixtureFraming.virtualDesktopCommand
    try feed(&apple, AppleFixtureFraming.appleBanner
        + [1, AppleFixtureFraming.ardSecurityType] + challenge + [0, 0, 0, 0]
        + [0, 2, 0, 2] + format + [0, 0, 0, UInt8(name.count)] + name
        + [AppleFixtureFraming.sessionInfoKind] + u16(2)
        + [AppleFixtureFraming.consoleCommand, AppleFixtureFraming.availableState, virtual,
           AppleFixtureFraming.availableState]
        + [AppleFixtureFraming.sessionResultKind, AppleFixtureFraming.outcomeGranted],
        sent: &appleSent)
    guard apple.session == .granted, apple.phase == .ready else {
        print("Synthetic Apple fixture failed: selection was not granted")
        exit(1)
    }
    print("MOCK ONLY: Apple fixture selection granted the virtual desktop (command 2).")
    print("Generated \(appleSent) protocol bytes in memory; network bytes sent: 0.")

    // Scenario 3 — the forbidden fallback. A console-only offer must terminate.
    var consoleOnly = RFBClient(authenticationPolicy: .syntheticAppleSubset,
                                appleCredentialProvider: DemoCredentialProvider())
    do {
        try feed(&consoleOnly, AppleFixtureFraming.appleBanner
            + [1, AppleFixtureFraming.ardSecurityType] + challenge + [0, 0, 0, 0]
            + [0, 2, 0, 2] + format + [0, 0, 0, UInt8(name.count)] + name
            + [AppleFixtureFraming.sessionInfoKind] + u16(1)
            + [AppleFixtureFraming.consoleCommand, AppleFixtureFraming.availableState],
            sent: &appleSent)
        print("Synthetic Apple fixture failed: console-only offer was not refused")
        exit(1)
    } catch let failure as RFBClient.Failure {
        guard failure == .consoleFallbackForbidden,
              consoleOnly.session == .consoleOnly else {
            print("Synthetic Apple fixture failed: unexpected \(failure)")
            exit(1)
        }
        print("MOCK ONLY: console-only SessionInfo refused (\(failure.rawValue)); no fallback attempted.")
    }

    print("The Apple selection framing here is package-local, not Apple's wire format.")
    print("Apple authentication/session selection and S1 gates remain unverified.")
} catch {
    print("Synthetic fixture failed: \(error)")
    exit(1)
}
