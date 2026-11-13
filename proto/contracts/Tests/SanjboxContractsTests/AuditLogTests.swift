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
                          "2026-02-31T12:34:56.789Z", "2025-02-29T12:34:56.789Z", "2026-04-31T12:34:56.789Z",
                          "2026-00-10T12:34:56.789Z", "2026-01-00T12:34:56.789Z",
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

    @Test func acceptsCalendarLeapDay() throws {
        let decoded = try AuditLog.decode(Data("[\(recordJSON(timestamp: "2024-02-29T12:34:56.789Z"))]".utf8))
        #expect(decoded.count == 1)
    }

    @Test func rejectsWrongZoneIDAndZeroSequence() {
        rejection("invalid-identifier") { _ = try AuditLog.decode(Data("[\(recordJSON(zoneID: "A1B2"))]".utf8)) }
        rejection("invalid-range") { _ = try AuditLog.decode(Data("[\(recordJSON(sequence: "0"))]".utf8)) }
    }

    @Test func rejectsLogThatDoesNotStartAtOne() {
        rejection("sequence-violation") { _ = try AuditLog.encode([auditRecord(sequence: 2)]) }
        rejection("sequence-violation") { _ = try AuditLog.encode([auditRecord(sequence: 7), auditRecord(sequence: 8)]) }
    }

    @Test func rejectsSequenceGap() {
        // 1 is accepted, 3 is not 2: a missing record is a failure, not a warning.
        rejection("sequence-violation") {
            _ = try AuditLog.encode([auditRecord(sequence: 1), auditRecord(sequence: 3)])
        }
    }

    @Test func rejectsSequenceDecrease() {
        // The first two records are valid; the third goes backwards instead of to 3.
        rejection("sequence-violation") {
            _ = try AuditLog.encode([auditRecord(sequence: 1), auditRecord(sequence: 2), auditRecord(sequence: 1)])
        }
    }

    @Test func rejectsDuplicateSequence() {
        rejection("sequence-violation") {
            _ = try AuditLog.encode([auditRecord(sequence: 1), auditRecord(sequence: 1)])
        }
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

    @Test func acceptsExactlyTheByteBudgetAndRejectsOneByteMore() throws {
        let record = Data("[\(recordJSON())]".utf8)
        let atLimit = record + Data(repeating: 0x20, count: AuditLog.maxBytes - record.count)
        #expect(atLimit.count == AuditLog.maxBytes)
        let decoded = try AuditLog.decode(atLimit)
        #expect(decoded.count == 1)
        rejection("input-too-large") { _ = try AuditLog.decode(atLimit + Data(" ".utf8)) }
    }

    @Test func acceptsExactlyMaxRecordsAndRejectsOneMore() throws {
        let atLimit = "[" + Array(1...AuditLog.maxRecords).map { recordJSON(sequence: String($0)) }
            .joined(separator: ",") + "]"
        let decoded = try AuditLog.decode(Data(atLimit.utf8))
        #expect(decoded.count == AuditLog.maxRecords)
        #expect(decoded.last?.sequence == UInt64(AuditLog.maxRecords))

        let overLimit = "[" + Array(1...(AuditLog.maxRecords + 1)).map { recordJSON(sequence: String($0)) }
            .joined(separator: ",") + "]"
        rejection("collection-limit") { _ = try AuditLog.decode(Data(overLimit.utf8)) }
    }

    @Test func rejectsNonArrayDocument() {
        rejection("invalid-value") { _ = try AuditLog.decode(Data("{}".utf8)) }
    }

    @Test func encoderRejectsOversizedValidRecords() throws {
        let records = (1...AuditLog.maxRecords).map {
            auditRecord(sequence: UInt64($0), detail: String(repeating: "d", count: AuditRecord.maxDetailBytes))
        }
        try AuditLog.validate(records)
        rejection("input-too-large") { _ = try AuditLog.encode(records) }
        // JSON escaping counts too: the decoded detail is 512 bytes but its wire string is larger.
        let escaped = (1...1024).map {
            auditRecord(sequence: UInt64($0), detail: String(repeating: "\\", count: AuditRecord.maxDetailBytes))
        }
        rejection("input-too-large") { _ = try AuditLog.encode(escaped) }
    }

    @Test func encoderAcceptsExactByteBudgetAndRejectsOneMore() throws {
        var records = (1...2048).map { auditRecord(sequence: UInt64($0), detail: "") }
        var remaining = AuditLog.maxBytes - (try AuditLog.encode(records)).count
        for index in records.indices {
            let size = min(remaining, AuditRecord.maxDetailBytes)
            records[index].detail = String(repeating: "d", count: size)
            remaining -= size
        }
        #expect(remaining == 0)
        let wire = try AuditLog.encode(records)
        #expect(wire.count == AuditLog.maxBytes)
        #expect(try AuditLog.decode(wire) == records)
        let index = try #require(records.firstIndex { ($0.detail?.utf8.count ?? 0) < AuditRecord.maxDetailBytes })
        records[index].detail! += "d"
        rejection("input-too-large") { _ = try AuditLog.encode(records) }
    }

}
