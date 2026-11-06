import Foundation

/// Runs a fixture tool and suspends until it exits. Never use waitUntilExit() in
/// these tests: the main actor serves every GatewayServer session in the process,
/// so blocking it stalls loopback I/O of tests running in parallel suites.
func runUntilExit(_ process: Process) async throws -> Int32 {
    try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do { try process.run() } catch { continuation.resume(throwing: error) }
    }
}
