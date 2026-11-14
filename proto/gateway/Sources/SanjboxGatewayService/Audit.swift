import Foundation

/// Rozhodnutí brány. Texty jsou stabilní součást prototypového kontraktu.
public enum AuditDecision: String, Sendable, Codable {
    /// Požadavek prošel do handleru a handler ho obsloužil bez odmítnutí.
    case routed
    /// Odmítla brána sama, ještě před handlerem (mount, cílový tvar, kapacita).
    case denied
    /// Handler požadavek přijal a sám ho odmítl; `reason` nese důvod.
    case deniedByHandler
    /// SSE producer has not finished; the record already consumes audit capacity.
    case pending
    /// The handler/stream failed; this is not a successful routed operation.
    case failed
    /// The operation was cancelled before a final handler result.
    case cancelled
}

/// Důvod odmítnutí. Texty jsou stabilní součást prototypového kontraktu.
public enum DenialReason: String, Sendable, Codable {
    // MARK: Rozhodnutí brány (`AuditDecision.denied`)

    /// Cesta nespadá pod žádný mount z politiky; nikdy se neposílá dál.
    case operationNotConfigured
    /// Mount existuje v politice, ale operace je vypnutá.
    case operationDisabled
    /// `path` nebo `method` by rozbily kanonický řádek auditu (`|`, řídicí znaky).
    case invalidRequestTarget
    case h1RequestLimit

    // MARK: Rozhodnutí handleru (`AuditDecision.deniedByHandler`)

    /// Handler odpověděl 403 (zakázaná hlavička, metoda, cíl nebo úkon).
    case handlerForbidden
    /// Handler odpověděl jiným odmítnutím 4xx (neplatný cíl, příliš velký vstup).
    case handlerRejected
    case handlerCapacity
    case modelBudget
    case modelRate
    case handlerReplay
}

/// Jeden auditní záznam. Pole jsou typovaná a omezená: záznam nemá volné textové
/// pole, do kterého by mohl proniknout klíč, hlavička nebo tělo požadavku.
///
/// `path`, `method`, `operation` a `reason` jsou volný text, proto se do
/// kanonického řádku zapisují **escapované** (`%` → `%25`, `|` → `%7C`, řídicí
/// znaky → `%XX`). Řádek má vždy právě 7 polí a `AuditRecord.parse` ho vrátí
/// zpět na stejný záznam; hodnota z požadavku tak nemůže podvrhnout jiné pole.
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

    /// Počet polí kanonického řádku; round-trip test na něm stojí.
    public static let fieldCount = 7

    /// Kanonický text jednoho záznamu; stabilní pořadí polí i pořadí záznamů.
    public var canonicalLine: String {
        Self.fieldList(self).joined(separator: "|")
    }

    /// Rozparsuje kanonický řádek zpět na záznam. Vrací `nil`, když řádek nemá
    /// přesně 7 polí nebo některé pole nejde dekódovat; nikdy nehádá.
    public static func parse(_ line: String) -> AuditRecord? {
        let fields = line.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == fieldCount,
              let sequence = UInt64(fields[0]),
              let decision = AuditDecision(rawValue: unescape(String(fields[4]))),
              let status = Int(fields[6]) else { return nil }
        let record = AuditRecord(
            sequence: sequence,
            operation: unescape(String(fields[1])),
            method: unescape(String(fields[2])),
            path: unescape(String(fields[3])),
            decision: decision,
            reason: unescape(String(fields[5])),
            status: status
        )
        guard record.canonicalLine == line else { return nil }
        return record
    }

    /// Pole kanonického řádku tak, jak jdou za sebou (bez oddělovače).
    public static func fieldList(_ record: AuditRecord) -> [String] {
        [String(record.sequence), escape(record.operation), escape(record.method),
         escape(record.path), record.decision.rawValue, escape(record.reason),
         String(record.status)]
    }

    /// Escapuje jen to, co by rozbilo sedmipolí řádek: `%`, `|` a řídicí znaky.
    /// Běžná cesta (`/npm/library-fixture`) zůstává čitelná beze změny.
    static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "%": result += "%25"
            case "|": result += "%7C"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "%%%02X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    /// Inverze k `escape`; neúplné nebo neplatné escape sekvence nechá být.
    static func unescape(_ value: String) -> String {
        guard value.contains("%") else { return value }
        let scalars = Array(value.unicodeScalars)
        var result = ""
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "%", index + 2 < scalars.count,
                  let byte = UInt8(String(String.UnicodeScalarView(scalars[(index + 1)...(index + 2)])), radix: 16)
            else {
                result.unicodeScalars.append(scalar)
                index += 1
                continue
            }
            result.unicodeScalars.append(Unicode.Scalar(byte))
            index += 3
        }
        return result
    }
}

extension AuditRecord: CustomStringConvertible {
    public var description: String { canonicalLine }
}
