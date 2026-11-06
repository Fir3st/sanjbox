import Foundation

public enum UpstreamFailure: Error, Equatable, Sendable {
    case busy, timedOut, connectionFailed, tlsFailed, invalidRequest
    case malformedResponse, unsupportedResponse, truncatedResponse, unexpectedSSE
}

/// The lock protects both early completion (including cancellation before install)
/// and callback races. No continuation is ever resumed while holding the lock.
final class IOResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Cancelling a Network operation closes its socket. libc DNS is not cancellable;
/// its bounded worker retains its slot until the operating-system call returns.
func boundedIO<Value: Sendable>(timeout: Duration,
                               cancel: @escaping @Sendable () -> Void = {},
                               start: @escaping @Sendable (IOResult<Value>) -> Void) async throws -> Value {
    try Task.checkCancellation()
    guard timeout > .zero else { throw UpstreamFailure.timedOut }
    let result = IOResult<Value>()
    let timer = Task {
        do { try await Task.sleep(for: timeout) } catch { return }
        result.finish(.failure(UpstreamFailure.timedOut))
        cancel()
    }
    defer { timer.cancel() }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            result.install(continuation)
            start(result)
        }
    } onCancel: {
        result.finish(.failure(CancellationError()))
        cancel()
    }
}

final class Capacity: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private let maximum: Int
    init(_ maximum: Int) { precondition(maximum > 0); self.maximum = maximum }
    func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active < maximum else { return false }
        active += 1
        return true
    }
    func release() { lock.lock(); active -= 1; lock.unlock() }
}

/// Structured timeout for cooperative async dependencies (the system resolver
/// releases its caller on cancellation even while libc retains a bounded slot).
func boundedOperation<Value: Sendable>(timeout: Duration,
                                      operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
    try Task.checkCancellation()
    guard timeout > .zero else { throw UpstreamFailure.timedOut }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    let value = try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            let value = try await operation()
            try Task.checkCancellation()
            // A timer task can be scheduled late (e.g. a synchronous dependency
            // occupies an executor). Winning the race is not proof of timeliness.
            guard clock.now < deadline else { throw UpstreamFailure.timedOut }
            return value
        }
        group.addTask {
            try await clock.sleep(until: deadline)
            throw UpstreamFailure.timedOut
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
    // Structured cancellation waits for children, which may finish after the
    // deadline. Never publish their discarded/late result or swallow cancellation.
    try Task.checkCancellation()
    guard clock.now < deadline else { throw UpstreamFailure.timedOut }
    return value
}

/// Temporary stress-branch instrumentation; never merged. Buffered in memory so
/// tracing does not perturb timing; tests dump it only after a failure.
public final class DiagTrace: @unchecked Sendable {
    public static let shared = DiagTrace()
    private let lock = NSLock()
    private var events: [(Double, String)] = []
    public func add(_ message: String) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock { events.append((now, message)); if events.count > 20_000 { events.removeFirst(10_000) } }
    }
    public func dump(since: Double) -> [String] {
        lock.withLock { events.filter { $0.0 >= since }.map { String(format: "%.3f ", $0.0) + $0.1 } }
    }
}
public let diagMode = ProcessInfo.processInfo.environment["SANJBOX_DIAG"] ?? "off"
func diag(_ message: String) { if diagMode != "off" { DiagTrace.shared.add(message) } }
