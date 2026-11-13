import Darwin
import Foundation

/// Fixed own-domain metadata queries; no caller-supplied executable, arguments or PID.
enum LaunchctlQuery {
    enum Command: String { case managerName = "managername", managerUID = "manageruid" }

    static func capture(run: (Command) throws -> Data = { try ContextChild.run($0) }) -> ProbeContext.LaunchdManager? {
        guard let nameData = try? run(.managerName), let name = line(nameData),
              let uidData = try? run(.managerUID), let uidText = line(uidData),
              uidText.utf8.allSatisfy({ (48...57).contains($0) }), let uid = UInt32(uidText)
        else { return nil }
        return .init(name: name, uid: uid)
    }

    // Keep manager names open-ended (e.g. Aqua, Background, System, LoginWindow).
    // Accept surrounding whitespace as before, but never replacement UTF-8, embedded
    // newlines, NULs or other control characters masquerading as a successful reply.
    static func line(_ data: Data) -> String? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
        }) else { return nil }
        return value
    }
}

/// The collector below is shared by real fixed children and deterministic I/O fixtures.
/// A child owns its wait status exclusively; callers must not use a competing wait(-1)
/// reaper or change SIGCHLD while collection is in progress.
protocol ContextChildIO {
    func now() -> UInt64
    func readOutput(maximum: Int) -> ContextChild.Read
    func wait() -> ContextChild.Wait
    func signal(_ value: Int32) -> Bool
    func pause()
}

enum ContextChild {
    enum Failure: Error, Equatable {
        case setup, unsafeReaping, deadline, outputLimit, read, wait, unsuccessfulExit, cleanupDeadline
    }
    enum Read { case bytes(Data), eof, retry, failed }
    enum Wait { case running, interrupted, exited(Int32), lost }
    struct Limits {
        let execution: UInt64
        let termination: UInt64
        let kill: UInt64
        let output: Int
        static let standard = Limits(execution: 2_000_000_000, termination: 200_000_000,
                                     kill: 200_000_000, output: 8192)
    }

    static func permitsExclusiveReap(handlerAddress: UInt, flags: Int32) -> Bool {
        handlerAddress == unsafeBitCast(SIG_DFL, to: UInt.self) && flags & SA_NOCLDWAIT == 0
    }

    static func run(_ command: LaunchctlQuery.Command) throws -> Data {
        let child = try OwnedContextChild(command: command)
        defer { child.closeDescriptors() }
        return try collect(child)
    }

    /// Internal test seam: only /bin/cat with a fixed synthetic input. Not public or CLI reachable.
    static func runEchoFixture(holdInputOpen: Bool, onSpawn: (pid_t) -> Void) throws -> Data {
        let child = try OwnedContextChild(command: nil, holdFixtureInputOpen: holdInputOpen)
        defer { child.closeDescriptors() }
        onSpawn(child.pid) // Observation only; no PID input to the runner.
        return try collect(child)
    }

    static func collect(_ child: any ContextChildIO, limits: Limits = .standard) throws -> Data {
        var owned = true
        var status: Int32?
        func reap() throws {
            guard owned else { return }
            switch child.wait() {
            case .running, .interrupted: break
            case .exited(let value): owned = false; status = value
            case .lost:
                // ECHILD / any unexpected wait failure: never signal a possibly reused PID.
                owned = false
                throw Failure.wait
            }
        }
        func finishWaiting(for duration: UInt64) throws {
            let start = child.now()
            while owned && child.now() &- start < duration {
                try reap()
                if owned { child.pause() }
            }
        }
        let start = child.now()
        func checkDeadline() throws {
            guard child.now() &- start < limits.execution else { throw Failure.deadline }
        }
        do {
            var output = Data(), eof = false
            while true {
                try checkDeadline()
                if !eof {
                    switch child.readOutput(maximum: min(1024, limits.output - output.count + 1)) {
                    case .bytes(let bytes):
                        guard bytes.count <= limits.output - output.count else { throw Failure.outputLimit }
                        output.append(bytes)
                    case .eof: eof = true
                    case .retry: break // EAGAIN / EINTR; the same monotonic deadline still applies.
                    case .failed: throw Failure.read
                    }
                }
                try checkDeadline()
                try reap()
                try checkDeadline()
                if eof && status != nil {
                    guard status == 0 else { throw Failure.unsuccessfulExit }
                    return output
                }
                child.pause()
            }
        } catch {
            // EOF does not establish exit; exit does not establish EOF (inherited pipe writer).
            // An unreaped direct child pins its PID under the exclusive-reaper contract.
            if owned {
                try reap()
                if owned {
                    guard child.signal(SIGTERM) else { throw Failure.unsafeReaping }
                    try finishWaiting(for: limits.termination)
                }
                if owned {
                    guard child.signal(SIGKILL) else { throw Failure.unsafeReaping }
                    try finishWaiting(for: limits.kill)
                }
                guard !owned else { throw Failure.cleanupDeadline }
            }
            throw error
        }
    }
}

/// Synchronous, exact-child waitpid only; no Foundation Process reaper, process groups,
/// detached workers or waitpid(-1). setup/spawn and OS scheduling are not hard real-time.
private final class OwnedContextChild: ContextChildIO {
    let pid: pid_t
    private var output: Int32
    private var heldInput: Int32

    private static func safeReaping() -> Bool {
        var disposition = sigaction()
        return sigaction(SIGCHLD, nil, &disposition) == 0 && ContextChild.permitsExclusiveReap(
            handlerAddress: unsafeBitCast(disposition.__sigaction_u.__sa_handler, to: UInt.self),
            flags: disposition.sa_flags)
    }

    init(command: LaunchctlQuery.Command?, holdFixtureInputOpen: Bool = false) throws {
        guard Self.safeReaping() else { throw ContextChild.Failure.unsafeReaping }
        var descriptors: [Int32] = []
        defer { descriptors.forEach { _ = Darwin.close($0) } }
        func retainDescriptor(_ fd: Int32) throws -> Int32 {
            guard fd >= 0 else { throw ContextChild.Failure.setup }
            // Keep spawn sources clear of stdin/out/err, even when the caller closed one.
            if fd < 3 {
                let moved = fcntl(fd, F_DUPFD_CLOEXEC, 3)
                _ = Darwin.close(fd)
                guard moved >= 0 else { throw ContextChild.Failure.setup }
                descriptors.append(moved)
                return moved
            }
            descriptors.append(fd)
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw ContextChild.Failure.setup }
            return fd
        }
        func makePipe() throws -> (Int32, Int32) {
            var pair: [Int32] = [-1, -1]
            guard pipe(&pair) == 0 else { throw ContextChild.Failure.setup }
            // Register both before fallible setup so every failure closes both ends.
            let first: Int32
            do { first = try retainDescriptor(pair[0]) }
            catch { _ = Darwin.close(pair[1]); throw error }
            return (first, try retainDescriptor(pair[1]))
        }
        let (reader, writer) = try makePipe()
        let null = try retainDescriptor(open("/dev/null", O_RDWR | O_CLOEXEC))
        guard fcntl(reader, F_SETFL, O_NONBLOCK) == 0 else { throw ContextChild.Failure.setup }
        var input = null, retainedInput: Int32 = -1
        let arguments: [String]
        if let command {
            arguments = ["/bin/launchctl", command.rawValue]
        } else {
            arguments = ["/bin/cat", "-u"]
            let (fixtureReader, fixtureWriter) = try makePipe()
            input = fixtureReader
            let bytes = Array("context-child-fixture\n".utf8)
            guard bytes.withUnsafeBytes({ write(fixtureWriter, $0.baseAddress, $0.count) }) == bytes.count
            else { throw ContextChild.Failure.setup }
            if holdFixtureInputOpen { retainedInput = fixtureWriter }
            else {
                _ = Darwin.close(fixtureWriter)
                descriptors.removeAll { $0 == fixtureWriter }
            }
        }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ContextChild.Failure.setup }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, writer, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO) == 0
        else { throw ContextChild.Failure.setup }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw ContextChild.Failure.setup }
        defer { posix_spawnattr_destroy(&attributes) }
        // No caller descriptors or DYLD/compiler environment reach launchctl.
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
        else { throw ContextChild.Failure.setup }
        let strings = (arguments + ["PATH=/usr/bin:/bin", "LC_ALL=C"]).map { $0.withCString { strdup($0) } }
        defer { strings.forEach { free($0) } }
        guard strings.allSatisfy({ $0 != nil }) else { throw ContextChild.Failure.setup }
        var argv = Array(strings.prefix(arguments.count)) + [nil]
        var env = Array(strings.suffix(2)) + [nil]
        var spawned: pid_t = 0
        guard posix_spawn(&spawned, arguments[0], &actions, &attributes, &argv, &env) == 0, spawned > 0
        else { throw ContextChild.Failure.setup }
        pid = spawned
        output = reader
        heldInput = retainedInput
        descriptors.removeAll { $0 == reader || $0 == retainedInput }
    }

    func closeDescriptors() {
        if output >= 0 { _ = Darwin.close(output); output = -1 }
        if heldInput >= 0 { _ = Darwin.close(heldInput); heldInput = -1 }
    }
    deinit { closeDescriptors() }
    func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    func pause() { usleep(5_000) }
    func readOutput(maximum: Int) -> ContextChild.Read {
        var bytes = [UInt8](repeating: 0, count: maximum)
        let count = read(output, &bytes, bytes.count)
        if count > 0 { return .bytes(Data(bytes.prefix(count))) }
        if count == 0 { return .eof }
        return errno == EAGAIN || errno == EINTR ? .retry : .failed
    }
    func wait() -> ContextChild.Wait {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return .exited(status) }
        if result == 0 { return .running }
        return errno == EINTR ? .interrupted : .lost
    }
    func signal(_ value: Int32) -> Bool {
        // Recheck the precondition; never restore/replace a caller's signal handler.
        guard Self.safeReaping() else { return false }
        // ESRCH is still followed by exact-child waitpid; no other PID is tried.
        return Darwin.kill(pid, value) == 0 || errno == ESRCH
    }
}
