import Foundation
import Security
import Testing
import SanjboxProbeKit
@testable import S1Instrumentation

private let hash = String(repeating: "a", count: 64)
private func check(_ host: Bool = false) -> (IdentityExpectation, IdentityCheck) {
    let uid: UInt32 = host ? 4502 : 4501
    let expected = IdentityExpectation(uid: uid, gid: 4500, kernelGroups: [4500], requiredGroups: [4500], forbiddenGroups: [20, 80], auditSessionID: host ? 124 : 123, onConsole: host)
    let membership = try! JSONDecoder().decode([ProbeContext.GroupMembership].self, from: Data("""
        [{"gid":4500,"isMember":true},{"gid":20,"isMember":false},{"gid":80,"isMember":false}]
        """.utf8))
    let identity = IdentityCheck(uid: uid, gid: 4500, realUID: uid, realGID: 4500, kernelGroups: [4500],
        auditSessionID: expected.auditSessionID, windowAuditSessionID: expected.auditSessionID, onConsole: host,
        auditUID: uid, managerName: "Aqua", managerUID: uid, windowUID: uid, loginDone: true,
        groupMembership: membership, mismatches: [])
    return (expected, identity)
}
private func clock(_ value: Double) -> ClockStamp {
    ClockStamp(monotonic: value, utc: 1_800_000_000 + value, bootIDHash: hash, uncertainty: 0)
}
private let signature = ProbeSignature(hardenedRuntime: true, forbiddenEntitlementPresent: false)
private func loginFixture() -> LoginAttempt {
    LoginAttempt(markers: [LoginEvent.start, .ready].enumerated().map { index, event in
        let (expected, identity) = check(index == 0)
        let request = LoginMarkerRequest(runID: "fixture-marker-\(index)", attemptID: "fixture-attempt", configurationSHA256: hash, mode: .warm,
            event: event, targetUID: 4501, order: 1, activeOtherZones: 2)
        return LoginMarker(request: request, source: "fixture", expected: expected, identity: identity, signature: signature,
            clock: clock(100 + Double(index)), eventDelayBoundSeconds: 0.001, calibrationSHA256: hash, observationSHA256: hash)
    })
}
private func memoryFixture() -> ProcessMemoryRecording {
    let (expected, identity) = check()
    return ProcessMemoryRecording(source: "fixture", plan: ProcessMemoryPlan(runID: "fixture-memory-supplement", seconds: 3, fixtureMiB: 4),
        expected: expected, initialIdentity: identity, finalIdentity: identity, signature: signature,
        registration: ProcessRegistration(pid: 42, uid: 4501, startSeconds: 1_800_000_000, startMicroseconds: 1, role: "owned-recorder-fixture"),
        started: clock(99), finished: clock(104), window: Window(start: 100, end: 103),
        samples: (100...103).map { ProcessMemoryPoint(time: Double($0), physicalFootprintBytes: 1234, residentBytes: 5678) })
}
private func workloadFixture(_ app: SyntheticApplication = .electron) -> ApplicationWorkload {
    let (expected, identity) = check()
    let kinds: [WorkloadObservationKind] = [.changingOutput, .inputResponse, .presentedOutput, .acceleratedBackend, .processContinuity, .webglCheck]
    let events = (100...103).flatMap { time in kinds.map { WorkloadObservation(kind: $0, time: Double(time), outcome: .success, artifactSHA256: hash) } }
    let binding = ExternalProcessBinding(pid: 42, uid: 4501, startSeconds: 1_800_000_000, startMicroseconds: 1, role: "application", artifactSHA256: hash)
    return ApplicationWorkload(runID: "fixture-workload", source: "fixture", profile: .diagnostic,
        workload: app == .xcodeSimulator ? "WX" : app == .androidEmulator ? "WA" : app == .safari ? "WS" : "WE",
        application: app, applicationVersion: "synthetic-1", runtimeVersion: "synthetic-1", fixtureSHA256: hash, preregistrationSHA256: hash,
        widthPixels: 1920, heightPixels: 1200, scale: 2, expected: expected, initialIdentity: identity, finalIdentity: identity,
        started: clock(90), finished: clock(104), window: Window(start: 100, end: 103),
        cycles: (1...3).map { ApplicationCycle(index: $0, start: 90 + Double($0), end: 90.5 + Double($0), launch: .success,
            build: app == .xcodeSimulator ? .success : nil, run: .success, artifactSHA256: hash) }, processes: [binding], observations: events)
}
@Test func supplementalStrictShapeRejectsUnknownDuplicateAndNull() throws {
    let good = try encoded(SupplementaryBundle(memory: [memoryFixture()]))
    _ = try StrictJSON.decodeExact(SupplementaryBundle.self, from: good)
    var object = try JSONSerialization.jsonObject(with: good) as! [String: Any]
    object["unknown"] = 1
    #expect(throws: InstrumentError.self) { try StrictJSON.decodeExact(SupplementaryBundle.self, from: JSONSerialization.data(withJSONObject: object)) }
    object.removeValue(forKey: "unknown"); object["login"] = NSNull()
    #expect(throws: InstrumentError.self) { try StrictJSON.decodeExact(SupplementaryBundle.self, from: JSONSerialization.data(withJSONObject: object)) }
    #expect(throws: InstrumentError.self) { try StrictJSON.validate(Data("{\"schemaVersion\":1,\"schema\\u0056ersion\":1}".utf8)) }
    #expect(throws: InstrumentError.self) { try SupplementaryAnalyzer.evaluate(SupplementaryBundle()) }
    #expect(throws: InstrumentError.self) { try SupplementaryAnalyzer.evaluate(SupplementaryBundle(login: [loginFixture()], memory: [memoryFixture()])) }
}
@Test func signatureRejectsBothEntitlementSpellingsAndUndecodedBlob() throws {
    let key = kSecCodeInfoFlags as String, ent = kSecCodeInfoEntitlementsDict as String
    #expect(try ProbeSignature.metadata([key: NSNumber(value: UInt32(0x10000))]).valid)
    #expect(try !ProbeSignature.metadata([key: NSNumber(value: 0)]).valid)
    for forbidden in ["get-task-allow", "com.apple.security.get-task-allow"] {
        #expect(try !ProbeSignature.metadata([key: NSNumber(value: UInt32(0x10000)), ent: [forbidden: false]]).valid)
    }
    #expect(throws: InstrumentError.self) { try ProbeSignature.metadata([key: true]) }
    #expect(throws: InstrumentError.self) { try ProbeSignature.metadata([key: NSNumber(value: 0x10000), kSecCodeInfoEntitlements as String: Data()]) }
    #expect(throws: InstrumentError.self) { try ProbeSignature.metadata([key: NSNumber(value: 0x10000), ent: "invalid"]) }
}
@Test func loginCalibratedSyntheticAndManualAreDistinguished() throws {
    var attempt = loginFixture()
    var report = try SupplementaryAnalyzer.login([attempt]).attempts[0]
    #expect(report.timingEvidenceComplete && report.markerIntervalSeconds == 1 && report.uncertaintySeconds == 0.002 && report.eventDurationUpperSeconds == 1.002)
    for i in attempt.markers.indices {
        attempt.markers[i].source = "measured-marker"
        attempt.markers[i].eventDelayBoundSeconds = nil
        attempt.markers[i].calibrationSHA256 = nil
        attempt.markers[i].observationSHA256 = nil
    }
    report = try SupplementaryAnalyzer.login([attempt]).attempts[0]
    #expect(!report.timingEvidenceComplete && report.markerIntervalSeconds == 1 && report.eventDurationUpperSeconds == nil)
    attempt.markers[0].eventDelayBoundSeconds = 0
    #expect(throws: InstrumentError.self) { try SupplementaryAnalyzer.login([attempt]) }
}
@Test func loginMissingReversedAndDifferentBootCannotComplete() throws {
    var attempt = loginFixture(); attempt.markers.removeLast()
    #expect(try !SupplementaryAnalyzer.login([attempt]).attempts[0].timingEvidenceComplete)
    attempt = loginFixture(); attempt.markers[1].clock = clock(99)
    #expect(try !SupplementaryAnalyzer.login([attempt]).attempts[0].timingEvidenceComplete)
    attempt = loginFixture(); attempt.markers[1].clock.bootIDHash = String(repeating: "b", count: 64)
    #expect(try !SupplementaryAnalyzer.login([attempt]).attempts[0].timingEvidenceComplete)
    attempt = loginFixture(); attempt.markers[1].clock.utc += 1
    #expect(try !SupplementaryAnalyzer.login([attempt]).attempts[0].timingEvidenceComplete)
}
@Test func loginRejectsDuplicateMixedConfigurationAndWrongRole() throws {
    var attempt = loginFixture(); attempt.markers.append(attempt.markers[1])
    #expect(throws: InstrumentError.self) { try SupplementaryAnalyzer.login([attempt]) }
    attempt = loginFixture(); attempt.markers[1].request.mode = .resume
    #expect(throws: InstrumentError.self) { try SupplementaryAnalyzer.login([attempt]) }
    attempt = loginFixture(); attempt.markers[1].expected.onConsole = true
    #expect(try !SupplementaryAnalyzer.login([attempt]).attempts[0].timingEvidenceComplete)
    #expect(throws: InstrumentError.self) { try SupplementaryAnalyzer.login([loginFixture(), loginFixture()]) }
}
@Test func loginTimeoutRemainsFailureNotDiscarded() throws {
    var attempt = loginFixture()
    attempt.markers[1].request.event = .timeout
    let (expected, identity) = check(true)
    attempt.markers[1].expected = expected; attempt.markers[1].identity = identity
    attempt.markers[1].clock = clock(160)
    let result = try SupplementaryAnalyzer.login([attempt]).attempts[0]
    #expect(result.timingEvidenceComplete && result.outcome == "timeout" && result.markerIntervalSeconds == 60)
    attempt.markers[1].clock = clock(159.99)
    #expect(try !SupplementaryAnalyzer.login([attempt]).attempts[0].timingEvidenceComplete)
}
@Test func loginUncertaintyThresholdAndLateReadyAreExplicit() throws {
    var attempt = loginFixture()
    attempt.markers[0].eventDelayBoundSeconds = 0.009
    #expect(try SupplementaryAnalyzer.login([attempt]).attempts[0].timingEvidenceComplete)
    attempt.markers[0].eventDelayBoundSeconds = 0.0091
    #expect(try !SupplementaryAnalyzer.login([attempt]).attempts[0].timingEvidenceComplete)
    attempt = loginFixture(); attempt.markers[1].clock = clock(161)
    #expect(try SupplementaryAnalyzer.login([attempt]).attempts[0].outcome == "ready-after-timeout")
}
@Test func memoryIsNonAdditiveAndZeroIsNotMissing() throws {
    var record = memoryFixture()
    record.samples[0].physicalFootprintBytes = 0; record.samples[0].residentBytes = 0
    let report = try SupplementaryAnalyzer.memory([record])
    #expect(!report.fullSessionAttributionComplete && report.processes[0].evidenceComplete)
    #expect(report.processes[0].physicalFootprintBytes?.minimum == 0)
    record.samples[0].physicalFootprintBytes = nil
    #expect(try !SupplementaryAnalyzer.memory([record]).processes[0].evidenceComplete)
}
@Test func memoryUnreadableSampleNeverBecomesZero() throws {
    var record = memoryFixture()
    record.samples[1] = ProcessMemoryPoint(time: 101, error: "unavailable")
    let result = try SupplementaryAnalyzer.memory([record]).processes[0]
    #expect(!result.evidenceComplete && result.physicalFootprintBytes?.count == 3 && result.physicalFootprintBytes?.minimum == 1234)
    record.samples[1].physicalFootprintBytes = 0
    #expect(throws: InstrumentError.self) { try SupplementaryAnalyzer.memory([record]) }
}
@Test func memoryUniqueProcessInstanceAndLifecycleBinding() throws {
    let record = memoryFixture()
    var duplicate = record; duplicate.plan.runID = "other-memory-record"
    #expect(throws: InstrumentError.self) { try SupplementaryAnalyzer.memory([record, duplicate]) }
    let instance = record.registration!
    var reused = instance; reused.startMicroseconds += 1
    #expect(OwnProcessMemory.sameInstance(instance, instance, instance))
    #expect(!OwnProcessMemory.sameInstance(instance, instance, reused))
    var alien = instance; alien.uid += 1
    #expect(!OwnProcessMemory.sameInstance(instance, alien, alien))
}
@Test func memoryRequiresEndpointsNoGapsAndOrderedSamples() throws {
    var record = memoryFixture(); record.samples.removeLast()
    #expect(try !SupplementaryAnalyzer.memory([record]).processes[0].evidenceComplete)
    record = memoryFixture(); record.samples = [record.samples[0], record.samples[3]]
    #expect(try !SupplementaryAnalyzer.memory([record]).processes[0].evidenceComplete)
    record = memoryFixture(); record.samples[1].time = 100
    #expect(throws: InstrumentError.self) { try SupplementaryAnalyzer.memory([record]) }
    record = memoryFixture(); record.samples.removeAll()
    #expect(try !SupplementaryAnalyzer.memory([record]).processes[0].evidenceComplete)
    record = memoryFixture(); record.samples[0].time = 100.11
    #expect(try !SupplementaryAnalyzer.memory([record]).processes[0].evidenceComplete)
}
@Test func memoryClockIdentityAndSignatureCannotBeAssertedValid() throws {
    var record = memoryFixture(); record.finished.clockChangeForTest()
    #expect(try !SupplementaryAnalyzer.memory([record]).processes[0].evidenceComplete)
    record = memoryFixture(); record.initialIdentity.auditUID = 1
    #expect(try !SupplementaryAnalyzer.memory([record]).processes[0].evidenceComplete)
    record = memoryFixture(); record.signature.hardenedRuntime = false
    #expect(try !SupplementaryAnalyzer.memory([record]).processes[0].evidenceComplete)
    record = memoryFixture(); record.registration!.uid += 1
    #expect(try !SupplementaryAnalyzer.memory([record]).processes[0].evidenceComplete)
}
private extension ClockStamp { mutating func clockChangeForTest() { bootIDHash = String(repeating: "b", count: 64) } }
@Test func processPlanRejectsOversizeAndNonfinite() throws {
    var plan = memoryFixture().plan
    plan.fixtureMiB = 65
    #expect(throws: InstrumentError.self) { try plan.validate() }
    plan.fixtureMiB = 4; plan.seconds = .nan
    #expect(throws: InstrumentError.self) { try plan.validate() }
    plan.seconds = 601
    #expect(throws: InstrumentError.self) { try plan.validate() }
}
@Test func workloadSyntheticRecordNeverVerifiesReferencedArtifacts() throws {
    let result = try SupplementaryAnalyzer.workloads([workloadFixture()])[0]
    #expect(result.recordComplete && !result.artifactsVerified && result.source == "fixture")
    var record = workloadFixture(); record.source = "measured"
    #expect(throws: InstrumentError.self) { try SupplementaryAnalyzer.workloads([record]) }
}
@Test func workloadPreservesReportedFailureAndUnknown() throws {
    var record = workloadFixture(); record.cycles[1].launch = .failure
    var result = try SupplementaryAnalyzer.workloads([record])[0]
    #expect(result.recordComplete && result.reportedFailures == ["cycle 2 launch"])
    record.observations[0].outcome = .unknown
    result = try SupplementaryAnalyzer.workloads([record])[0]
    #expect(!result.recordComplete && result.reportedFailures == ["cycle 2 launch"])
}
@Test func workloadNeedsRealOutputCategoriesAndBothEnds() throws {
    var record = workloadFixture(); record.observations.removeAll { $0.kind == .presentedOutput }
    #expect(try !SupplementaryAnalyzer.workloads([record])[0].recordComplete)
    record = workloadFixture(); record.observations.removeAll { $0.time >= 102 }
    #expect(try !SupplementaryAnalyzer.workloads([record])[0].recordComplete)
    record = workloadFixture(); record.cycles.removeLast()
    #expect(try !SupplementaryAnalyzer.workloads([record])[0].recordComplete)
}
@Test func workloadRequiresServicesAndExactProcessOwnership() throws {
    var record = workloadFixture(.xcodeSimulator)
    #expect(try !SupplementaryAnalyzer.workloads([record])[0].recordComplete)
    var service = record.processes[0]; service.pid = 43; service.role = "coreSimulatorService"
    record.processes.append(service)
    #expect(try SupplementaryAnalyzer.workloads([record])[0].recordComplete)
    record.processes[1].uid = 99
    #expect(try !SupplementaryAnalyzer.workloads([record])[0].recordComplete)
    record = workloadFixture(); record.processes.append(record.processes[0])
    #expect(throws: InstrumentError.self) { try SupplementaryAnalyzer.workloads([record]) }
}
@Test func workloadRejectsMixedProfilesMalformedHashesAndUnorderedTimes() throws {
    var record = workloadFixture(); record.workload = "WX"
    #expect(throws: InstrumentError.self) { try SupplementaryAnalyzer.workloads([record]) }
    record = workloadFixture(); record.fixtureSHA256 = "../outside"
    #expect(throws: InstrumentError.self) { try SupplementaryAnalyzer.workloads([record]) }
    record = workloadFixture(); record.cycles[1].start = 90
    #expect(throws: InstrumentError.self) { try SupplementaryAnalyzer.workloads([record]) }
    record = workloadFixture(); record.observations[0].time = 200
    #expect(throws: InstrumentError.self) { try SupplementaryAnalyzer.workloads([record]) }
    record = workloadFixture(); record.profile = .labV1Draft
    #expect(throws: InstrumentError.self) { try SupplementaryAnalyzer.workloads([record]) }
}
@Test func workloadClockAndIdentityGapsRemainIncomplete() throws {
    var record = workloadFixture(); record.finished.clockChangeForTest()
    #expect(try !SupplementaryAnalyzer.workloads([record])[0].recordComplete)
    record = workloadFixture(); record.finalIdentity.loginDone = false
    #expect(try !SupplementaryAnalyzer.workloads([record])[0].recordComplete)
    record = workloadFixture(); record.observations.removeAll { $0.kind == .processContinuity && $0.time > 100 && $0.time < 103 }
    #expect(try !SupplementaryAnalyzer.workloads([record])[0].recordComplete)
}

@Test func memoryRejectsPrewindowSamplesAndAcceptsFractionalDurationRounding() throws {
    var record = memoryFixture()
    record.started = clock(90); record.samples[0].time = 99
    #expect(try !SupplementaryAnalyzer.memory([record]).processes[0].evidenceComplete)
    record = memoryFixture(); record.plan.seconds = 1.1; record.window = Window(start: 100, end: 101.1)
    record.samples = [record.samples[0], ProcessMemoryPoint(time: 101.1, physicalFootprintBytes: 1234, residentBytes: 5678)]
    #expect(try SupplementaryAnalyzer.memory([record]).processes[0].evidenceComplete)
}
