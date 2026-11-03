import Foundation

/// One line of a run protocol (`docs/evidence/<gate>/<run>/raw/*.jsonl`).
///
/// Every probe writes the context it actually ran in next to its outcome, so a verdict can
/// always be traced back to the credentials and session of the measurement (GUIDE §7).
public struct RunRecord: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var probe: String
    /// Test case ID from COVERAGE.md, e.g. `FS-01`.
    public var caseID: String?
    public var outcome: Outcome
    public var context: ProbeContext
    public var mismatches: [Mismatch]
    public var details: [String: String]

    /// PLAN §Akceptační kontrakt. `invalidMeasurement` is not a verdict about the boundary:
    /// the probe ran with the wrong credentials or session and the run must be repeated.
    public enum Outcome: String, Codable, Sendable {
        case passed, failed, unclear, invalidMeasurement
    }

    public init(
        timestamp: Date = Date(), probe: String, caseID: String?, outcome: Outcome,
        context: ProbeContext, mismatches: [Mismatch] = [], details: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.probe = probe
        self.caseID = caseID
        self.outcome = outcome
        self.context = context
        self.mismatches = mismatches
        self.details = details
    }
}
