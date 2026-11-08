import Darwin
import Foundation
import Testing
@testable import S1Instrumentation

private func relation(_ pid: Int32, parent: Int32 = 1) -> ProcessRelation {
    ProcessRelation(identity: TestProcessIdentity(pid: pid, uid: 4501, realUID: 4501, startSeconds: 1800000000, startMicroseconds: UInt64(pid)), parentPID: parent)
}
private func descendantPlan() -> DescendantMemoryPlan {
    DescendantMemoryPlan(runID: "descendant-unit-fixture", seconds: 3, root: relation(10), provenanceSHA256: String(repeating: "a", count: 64), maxProcesses: 4, maxDepth: 2)
}
private final class TreeMock {
    var tree = [Int32(10): relation(10)]
    var lists: [Int32: [Int32]] = [:]
    var listCalls: [Int32] = [], memoryCalls: [Int32] = []
    var now = 100.0
    var failMemory: Int32?, failList: Int32?, saturated = false
    var afterMemory: ((Int32) -> Void)?
    var afterList: ((Int32) -> Void)?
    var reader: DescendantReader { DescendantReader(relation: { pid in
        guard let value = self.tree[pid] else { throw ProcessReadFailure(code: ESRCH) }; return value
    }, memory: { pid in
        self.memoryCalls.append(pid); self.afterMemory?(pid)
        if pid == self.failMemory { throw ProcessReadFailure(code: EPERM) }
        return (UInt64(pid * 1024), UInt64(pid * 2048))
    }, children: { pid, _ in
        self.listCalls.append(pid); self.afterList?(pid)
        if pid == self.failList { throw ProcessReadFailure(code: EACCES) }
        return (self.lists[pid] ?? [], self.saturated)
    }, now: { self.now }) }
}
@Test func descendantsDiscoverLateChildAndGrandchildWithoutRegistration() throws {
    let m = TreeMock(); var c = DescendantCollector(plan: descendantPlan(), reader: m.reader, started: 100)
    var observations: [DescendantObservation] = []
    try c.tick(deadline: 101) { observations.append($0) }
    #expect(c.bindings.count == 1 && m.listCalls == [10])
    m.tree[11] = relation(11, parent: 10); m.tree[12] = relation(12, parent: 11)
    m.lists = [10: [11], 11: [12]]; m.now = 101
    try c.tick(deadline: 102) { observations.append($0) }
    #expect(c.bindings.map(\.process.identity.pid) == [10, 11, 12])
    #expect(c.bindings.map(\.parentIndex) == [nil, 0, 1])
    #expect(m.listCalls == [10, 10, 11, 12])
    #expect(observations.last?.before == [relation(10), relation(11, parent: 10), relation(12, parent: 11)])
    #expect(observations.last?.before == observations.last?.after)
    #expect(observations.last?.physicalFootprintBytes == 12 * 1024)
}
@Test func descendantsRefuseWrongRootBeforeAnyMemoryOrList() throws {
    let m = TreeMock(); m.tree[10]!.identity.startMicroseconds += 1
    var c = DescendantCollector(plan: descendantPlan(), reader: m.reader, started: 100)
    var rows: [DescendantObservation] = []; try c.tick(deadline: 101) { rows.append($0) }
    #expect(rows.first?.state == .scopeChangedBefore && m.memoryCalls.isEmpty && m.listCalls.isEmpty)
}
@Test func descendantsDiscardMetricsAndCandidatesOnParentRace() throws {
    let m = TreeMock(); m.lists[10] = [11]; m.tree[11] = relation(11, parent: 10)
    m.afterList = { pid in m.tree[pid]!.parentPID = 2 }
    var c = DescendantCollector(plan: descendantPlan(), reader: m.reader, started: 100)
    var rows: [DescendantObservation] = []; try c.tick(deadline: 101) { rows.append($0) }
    #expect(rows.first?.state == .scopeChangedAfter && rows.first?.physicalFootprintBytes == nil && c.bindings.count == 1)
}
@Test func descendantsRejectCrossUIDOrReparentedCandidate() throws {
    for changedUID in [true, false] {
        let m = TreeMock(); m.lists[10] = [11]; m.tree[11] = relation(11, parent: changedUID ? 10 : 2)
        if changedUID { m.tree[11]!.identity.realUID = 4502 }
        var c = DescendantCollector(plan: descendantPlan(), reader: m.reader, started: 100)
        var rows: [DescendantObservation] = []; try c.tick(deadline: 101) { rows.append($0) }
        #expect(rows.last?.state == .candidateOutOfScope && m.memoryCalls == [10] && c.bindings.count == 1)
    }
}
@Test func descendantsRetainUnreadableCandidates() throws {
    let m = TreeMock(); m.lists[10] = [11]
    var c = DescendantCollector(plan: descendantPlan(), reader: m.reader, started: 100)
    var rows: [DescendantObservation] = []; try c.tick(deadline: 101) { rows.append($0) }
    #expect(rows.last?.state == .candidateUnreadable && rows.last?.errorCode == ESRCH && rows.last?.physicalFootprintBytes == nil)
}
@Test func descendantsDoNotRebindReusedPID() throws {
    let m = TreeMock(); m.tree[11] = relation(11, parent: 10); m.lists[10] = [11]
    var c = DescendantCollector(plan: descendantPlan(), reader: m.reader, started: 100)
    try c.tick(deadline: 101) { _ in }
    m.tree[11]!.identity.startSeconds += 1; m.memoryCalls = []; m.listCalls = []
    var rows: [DescendantObservation] = []; try c.tick(deadline: 101) { rows.append($0) }
    #expect(c.bindings.count == 2 && rows.last?.state == .scopeChangedBefore && m.memoryCalls == [10] && m.listCalls == [10])
}
@Test func descendantsRetainExitAndReadPermissionFailure() throws {
    let m = TreeMock(); m.failMemory = 10
    var c = DescendantCollector(plan: descendantPlan(), reader: m.reader, started: 100)
    var rows: [DescendantObservation] = []; try c.tick(deadline: 101) { rows.append($0) }
    #expect(rows.first?.state == .memoryFailed && rows.first?.errorCode == EPERM && rows.first?.before == rows.first?.after && rows.first?.residentBytes == nil)
    m.tree.removeValue(forKey: 10); rows = []; try c.tick(deadline: 101) { rows.append($0) }
    #expect(rows.first?.state == .unreadableBefore && rows.first?.errorCode == ESRCH)
}
@Test func descendantsDropMetricsIfProcessExitsDuringRead() throws {
    let m = TreeMock(); m.afterMemory = { pid in m.tree.removeValue(forKey: pid) }
    var c = DescendantCollector(plan: descendantPlan(), reader: m.reader, started: 100)
    var rows: [DescendantObservation] = []; try c.tick(deadline: 101) { rows.append($0) }
    #expect(rows.first?.state == .unreadableAfter && rows.first?.physicalFootprintBytes == nil)
}
@Test func descendantsListPermissionFailureIsNotEmptyTree() throws {
    let m = TreeMock(); m.failList = 10
    var c = DescendantCollector(plan: descendantPlan(), reader: m.reader, started: 100)
    var rows: [DescendantObservation] = []; try c.tick(deadline: 101) { rows.append($0) }
    #expect(rows.first?.state == .enumerationFailed && rows.first?.errorCode == EACCES && rows.first?.children == nil && rows.first?.residentBytes == nil)
}
@Test func descendantsSaturationAndMalformedListsAreExplicit() throws {
    let m = TreeMock(); m.saturated = true
    var c = DescendantCollector(plan: descendantPlan(), reader: m.reader, started: 100)
    var rows: [DescendantObservation] = []; try c.tick(deadline: 101) { rows.append($0) }
    #expect(rows.first?.state == .enumerationCapacity)
    m.saturated = false; m.lists[10] = [11, 11]; rows = []
    try c.tick(deadline: 101) { rows.append($0) }
    #expect(rows.count == 1 && rows.first?.state == .malformedEnumeration && c.bindings.count == 1)
}
@Test func descendantsDepthAndProcessLimitsPreventFurtherReads() throws {
    for depthLimit in [true, false] {
        let m = TreeMock(); m.tree[11] = relation(11, parent: 10); m.tree[12] = relation(12, parent: 11); m.lists = [10: [11], 11: [12]]
        var plan = descendantPlan(); if depthLimit { plan.maxDepth = 1 } else { plan.maxProcesses = 2 }
        var c = DescendantCollector(plan: plan, reader: m.reader, started: 100)
        var rows: [DescendantObservation] = []; try c.tick(deadline: 101) { rows.append($0) }
        #expect(rows.last?.state == (depthLimit ? .depthLimit : .processLimit) && m.memoryCalls == [10, 11] && c.bindings.count == 2)
    }
}
@Test func descendantsCandidateBudgetAndDeadlineBoundWork() throws {
    let m = TreeMock(); m.lists[10] = [11, 12, 13, 14, 15]
    var c = DescendantCollector(plan: descendantPlan(), reader: m.reader, started: 100)
    var rows: [DescendantObservation] = []; try c.tick(deadline: 101) { rows.append($0) }
    #expect(rows.last?.state == .candidateLimit)
    rows = []; m.memoryCalls = []; try c.tick(deadline: 99) { rows.append($0) }
    #expect(rows.count == 1 && rows.first?.state == .timeLimit && m.memoryCalls.isEmpty)
}
@Test func descendantPlanRejectsUnsafeBoundsAndUnknownKeys() throws {
    var p = descendantPlan(); try p.validate(expectedUID: 4501)
    #expect(throws: InstrumentError.self) { try p.validate(expectedUID: 4502) }
    p.maxProcesses = 17; #expect(throws: InstrumentError.self) { try p.validate(expectedUID: 4501) }
    p = descendantPlan(); p.maxDepth = 5; #expect(throws: InstrumentError.self) { try p.validate(expectedUID: 4501) }
    p = descendantPlan(); p.seconds = 601; #expect(throws: InstrumentError.self) { try p.validate(expectedUID: 4501) }
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(descendantPlan())) as! [String: Any]; json["pid"] = 5
    #expect(throws: InstrumentError.self) { try StrictJSON.decodeExact(DescendantMemoryPlan.self, from: JSONSerialization.data(withJSONObject: json)) }
}
@Test func descendantsRecheckAncestorsBeforeDescendantMemory() throws {
    let m = TreeMock(); m.tree[11] = relation(11, parent: 10); m.tree[12] = relation(12, parent: 11); m.lists = [10: [11], 11: [12]]
    var c = DescendantCollector(plan: descendantPlan(), reader: m.reader, started: 100)
    try c.tick(deadline: 101) { _ in }
    m.tree[11]!.parentPID = 2; m.memoryCalls = []; m.listCalls = []
    var rows: [DescendantObservation] = []; try c.tick(deadline: 101) { rows.append($0) }
    #expect(m.memoryCalls == [10] && m.listCalls == [10] && rows.last?.before.count == 2 && rows.last?.state == .scopeChangedBefore)
}
@Test func descendantsCandidateReuseDuringDiscoveryIsNotRegistered() throws {
    let m = TreeMock(); m.lists[10] = [11]
    var childReads = 0
    var reader = m.reader
    let base = reader.relation
    reader.relation = { pid in
        if pid == 11 { childReads += 1; var child = relation(11, parent: 10); if childReads > 1 { child.identity.startSeconds += 1 }; return child }
        return try base(pid)
    }
    var c = DescendantCollector(plan: descendantPlan(), reader: reader, started: 100)
    var rows: [DescendantObservation] = []; try c.tick(deadline: 101) { rows.append($0) }
    #expect(c.bindings.count == 1 && rows.last?.state == .candidateChanged && m.memoryCalls == [10])
}
@Test func descendantsDoNotEnumeratePIDReusedDuringMemoryRead() throws {
    let m = TreeMock(); m.afterMemory = { pid in m.tree[pid]!.identity.startSeconds += 1 }
    var c = DescendantCollector(plan: descendantPlan(), reader: m.reader, started: 100)
    var rows: [DescendantObservation] = []; try c.tick(deadline: 101) { rows.append($0) }
    #expect(m.listCalls.isEmpty && rows.first?.state == .scopeChangedAfter && rows.first?.physicalFootprintBytes == nil)
}
@Test func descendantsReportGapsWithoutFullTreeClaim() throws {
    let expected = IdentityExpectation(uid: 4501, gid: 4500, kernelGroups: [4500], requiredGroups: [4500], forbiddenGroups: [], auditSessionID: 123, onConsole: false)
    let identity = IdentityCheck(uid: 4501, gid: 4500, realUID: 4501, realGID: 4500, kernelGroups: [4500], groupMembership: [], mismatches: [])
    let stamp = ClockStamp(monotonic: 99, utc: 1800000099, bootIDHash: String(repeating: "a", count: 64), uncertainty: 0)
    var record = DescendantMemoryRecording(plan: descendantPlan(), expected: expected, initialIdentity: identity,
        signature: ProbeSignature(hardenedRuntime: true, forbiddenEntitlementPresent: false), started: stamp, finished: stamp)
    record.window = Window(start: 100, end: 103); record.ticks = [100, 103]; record.pollingWindowCompleted = true
    record.bindings = [DescendantBinding(index: 0, depth: 0, process: relation(10), discoveredAt: 100)]
    record.observations = [DescendantObservation(operation: "poll", index: 0, readStarted: 100, time: 100.01, state: .sampled,
        physicalFootprintBytes: 12 * 1024 * 1024, residentBytes: 15 * 1024 * 1024)]
    let report = descendantReport(record)
    #expect(report.processes[0].physicalFootprintBytes?.minimum == 12_582_912.0)
    #expect(report.processes[0].residentBytes?.maximum == 15_728_640.0)
    #expect(report.issues.contains("polling gap exceeds 2 seconds") && !report.fullTreeAttributionComplete && !report.wholeUIDAttributionComplete && report.quickProcessesMayBeMissed)
}
