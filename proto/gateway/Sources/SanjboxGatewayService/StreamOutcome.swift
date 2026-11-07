import SanjboxGatewayCore
import Synchronization

/// Stable audit/HTTP interpretation of errors from a lazy model producer.
/// Provider messages and request data must never be used as a reason.
struct StreamOutcome: Sendable {
    let decision: AuditDecision
    let reason: String
    let status: Int

    static let completed = StreamOutcome(decision: .routed, reason: "", status: 200)
    static func failure(_ error: any Error) -> StreamOutcome {
        if error is CancellationError {
            return StreamOutcome(decision: .cancelled, reason: "cancelled", status: 0)
        }
        switch error as? ModelAPIFailure {
        case .budget: return denied(.modelBudget, status: 403)
        case .rate: return denied(.modelRate, status: 429)
        case .busy: return denied(.handlerCapacity, status: 503)
        case .replay: return denied(.handlerReplay, status: 409)
        default: return StreamOutcome(decision: .failed, reason: "streamFailed", status: 502)
        }
    }

    private static func denied(_ reason: DenialReason, status: Int) -> StreamOutcome {
        StreamOutcome(decision: .deniedByHandler, reason: reason.rawValue, status: status)
    }
}

/// Protect the final audit result as well as the handler's single-use producer.
final class StreamTicket: Sendable {
    private let unused = Mutex(true)
    func consume() -> Bool {
        unused.withLock { value in defer { value = false }; return value }
    }
}
