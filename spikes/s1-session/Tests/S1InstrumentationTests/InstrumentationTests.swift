import Darwin
import Foundation
import Testing
import SanjboxProbeKit
import S1Probe
@testable import S1Instrumentation

private func context() throws -> ProbeContext {
    try JSONDecoder().decode(ProbeContext.self, from: Data("""
    {"pid":42,"parentPID":1,"realUID":4501,"effectiveUID":4501,"realGID":4500,"effectiveGID":4500,
    "kernelGroups":[4500],"groupMembership":[{"gid":4500,"isMember":true},{"gid":20,"isMember":false},{"gid":80,"isMember":false}],
    "audit":{"sessionID":123,"auditUID":4501,"flags":0},"launchdManager":{"name":"Aqua","uid":4501},
    "windowSession":{"userID":4501,"auditSessionID":123,"onConsole":false,"loginDone":true}}
    """.utf8))
}
private func expectation() -> IdentityExpectation {
    IdentityExpectation(uid: 4501, gid: 4500, kernelGroups: [4500], requiredGroups: [4500], forbiddenGroups: [20, 80], auditSessionID: 123, onConsole: false)
}
private func stamp(_ time: Double) -> ClockStamp {
    ClockStamp(monotonic: time, utc: 1_800_000_000 + time, bootIDHash: String(repeating: "a", count: 64), uncertainty: 0)
}
private func base(_ plan: Plan) throws -> Recording {
    let expected = expectation(), check = expected.check(try context())
    var record = Recording(source: "fixture", plan: plan, expected: expected, initialIdentity: check,
        started: stamp(plan.start - 4), finished: stamp(plan.end + 3))
    var cursor = plan.start
    for phase in plan.phases {
        record.boundaries.append(Boundary(phase: phase.name, edge: "start", scheduled: cursor, actual: stamp(cursor), identity: check))
        cursor += phase.seconds
        record.boundaries.append(Boundary(phase: phase.name, edge: "end", scheduled: cursor, actual: stamp(cursor), identity: check))
    }
    return record
}
private func presentation(profile: Profile = .labV1Draft) throws -> Recording {
    let seconds: Double = profile == .labV1Draft ? 600 : 2
    let plan = Plan(runID: "fixture-presentation", profile: profile, kind: .presentation, start: 1000,
        phases: [.init("warmup", 5), .init("measurement", seconds)])
    var record = try base(plan)
    let window = plan.window("measurement")!
    var trace = PresentationTrace(recorderStart: plan.start - 3, recorderEnd: plan.end + 0.25, drainEnd: plan.end + 2,
        measurementAcquisition: Window(start: window.start - 1, end: plan.end + 0.25))
    trace.frames = (0..<Int(seconds * 60)).map { n in
        let time = window.start + (Double(n) + 0.5) / 60
        return Frame(sequence: n, submitted: time - 0.001, presented: time, callback: time + 0.001)
    }
    trace.visibility = stride(from: plan.start - 2, through: plan.end + 1, by: 1).map {
        Visibility(time: $0, visible: true, width: 1920, height: 1200, scale: 2)
    }
    record.presentation = trace
    return record
}
private func memory() throws -> Recording {
    let plan = Plan(runID: "fixture-memory", profile: .labV1Draft, kind: .ram, start: 1000,
        phases: [.init("baselineBefore", 300), .init("settle", 300), .init("measurement", 600), .init("cleanup", 300), .init("baselineAfter", 300)])
    var record = try base(plan)
    let window = plan.window("measurement")!
    let physical: UInt64 = 16 * 1024 * 1024 * 1024
    var trace = RAMTrace(recorderStart: plan.start - 1, recorderEnd: plan.end + 0.1)
    trace.samples = stride(from: plan.start, through: plan.end, by: 1).map { time in
        let used: UInt64 = window.contains(time) ? 11 * 1024 * 1024 * 1024 : 8 * 1024 * 1024 * 1024
        return RAMSample(time: time, physicalBytes: physical, pageBytes: 16384, freePages: (physical - used) / 16384,
            swapUsedBytes: 0, pressure: 1)
    }
    record.ram = trace
    return record
}
@Test func goldenFixedWindowsAndEndpointSlots() throws {
    let result = try Analyzer.evaluate(presentation())
    #expect(result.evidenceComplete)
    #expect(result.frameBlocks.count == 10)
    for block in result.frameBlocks {
        #expect(block.presented == 3600 && block.fps == 60)
        #expect(block.gapsMilliseconds.count == 3601)
        #expect(block.gapsMilliseconds.maximum < 16.667)
        #expect(block.dropSlots == 0 && block.adverseDropSlots == 2)
        #expect(block.conditionalTargetsMet == true)
    }
}
@Test func windowHalfOpenAndLateFramesExcluded() throws {
    var record = try presentation(profile: .diagnostic)
    let w = record.plan.window("measurement")!
    record.presentation!.frames = [
        Frame(sequence: 0, submitted: w.start - 0.01, presented: w.start, callback: w.start + 0.01),
        Frame(sequence: 1, submitted: w.end - 0.01, presented: w.end, callback: w.end + 0.01),
        Frame(sequence: 2, submitted: w.end + 0.05, presented: w.end + 0.1, callback: w.end + 0.2)]
    let block = try Analyzer.evaluate(record).frameBlocks[0]
    #expect(block.presented == 1 && block.fps == 0.5)
    #expect(block.gapsMilliseconds.maximum == 2000)
    #expect(block.unpresentedInWindow == 1)
    #expect(block.conditionalTargetsMet == nil)
}
@Test func emptyAndEndGapsCannotPass() throws {
    var record = try presentation()
    record.presentation!.frames.removeAll()
    let result = try Analyzer.evaluate(record)
    #expect(result.evidenceComplete) // measured inability to present is a failure, not exclusion
    #expect(result.frameBlocks.allSatisfy { $0.secondsWithoutFrame == 60 && $0.gapsMilliseconds.maximum == 60_000 && $0.conditionalTargetsMet == false })
    record = try presentation()
    record.presentation!.frames.removeLast(120)
    #expect(try Analyzer.evaluate(record).frameBlocks.last!.gapsMilliseconds.maximum > 2000)
}
@Test func malformedTimesAndDuplicatesRejected() throws {
    var record = try presentation(profile: .diagnostic)
    record.presentation!.frames[0].presented = .nan
    #expect(throws: InstrumentError.self) { try Analyzer.evaluate(record) }
    record = try presentation(profile: .diagnostic)
    record.presentation!.frames[1].sequence = 0
    #expect(throws: InstrumentError.self) { try Analyzer.evaluate(record) }
    record = try presentation(profile: .diagnostic)
    record.presentation!.frames[0].callback = record.plan.end + 100
    #expect(throws: InstrumentError.self) { try Analyzer.evaluate(record) }
}
@Test func actualClockEnvelopeAndWarmupRequired() throws {
    var record = try presentation()
    record.finished = record.started
    #expect(try !Analyzer.evaluate(record).evidenceComplete)
    record = try presentation()
    record.presentation!.recorderStart = record.plan.window("measurement")!.start - 2
    let changedStart = record.presentation!.recorderStart
    record.presentation!.visibility.removeAll { $0.time < changedStart }
    #expect(try !Analyzer.evaluate(record).evidenceComplete)
    record = try presentation()
    record.finished.utc += 2
    #expect(try !Analyzer.evaluate(record).evidenceComplete)
    record = try presentation()
    record.boundaries[2].actual.monotonic = record.started.monotonic - 1
    #expect(try !Analyzer.evaluate(record).evidenceComplete)
}
@Test func missingOrExtraBoundariesAreIncompleteNotCrash() throws {
    var record = try presentation(profile: .diagnostic)
    record.boundaries.append(record.boundaries[0])
    #expect(try !Analyzer.evaluate(record).evidenceComplete)
    record.boundaries.removeAll()
    #expect(try !Analyzer.evaluate(record).evidenceComplete)
}
@Test func visibilityCoverageIsRequiredAndOcclusionFails() throws {
    var record = try presentation()
    record.presentation!.visibility.removeSubrange(20...26)
    #expect(try !Analyzer.evaluate(record).evidenceComplete)
    record = try presentation()
    record.presentation!.visibility[20].visible = false
    let result = try Analyzer.evaluate(record)
    #expect(result.evidenceComplete && result.frameBlocks[0].conditionalTargetsMet == false)
}
@Test func exactIdentityCannotBeReplacedByEmptyMismatchList() throws {
    let expected = expectation()
    var ctx = try context()
    #expect(expected.check(ctx).valid)
    ctx.audit!.sessionID += 1
    #expect(!expected.check(ctx).valid)
    ctx = try context(); ctx.windowSession!.auditSessionID = nil
    #expect(!expected.check(ctx).valid)
    var record = try presentation(profile: .diagnostic)
    record.initialIdentity.auditUID = 99
    #expect(try !Analyzer.evaluate(record).evidenceComplete)
    record = try presentation(profile: .diagnostic)
    record.boundaries[0].identity.managerName = "Background"
    #expect(try !Analyzer.evaluate(record).evidenceComplete)
}
@Test func profilesAreExplicitAndBounded() throws {
    var plan = try presentation().plan
    plan.phases[1].seconds = 30
    #expect(throws: InstrumentError.self) { try plan.validate() }
    plan.profile = .diagnostic
    try plan.validate()
    plan.start = .infinity
    #expect(throws: InstrumentError.self) { try plan.validate() }
    plan.start = 1; plan.phases[1].seconds = -1
    #expect(throws: InstrumentError.self) { try plan.validate() }
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Profile.self, from: Data("\"lab-approved\"".utf8)) }
}
@Test func goldenRAMBaselineUsesMinAndPreservesNegative() throws {
    var record = try memory()
    var result = try Analyzer.evaluate(record)
    #expect(result.evidenceComplete)
    #expect(result.ram?.baselineBytes == Double(8 * 1024 * 1024 * 1024))
    #expect(result.ram?.deltaBytes?.p95 == Double(3 * 1024 * 1024 * 1024))
    #expect(result.ram?.conditionalTargetsMet == true)
    for i in record.ram!.samples.indices where record.plan.window("baselineAfter")!.contains(record.ram!.samples[i].time) {
        record.ram!.samples[i].freePages += 1024 // lower baseline after; min must select it
    }
    result = try Analyzer.evaluate(record)
    #expect(result.ram?.baselineBytes == Double(8 * 1024 * 1024 * 1024 - 16384 * 1024))
    record = try memory()
    record.ram!.samples[700].freePages = 9 * 1024 * 1024 * 1024 / 16384
    result = try Analyzer.evaluate(record)
    #expect(!result.evidenceComplete && result.ram?.negativeDeltaCount == 1)
    #expect(result.ram!.deltaBytes!.minimum < 0)
}
@Test func RAMGapsDriftUnknownPressureAndEndpointsAreIncomplete() throws {
    var record = try memory()
    record.ram!.samples.removeSubrange(150...153)
    #expect(try !Analyzer.evaluate(record).evidenceComplete)
    record = try memory()
    for i in record.ram!.samples.indices where record.plan.window("baselineAfter")!.contains(record.ram!.samples[i].time) {
        record.ram!.samples[i].freePages -= 40_000
    }
    #expect(try !Analyzer.evaluate(record).evidenceComplete)
    record = try memory(); record.ram!.samples[700].pressure = nil
    #expect(try !Analyzer.evaluate(record).evidenceComplete)
    record = try memory(); record.ram!.samples.removeLast(4)
    #expect(try !Analyzer.evaluate(record).evidenceComplete)
}
@Test func RAMLoadPressureSwapAndMalformedFreeCount() throws {
    var record = try memory()
    record.plan.phases = [.init("measurement", 600)]
    record = try base(record.plan)
    let sample = RAMSample(time: record.plan.start, physicalBytes: 16 << 30, pageBytes: 16384, freePages: 1000, swapUsedBytes: 0, pressure: 1)
    var trace = RAMTrace(recorderStart: record.plan.start, recorderEnd: record.plan.end)
    trace.samples = (0...600).map { n in var s = sample; s.time += Double(n); s.swapUsedBytes = n == 600 ? 2 << 30 : 0; return s }
    record.ram = trace
    #expect(try Analyzer.evaluate(record).ram?.conditionalTargetsMet == false)
    record.ram!.samples[5].freePages = .max
    #expect(throws: InstrumentError.self) { try Analyzer.evaluate(record) }
}
@Test func syntheticAndDifferentBootCannotProveConcurrency() throws {
    let record = try presentation(profile: .diagnostic)
    let result = try Analyzer.evaluate(EvidenceBundle(recordings: [record, record, record, record]))
    #expect(result.simultaneousPresentationWindow == nil)
    #expect(result.concurrencyIssues.contains("synthetic fixtures do not prove live concurrency"))
    #expect(result.concurrencyIssues.contains("UIDs and audit sessions must be distinct"))
}
@Test func storageNeverReusesDatasetOrFile() throws {
    let run = "fixture-" + UUID().uuidString
    let dataset = try Dataset(runID: run, role: "report")
    try dataset.write("report.json", ["synthetic": true])
    #expect(throws: InstrumentError.self) { try dataset.write("report.json", ["replacement": true]) }
    #expect(throws: InstrumentError.self) { try Dataset(runID: run, role: "report") }
    #expect(throws: InstrumentError.self) { try Dataset(runID: "../../bad", role: "report") }
    // Test artifacts are deliberately preserved; no recursive cleanup helper is introduced.
}
@Test func inputFixtureIsAllowlistedAndRejectsSymlink() throws {
    #expect(throws: InstrumentError.self) { try Dataset.readFixture(name: "../../bad") }
    let name = "fixture-" + UUID().uuidString
    let path = "/private/tmp/sanjbox-a2-fixture-\(geteuid())-\(name).json"
    #expect(symlink("/dev/null", path) == 0)
    #expect(throws: InstrumentError.self) { try Dataset.readFixture(name: name) }
    var info = stat()
    if lstat(path, &info) == 0 && info.st_uid == geteuid() && (info.st_mode & S_IFMT) == S_IFLNK { #expect(unlink(path) == 0) }
}

@Test func duplicateJSONKeysIncludingEscapesAreRejected() throws {
    for text in [#"{"uid":1,"uid":2}"#, #"{"uid":1,"\u0075id":2}"#, #"{"a":[{"x":1,"x":2}]}"#] {
        #expect(throws: InstrumentError.self) { try StrictJSON.validate(Data(text.utf8)) }
    }
    let decoded = try StrictJSON.decode([String: [Int]].self, from: Data(#"{"a":[1,2]}"#.utf8))
    #expect(decoded["a"] == [1, 2])
}

@Test func nonfiniteOffscreenResultsRemainEncodableWithoutGPU() throws {
    let fixture = Data(#"{"device":"synthetic","width":2048,"height":2048,"iterationsPerPixel":512,"frames":60,"gpuMillisecondsMedian":1,"gpuMillisecondsP95":2,"wallSeconds":1,"gigaIterationsPerSecond":1,"verifiedPixels":4096,"mismatchedPixels":0}"#.utf8)
    let good = try JSONDecoder().decode(OffscreenResult.self, from: fixture)
    let expected = expectation()
    for badValue in [Double.infinity, Double.nan, 0, -1] {
        var value = good
        value.gpuMillisecondsMedian = badValue
        var record = OffscreenRecording(runID: "fixture-offscreen", expected: expected, initialIdentity: expected.check(try context()), started: stamp(1000))
        record.accept(value)
        #expect(record.result == nil && !record.errors.isEmpty)
        #expect(record.invalidResult?["gpuMillisecondsMedian"] == String(badValue))
        let data = try encoded(record)
        #expect(try JSONDecoder().decode(OffscreenRecording.self, from: data).invalidResult == record.invalidResult)
    }
    var record = OffscreenRecording(runID: "fixture-offscreen", expected: expected, initialIdentity: expected.check(try context()), started: stamp(1000))
    record.accept(good)
    #expect(record.result == good && record.errors.isEmpty)
}
