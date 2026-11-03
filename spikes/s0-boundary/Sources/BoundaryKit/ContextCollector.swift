import CoreGraphics
import Darwin
import Darwin.membership
import Foundation
import SanjboxProbeKit

enum ContextCollector {
    /// Local collector: common's public context/schema and expectation checks are reused, but its
    /// unbounded launchctl read/wait is not. No window listing, capture, TCC request or service lookup.
    static func capture(groups: Set<UInt32>) throws -> ProbeContext {
        let count = getgroups(0, nil)
        guard count > 0, count <= 128 else { throw BoundaryError.invalid("cannot enumerate kernel groups") }
        var kernel = [gid_t](repeating: 0, count: Int(count))
        let actual = getgroups(count, &kernel)
        guard actual == count else { throw BoundaryError.invalid("kernel groups changed during collection") }
        var audit = auditinfo_addr()
        guard getaudit_addr(&audit, Int32(MemoryLayout<auditinfo_addr>.size)) == 0
        else { throw BoundaryError.invalid("audit identity unavailable") }
        let managerName = try FixedChild.run(.managerName).text
        let managerUID = try FixedChild.run(.managerUID).text
        guard let managerUID = UInt32(managerUID), ["Aqua", "Background"].contains(managerName)
        else { throw BoundaryError.invalid("bootstrap manager unavailable or unsupported") }
        let membership: [[String: Any]] = groups.sorted().map { gid in
            var user = UUID().uuid
            var group = UUID().uuid
            var member: Int32 = 0
            let status = withUnsafeMutableBytes(of: &user) { user in
                withUnsafeMutableBytes(of: &group) { group in
                    let u = user.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let g = group.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    guard mbr_uid_to_uuid(geteuid(), u) == 0, mbr_gid_to_uuid(gid, g) == 0 else { return Int32(-1) }
                    return mbr_check_membership(u, g, &member)
                }
            }
            return ["gid": gid, "isMember": status == 0 ? (member != 0) as Any : NSNull()]
        }
        var window: Any = NSNull()
        if let info = CGSessionCopyCurrentDictionary() as? [String: Any] {
            window = [
                "userID": info["kCGSSessionUserIDKey"] ?? NSNull(),
                "auditSessionID": info["kCGSSessionAuditIDKey"] ?? NSNull(),
                "onConsole": info["kCGSSessionOnConsoleKey"] ?? NSNull(),
                "loginDone": info["kCGSessionLoginDoneKey"] ?? NSNull(),
            ]
        }
        // The common nested context types expose no public memberwise initializer.
        let object: [String: Any] = [
            "pid": getpid(), "parentPID": getppid(), "realUID": getuid(), "effectiveUID": geteuid(),
            "realGID": getgid(), "effectiveGID": getegid(), "kernelGroups": kernel,
            "groupMembership": membership,
            "audit": ["sessionID": audit.ai_asid, "auditUID": audit.ai_auid, "flags": audit.ai_flags],
            "launchdManager": ["name": managerName, "uid": managerUID], "windowSession": window,
        ]
        return try JSONDecoder().decode(ProbeContext.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

/// Intentionally not a command runner: three fixed executable/argument combinations, no user path,
/// environment, arguments or PID. This function exclusively reaps the child it spawns. Foundation
/// Process and asynchronous SIGCHLD handlers are deliberately not used here.
enum FixedChild {
    enum Job { case managerName, managerUID, echo }
    enum TestFault { case holdEchoInputOpen }
    struct Result {
        let data: Data
        let status: Int32
        var text: String { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    static func permitsExclusiveReap(handlerAddress: UInt, flags: Int32) -> Bool {
        handlerAddress == unsafeBitCast(SIG_DFL, to: UInt.self) && flags & SA_NOCLDWAIT == 0
    }
    static func run(_ job: Job, input: Data = Data(), testFault: TestFault? = nil,
                    onSpawn: ((pid_t) -> Void)? = nil) throws -> Result {
        guard input.count <= 256 else { throw BoundaryError.invalid("child input limit") }
        var disposition = sigaction()
        guard sigaction(SIGCHLD, nil, &disposition) == 0,
              permitsExclusiveReap(handlerAddress: unsafeBitCast(disposition.__sigaction_u.__sa_handler, to: UInt.self), flags: disposition.sa_flags)
        else { throw BoundaryError.invalid("exclusive child reaping requires default SIGCHLD without SA_NOCLDWAIT") }
        if testFault != nil && job != .echo { throw BoundaryError.invalid("fault fixture supports only own echo child") }
        let arguments: [String]
        switch job {
        case .managerName: arguments = ["/bin/launchctl", "managername"]
        case .managerUID: arguments = ["/bin/launchctl", "manageruid"]
        case .echo: arguments = ["/bin/cat", "-u"]
        }
        var incoming: [Int32] = [-1, -1], outgoing: [Int32] = [-1, -1]
        guard pipe(&incoming) == 0 else { throw BoundaryError.io("child input pipe failed") }
        defer { incoming.filter { $0 >= 0 }.forEach { close($0) } }
        guard pipe(&outgoing) == 0 else { throw BoundaryError.io("child output pipe failed") }
        defer { outgoing.filter { $0 >= 0 }.forEach { close($0) } }
        let null = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard null >= 0 else { throw BoundaryError.io("child stderr setup failed") }
        defer { close(null) }
        for fd in incoming + outgoing {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw BoundaryError.io("child close-on-exec setup failed") }
        }
        guard fcntl(outgoing[0], F_SETFL, O_NONBLOCK) == 0 else { throw BoundaryError.io("child nonblocking setup failed") }
        // Preload at most 256 bytes into an empty pipe, well below PIPE_BUF, then close its writer.
        let written = input.withUnsafeBytes { write(incoming[1], $0.baseAddress, $0.count) }
        guard written == input.count else { throw BoundaryError.io("child fixture input write failed") }
        if testFault == nil { close(incoming[1]); incoming[1] = -1 }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw BoundaryError.io("child spawn actions failed") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_adddup2(&actions, incoming[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, outgoing[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO) == 0
        else { throw BoundaryError.io("child spawn descriptors failed") }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw BoundaryError.io("child spawn attributes failed") }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
        else { throw BoundaryError.io("child spawn close-on-exec failed") }
        let strings = arguments.map { strdup($0)! }
        let environmentStrings: [String] = ["PATH=/usr/bin:/bin", "LC_ALL=C"]
        let environment = environmentStrings.map { strdup($0)! }
        defer { (strings + environment).forEach { free($0) } }
        var argv: [UnsafeMutablePointer<CChar>?] = strings.map { $0 } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { $0 } + [nil]
        var child: pid_t = 0
        guard posix_spawn(&child, arguments[0], &actions, &attributes, &argv, &envp) == 0, child > 0
        else { throw BoundaryError.io("fixed child spawn failed") }
        onSpawn?(child) // Internal output-only test observation; no PID input or CLI exposure.
        close(incoming[0]); incoming[0] = -1
        close(outgoing[1]); outgoing[1] = -1
        var reaped = false
        var status: Int32 = 0
        func reap() throws {
            guard !reaped else { return }
            let value = waitpid(child, &status, WNOHANG)
            if value == child { reaped = true }
            else if value < 0 && errno != EINTR {
                // Losing ownership must never lead to a signal to a potentially reused PID.
                reaped = true
                throw BoundaryError.conflict("owned child wait status unavailable")
            }
        }
        do {
            var data = Data(), eof = false
            let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            while !eof || !reaped {
                var bytes = [UInt8](repeating: 0, count: 1024)
                let count = read(outgoing[0], &bytes, bytes.count)
                if count > 0 {
                    data.append(contentsOf: bytes.prefix(count))
                    guard data.count <= 8192 else { throw BoundaryError.invalid("child output limit") }
                } else if count == 0 { eof = true }
                else if errno != EAGAIN && errno != EINTR { throw BoundaryError.io("child output read failed") }
                try reap()
                guard DispatchTime.now().uptimeNanoseconds < deadline
                else { throw BoundaryError.invalid("child deadline exceeded") }
                if count <= 0 { usleep(5_000) }
            }
            guard status == 0 else { throw BoundaryError.invalid("owned child did not exit successfully") }
            return Result(data: data, status: status)
        } catch {
            // With the checked default SIGCHLD disposition and no other reaper in this CLI, until
            // our own waitpid succeeds its PID is pinned,
            // even if it exits between the ownership check and kill (it remains an unreaped zombie).
            if !reaped { _ = kill(child, SIGTERM) }
            let grace = DispatchTime.now().uptimeNanoseconds + 200_000_000
            while !reaped && DispatchTime.now().uptimeNanoseconds < grace { try reap(); usleep(5_000) }
            if !reaped { _ = kill(child, SIGKILL) }
            let limit = DispatchTime.now().uptimeNanoseconds + 200_000_000
            while !reaped && DispatchTime.now().uptimeNanoseconds < limit { try reap(); usleep(5_000) }
            guard reaped else { throw BoundaryError.conflict("owned child did not reap after SIGKILL; manual review required") }
            throw error
        }
    }
}
