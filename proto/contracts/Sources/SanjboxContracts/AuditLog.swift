import Foundation

/// Documented action vocabulary of `sanjbox.audit.v1`. Closed on purpose: an unknown action is a
/// decoding error, not an extra string that later readers have to interpret.
public enum AuditAction: String, CaseIterable, Codable, Sendable {
    case zoneCreated = "zone.created"
    case zoneStarted = "zone.started"
    case zonePaused = "zone.paused"
    case zoneResumed = "zone.resumed"
    case zoneStopped = "zone.stopped"
    case zoneCleaned = "zone.cleaned"
    case policyApplied = "policy.applied"
    case gateRequestDenied = "gate.request.denied"
    case exportCompleted = "export.completed"
}

public enum AuditOutcome: String, CaseIterable, Codable, Sendable {
    case allowed
    case denied
    case failed
}

/// One audit record with a stable, closed key set:
/// `schema, sequence, timestampUTC, zoneID, actorUID, action, outcome, subjectID?, detail?`.
public struct AuditRecord: Codable, Equatable, Sendable {
    public static let schemaName = "sanjbox.audit.v1"
    public static let maxDetailBytes = 512
    public static let keys = ["schema", "sequence", "timestampUTC", "zoneID", "actorUID", "action", "outcome",
                              "subjectID", "detail"]

    public var schema: String
    /// Strictly increasing within one log, starting at 1. Gaps are a failure, not a warning.
    public var sequence: UInt64
    /// Fixed-format UTC timestamp `YYYY-MM-DDTHH:MM:SS.sssZ` (24 bytes, millisecond precision).
    public var timestampUTC: String
    public var zoneID: String
    /// 0 denotes the host control plane; zone actions use the zone UID.
    public var actorUID: UInt32
    public var action: AuditAction
    public var outcome: AuditOutcome
    /// Optional plan identifier of the object the action applied to (gate, export, policy).
    public var subjectID: String?
    /// Optional bounded, control-character-free explanation. Never a secret or a payload dump.
    public var detail: String?

    public init(schema: String = AuditRecord.schemaName, sequence: UInt64, timestampUTC: String, zoneID: String,
                actorUID: UInt32, action: AuditAction, outcome: AuditOutcome, subjectID: String? = nil,
                detail: String? = nil) {
        self.schema = schema
        self.sequence = sequence
        self.timestampUTC = timestampUTC
        self.zoneID = zoneID
        self.actorUID = actorUID
        self.action = action
        self.outcome = outcome
        self.subjectID = subjectID
        self.detail = detail
    }

    static let shape = Shape.object([
        "schema": .scalar(maxBytes: 64),
        "sequence": .integer(minimum: 1, maximum: UInt64.max),
        "timestampUTC": .scalar(maxBytes: 24),
        "zoneID": .scalar(maxBytes: 8),
        "actorUID": .integer(minimum: 0, maximum: UInt64(UInt32.max)),
        "action": .scalar(maxBytes: 32),
        "outcome": .scalar(maxBytes: 16),
        "subjectID": .optionalScalar(maxBytes: 32),
        "detail": .optionalScalar(maxBytes: AuditRecord.maxDetailBytes),
    ])

    public func validate() throws {
        guard schema == Self.schemaName else {
            throw ContractError("invalid-value", "schema \(schema) != \(Self.schemaName)")
        }
        guard sequence >= 1 else { throw ContractError.invalidRange("sequence") }
        guard Self.isTimestamp(timestampUTC) else {
            throw ContractError.invalidValue("timestampUTC must be YYYY-MM-DDTHH:MM:SS.sssZ")
        }
        guard Identifier.isValidZoneID(zoneID) else { throw ContractError.invalidIdentifier("zoneID") }
        if let subjectID, !Identifier.isValidPlanID(subjectID) {
            throw ContractError.invalidIdentifier("subjectID")
        }
        if let detail {
            guard detail.utf8.count <= Self.maxDetailBytes else {
                throw ContractError("string-limit", "detail \(detail.utf8.count) > \(Self.maxDetailBytes)")
            }
            guard !detail.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
                throw ContractError("invalid-value", "detail contains control characters")
            }
        }
    }

    /// Accepts exactly `YYYY-MM-DDTHH:MM:SS.sssZ`; no timezone offsets, no local time, no leap second.
    public static func isTimestamp(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 24 else { return false }
        func digits(_ range: Range<Int>) -> Int? {
            let slice = bytes[range]
            guard slice.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return slice.reduce(0) { $0 * 10 + Int($1 - 48) }
        }
        guard bytes[4] == 45, bytes[7] == 45, bytes[10] == 84, bytes[13] == 58, bytes[16] == 58,
              bytes[19] == 46, bytes[23] == 90,
              let year = digits(0..<4), let month = digits(5..<7), let day = digits(8..<10),
              let hour = digits(11..<13), let minute = digits(14..<16), let second = digits(17..<19),
              digits(20..<23) != nil else { return false }
        guard (1...12).contains(month), (0...23).contains(hour), (0...59).contains(minute),
              (0...59).contains(second) else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let monthLengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...monthLengths[month - 1]).contains(day)
    }
}

/// Audit log document format: a bounded JSON array of `AuditRecord` with strictly increasing
/// `sequence`, one zone per document and a closed key set per record.
public enum AuditLog {
    public static let maxBytes = 1024 * 1024
    public static let maxRecords = 4096

    public static func decode(_ data: Data) throws -> [AuditRecord] {
        let records = try StrictJSON.decode(data, shape: .array(AuditRecord.shape, max: maxRecords),
                                            limit: maxBytes, arrayLimit: maxRecords, as: [AuditRecord].self)
        try validate(records)
        return records
    }

    public static func encode(_ records: [AuditRecord]) throws -> Data {
        try validate(records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(records)
        guard data.count <= maxBytes else {
            throw ContractError.inputTooLarge("audit log \(data.count) > \(maxBytes)")
        }
        return data
    }

    public static func validate(_ records: [AuditRecord]) throws {
        guard records.count <= maxRecords else {
            throw ContractError("collection-limit", "\(records.count) > \(maxRecords)")
        }
        var previousSequence: UInt64 = 0
        var zoneID: String?
        for record in records {
            try record.validate()
            // Not merely monotonic: the first record is 1 and every later record is exactly the
            // previous sequence plus one. A gap, a start above 1 and a decrease are all failures.
            let expected = previousSequence + 1
            guard record.sequence == expected else {
                throw ContractError("sequence-violation", "sequence \(record.sequence), expected \(expected)")
            }
            previousSequence = record.sequence
            if let zoneID, zoneID != record.zoneID {
                throw ContractError("sequence-violation", "mixed zones \(zoneID) and \(record.zoneID)")
            }
            zoneID = record.zoneID
        }
    }
}
