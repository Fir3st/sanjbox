import Foundation
import Testing
@testable import SanjboxContracts

@Suite("Audit log")
struct AuditLogTests {
    private func recordJSON(sequence: String = "1", timestamp: String = "2026-11-07T12:34:56.789Z",
                            zoneID: String = "a1b2", action: String = "zone.created",
                            outcome: String = "allowed") -> String {
        jsonObject([("schema", "\"sanjbox.audit.v1\""), ("sequence", sequence),
                    ("timestampUTC", "\"\(timestamp)\""), ("zoneID", "\"\(zoneID)\""),
                    ("actorUID", "4501"), ("action", "\"\(action)\""), ("outcome", "\"\(outcome)\"")])
    }

    @Test func roundTripsCanonically() throws {
        let records = [auditRecord(sequence: 1), auditRecord(sequence: 2, action: .zoneStarted),
                       auditRecord(sequence: 3, action: .gateRequestDenied, detail: "deny by policy")]
        let first = try AuditLog.encode(records)
        let decoded = try AuditLog.decode(first)
        #expect(decoded == records)
        #expect(try AuditLog.encode(decoded) == first)
    }

    @Test func rejectsUnknownRecordField() {
        let record = recordJSON().replacingOccurrences(of: "}", with: ",\"payload\":\"x\"}")
        rejection("unknown-field") { _ = try AuditLog.decode(Data("[\(record)]".utf8)) }
    }

    @Test func rejectsMissingRequiredField() {
        let record = "{\"schema\":\"sanjbox.audit.v1\",\"sequence\":1,\"zoneID\":\"a1b2\",\"actorUID\":4501,\"action\":\"zone.created\",\"outcome\":\"allowed\"}"
        rejection("missing-field") { _ = try AuditLog.decode(Data("[\(record)]".utf8)) }
    }

    @Test func rejectsDuplicateKey() {
        let record = "{\"schema\":\"sanjbox.audit.v1\",\"sequence\":1,\"sequence\":2,\"timestampUTC\":\"2026-11-07T12:34:56.789Z\",\"zoneID\":\"a1b2\",\"actorUID\":4501,\"action\":\"zone.created\",\"outcome\":\"allowed\"}"
        rejection("duplicate-key") { _ = try AuditLog.decode(Data("[\(record)]".utf8)) }
    }

    @Test func rejectsUnknownActionOrOutcome() {
        rejection("invalid-value") { _ = try AuditLog.decode(Data("[\(recordJSON(action: "zone.teleported"))]".utf8)) }
        rejection("invalid-value") { _ = try AuditLog.decode(Data("[\(recordJSON(outcome: "maybe"))]".utf8)) }
    }

    @Test func rejectsWrongSchema() {
        let record = recordJSON().replacingOccurrences(of: "sanjbox.audit.v1", with: "sanjbox.audit.v2")
        rejection("invalid-value") { _ = try AuditLog.decode(Data("[\(record)]".utf8)) }
    }

    @Test func rejectsMalformedTimestamp() {
        for timestamp in ["2026-11-07T12:34:56Z", "2026-11-07 12:34:56.789Z", "2026-13-07T12:34:56.789Z",
                          "2026-11-07T24:00:00.000Z", "2026-11-07T12:34:56.789+01:00", "2026-11-07T12:34:56.789"] {
            do {
                _ = try AuditLog.decode(Data("[\(recordJSON(timestamp: timestamp))]".utf8))
                Issue.record("timestamp '\(timestamp)' must be rejected")
            } catch let error as ContractError {
                // Over-long offsets fail the 24-byte field budget before the format check.
                #expect(["invalid-value", "string-limit"].contains(error.code), "timestamp '\(timestamp)': \(error)")
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test func rejectsWrongZoneIDAndZeroSequence() {
        rejection("invalid-identifier") { _ = try AuditLog.decode(Data("[\(recordJSON(zoneID: "A1B2"))]".utf8)) }
        rejection("invalid-range") { _ = try AuditLog.decode(Data("[\(recordJSON(sequence: "0"))]".utf8)) }
    }

    @Test func rejectsNonIncreasingSequence() {
        let records = [auditRecord(sequence: 2), auditRecord(sequence: 2)]
        rejection("sequence-violation") { _ = try AuditLog.encode(records) }
        let decreasing = [auditRecord(sequence: 3), auditRecord(sequence: 1)]
        rejection("sequence-violation") { _ = try AuditLog.encode(decreasing) }
    }

    @Test func rejectsMixedZonesInOneDocument() {
        let records = [auditRecord(sequence: 1), auditRecord(sequence: 2, zoneID: "zz99")]
        rejection("sequence-violation") { _ = try AuditLog.encode(records) }
    }

    @Test func rejectsInvalidSubjectAndDetail() {
        var record = auditRecord(sequence: 1)
        record.subjectID = "NPM_Edge"
        rejection("invalid-identifier") { _ = try AuditLog.encode([record]) }
        record.subjectID = nil
        record.detail = String(repeating: "d", count: AuditRecord.maxDetailBytes + 1)
        rejection("string-limit") { _ = try AuditLog.encode([record]) }
        record.detail = "line\nbreak"
        rejection("invalid-value") { _ = try AuditLog.encode([record]) }
    }

    @Test func rejectsOversizedLogAndRecordCollection() {
        let record = Data("[\(recordJSON())]".utf8)
        rejection("input-too-large") { _ = try AuditLog.decode(record + Data(String(repeating: " ", count: AuditLog.maxBytes).utf8)) }
        let many = "[" + Array(repeating: recordJSON(sequence: "1"), count: AuditLog.maxRecords + 1).joined(separator: ",") + "]"
        rejection("collection-limit") { _ = try AuditLog.decode(Data(many.utf8)) }
    }

    @Test func rejectsNonArrayDocument() {
        rejection("invalid-value") { _ = try AuditLog.decode(Data("{}".utf8)) }
    }
}
