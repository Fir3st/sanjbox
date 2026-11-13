import Darwin
import Foundation

/// Run in a disposable process, never inside the concurrent Swift test runner:
/// swiftc Sources/SanjboxProbeKit/{ProbeContext,ContextChild}.swift \
///   Tests/context_child_native_audit.swift -o <temporary-audit>
/// <temporary-audit> <mode>
/// Only this process's descriptors/signals and its own fixed children are touched.
@main
struct ContextChildNativeAudit {
    enum AuditFailure: Error { case failed(String) }

    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw AuditFailure.failed(message) }
    }

    static func descriptors() -> Set<Int32> {
        Set((0..<256).filter { fcntl($0, F_GETFD) >= 0 })
    }

    static func requireReaped(_ pid: pid_t) throws {
        try require(pid > 0, "fixture did not spawn")
        var status: Int32 = 0
        try require(waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD,
                    "exact child was not reaped")
    }

    static func echo(hold: Bool = false, inspect: ((pid_t) -> Void)? = nil) throws {
        var pid: pid_t = 0
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let bytes = try ContextChild.runEchoFixture(holdInputOpen: hold) {
                pid = $0
                inspect?($0)
            }
            try require(!hold && bytes == Data("context-child-fixture\n".utf8), "echo result")
        } catch ContextChild.Failure.deadline {
            try require(hold, "unexpected timeout")
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        if hold {
            try require(elapsed >= ContextChild.Limits.standard.execution && elapsed < 5_000_000_000,
                        "timeout outside scheduling tolerance")
        }
        try requireReaped(pid)
    }

    static func audit(_ mode: String) throws {
        // Warm Swift/Foundation's lazy allocations before comparing descriptor inventories.
        try echo()
        if mode == "repeat" {
            let before = descriptors()
            for _ in 0..<32 { try echo() }
            try require(descriptors() == before, "descriptor leak across repeated capture")
        } else if mode == "child-descriptors" {
            let borrowed = open("/dev/null", O_RDONLY) // Deliberately lacks FD_CLOEXEC.
            try require(borrowed >= 3, "borrowed descriptor")
            defer { close(borrowed) }
            let before = descriptors()
            var childDescriptors: Set<Int32> = []
            try echo(hold: true) { pid in
                var info = [proc_fdinfo](repeating: proc_fdinfo(), count: 128)
                let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &info,
                                         Int32(info.count * MemoryLayout<proc_fdinfo>.stride))
                if bytes > 0 && bytes % Int32(MemoryLayout<proc_fdinfo>.stride) == 0 {
                    childDescriptors = Set(info.prefix(Int(bytes) / MemoryLayout<proc_fdinfo>.stride).map(\.proc_fd))
                }
            }
            try require(childDescriptors == [0, 1, 2], "child inherited unexpected descriptors")
            try require(descriptors() == before, "timeout leaked or closed a borrowed descriptor")
        } else if mode.hasPrefix("closed-") {
            guard let mask = Int(mode.dropFirst(7)), (1...7).contains(mask) else {
                throw AuditFailure.failed("invalid descriptor mask")
            }
            for fd: Int32 in 0...2 where mask & (1 << fd) != 0 { close(fd) }
            let before = descriptors()
            try echo()
            try require(descriptors() == before, "closed standard descriptors were not preserved")
            try require(LaunchctlQuery.capture() != nil, "query failed with closed standard descriptors")
            try require(descriptors() == before, "query leaked descriptors")
        } else if ["ignored-chld", "custom-chld", "no-cldwait"].contains(mode) {
            var disposition = sigaction()
            disposition.__sigaction_u.__sa_handler = mode == "ignored-chld" ? SIG_IGN : SIG_DFL
            if mode == "custom-chld" { disposition.__sigaction_u.__sa_handler = { _ in } }
            if mode == "no-cldwait" { disposition.sa_flags = SA_NOCLDWAIT }
            try require(sigaction(SIGCHLD, &disposition, nil) == 0, "set isolated SIGCHLD")
            let before = descriptors()
            var spawned = false
            do {
                _ = try ContextChild.runEchoFixture(holdInputOpen: false) { _ in spawned = true }
                throw AuditFailure.failed("unsafe SIGCHLD accepted")
            } catch ContextChild.Failure.unsafeReaping {}
            try require(!spawned && LaunchctlQuery.capture() == nil, "unsafe query spawned or succeeded")
            try require(descriptors() == before, "precondition failure leaked descriptors")
        } else if mode == "blocked-chld" {
            var blocked = sigset_t()
            sigemptyset(&blocked)
            sigaddset(&blocked, SIGCHLD)
            try require(pthread_sigmask(SIG_BLOCK, &blocked, nil) == 0, "block isolated SIGCHLD")
            try echo()
            try echo(hold: true)
        } else if mode == "blocked-term" || mode == "ignored-term" {
            if mode == "blocked-term" {
                var blocked = sigset_t()
                sigemptyset(&blocked)
                sigaddset(&blocked, SIGTERM)
                try require(pthread_sigmask(SIG_BLOCK, &blocked, nil) == 0, "block isolated SIGTERM")
            } else {
                var disposition = sigaction()
                disposition.__sigaction_u.__sa_handler = SIG_IGN
                try require(sigaction(SIGTERM, &disposition, nil) == 0, "ignore isolated SIGTERM")
            }
            let before = descriptors()
            let start = DispatchTime.now().uptimeNanoseconds
            try echo(hold: true)
            try require(DispatchTime.now().uptimeNanoseconds - start >=
                        ContextChild.Limits.standard.execution + ContextChild.Limits.standard.termination,
                        "TERM-resistant child did not reach escalation window")
            try require(descriptors() == before, "escalation leaked descriptors")
        } else if mode == "unrelated-child" {
            // A separate direct child must retain its own status throughout collection.
            let executable = strdup("/usr/bin/true")!
            defer { free(executable) }
            var argv: [UnsafeMutablePointer<CChar>?] = [executable, nil]
            var env: [UnsafeMutablePointer<CChar>?] = [nil]
            var unrelated: pid_t = 0
            try require(posix_spawn(&unrelated, executable, nil, nil, &argv, &env) == 0, "spawn unrelated fixture")
            var reaped = false
            defer {
                if !reaped {
                    var status: Int32 = 0
                    while waitpid(unrelated, &status, 0) == -1 && errno == EINTR {}
                }
            }
            try echo(hold: true)
            var status: Int32 = 0
            try require(waitpid(unrelated, &status, WNOHANG) == unrelated && status == 0,
                        "collector stole unrelated child status")
            reaped = true
        } else if mode == "exhaustion" || mode == "exhaustion-closed" {
            if mode == "exhaustion-closed" { for fd: Int32 in 0...2 { close(fd) } }
            var limit = rlimit(rlim_cur: 64, rlim_max: 64)
            try require(setrlimit(RLIMIT_NOFILE, &limit) == 0, "set isolated descriptor ceiling")
            for freeSlots in 0..<5 {
                var held: [Int32] = []
                defer { held.forEach { close($0) } }
                while true {
                    let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
                    if fd < 0 { break }
                    held.append(fd)
                }
                try require(errno == EMFILE && held.count > freeSlots, "fill isolated descriptor table")
                for _ in 0..<freeSlots {
                    // Low slots force the F_DUPFD_CLOEXEC path to fail partway through setup.
                    close(mode == "exhaustion-closed" ? held.removeFirst() : held.removeLast())
                }
                let before = descriptors()
                var spawned = false
                do {
                    _ = try ContextChild.runEchoFixture(holdInputOpen: false) { _ in spawned = true }
                    throw AuditFailure.failed("exhausted setup unexpectedly succeeded")
                } catch ContextChild.Failure.setup {}
                try require(!spawned && descriptors() == before, "partial setup leaked descriptors")
            }
        } else {
            throw AuditFailure.failed("unknown audit mode")
        }
    }

    static func main() {
        // Keep a reporting channel while testing every combination of closed stdin/out/err.
        let report = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 32)
        guard report >= 0, CommandLine.arguments.count == 2 else { exit(2) }
        defer { close(report) }
        let mode = CommandLine.arguments[1]
        let message: String
        let result: Int32
        do { try audit(mode); message = "PASS \(mode)\n"; result = 0 }
        catch { message = "FAIL \(mode): \(error)\n"; result = 1 }
        let bytes = Array(message.utf8)
        _ = bytes.withUnsafeBytes { write(report, $0.baseAddress, $0.count) }
        exit(result)
    }
}
