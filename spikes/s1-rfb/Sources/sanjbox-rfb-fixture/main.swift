import Foundation
import RFBProtocol

// No files, sockets, environment variables, live credentials, or screen APIs.
guard CommandLine.arguments == [CommandLine.arguments[0], "--demo"] else {
    print("Usage: sanjbox-rfb-fixture --demo")
    print("Replays an embedded synthetic 2x2 RFB 3.8 transcript entirely in memory.")
    exit(CommandLine.arguments.count == 1 || CommandLine.arguments.dropFirst() == ["--help"] ? 0 : 2)
}

do {
    var client = RFBClient(authenticationPolicy: .syntheticNoneOnly)
    let format: [UInt8] = [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
    let name = Array("SYNTHETIC".utf8)
    let handshake = Array("RFB 003.008\n".utf8) + [1, 1, 0, 0, 0, 0]
        + [0, 2, 0, 2] + format + [0, 0, 0, UInt8(name.count)] + name
    var sent = 0
    for byte in handshake {
        for event in try client.receive([byte]) {
            if case .send(let output) = event { sent += output.count }
        }
    }
    sent += try client.requestFramebufferUpdate().count
    let pixels: [UInt8] = [0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0]
    let update: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 2, 0, 0, 0, 0] + pixels
    for byte in update { _ = try client.receive([byte]) }
    guard client.framebuffer == pixels else {
        print("Synthetic fixture failed: pixel mismatch")
        exit(1)
    }
    try client.finish()
    print("MOCK ONLY: 2x2 Raw framebuffer matched all 16 expected bytes.")
    print("Generated \(sent) protocol bytes in memory; network bytes sent: 0.")
    print("Apple authentication/session selection and S1 gates remain unverified.")
} catch {
    print("Synthetic fixture failed: \(error)")
    exit(1)
}
