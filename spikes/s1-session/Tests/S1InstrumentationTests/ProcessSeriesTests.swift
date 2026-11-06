import Foundation
import Testing
import SanjboxProbeKit
@testable import S1Instrumentation

private let seriesHash = String(repeating: "b", count: 64)
private func seriesFixture() throws -> ProcessSeriesRecording {
    let expected = IdentityExpectation(uid: 4501, gid: 4500, kernelGroups: [4500], requiredGroups: [4500], forbiddenGroups: [], auditSessionID: 123, onConsole: false)
    let membership = try JSONDecoder().decode([ProbeContext.GroupMembership].self, from: Data("[{\"gid\":4500,\"isMember\":true}]".utf8))
    let identity = IdentityCheck(uid: 4501, gid: 4500, realUID: 4501, realGID: 4500, kernelGroups: [4500], auditSessionID: 123, windowAuditSessionID: 123, onConsole: false, auditUID: 4501, managerName: "Aqua", managerUID: 4501, windowUID: 4501, loginDone: true, groupMembership: membership, mismatches: [])
    let process = TestProcessIdentity(pid: 42, uid: 4501, realUID: 4501, startSeconds: 1_800_000_000, startMicroseconds: 7)
    let target = TestProcessRegistration(slot: 1, identity: process, role: .application, provenanceSHA256: seriesHash)
    func stamp(_ t: Double) -> ClockStamp { ClockStamp(monotonic: t, utc: 1_800_000_000 + t, bootIDHash: seriesHash, uncertainty: 0) }
    let points: [ProcessSeriesPoint] = (100...103).map { (t: Int) -> ProcessSeriesPoint in
        let time: Double = Double(t)
        let footprint: UInt64 = UInt64(t - 100)
        let resident: UInt64 = UInt64(t * 10)
        return ProcessSeriesPoint(slot: 1, readStarted: time, time: time + 0.001, state: .sampled, before: process, after: process, physicalFootprintBytes: footprint, residentBytes: resident)
    }
    return ProcessSeriesRecording(source: "fixture", runID: "fixture-process-series", seconds: 3, expectedSlots: [1], expected: expected,
        initialIdentity: identity, finalIdentity: identity, signature: ProbeSignature(hardenedRuntime: true, forbiddenEntitlementPresent: false),
        started: stamp(99), finished: stamp(104), window: Window(start: 100, end: 103),
        bindings: [ProcessSeriesBinding(registration: target, registeredAt: 99.5)],
        samples: points)
}
@Test func registeredSeriesReportsSeparateKnownDistributions() throws {
    let result = try ProcessSeriesAnalyzer.evaluate(seriesFixture())
    #expect(result.acquisitionComplete)
    #expect(result.processes[0].physicalFootprintBytes?.count == 4)
    #expect(result.processes[0].physicalFootprintBytes?.minimum == 0)
    #expect(result.processes[0].physicalFootprintBytes?.p95 == 3)
    #expect(!result.fullSessionAttributionComplete && !result.windowServerAttributionComplete && !result.crossUIDClientAttributionComplete && !result.provenanceArtifactsVerified)
}
@Test func registeredPlanRejectsDuplicatesCrossUIDAndBounds() throws {
    let value = try seriesFixture(), target = value.bindings[0].registration
    var plan = ProcessSeriesPlan(runID: value.runID, seconds: 3, registrations: [target])
    try plan.validate(expectedUID: 4501)
    #expect(throws: InstrumentError.self) { try plan.validate(expectedUID: 4502) }
    plan.registrations.append(target)
    #expect(throws: InstrumentError.self) { try plan.validate() }
    plan.registrations[1].slot = 2; plan.registrations[1].identity.startMicroseconds += 1
    #expect(throws: InstrumentError.self) { try plan.validate() }
    #expect(throws: InstrumentError.self) { try target.validate(uid: 4502) }
    plan.registrations = [target]; plan.seconds = 601
    #expect(throws: InstrumentError.self) { try plan.validate() }
    plan.seconds = 0.5
    #expect(throws: InstrumentError.self) { try plan.validate() }
}
@Test func readerChecksIdentityBeforeAndAfterSuccessfulRead() throws {
    let target = try seriesFixture().bindings[0].registration
    var calls: [String] = []
    let reader = RegisteredProcessReader(identity: { _ in calls.append("identity"); return target.identity }, memory: { _ in calls.append("memory"); return (12, 34) }, now: { 100 })
    let result = reader.sample(target)
    #expect(calls == ["identity", "memory", "identity"])
    #expect(result.state == .sampled && result.physicalFootprintBytes == 12 && result.residentBytes == 34)
}
@Test func readerRejectsPIDReuseBeforeReadingMemory() throws {
    let target = try seriesFixture().bindings[0].registration
    var other = target.identity; other.startMicroseconds += 1
    var reads = 0
    let result = RegisteredProcessReader(identity: { _ in other }, memory: { _ in reads += 1; return (99, 99) }, now: { 100 }).sample(target)
    #expect(result.state == .identityChangedBefore && reads == 0 && result.physicalFootprintBytes == nil)
}
@Test func readerRejectsPIDReuseDuringReadAndDoesNotPublishNumbers() throws {
    let target = try seriesFixture().bindings[0].registration
    var other = target.identity; other.startSeconds += 1
    var reads = 0
    let result = RegisteredProcessReader(identity: { _ in reads += 1; return reads == 1 ? target.identity : other }, memory: { _ in (999, 999) }, now: { 100 }).sample(target)
    #expect(result.state == .identityChangedAfter && result.before == target.identity && result.after == other && result.physicalFootprintBytes == nil)
}
@Test func readerChecksAfterRusageFailureAndPreservesErrno() throws {
    let target = try seriesFixture().bindings[0].registration
    var checks = 0
    let result = RegisteredProcessReader(identity: { _ in checks += 1; return target.identity }, memory: { _ in throw ProcessReadFailure(code: 13) }, now: { 100 }).sample(target)
    #expect(checks == 2 && result.state == .readFailed && result.errorCode == 13 && result.residentBytes == nil)
}
@Test func readerRetainsExitBeforeAndDuringRead() throws {
    let target = try seriesFixture().bindings[0].registration
    var calls = 0
    let before = RegisteredProcessReader(identity: { _ in throw ProcessReadFailure(code: 3) }, memory: { _ in calls += 1; return (0, 0) }, now: { 100 }).sample(target)
    #expect(before.state == .unreadableBefore && calls == 0)
    var checks = 0
    let after = RegisteredProcessReader(identity: { _ in checks += 1; if checks == 2 { throw ProcessReadFailure(code: 3) }; return target.identity }, memory: { _ in (0, 0) }, now: { 100 }).sample(target)
    #expect(after.state == .unreadableAfter && after.physicalFootprintBytes == nil)
}
@Test func readerRejectsRealUIDChanges() throws {
    let target = try seriesFixture().bindings[0].registration
    var other = target.identity; other.realUID = 4502
    let point = RegisteredProcessReader(identity: { _ in other }, memory: { _ in (1, 1) }, now: { 100 }).sample(target)
    #expect(point.state == .identityChangedBefore)
}
@Test func seriesArrivalExitAndMissingStayIncomplete() throws {
    var value = try seriesFixture()
    value.bindings[0].registeredAt = 101
    value.samples[0] = ProcessSeriesPoint(slot: 1, readStarted: 100, time: 100.001, state: .notRegistered)
    value.samples[3] = ProcessSeriesPoint(slot: 1, readStarted: 103, time: 103.001, state: .unreadableBefore, errorCode: 3)
    let result = try ProcessSeriesAnalyzer.evaluate(value)
    #expect(!result.acquisitionComplete && result.processes[0].physicalFootprintBytes?.count == 2)
    #expect(result.processes[0].issues.contains("process arrival inside window"))
    value.bindings = []
    #expect(try !ProcessSeriesAnalyzer.evaluate(value).acquisitionComplete)
}
@Test func seriesGapAndLongReadCannotComplete() throws {
    var value = try seriesFixture(); value.samples.removeSubrange(1...2)
    #expect(try !ProcessSeriesAnalyzer.evaluate(value).acquisitionComplete)
    value = try seriesFixture(); value.samples[1].time = 102.1; value.samples.remove(at: 2)
    #expect(try !ProcessSeriesAnalyzer.evaluate(value).acquisitionComplete)
}
@Test func seriesMissingAndOutOfWindowEndpointsCannotComplete() throws {
    var value = try seriesFixture(); value.samples.removeLast()
    #expect(try !ProcessSeriesAnalyzer.evaluate(value).acquisitionComplete)
    value = try seriesFixture(); value.samples[0].readStarted = 99.9
    #expect(try !ProcessSeriesAnalyzer.evaluate(value).acquisitionComplete)
    value = try seriesFixture(); value.window = nil
    #expect(try !ProcessSeriesAnalyzer.evaluate(value).acquisitionComplete)
}
@Test func seriesRejectsDuplicateInstanceAcrossRolesAndSlots() throws {
    var value = try seriesFixture(); var binding = value.bindings[0]
    binding.registration.slot = 2; binding.registration.role = .renderer
    value.expectedSlots.append(2); value.bindings.append(binding)
    #expect(throws: InstrumentError.self) { try ProcessSeriesAnalyzer.evaluate(value) }
}
@Test func seriesForgedSuccessfulIdentityDoesNotEnterStats() throws {
    var value = try seriesFixture(); value.samples[1].after!.startSeconds += 1
    let result = try ProcessSeriesAnalyzer.evaluate(value)
    #expect(!result.acquisitionComplete && result.processes[0].physicalFootprintBytes?.count == 3)
    value = try seriesFixture(); value.samples[1].state = .readFailed
    #expect(throws: InstrumentError.self) { try ProcessSeriesAnalyzer.evaluate(value) }
}
@Test func seriesRequiresCollectorIdentitySignatureAndClock() throws {
    var value = try seriesFixture(); value.finalIdentity!.auditSessionID = 124
    #expect(try !ProcessSeriesAnalyzer.evaluate(value).acquisitionComplete)
    value = try seriesFixture(); value.signature.hardenedRuntime = false
    #expect(try !ProcessSeriesAnalyzer.evaluate(value).acquisitionComplete)
    value = try seriesFixture(); value.finished.bootIDHash = String(repeating: "a", count: 64)
    #expect(try !ProcessSeriesAnalyzer.evaluate(value).acquisitionComplete)
    value = try seriesFixture(); value.bindings[0].registeredAt = 101
    #expect(try !ProcessSeriesAnalyzer.evaluate(value).acquisitionComplete)
}
@Test func seriesExactDecodeRejectsNamesNullAndUnknownNestedKeys() throws {
    let raw = try encoded(seriesFixture())
    _ = try StrictJSON.decodeExact(ProcessSeriesRecording.self, from: raw)
    var object = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
    object["processName"] = "forbidden"
    #expect(throws: InstrumentError.self) { try StrictJSON.decodeExact(ProcessSeriesRecording.self, from: JSONSerialization.data(withJSONObject: object)) }
    object.removeValue(forKey: "processName"); object["ownedCleanupComplete"] = NSNull()
    #expect(throws: InstrumentError.self) { try StrictJSON.decodeExact(ProcessSeriesRecording.self, from: JSONSerialization.data(withJSONObject: object)) }
}
@Test func childRequestRejectsCommandsAndUnboundedSlots() throws {
    let value = try seriesFixture()
    var request = OwnedFixtureRequest(slot: 1, parentPID: 42, expected: value.expected)
    try request.validate(); request.slot = 3
    #expect(throws: InstrumentError.self) { try request.validate() }
    let raw = try encoded(OwnedFixtureRequest(slot: 1, parentPID: 42, expected: value.expected))
    var object = try JSONSerialization.jsonObject(with: raw) as! [String: Any]; object["command"] = "echo"
    #expect(throws: InstrumentError.self) { try StrictJSON.decodeExact(OwnedFixtureRequest.self, from: JSONSerialization.data(withJSONObject: object)) }
}
@Test func seriesRejectsRebindingReusedPIDAndUnknownSlots() throws {
    var value = try seriesFixture(); var binding = value.bindings[0]
    binding.registration.slot = 2; binding.registration.identity.startSeconds += 1
    value.expectedSlots.append(2); value.bindings.append(binding)
    #expect(throws: InstrumentError.self) { try ProcessSeriesAnalyzer.evaluate(value) }
    value = try seriesFixture(); value.samples[0].slot = 2
    #expect(throws: InstrumentError.self) { try ProcessSeriesAnalyzer.evaluate(value) }
}
@Test func seriesRequiresOwnedCompletionWithoutErasingIdentityFailure() throws {
    var value = try seriesFixture(); value.source = "measured-owned-fixtures"
    value.ownedCleanupComplete = true
    let result = try ProcessSeriesAnalyzer.evaluate(value)
    #expect(!result.acquisitionComplete && result.issues.contains("missing owned fixture completion"))
    value.samples = []; value.bindings = []; value.window = nil
    value.initialIdentity.auditSessionID = 124
    #expect(try !ProcessSeriesAnalyzer.evaluate(value).acquisitionComplete)
}
@Test func seriesBoundPerSlotAndEmptyRegistrationRemainExplicit() throws {
    var value = try seriesFixture()
    value.samples = Array(repeating: value.samples[0], count: 603)
    #expect(throws: InstrumentError.self) { try ProcessSeriesAnalyzer.evaluate(value) }
    value = try seriesFixture(); value.bindings = []
    #expect(try ProcessSeriesAnalyzer.evaluate(value).processes[0].issues.contains("missing registration"))
}
@Test func journalPersistsPointsAndErrorsAndRefusesReuse() throws {
    let record = try seriesFixture()
    let runID = "fixture-journal-" + UUID().uuidString
    let dataset = try Dataset(runID: runID, role: "process-series")
    let journal = try dataset.processSeriesJournal(runID: runID)
    try journal.append(record.samples[0], window: record.window!)
    let failure = ProcessSeriesPoint(slot: 1, readStarted: 101, time: 101.001, state: .readFailed, before: record.bindings[0].registration.identity, after: record.bindings[0].registration.identity, errorCode: 13)
    try journal.append(failure, window: record.window!)
    let url = URL(fileURLWithPath: dataset.path).appendingPathComponent("samples.jsonl")
    let bytes = try Data(contentsOf: url)
    let lines = bytes.split(separator: 10)
    let entries = try lines.map { try StrictJSON.decodeExact(ProcessSeriesJournalEntry.self, from: Data($0)) }
    #expect(entries.count == 2 && entries[0].sequence == 0 && entries[1].sequence == 1)
    #expect(entries[0].point.physicalFootprintBytes == 0 && entries[1].point.state == .readFailed && entries[1].point.errorCode == 13 && entries[1].point.physicalFootprintBytes == nil)
    #expect(throws: InstrumentError.self) { try dataset.processSeriesJournal(runID: runID) }
    #expect(try Data(contentsOf: url) == bytes)
    let truncated = bytes.dropLast(7)
    let completed = truncated.split(separator: 10, omittingEmptySubsequences: false).dropLast()
    #expect(completed.count == 1)
    #expect(try StrictJSON.decodeExact(ProcessSeriesJournalEntry.self, from: Data(completed.first!)).point.physicalFootprintBytes == 0)
    #expect(!FileManager.default.fileExists(atPath: dataset.path + "/recording.json"))
    // Exclusive fixture evidence is intentionally retained like the existing storage regression.
}
