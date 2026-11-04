import Foundation

/// Exactly one payload. Original recording schema and immutable prior evidence remain unchanged.
public struct SupplementaryBundle: Codable, Sendable {
    public var schemaVersion = 1
    public var login: [LoginAttempt]?
    public var memory: [ProcessMemoryRecording]?
    public var workloads: [ApplicationWorkload]?
    public init(login: [LoginAttempt]? = nil, memory: [ProcessMemoryRecording]? = nil, workloads: [ApplicationWorkload]? = nil) {
        self.login = login; self.memory = memory; self.workloads = workloads
    }
}
public struct SupplementaryReport: Codable, Sendable {
    public var scope = "supplementary instrumentation only; all externally supplied claims require independent provenance review; no S1 verdict"
    public var evidenceComplete: Bool
    public var login: LoginReport?
    public var memory: ProcessMemoryReport?
    public var workloads: [ApplicationWorkloadReport]?
}
public enum SupplementaryAnalyzer {
    public static func evaluate(_ bundle: SupplementaryBundle) throws -> SupplementaryReport {
        try require(bundle.schemaVersion == 1 && [bundle.login != nil, bundle.memory != nil, bundle.workloads != nil].filter({ $0 }).count == 1, "exactly one supplementary payload required")
        if let values = bundle.login {
            let result = try login(values)
            return SupplementaryReport(evidenceComplete: result.attempts.allSatisfy(\.timingEvidenceComplete), login: result)
        }
        if let values = bundle.memory {
            let result = try memory(values)
            return SupplementaryReport(evidenceComplete: result.processes.allSatisfy(\.evidenceComplete), memory: result)
        }
        let result = try workloads(bundle.workloads!)
        return SupplementaryReport(evidenceComplete: result.allSatisfy(\.recordComplete), workloads: result)
    }
}
