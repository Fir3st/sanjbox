import Foundation
import S1Forward
import SanjboxProbeKit

// sanjbox-s1-forward — lets Screen Sharing.app open a virtual session on this Mac:
// vnc://127.0.0.1:<listen> reaches the local VNC server on <target>. Loopback only.

let usage = """
    usage: sanjbox-s1-forward [--listen PORT] [--target PORT]
      --listen PORT  port on 127.0.0.1 to accept on, default 5901
      --target PORT  local VNC server port, default 5900
    runs until interrupted; prints one line per finished connection
    """

let arguments: ProbeArguments
do {
    arguments = try ProbeArguments(Array(CommandLine.arguments.dropFirst()), valueFlags: ["listen", "target"])
} catch {
    exitWithError("\(error)\n\(usage)")
}
guard arguments.positional.isEmpty,
      let listenPort = UInt16(arguments.options["listen"] ?? "5901"),
      let targetPort = UInt16(arguments.options["target"] ?? "5900")
else { exitWithError(usage) }

let forwarder: LoopbackForwarder
do { forwarder = try LoopbackForwarder(listenPort: listenPort, targetPort: targetPort) } catch {
    exitWithError("cannot start: \(error)")
}
print("forwarding 127.0.0.1:\(forwarder.listenPort) -> 127.0.0.1:\(forwarder.targetPort); open vnc://127.0.0.1:\(forwarder.listenPort)")
fflush(stdout)
forwarder.serve { line in
    print("\(Date().formatted(JSONLines.timestampStyle)) \(line)")
    fflush(stdout)
}
