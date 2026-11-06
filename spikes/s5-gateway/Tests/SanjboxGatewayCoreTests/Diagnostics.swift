import Foundation
@testable import SanjboxGatewayCore

/// Temporary stress-branch instrumentation; never merged.
enum Diag {
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
    static func log(_ message: String) { print(String(format: "DIAG %.3f ", now()) + message) }
    static func trace(_ message: String) { if diagMode != "off" { DiagTrace.shared.add(message) } }
    static func blocking<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let start = now()
        defer {
            let elapsed = now() - start
            if elapsed > 0.05 { log("\(label) \(Thread.isMainThread ? "MAIN" : "bg") \(Int(elapsed * 1000))ms start=\(String(format: "%.3f", start))") }
        }
        return try body()
    }
}

/// Measures main-queue (main actor) round-trip latency from a plain thread.
final class MainLagProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var worst = 0.0
    private var worstAt = 0.0
    init() {
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let start = Diag.now()
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                done.wait()
                let lag = Diag.now() - start
                lock.withLock { if lag > worst { worst = lag; worstAt = start } }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }
    func stop() -> String {
        lock.withLock {
            running = false
            return "worstMainLag=\(Int(worst * 1000))ms at=\(String(format: "%.3f", worstAt))"
        }
    }
}

import Testing

/// Runs beside the whole suite and reports the worst main-actor stall it saw.
@Test func zzDiagnosticMainActorLagMonitor() async throws {
    let probe = MainLagProbe(), began = Diag.now()
    try await Task.sleep(for: .seconds(12))
    Diag.log("monitor began=\(String(format: "%.3f", began)) \(probe.stop())")
}
