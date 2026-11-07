import Foundation

/// Rozhodnutí brány. Texty jsou stabilní součást prototypového kontraktu.
public enum AuditDecision: String, Sendable, Codable {
    case routed
    case denied
}

/// Důvod odmítnutí na úrovni brány (ne uvnitř handleru).
public enum DenialReason: String, Sendable, Codable {
    /// Cesta nespadá pod žádný mount z politiky; nikdy se neposílá dál.
    case operationNotConfigured
    /// Mount existuje v politice, ale operace je vypnutá.
    case operationDisabled
    /// Kapacita auditu je vyčerpaná; nový požadavek se odmítne (nezahazuje historii).
    case auditSaturated
}

/// Jeden auditní záznam. Pole jsou typovaná a omezená: záznam nemá volné textové
/// pole, do kterého by mohl proniknout klíč, hlavička nebo tělo požadavku.
public struct AuditRecord: Sendable, Equatable, Codable {
    public let sequence: UInt64
    public let operation: String
    public let method: String
    public let path: String
    public let decision: AuditDecision
    public let reason: String
    public let status: Int

    public init(sequence: UInt64, operation: String, method: String, path: String,
                decision: AuditDecision, reason: String, status: Int) {
        self.sequence = sequence
        self.operation = operation
        self.method = method
        self.path = path
        self.decision = decision
        self.reason = reason
        self.status = status
    }

    /// Kanonický text jednoho záznamu; stabilní pořadí polí i pořadí záznamů.
    public var canonicalLine: String {
        "\(sequence)|\(operation)|\(method)|\(path)|\(decision.rawValue)|\(reason)|\(status)"
    }
}

extension AuditRecord: CustomStringConvertible {
    public var description: String { canonicalLine }
}
