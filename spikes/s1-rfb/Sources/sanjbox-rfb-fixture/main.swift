import Foundation
import RFBProtocol

// No files, sockets, environment variables, live credentials, or screen APIs.
guard CommandLine.arguments == [CommandLine.arguments[0], "--demo"] else {
    print("Usage: sanjbox-rfb-fixture --demo")
    print("Replays embedded synthetic RFB transcripts entirely in memory.")
    print("Scenario 1: standard RFB 3.8 + one Raw 2x2 framebuffer.")
    print("Scenario 2: mocked Apple auth, local virtual-only choice, pending/grant, refusal before unverified identity.")
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

    // Scenario 2 — source-backed S5 records, synthetic auth and explicit local policy only.
    var apple = RFBClient(authenticationPolicy: .syntheticAppleSubset,
                          appleCredentialProvider: DemoCredentialProvider(),
                          appleSelectionPolicy: .syntheticVirtualOnly)
    var appleSent = 0
    let challenge = u16(2) + u16(8) + Array(0x80...0x87) + Array(0x40...0x47)
    let metadata: [UInt8] = [0, 0, 0, 0, 0, 4] + Array(repeating: 0, count: 16) + name
    let sessionInfo: [UInt8] = [0, 14, 0, 1, 0, 0, 0, 4,
                                0, 0, 0, 0, 115, 121, 110, 0]
    let pendingAndGrant: [UInt8] = [0, 6, 0, 1, 0, 0, 0, 2, 0, 6, 0, 1, 0, 0, 0, 4]
    do {
        try feed(&apple, AppleFixtureFraming.appleBanner
            + [1, 30] + challenge + [0, 0, 0, 0]
            + [0, 2, 0, 2] + format + [0, 0, 0, UInt8(metadata.count)] + metadata + sessionInfo + pendingAndGrant,
            sent: &appleSent)
        print("Synthetic Apple fixture failed: unverified identity was accepted")
        exit(1)
    } catch let failure as RFBClient.Failure {
        guard failure == .unverifiedSessionIdentity, apple.session == .grantedUnverified,
              apple.framebuffer == nil, appleSent == 224 else {
            print("Synthetic Apple fixture failed: unexpected result")
            exit(1)
        }
        print("MOCK ONLY: local virtual command, pending and grant parsed; unverified identity refused.")
        print("Generated \(appleSent) protocol bytes in memory; network bytes sent: 0.")
    }
    print("Exactly one virtual command; no console fallback or Apple surface was produced.")
    print("Apple authentication, selection interoperability and S1 gates remain unverified.")

} catch {
    print("Synthetic fixture failed: \(error)")
    exit(1)
}
