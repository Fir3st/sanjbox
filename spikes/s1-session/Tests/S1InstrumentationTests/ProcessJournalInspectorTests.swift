import CryptoKit
import Foundation
import Testing
@testable import S1Instrumentation

private func journalPoint(_ time: Double = 100, slot: Int = 1) -> ProcessSeriesPoint {
    let identity = TestProcessIdentity(pid: Int32(40 + slot), uid: 4501, realUID: 4501, startSeconds: 1_800_000_000, startMicroseconds: 7)
    return ProcessSeriesPoint(slot: slot, readStarted: time, time: time + 0.001, state: .sampled,
        before: identity, after: identity, physicalFootprintBytes: 0, residentBytes: 99)
}
private func journalRow(_ point: ProcessSeriesPoint = journalPoint(), sequence: Int = 0, runID: String = "fixture-journal-inspector", window: Window = Window(start: 100, end: 103)) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(ProcessSeriesJournalEntry(runID: runID, sequence: sequence, window: window, point: point))
    data.append(10); return data
}
private func journalPlan() throws -> Data {
    try encoded(ProcessSeriesPlan(runID: "fixture-journal-inspector", seconds: 3,
        registrations: [TestProcessRegistration(slot: 1, identity: journalPoint().before!, role: .application, provenanceSHA256: String(repeating: "a", count: 64))]))
}
private func inspectText(_ text: String) throws -> ProcessJournalInspection { try ProcessJournalInspector.inspect(Data(text.utf8)) }

@Test func inspectorReadsActualWriterAndRetainsZeroVersusFailure() throws {
    let dataset = try Dataset(runID: "fixture-inspector-" + UUID().uuidString, role: "process-series")
    let writer = try dataset.processSeriesJournal(runID: "fixture-journal-inspector")
    try writer.append(journalPoint(), window: Window(start: 100, end: 103))
    let failed = ProcessSeriesPoint(slot: 1, readStarted: 101, time: 101.001, state: .unreadableBefore, errorCode: 3)
    try writer.append(failed, window: Window(start: 100, end: 103))
    let bytes = try Data(contentsOf: URL(fileURLWithPath: dataset.path + "/samples.jsonl"))
    let report = try ProcessJournalInspector.inspect(bytes, suppliedPlanJSON: journalPlan())
    #expect(!report.structuralError && report.rows.count == 2)
    #expect(report.rows[0].point.physicalFootprintBytes == 0 && report.rows[0].point.residentBytes == 99)
    #expect(report.rows[1].point.physicalFootprintBytes == nil && report.rows[1].point.residentBytes == nil)
    #expect(report.rows[1].line == 2 && report.rows[1].bytes.start == report.rows[0].bytes.end)
    #expect(report.contiguousPrefixBytes == bytes.count && report.inputBytes == bytes.count)
    #expect(report.inputSHA256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    #expect(report.status == "incomplete-unverified" && !report.acquisitionComplete && !report.identityAuthenticated && !report.provenanceArtifactsVerified)
    #expect(try Data(contentsOf: URL(fileURLWithPath: dataset.path + "/samples.jsonl")) == bytes)
}
@Test func inspectorTruncationAndAbsentLFNeverCommitARow() throws {
    let first = try journalRow(), second = try journalRow(journalPoint(101), sequence: 1)
    for cut in [1, 7, second.count - 1] {
        let report = try ProcessJournalInspector.inspect(first + second.dropLast(cut))
        #expect(report.rows.count == 1 && !report.structuralError)
        #expect(report.tail?.line == 2 && report.tail?.bytes.start == first.count)
        #expect(report.tail?.bytes.end == first.count + second.count - cut)
        #expect(report.tail?.kind == (cut == 1 ? "complete-row-without-LF" : "unterminated-final-bytes"))
    }
}
@Test func inspectorRejectsBadCompleteMiddleAndFinalWithoutResync() throws {
    let first = try journalRow(), later = try journalRow(journalPoint(102), sequence: 2)
    for suffix in [Data("{}\n".utf8), Data("{}".utf8), Data("{bad}\n".utf8), Data("{bad}".utf8)] {
        let report = try ProcessJournalInspector.inspect(first + suffix)
        #expect(report.structuralError && report.rows.count == 1 && report.contiguousPrefixBytes == first.count)
        #expect(report.diagnostics.last?.line == 2)
    }
    let report = try ProcessJournalInspector.inspect(first + Data("{}\n".utf8) + later)
    #expect(report.rows.count == 1 && report.unexaminedBytes?.end == report.inputBytes)
    #expect(report.unexaminedBytes?.start == first.count + 3)
}
@Test func inspectorKeepsFailureDiagnosticsBeforeBadSibling() throws {
    let failed = ProcessSeriesPoint(slot: 1, readStarted: 100, time: 100.1, state: .unreadableBefore, errorCode: 13)
    let report = try ProcessJournalInspector.inspect(journalRow(failed) + Data("{}\n".utf8))
    #expect(report.rows.count == 1 && report.diagnostics.count == 2)
    #expect(report.diagnostics[0].code == "retained failure state: unreadableBefore")
}
@Test func inspectorRejectsUnknownNullDuplicateEscapedAndMissingKeys() throws {
    let valid = String(decoding: try journalRow(), as: UTF8.self)
    let bad = [
        valid.replacingOccurrences(of: "\"sequence\":0", with: "\"sequence\":0,\"seque\\u006ece\":0"),
        valid.replacingOccurrences(of: "\"point\":{", with: "\"point\":{\"path\":\"x\","),
        valid.replacingOccurrences(of: "\"point\":{", with: "\"point\":{\"errorCode\":null,"),
        valid.replacingOccurrences(of: "\"schemaVersion\":1,", with: ""),
        valid.replacingOccurrences(of: "\"residentBytes\":99", with: "\"residentBytes\":true"),
        valid.replacingOccurrences(of: "\"before\":{", with: "\"before\":{\"name\":\"x\",")
    ]
    for text in bad { #expect(try inspectText(text).structuralError) }
}
@Test func inspectorStrictNumbersAndJSONFraming() throws {
    let valid = String(decoding: try journalRow(), as: UTF8.self)
    for number in ["-1", "1.5", "1.0", "1e0", "18446744073709551616", "NaN", "Infinity", "1e999", "01", "+1"] {
        #expect(try inspectText(valid.replacingOccurrences(of: "\"residentBytes\":99", with: "\"residentBytes\":" + number)).structuralError)
    }
    for suffix in [" {}\n", "\r{}\n", "\u{0}\n"] {
        #expect(try inspectText(String(valid.dropLast()) + suffix).structuralError)
    }
    #expect(try inspectText("\n").structuralError)
    #expect(try inspectText("\u{feff}" + valid).structuralError)
    #expect(try !inspectText("").structuralError)
    #expect(try inspectText(valid.replacingOccurrences(of: "100.001", with: "1e999")).structuralError)
}
@Test func inspectorRejectsCrossRunWindowSequenceAndChronology() throws {
    let first = try journalRow()
    var overlap = journalPoint(100); overlap.readStarted = 100.0005
    let variants = [
        try journalRow(journalPoint(101), sequence: 2),
        try journalRow(journalPoint(101), sequence: 1, runID: "different-journal-run"),
        try journalRow(journalPoint(101), sequence: 1, window: Window(start: 100, end: 104)),
        try journalRow(overlap, sequence: 1),
        try journalRow(journalPoint(100, slot: 2), sequence: 1)
    ]
    for row in variants {
        let report = try ProcessJournalInspector.inspect(first + row)
        #expect(report.structuralError && report.rows.count == 1)
    }
    #expect(try ProcessJournalInspector.inspect(journalRow(sequence: 1)).structuralError)
}
@Test func inspectorRetainsValidStateShapesIncludingUIDDrift() throws {
    let identity = journalPoint().before!
    var drift = identity; drift.uid = 0; drift.realUID = 4502
    let points = [
        ProcessSeriesPoint(slot: 1, readStarted: 100, time: 100.01, state: .notRegistered),
        ProcessSeriesPoint(slot: 1, readStarted: 101, time: 101.01, state: .identityChangedBefore, before: drift),
        ProcessSeriesPoint(slot: 1, readStarted: 102, time: 102.01, state: .readFailed, before: identity, after: identity, errorCode: 0),
        ProcessSeriesPoint(slot: 1, readStarted: 103, time: 103.01, state: .unreadableAfter, before: identity, errorCode: 3),
        ProcessSeriesPoint(slot: 1, readStarted: 104, time: 104.01, state: .identityChangedAfter, before: identity, after: drift, errorCode: 13)
    ]
    let bytes = try points.enumerated().reduce(into: Data()) { $0.append(try journalRow($1.element, sequence: $1.offset)) }
    let report = try ProcessJournalInspector.inspect(bytes)
    #expect(!report.structuralError && report.rows.count == 5 && !report.acquisitionComplete)
    #expect(report.rows.last?.point.after?.uid == 0 && report.rows.last?.point.errorCode == 13)
}
@Test func inspectorRejectsContradictoryStatesAndInstanceSwitching() throws {
    var sampled = journalPoint(); sampled.after!.startSeconds += 1
    var missingMetric = journalPoint(); missingMetric.residentBytes = nil
    var errorMetric = journalPoint(); errorMetric.state = .readFailed; errorMetric.errorCode = 13
    var unreadable = journalPoint(); unreadable.state = .unreadableBefore; unreadable.physicalFootprintBytes = nil; unreadable.residentBytes = nil
    for point in [sampled, missingMetric, errorMetric, unreadable] { #expect(try ProcessJournalInspector.inspect(journalRow(point)).structuralError) }
    var changed = journalPoint(101); changed.before!.startSeconds += 1; changed.after = changed.before
    #expect(try ProcessJournalInspector.inspect(journalRow() + journalRow(changed, sequence: 1)).rows.count == 1)
    var duplicate = journalPoint(101, slot: 2); duplicate.before = journalPoint().before; duplicate.after = duplicate.before
    #expect(try ProcessJournalInspector.inspect(journalRow() + journalRow(duplicate, sequence: 1)).structuralError)
}
@Test func inspectorExplicitPlanBindsClaimsWithoutAuthenticatingThem() throws {
    let plan = try journalPlan(), bytes = try journalRow()
    #expect(try ProcessJournalInspector.inspect(bytes, suppliedPlanJSON: plan).suppliedPlanSHA256 != nil)
    var object = try JSONDecoder().decode(ProcessSeriesPlan.self, from: plan)
    object.runID = "another-intended-run"
    #expect(try ProcessJournalInspector.inspect(bytes, suppliedPlanJSON: encoded(object)).structuralError)
    object.runID = "fixture-journal-inspector"; object.seconds = 4
    #expect(try ProcessJournalInspector.inspect(bytes, suppliedPlanJSON: encoded(object)).structuralError)
    object.seconds = 3; object.registrations[0].identity.startSeconds += 1
    #expect(try ProcessJournalInspector.inspect(bytes, suppliedPlanJSON: encoded(object)).structuralError)
    object.registrations[0].slot = 2
    #expect(try ProcessJournalInspector.inspect(bytes, suppliedPlanJSON: encoded(object)).structuralError)
    let falseMismatch = ProcessSeriesPoint(slot: 1, readStarted: 100, time: 100.01, state: .identityChangedBefore, before: journalPoint().before!)
    #expect(try ProcessJournalInspector.inspect(journalRow(falseMismatch), suppliedPlanJSON: plan).structuralError)
}
@Test func inspectorBoundsRowsBytesDepthAndCounts() throws {
    let row = try journalRow()
    let padded = Data(repeating: 32, count: 4096 - row.count) + row
    #expect(try !ProcessJournalInspector.inspect(padded).structuralError)
    #expect(try ProcessJournalInspector.inspect(Data([32]) + padded).structuralError)
    #expect(throws: InstrumentError.self) { try ProcessJournalInspector.inspect(Data(repeating: 32, count: ProcessJournalInspector.maximumBytes + 1)) }
    #expect(try inspectText(String(repeating: "[", count: 26) + "0" + String(repeating: "]", count: 26) + "\n").structuralError)
    var data = Data()
    for i in 0..<603 { data.append(try journalRow(journalPoint(100 + Double(i) * 0.01), sequence: i)) }
    let result = try ProcessJournalInspector.inspect(data)
    #expect(result.rows.count == 602 && result.structuralError)
}
@Test func inspectorRetainsTimingProblemsAsDiagnosticsNotRepairedMetrics() throws {
    var first = journalPoint(100.2); first.time = 101.4
    let second = journalPoint(104.5)
    let report = try ProcessJournalInspector.inspect(journalRow(first) + journalRow(second, sequence: 1))
    #expect(!report.structuralError && report.rows.count == 2)
    #expect(report.diagnostics.contains { $0.code == "process read exceeds one second" })
    #expect(report.diagnostics.contains { $0.code == "process sampling gap exceeds two seconds" })
    #expect(report.diagnostics.contains { $0.code == "sample exceeds acquisition end tolerance" })
}

@Test func inspectorCannotRebindAPriorFailureToAnotherPIDOrIdentity() throws {
    let observed = journalPoint().before!
    let failure = ProcessSeriesPoint(slot: 1, readStarted: 100, time: 100.01, state: .identityChangedBefore, before: observed)
    let first = try journalRow(failure)
    #expect(try ProcessJournalInspector.inspect(first + journalRow(journalPoint(101), sequence: 1)).structuralError)
    var changed = journalPoint(101); changed.before!.pid += 1; changed.after = changed.before
    #expect(try ProcessJournalInspector.inspect(first + journalRow(changed, sequence: 1)).structuralError)
    let absent = ProcessSeriesPoint(slot: 1, readStarted: 101, time: 101.01, state: .notRegistered)
    #expect(try ProcessJournalInspector.inspect(first + journalRow(absent, sequence: 1)).structuralError)
}
@Test func inspectorTotalRowLimitRetainsTheEntireAllowedPrefix() throws {
    var data = Data()
    for i in 0..<ProcessJournalInspector.maximumRows {
        data.append(try journalRow(journalPoint(100 + Double(i / 32) * 0.5 + Double(i % 32) * 0.002, slot: i % 32 + 1), sequence: i, window: Window(start: 100, end: 700)))
    }
    let prefixBytes = data.count
    data.append(try journalRow(journalPoint(402), sequence: ProcessJournalInspector.maximumRows, window: Window(start: 100, end: 700)))
    let report = try ProcessJournalInspector.inspect(data)
    #expect(report.structuralError && report.rows.count == ProcessJournalInspector.maximumRows)
    #expect(report.contiguousPrefixBytes == prefixBytes)
}
