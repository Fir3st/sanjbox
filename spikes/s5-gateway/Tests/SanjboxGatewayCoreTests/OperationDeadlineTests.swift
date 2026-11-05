import Foundation
import Testing
@testable import SanjboxGatewayCore

@Test func boundedOperationRejectsSynchronousLateValueRegardlessOfTimerScheduling() async throws {
    // Deliberately occupy one executor briefly without a suspension point. The
    // oracle is the absolute deadline, not which task the scheduler runs first.
    await #expect(throws: UpstreamFailure.timedOut) {
        _ = try await boundedOperation(timeout: .milliseconds(5)) {
            let until = ContinuousClock.now.advanced(by: .milliseconds(25))
            while ContinuousClock.now < until {}
            return "late synthetic value"
        }
    }
}

@Test func boundedOperationChecksCancelledParentEvenWhenChildIgnoresCancellation() async throws {
    let task = Task {
        try await boundedOperation(timeout: .seconds(5)) {
            try? await Task.sleep(for: .seconds(2))
            return "discard this synthetic value"
        }
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(try await boundedOperation(timeout: .seconds(5)) { 42 } == 42)
}
