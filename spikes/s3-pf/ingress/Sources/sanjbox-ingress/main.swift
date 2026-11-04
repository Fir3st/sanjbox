import Darwin
import Foundation
import IngressKit

let usage = """
usage: sanjbox-ingress [plan]
       sanjbox-ingress identity
       sanjbox-ingress smoke --expect-json JSON [--apply]
       sanjbox-ingress evaluate < strict-evidence.json
       sanjbox-ingress link < adapter-input.json
       sanjbox-ingress cleanup --run-id UUID [--apply]
Default is dry-run. Live smoke accepts no host, port, PID, file or command.
identity only reports own metadata; inspect and explicitly supply --expect-json before smoke.
evaluate/link read at most 1 MiB from stdin within 2 seconds; no identity/OS/network collection.
"""
func printValue<T: Encodable>(_ value: T) throws {
    var bytes = try encodeJSON(value); bytes.append(10); FileHandle.standardOutput.write(bytes)
}
func stdinJSON() throws -> Data {
    let original = fcntl(STDIN_FILENO, F_GETFL)
    guard original >= 0, fcntl(STDIN_FILENO, F_SETFL, original | O_NONBLOCK) == 0 else { throw IngressError("cannot read bounded stdin") }
    defer { _ = fcntl(STDIN_FILENO, F_SETFL, original) }
    let end = ProcessInfo.processInfo.systemUptime + 2
    var data = Data(); var bytes = [UInt8](repeating: 0, count: 8192)
    while ProcessInfo.processInfo.systemUptime < end {
        var p = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let result = poll(&p, 1, 50)
        if result < 0 && errno == EINTR { continue }
        guard result >= 0 else { throw IngressError("stdin poll failed") }
        if result == 0 { continue }
        let n = read(STDIN_FILENO, &bytes, bytes.count)
        if n < 0 && [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { continue }
        guard n >= 0 else { throw IngressError("stdin read failed") }
        if n == 0 { return data }
        data.append(contentsOf: bytes.prefix(n))
        guard data.count <= 1_048_576 else { throw IngressError("stdin exceeds 1 MiB") }
    }
    throw IngressError("stdin deadline exceeded")
}
var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "plan" : args.removeFirst()
do {
    switch command {
    case "plan":
        guard args.isEmpty else { throw IngressError(usage) }
        try printValue(["mode": "dry-run", "activity": "none; no sockets/files/identity collection", "smoke": "with explicit --apply: verify exact identity and own hardened signature, only 127.0.0.1/::1 ephemeral TCP, bounded nonce echo, held-port EADDRINUSE, close/rebind/recovery; create UUID report under /private/tmp/sanjbox-c3-run-*", "matrix": "evaluate returns all 28 planned NET-10..12 cells; S3b remains unverified"])
    case "identity":
        guard args.isEmpty else { throw IngressError(usage) }
        try printValue(OwnIdentity.capture())
    case "evaluate":
        guard args.isEmpty else { throw IngressError(usage) }
        try printValue(Adjudicator.evaluate(EvidenceInput.decode(stdinJSON())))
    case "link":
        guard args.isEmpty else { throw IngressError(usage) }
        try printValue(EvidenceAdapter.link(stdinJSON()))
    case "smoke":
        let apply = args.last == "--apply"
        if apply { args.removeLast() }
        guard args.count == 2, args[0] == "--expect-json", args[1].utf8.count <= 16_384 else { throw IngressError(usage) }
        let expected = try Identity.decode(Data(args[1].utf8))
        if !apply { try printValue(["mode": "dry-run", "activity": "none; expectation syntax accepted; identity/signature not measured; run plan for exact actions"]); break }
        let authorization: LiveAuthorization
        do { authorization = try LiveAuthorization.verify(expected: expected) }
        catch { FileHandle.standardError.write(Data(("\(error)\n").utf8)); exit(3) }
        let report = LoopbackSmoke.run(authorization: authorization, runID: UUID())
        let path = try OwnedOutput.save(report)
        try printValue(["runID": report.runID.uuidString.lowercased(), "path": path, "gate": report.gate])
        if report.families.contains(where: { $0.status != "transportControlObserved" }) { exit(3) }
    case "cleanup":
        let apply = args.last == "--apply"
        if apply { args.removeLast() }
        guard args.count == 2, args[0] == "--run-id", let id = UUID(uuidString: args[1]), args[1].lowercased() == id.uuidString.lowercased() else { throw IngressError(usage) }
        try printValue(OwnedOutput.cleanup(runID: id, apply: apply))
    default: throw IngressError(usage)
    }
} catch {
    FileHandle.standardError.write(Data(("\(error)\n").utf8)); exit(2)
}
