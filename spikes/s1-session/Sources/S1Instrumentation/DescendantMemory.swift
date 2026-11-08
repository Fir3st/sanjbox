import Darwin
import Foundation

/// Numeric process identity and direct parent only. No names, argv, environment or task ports.
public struct ProcessRelation: Codable, Equatable, Sendable {
    public var identity: TestProcessIdentity
    public var parentPID: Int32
}
public struct DescendantMemoryPlan: Codable, Sendable {
    public var runID: String
    public var seconds: Double
    public var root: ProcessRelation
    public var provenanceSHA256: String
    public var maxProcesses: Int
    public var maxDepth: Int
    public func validate(expectedUID: UInt32) throws {
        try root.identity.validate()
        try require(identifier(runID) && seconds.isFinite && (1...600).contains(seconds) &&
            root.identity.uid == expectedUID && root.parentPID > 0 && root.parentPID != root.identity.pid &&
            digest(provenanceSHA256) && (1...16).contains(maxProcesses) && (1...4).contains(maxDepth), "invalid descendant plan/root/limits")
    }
}
public struct DescendantBinding: Codable, Sendable {
    public var index: Int
    public var parentIndex: Int?
    public var depth: Int
    public var process: ProcessRelation
    public var discoveredAt: Double
}
public enum DescendantState: String, Codable, Sendable {
    case sampled, discovered, unreadableBefore, scopeChangedBefore, unreadableAfter, scopeChangedAfter
    case memoryFailed, enumerationFailed, enumerationCapacity, malformedEnumeration
    case candidateUnreadable, candidateChanged, candidateOutOfScope, reusedPID
    case depthLimit, processLimit, candidateLimit, timeLimit
}
public struct DescendantObservation: Codable, Sendable {
    /// `poll` combines one process memory read and its child-list call within the same scope checks.
    public var operation: String
    public var index: Int
    public var candidatePID: Int32?
    public var readStarted: Double
    public var time: Double
    public var state: DescendantState
    public var before: [ProcessRelation] = []
    public var afterMemory: [ProcessRelation] = []
    public var after: [ProcessRelation] = []
    public var children: [Int32]?
    public var errorCode: Int32?
    public var physicalFootprintBytes: UInt64?
    public var residentBytes: UInt64?
}
public struct DescendantMemoryRecording: Codable, Sendable {
    public var schemaVersion = 1
    public var source = "measured-descendants"
    public var plan: DescendantMemoryPlan
    public var expected: IdentityExpectation
    public var initialIdentity: IdentityCheck
    public var finalIdentity: IdentityCheck?
    public var signature: ProbeSignature
    public var started: ClockStamp
    public var finished: ClockStamp
    public var window: Window?
    public var ticks: [Double] = []
    public var bindings: [DescendantBinding] = []
    public var observations: [DescendantObservation] = []
    public var errors: [String] = []
    public var pollingWindowCompleted = false
}
public struct DescendantMemorySummary: Codable, Sendable {
    public var binding: DescendantBinding
    public var successfulSamples: Int
    public var states: [String: Int]
    public var physicalFootprintBytes: Distribution?
    public var residentBytes: Distribution?
}
public struct DescendantMemoryReport: Codable, Sendable {
    public var scope = "polling descendants of one explicitly registered same-UID test root; separate footprint/resident diagnostics, never add to systemDeltaM"
    public var fullTreeAttributionComplete = false
    public var fullSessionAttributionComplete = false
    public var wholeUIDAttributionComplete = false
    public var windowServerAttributionComplete = false
    public var crossUIDClientAttributionComplete = false
    public var provenanceArtifactsVerified = false
    public var quickProcessesMayBeMissed = true
    public var pollingWindowCompleted: Bool
    public var issues: [String]
    public var processes: [DescendantMemorySummary]
}

struct DescendantReader {
    var relation: (Int32) throws -> ProcessRelation
    var memory: (Int32) throws -> (footprint: UInt64, resident: UInt64)
    /// Fixed-capacity child list; `saturated` cannot be interpreted as a complete list.
    var children: (Int32, Int) throws -> (pids: [Int32], saturated: Bool)
    var now: () -> Double
    static var native: DescendantReader { DescendantReader(relation: { pid in
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { throw ProcessReadFailure(code: errno == 0 ? EIO : errno) }
        guard info.pbi_status != UInt32(SZOMB) else { throw ProcessReadFailure(code: ESRCH) }
        return ProcessRelation(identity: TestProcessIdentity(pid: Int32(bitPattern: info.pbi_pid), uid: info.pbi_uid, realUID: info.pbi_ruid,
            startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec), parentPID: Int32(bitPattern: info.pbi_ppid))
    }, memory: RegisteredProcessReader.native.memory, children: { pid, capacity in
        var buffer = [Int32](repeating: 0, count: capacity)
        errno = 0
        // libproc's proc_listchildpids returns a PID COUNT (unlike proc_listpids' byte count).
        let count = proc_listchildpids(pid, &buffer, Int32(capacity * MemoryLayout<Int32>.size))
        guard count >= 0 && errno == 0 else { throw ProcessReadFailure(code: errno == 0 ? EIO : errno) }
        guard count <= capacity else { throw ProcessReadFailure(code: EOVERFLOW) }
        return (Array(buffer.prefix(Int(count))), Int(count) == capacity)
    }, now: InstrumentClock.now) }
}

/// Only the normal runner constructs this with a native reader, AFTER credentials/signature gates.
/// All candidate PIDs come from a checked parent's child list; there is no global/UID enumeration.
struct DescendantCollector {
    let plan: DescendantMemoryPlan
    let reader: DescendantReader
    var bindings: [DescendantBinding]
    init(plan: DescendantMemoryPlan, reader: DescendantReader, started: Double) {
        self.plan = plan; self.reader = reader
        bindings = [DescendantBinding(index: 0, depth: 0, process: plan.root, discoveredAt: started)]
    }
    func chain(_ index: Int) -> [ProcessRelation] {
        var indices = [index], cursor = bindings[index].parentIndex
        while let parent = cursor { indices.append(parent); cursor = bindings[parent].parentIndex }
        return indices.reversed().map { bindings[$0].process }
    }
    /// Save even a partial/changed chain. Do not inspect descendants past the first failed ancestor.
    func check(_ expected: [ProcessRelation], into values: inout [ProcessRelation]) throws -> Bool {
        for process in expected {
            let actual = try reader.relation(process.identity.pid)
            values.append(actual)
            if actual != process { return false }
        }
        return true
    }
    func checkedBefore(_ expected: [ProcessRelation], point: inout DescendantObservation) -> Bool {
        do {
            if try check(expected, into: &point.before) { return true }
            point.state = .scopeChangedBefore
        } catch { point.state = .unreadableBefore; point.errorCode = (error as? ProcessReadFailure)?.code ?? EIO }
        return false
    }
    func checkedAfter(_ expected: [ProcessRelation], point: inout DescendantObservation) -> Bool {
        do {
            if try check(expected, into: &point.after) { return true }
            point.state = .scopeChangedAfter
        } catch { point.state = .unreadableAfter; point.errorCode = (error as? ProcessReadFailure)?.code ?? EIO }
        return false
    }
    mutating func tick(deadline: Double, emit: (DescendantObservation) throws -> Void) throws {
        var index = 0, candidates = 0
        while index < bindings.count {
            if reader.now() > deadline { try emit(DescendantObservation(operation: "limit", index: index, readStarted: reader.now(), time: reader.now(), state: .timeLimit)); return }
            let expected = chain(index), binding = bindings[index]
            var point = DescendantObservation(operation: "poll", index: index, readStarted: reader.now(), time: 0, state: .sampled)
            if checkedBefore(expected, point: &point) {
                var metrics: (footprint: UInt64, resident: UInt64)?
                var listed: (pids: [Int32], saturated: Bool)?
                do { metrics = try reader.memory(binding.process.identity.pid) }
                catch { point.state = .memoryFailed; point.errorCode = (error as? ProcessReadFailure)?.code ?? EIO }
                // Recheck immediately after memory, BEFORE using this PID as a discovery parent.
                let memoryScopeValid = checkedAfter(expected, point: &point)
                point.afterMemory = point.after; point.after = []
                if memoryScopeValid {
                    do { listed = try reader.children(binding.process.identity.pid, plan.maxProcesses + 1) }
                    catch { point.state = .enumerationFailed; point.errorCode = (error as? ProcessReadFailure)?.code ?? EIO }
                }
                if memoryScopeValid && checkedAfter(expected, point: &point), let list = listed {
                    point.children = list.pids
                    if list.pids.count > plan.maxProcesses + 1 || list.pids.contains(where: { $0 <= 0 }) || Set(list.pids).count != list.pids.count {
                        point.state = .malformedEnumeration
                    } else if list.saturated { point.state = .enumerationCapacity }
                    // A failed combined observation never publishes numeric memory values.
                    if point.state == .sampled, let metrics {
                        point.physicalFootprintBytes = metrics.footprint; point.residentBytes = metrics.resident
                    }
                }
            }
            point.time = reader.now()
            try emit(point)
            // Only a successful checked enumeration permits candidate identity reads.
            if [.sampled, .memoryFailed, .enumerationCapacity].contains(point.state), let children = point.children {
                for pid in children {
                    if let old = bindings.first(where: { $0.process.identity.pid == pid }), old.parentIndex == index { continue }
                    var event = DescendantObservation(operation: "discover", index: index, candidatePID: pid, readStarted: reader.now(), time: 0, state: .discovered)
                    if binding.depth >= plan.maxDepth { event.state = .depthLimit }
                    else if bindings.count >= plan.maxProcesses { event.state = .processLimit }
                    else if candidates >= plan.maxProcesses { event.state = .candidateLimit }
                    else if reader.now() > deadline { event.state = .timeLimit }
                    else {
                        candidates += 1
                        if checkedBefore(expected, point: &event) {
                            do {
                                let child = try reader.relation(pid)
                                event.before.append(child)
                                if child.identity.pid != pid || child.identity.uid != plan.root.identity.uid || child.identity.realUID != plan.root.identity.uid || child.parentPID != binding.process.identity.pid {
                                    event.state = .candidateOutOfScope
                                } else {
                                    try child.identity.validate()
                                    if checkedAfter(expected, point: &event) {
                                        let after = try reader.relation(pid); event.after.append(after)
                                        if after != child { event.state = .candidateChanged }
                                        else if bindings.contains(where: { $0.process.identity.pid == pid }) { event.state = .reusedPID }
                                        else { bindings.append(DescendantBinding(index: bindings.count, parentIndex: index, depth: binding.depth + 1, process: child, discoveredAt: reader.now())) }
                                    }
                                }
                            } catch { event.state = .candidateUnreadable; event.errorCode = (error as? ProcessReadFailure)?.code ?? EIO }
                        }
                    }
                    event.time = reader.now(); try emit(event)
                }
            }
            index += 1
        }
    }
}

extension InstrumentRunner {
    public static func descendantMemory(plan: DescendantMemoryPlan, expected: IdentityExpectation) throws -> (path: String, valid: Bool) {
        try expected.validate(); try plan.validate(expectedUID: expected.uid)
        let identity = expected.capture(), signature = try ProbeSignature.capture()
        try require(signature.valid, "invalidMeasurement: unsafe collector signature; no descendant read")
        let started = try InstrumentClock.stamp()
        var record = DescendantMemoryRecording(plan: plan, expected: expected, initialIdentity: identity, signature: signature, started: started, finished: started)
        let dataset = try Dataset(runID: plan.runID, role: "descendant-memory")
        try dataset.write("intent.json", record)
        if identity.matches(expected) {
            let begin = InstrumentClock.now(), end = begin + plan.seconds
            record.window = Window(start: begin, end: end)
            var collector = DescendantCollector(plan: plan, reader: .native, started: begin)
            do {
                let journal = try dataset.descendantJournal(runID: plan.runID)
                var next = begin
                while true {
                    InstrumentClock.wait(until: next)
                    record.ticks.append(InstrumentClock.now())
                    try collector.tick(deadline: min(end + 1, record.ticks.last! + 1)) { point in
                        try journal.append(point)
                        record.observations.append(point)
                    }
                    if next >= end { record.pollingWindowCompleted = InstrumentClock.now() <= end + 1; break }
                    if InstrumentClock.now() > end + 1 { record.errors.append("acquisition deadline exceeded"); break }
                    next = min(end, begin + floor(InstrumentClock.now() - begin) + 1)
                }
            } catch { record.errors.append("descendant journal acquisition failed; partial evidence retained") }
            record.bindings = collector.bindings
            record.finalIdentity = expected.capture()
        } else { record.errors.append("invalidMeasurement: initial identity; no target read") }
        record.finished = try InstrumentClock.stamp()
        let report = descendantReport(record)
        try dataset.write("recording.json", record, compact: true)
        try dataset.write("report.json", report)
        return (dataset.path, report.pollingWindowCompleted && report.issues.isEmpty)
    }
}

func descendantReport(_ record: DescendantMemoryRecording) -> DescendantMemoryReport {
    var issues = record.errors
    issues += (try? clockIssues(record.started, record.finished)) ?? ["invalid recorder clock envelope"]
    if !record.initialIdentity.matches(record.expected) || record.finalIdentity?.matches(record.expected) != true { issues.append("invalid collector identity") }
    if !record.signature.valid { issues.append("unsafe collector signature") }
    if !record.pollingWindowCompleted { issues.append("polling window incomplete") }
    if let window = record.window {
        if record.ticks.first.map({ $0 - window.start > 0.1 }) != false || record.ticks.last.map({ $0 < window.end || $0 - window.end > 1 }) != false { issues.append("missing polling endpoints") }
    } else { issues.append("missing polling window") }
    if zip(record.ticks, record.ticks.dropFirst()).contains(where: { $1 - $0 > 2 }) { issues.append("polling gap exceeds 2 seconds") }
    if record.observations.contains(where: { $0.time - $0.readStarted > 1 }) { issues.append("process operation exceeds one second") }
    issues += record.observations.filter { ![.sampled, .discovered].contains($0.state) }.map { $0.state.rawValue }
    let summaries = record.bindings.map { binding in
        let points = record.observations.filter { $0.operation == "poll" && $0.index == binding.index }
        let successful = points.filter { $0.state == .sampled }
        return DescendantMemorySummary(binding: binding, successfulSamples: successful.count,
            states: Dictionary(points.map { ($0.state.rawValue, 1) }, uniquingKeysWith: +),
            physicalFootprintBytes: successful.isEmpty ? nil : Distribution(successful.compactMap { $0.physicalFootprintBytes.map { Double($0) } }),
            residentBytes: successful.isEmpty ? nil : Distribution(successful.compactMap { $0.residentBytes.map { Double($0) } }))
    }
    return DescendantMemoryReport(pollingWindowCompleted: record.pollingWindowCompleted, issues: Array(Set(issues)).sorted(), processes: summaries)
}
