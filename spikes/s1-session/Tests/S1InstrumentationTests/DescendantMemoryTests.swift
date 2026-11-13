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

@Test func descendantsDeadlineAfterEachOperationStopsFurtherReads() throws {
    // Root poll: metadata, memory, metadata, enumeration, metadata.
    // Candidate admission: parent metadata, child metadata, parent metadata, child metadata.
    for slowOperation in 1...9 {
        var now = 100.0, calls: [String] = []
        func operation(_ name: String) { calls.append(name); if calls.count == slowOperation { now = 102 } }
        let reader = DescendantReader(relation: { pid in
            operation("identity-\(pid)"); return relation(pid, parent: pid == 10 ? 1 : 10)
        }, memory: { pid in operation("memory-\(pid)"); return (12, 34) }, children: { pid, _ in
            operation("children-\(pid)"); return ([11], false)
        }, now: { now })
        var collector = DescendantCollector(plan: descendantPlan(), reader: reader, started: 100)
        var rows: [DescendantObservation] = []
        try collector.tick(deadline: 101) { rows.append($0) }
        #expect(calls.count == slowOperation)
        #expect(rows.last?.state == .timeLimit && rows.last?.time == 102)
        #expect(rows.last?.physicalFootprintBytes == nil && rows.last?.residentBytes == nil)
        #expect(collector.bindings.count == 1)
        if slowOperation == 1 { #expect(calls == ["identity-10"]) }
        if slowOperation == 2 { #expect(calls == ["identity-10", "memory-10"]) }
    }
}
@Test func descendantsDeadlineEqualityStopsAtEntryAndBetweenOperations() throws {
    let mock = TreeMock(); mock.now = 101
    var collector = DescendantCollector(plan: descendantPlan(), reader: mock.reader, started: 100)
    var rows: [DescendantObservation] = []
    try collector.tick(deadline: 101) { rows.append($0) }
    #expect(mock.memoryCalls.isEmpty && mock.listCalls.isEmpty && rows.first?.state == .timeLimit)

    var clockReads = 0, identityReads = 0, memoryReads = 0, listReads = 0
    // Entry, timestamp, pre-metadata and post-metadata are in budget. The next operation's
    // pre-call check lands EXACTLY on the deadline, before a memory read may be admitted.
    let reader = DescendantReader(relation: { _ in identityReads += 1; return relation(10) },
        memory: { _ in memoryReads += 1; return (12, 34) },
        children: { _, _ in listReads += 1; return ([], false) },
        now: { clockReads += 1; return clockReads < 5 ? 100 : 101 })
    collector = DescendantCollector(plan: descendantPlan(), reader: reader, started: 100)
    rows = []; try collector.tick(deadline: 101) { rows.append($0) }
    #expect(identityReads == 1 && memoryReads == 0 && listReads == 0)
    #expect(rows.first?.state == .timeLimit && rows.first?.physicalFootprintBytes == nil)
}
@Test func descendantsDeadlineIsCheckedForEachKnownAncestor() throws {
    let mock = TreeMock(); mock.tree[11] = relation(11, parent: 10); mock.tree[12] = relation(12, parent: 11)
    mock.lists = [10: [11], 11: [12]]
    var collector = DescendantCollector(plan: descendantPlan(), reader: mock.reader, started: 100)
    try collector.tick(deadline: 101) { _ in }
    #expect(collector.bindings.count == 3)
    var calls: [String] = []
    var reader = mock.reader
    let originalRelation = reader.relation, originalMemory = reader.memory, originalChildren = reader.children
    reader.relation = { pid in
        calls.append("identity-\(pid)")
        // Five calls complete the root poll. The child's first ancestry element overruns.
        if calls.count == 6 { mock.now = 101 }
        return try originalRelation(pid)
    }
    reader.memory = { pid in calls.append("memory-\(pid)"); return try originalMemory(pid) }
    reader.children = { pid, capacity in calls.append("children-\(pid)"); return try originalChildren(pid, capacity) }
    var bounded = DescendantCollector(plan: descendantPlan(), reader: reader, started: 100)
    bounded.bindings = collector.bindings
    var rows: [DescendantObservation] = []; try bounded.tick(deadline: 101) { rows.append($0) }
    #expect(calls == ["identity-10", "memory-10", "identity-10", "children-10", "identity-10", "identity-10"])
    #expect(rows.count == 2 && rows.last?.index == 1 && rows.last?.state == .timeLimit)
    #expect(rows.last?.physicalFootprintBytes == nil)
}
@Test func descendantsSlowEmissionStopsCandidateTraversalWithoutReads() throws {
    let mock = TreeMock(); mock.tree[11] = relation(11, parent: 10); mock.lists[10] = [11]
    var collector = DescendantCollector(plan: descendantPlan(), reader: mock.reader, started: 100)
    var rows: [DescendantObservation] = []
    try collector.tick(deadline: 101) { point in rows.append(point); mock.now = 101 }
    #expect(rows.count == 2 && rows[0].state == .sampled && rows[1].state == .timeLimit)
    #expect(collector.bindings.count == 1 && mock.memoryCalls == [10] && mock.listCalls == [10])
    #expect(rows[1].before.isEmpty && rows[1].physicalFootprintBytes == nil)
}

@Test func descendantsJournalFailureStopsBeforeNewDescendantReads() throws {
    let mock = TreeMock(); mock.tree[11] = relation(11, parent: 10); mock.lists[10] = [11]
    var collector = DescendantCollector(plan: descendantPlan(), reader: mock.reader, started: 100)
    var durable: [DescendantObservation] = []
    #expect(throws: InstrumentError.self) {
        try collector.tick(deadline: 101) { point in
            if point.operation == "discover" { throw InstrumentError("synthetic journal failure") }
            durable.append(point)
        }
    }
    #expect(durable.count == 1 && durable[0].state == .sampled)
    #expect(mock.memoryCalls == [10] && mock.listCalls == [10])
}

@Test func descendantsJournalPreservesPrefixOnRowBoundAndRefusesReuse() throws {
    let runID = "fixture-descendant-journal-" + UUID().uuidString
    let dataset = try Dataset(runID: runID, role: "descendant-memory")
    let journal = try dataset.descendantJournal(runID: runID)
    let point = DescendantObservation(operation: "poll", index: 0, readStarted: 100, time: 100.001,
        state: .sampled, physicalFootprintBytes: 1024, residentBytes: 2048)
    try journal.append(point)
    let url = URL(fileURLWithPath: dataset.path).appendingPathComponent("descendants.jsonl")
    let prefix = try Data(contentsOf: url)
    let entry = try JSONSerialization.jsonObject(with: prefix) as! [String: Any]
    #expect(entry["mode"] as? String == "descendant-memory" && entry["sequence"] as? Int == 0)
    var oversized = point; oversized.children = Array(1...4096)
    #expect(throws: InstrumentError.self) { try journal.append(oversized) }
    #expect(try Data(contentsOf: url) == prefix)
    #expect(throws: InstrumentError.self) { try dataset.descendantJournal(runID: runID) }
    #expect(try Data(contentsOf: url) == prefix)
    #expect(!FileManager.default.fileExists(atPath: dataset.path + "/recording.json"))
    // A rejected row consumes neither bytes nor a sequence number.
    try journal.append(point)
    let rows = try Data(contentsOf: url).split(separator: 10)
    let last = try JSONSerialization.jsonObject(with: Data(rows[1])) as! [String: Any]
    #expect(rows.count == 2 && last["sequence"] as? Int == 1)
}
