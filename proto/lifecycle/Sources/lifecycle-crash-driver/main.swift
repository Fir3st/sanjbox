import Darwin
import Foundation
import SanjboxLifecycle

// Test-only process-death driver. All input paths must be private H2 fixtures; operations affect
// only inert JSON. No shell commands, arbitrary file paths, real UIDs or system adapter exist.
let args = CommandLine.arguments
if args.count != 5 { fputs("usage: lifecycle-crash-driver FIXTURE ZONE OPERATION HOOK\n", stderr); exit(64) }
do {
    guard let operation = LifecycleOperation(rawValue: args[3]), operation.crashHooks.contains(args[4]) else {
        throw LifecycleFailure("unknown test operation/hook")
    }
    let store = try LifecycleStore(path: args[1])
    let coordinator = LifecycleCoordinator(store: store)
    coordinator.hook = { if $0 == args[4] { _exit(77) } }
    try coordinator.execute(operation, zone: args[2])
    exit(0)
} catch {
    fputs("synthetic crash driver failed: \(error)\n", stderr); exit(65)
}
