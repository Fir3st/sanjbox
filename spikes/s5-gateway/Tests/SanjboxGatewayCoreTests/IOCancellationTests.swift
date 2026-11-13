import Foundation
import Testing
@testable import SanjboxGatewayCore

@Test func boundedIOCancellationBeforeCompletionDiscardsLateSuccess() async throws {
    let task = Task {
        try await boundedIO(timeout: .seconds(30)) { (result: IOResult<Int>) in
            // Cancel synchronously after the handler is installed, without a
            // second task or timer needing to win an executor scheduling race.
            withUnsafeCurrentTask { current in
                #expect(current != nil)
                current?.cancel()
            }
            result.finish(.success(42))
        }
    }
    await #expect(throws: CancellationError.self) { _ = try await task.value }
}

@Test func boundedIOCommittedTimeoutIsNotReplacedByLaterCancellation() async throws {
    let task = Task {
        try await boundedIO(timeout: .seconds(30)) { (result: IOResult<Int>) in
            // The real DNS timeout test covers the timer. Here commit its error
            // synchronously to make the timeout-before-cancellation order exact.
            result.finish(.failure(UpstreamFailure.timedOut))
            withUnsafeCurrentTask { current in
                #expect(current != nil)
                current?.cancel()
            }
            result.finish(.success(42))
        }
    }
    await #expect(throws: UpstreamFailure.timedOut) { _ = try await task.value }
}
