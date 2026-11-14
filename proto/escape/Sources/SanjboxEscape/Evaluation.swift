import Foundation
import SanjboxContracts

public enum SyntheticStatus: String, Codable, Sendable {
    case syntheticPassed, syntheticFailed, incomplete, manualRequired, unsupported
}
/// Probe facts, never a caller-supplied pass verdict. Controls and completeness are independent.
public struct Observation: Codable, Equatable, Sendable {
    public var identityValid: Bool
    public var attempted: Bool
    public var controlValid: Bool
    public var complete: Bool
    public var oracleSatisfied: Bool
    public var detail: String
    public init(identityValid: Bool = true, attempted: Bool = true, controlValid: Bool = true,
                complete: Bool = true, oracleSatisfied: Bool, detail: String) {
        self.identityValid = identityValid; self.attempted = attempted; self.controlValid = controlValid
        self.complete = complete; self.oracleSatisfied = oracleSatisfied; self.detail = detail
    }
}
public struct CaseResult: Codable, Equatable, Sendable {
    public let id: String
    public let status: SyntheticStatus
    /// H6 has no API that promotes a real acceptance case to passed.
    public let acceptanceStatus: String
    public let observation: Observation?
}
public enum Evaluation {
    public static func evaluate(_ item: AcceptanceCase, observation: Observation?) -> CaseResult {
        let status: SyntheticStatus
        switch item.mode {
        case .manual: status = .manualRequired
        case .unsupported: status = .unsupported
        case .synthetic:
            if let observation, observation.identityValid, observation.attempted,
               observation.controlValid, observation.complete {
                status = observation.oracleSatisfied ? .syntheticPassed : .syntheticFailed
            } else { status = .incomplete }
        }
        return CaseResult(id: item.id, status: status, acceptanceStatus: "unverified", observation: observation)
    }
}
public struct HarnessReport: Encodable, Sendable {
    public let schema: String
    public let scope: String
    public let results: [CaseResult]
    public let counterpart: [CounterpartEvidence]
    public let auditJSON: String
    public let cleanupVerified: Bool
    public var counts: [String: Int] {
        Dictionary(grouping: results, by: { $0.status.rawValue }).mapValues(\.count)
    }
    /// Full coverage cannot pass while any case is manual, unsupported or incomplete.
    public var exitCode: Int32 {
        if results.contains(where: { $0.status == .syntheticFailed }) { return 1 }
        if !cleanupVerified || results.contains(where: { $0.status != .syntheticPassed }) { return 3 }
        return 0
    }
    public var summary: String { exitCode == 1 ? "synthetic-failure" : exitCode == 3 ? "incomplete" : "synthetic-only" }

    enum CodingKeys: String, CodingKey {
        case schema, scope, results, counterpart, auditJSON, cleanupVerified, counts, exitCode, summary
    }
    public func encode(to encoder: Encoder) throws {
        var out = encoder.container(keyedBy: CodingKeys.self)
        try out.encode(schema, forKey: .schema); try out.encode(scope, forKey: .scope)
        try out.encode(results, forKey: .results); try out.encode(counterpart, forKey: .counterpart)
        try out.encode(auditJSON, forKey: .auditJSON); try out.encode(cleanupVerified, forKey: .cleanupVerified)
        try out.encode(counts, forKey: .counts); try out.encode(exitCode, forKey: .exitCode)
        try out.encode(summary, forKey: .summary)
    }
    init(results: [CaseResult], counterpart: [CounterpartEvidence], audit: [AuditRecord], cleanupVerified: Bool) throws {
        schema = "sanjbox.escape.synthetic.v1"
        scope = "same-user mocks and owned fixtures; all 155 acceptance cases remain unverified"
        self.results = results; self.counterpart = counterpart; self.cleanupVerified = cleanupVerified
        auditJSON = String(decoding: try AuditLog.encode(audit), as: UTF8.self)
    }
}
