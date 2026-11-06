import Darwin
import Foundation

/// No process names, paths, command lines, environments, task ports, or PID discovery.
public struct TestProcessIdentity: Codable, Equatable, Hashable, Sendable {
    public var pid: Int32
    public var uid: UInt32
    public var realUID: UInt32
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64
    func validate() throws {
        try require(pid > 0 && uid > 0 && realUID == uid && startSeconds > 0 && startMicroseconds < 1_000_000, "invalid test process identity")
    }
    var instanceKey: String { "\(pid)-\(startSeconds)-\(startMicroseconds)" }
}
public enum TestProcessRole: String, Codable, Sendable {
    case application, renderer, simulator, emulator, keeper
    case ownedAllocationFixture, ownedTransientFixture
}
public struct TestProcessRegistration: Codable, Equatable, Sendable {
    public var slot: Int
    public var identity: TestProcessIdentity
    public var role: TestProcessRole
    /// Hash of the operator's external test-process registration/provenance, not opened here.
    public var provenanceSHA256: String
    func validate(uid: UInt32) throws {
        try identity.validate()
        try require((1...32).contains(slot) && identity.uid == uid && digest(provenanceSHA256), "invalid same-UID test registration")
    }
}
public struct ProcessSeriesPlan: Codable, Sendable {
    public var runID: String
    public var seconds: Double
    public var registrations: [TestProcessRegistration]
    public func validate() throws {
        try require(identifier(runID) && seconds.isFinite && (1...600).contains(seconds) && (1...32).contains(registrations.count), "invalid registered process series plan")
        try require(Set(registrations.map(\.slot)).count == registrations.count && Set(registrations.map { $0.identity.pid }).count == registrations.count, "duplicate process slot or PID")
        for value in registrations { try value.validate(uid: value.identity.uid) }
    }
}
extension ProcessSeriesPlan {
    public func validate(expectedUID: UInt32) throws {
        try validate()
        for target in registrations { try target.validate(uid: expectedUID) }
    }
}
public struct ProcessSeriesBinding: Codable, Sendable {
    public var registration: TestProcessRegistration
    /// Registration sealed before any read of this process's memory; may be inside the window.
    public var registeredAt: Double
    public var childIdentity: IdentityCheck?
    public var childSignature: ProbeSignature?
}
public enum ProcessSeriesState: String, Codable, Sendable {
    case sampled, notRegistered, unreadableBefore, identityChangedBefore, readFailed, unreadableAfter, identityChangedAfter
}
public struct ProcessSeriesPoint: Codable, Sendable {
    public var slot: Int
    public var readStarted: Double
    public var time: Double
    public var state: ProcessSeriesState
    public var before: TestProcessIdentity?
    public var after: TestProcessIdentity?
    public var errorCode: Int32?
    public var physicalFootprintBytes: UInt64?
    public var residentBytes: UInt64?
}
public struct ProcessSeriesRecording: Codable, Sendable {
    public var schemaVersion = 1
    public var source: String
    public var runID: String
    public var seconds: Double
    public var expectedSlots: [Int]
    public var expected: IdentityExpectation
    public var initialIdentity: IdentityCheck
    public var finalIdentity: IdentityCheck?
    public var signature: ProbeSignature
    public var started: ClockStamp
    public var finished: ClockStamp
    public var window: Window?
    public var bindings: [ProcessSeriesBinding] = []
    public var samples: [ProcessSeriesPoint] = []
    public var errors: [String] = []
    public var ownedCleanupComplete: Bool?
    public var ownedFixtureResults: [OwnedFixtureOutcome]?
}
public struct RegisteredProcessSummary: Codable, Sendable {
    public var slot: Int
    public var registration: TestProcessRegistration?
    public var fullWindowComplete: Bool
    public var issues: [String]
    public var physicalFootprintBytes: Distribution?
    public var residentBytes: Distribution?
}
public struct ProcessSeriesReport: Codable, Sendable {
    public var scope = "explicit registered same-UID test instances only; footprint and resident are separate diagnostics, never added to systemDeltaM"
    public var fullSessionAttributionComplete = false
    public var unregisteredProcessesCovered = false
    public var windowServerAttributionComplete = false
    public var crossUIDClientAttributionComplete = false
    public var provenanceArtifactsVerified = false
    public var runID: String
    public var source: String
    public var acquisitionComplete: Bool
    public var issues: [String]
    public var processes: [RegisteredProcessSummary]
}

struct ProcessReadFailure: Error { let code: Int32 }
/// Internal injectable numeric reader. No public live API accepts an unregistered PID.
struct RegisteredProcessReader {
    var identity: (Int32) throws -> TestProcessIdentity
    var memory: (Int32) throws -> (footprint: UInt64, resident: UInt64)
    var now: () -> Double
    static var native: RegisteredProcessReader { RegisteredProcessReader(identity: { pid in
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { throw ProcessReadFailure(code: errno) }
        return TestProcessIdentity(pid: Int32(bitPattern: info.pbi_pid), uid: info.pbi_uid, realUID: info.pbi_ruid,
            startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }, memory: { pid in
        var usage = rusage_info_v4()
        errno = 0
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { throw ProcessReadFailure(code: errno) }
        return (usage.ri_phys_footprint, usage.ri_resident_size)
    }, now: InstrumentClock.now) }

    func sample(_ target: TestProcessRegistration) -> ProcessSeriesPoint {
        var point = ProcessSeriesPoint(slot: target.slot, readStarted: now(), time: 0, state: .unreadableBefore)
        do { point.before = try identity(target.identity.pid) }
        catch { point.errorCode = (error as? ProcessReadFailure)?.code ?? EIO; point.time = now(); return point }
        guard point.before == target.identity else { point.state = .identityChangedBefore; point.time = now(); return point }
        var metrics: (footprint: UInt64, resident: UInt64)?
        do { metrics = try memory(target.identity.pid) }
        catch { point.errorCode = (error as? ProcessReadFailure)?.code ?? EIO }
        // The after check is performed even if rusage fails. Failed/reused samples never have metrics.
        do { point.after = try identity(target.identity.pid) }
        catch { point.state = .unreadableAfter; point.errorCode = (error as? ProcessReadFailure)?.code ?? EIO; point.time = now(); return point }
        if point.after != target.identity { point.state = .identityChangedAfter }
        else if let metrics {
            point.state = .sampled; point.physicalFootprintBytes = metrics.footprint; point.residentBytes = metrics.resident
        } else { point.state = .readFailed }
        point.time = now()
        return point
    }
}

public enum ProcessSeriesAnalyzer {
    public static func evaluate(_ record: ProcessSeriesRecording) throws -> ProcessSeriesReport {
        try record.expected.validate()
        try require(record.schemaVersion == 1 && ["measured-registered", "measured-owned-fixtures", "fixture"].contains(record.source) && identifier(record.runID), "invalid process series schema/source")
        try require(record.seconds.isFinite && (1...600).contains(record.seconds) && (1...32).contains(record.expectedSlots.count) &&
            Set(record.expectedSlots).count == record.expectedSlots.count && record.expectedSlots.allSatisfy { (1...32).contains($0) }, "invalid series duration/slots")
        try require(record.bindings.count <= 32 && record.samples.count <= 32 * 602 && record.errors.count <= 64 && record.errors.allSatisfy { $0.utf8.count <= 256 }, "oversize process series")
        var issues = record.errors + (try clockIssues(record.started, record.finished))
        if !record.initialIdentity.matches(record.expected) || record.finalIdentity?.matches(record.expected) != true { issues.append("invalid collector identity") }
        if !record.signature.valid { issues.append("unsafe collector signature") }
        if record.source == "measured-owned-fixtures" && record.ownedCleanupComplete != true { issues.append("owned child cleanup unverified") }
        if record.source == "measured-owned-fixtures" {
            let outcomes = record.ownedFixtureResults ?? []
            try require(outcomes.count <= 2 && Set(outcomes.map(\.slot)).count == outcomes.count, "duplicate owned fixture completion")
            if Set(outcomes.map(\.slot)) != Set(record.expectedSlots) { issues.append("missing owned fixture completion") }
            for outcome in outcomes {
                try require(boundedTime(outcome.started) && boundedTime(outcome.finished) && ["lifetime", "parent-exit", "parent-closed", "protocol-stop"].contains(outcome.reason), "invalid owned fixture completion")
                if !outcome.finalIdentity.matches(record.expected) || outcome.finished < outcome.started || outcome.started < record.started.monotonic || outcome.finished > record.finished.monotonic { issues.append("invalid owned fixture completion identity/time") }
                if let allocation = outcome.allocatedAt {
                    if !boundedTime(allocation) || allocation < outcome.started || allocation > outcome.finished { issues.append("invalid fixture allocation time") }
                } else { issues.append("missing fixture allocation") }
            }
        }
        var instances = Set<String>(), slots = Set<Int>(), pids = Set<Int32>()
        for binding in record.bindings {
            try binding.registration.validate(uid: record.expected.uid)
            try require(record.expectedSlots.contains(binding.registration.slot) && slots.insert(binding.registration.slot).inserted &&
                instances.insert(binding.registration.identity.instanceKey).inserted && pids.insert(binding.registration.identity.pid).inserted, "duplicate or unexpected registered instance/slot")
            try require(boundedTime(binding.registeredAt), "invalid registration time")
            if binding.registeredAt < record.started.monotonic || binding.registeredAt > record.finished.monotonic { issues.append("registration outside recording envelope") }
            if record.source == "measured-owned-fixtures" && (binding.childIdentity?.matches(record.expected) != true || binding.childSignature?.valid != true) { issues.append("invalid owned child identity/signature") }
        }
        try require(record.samples.allSatisfy { record.expectedSlots.contains($0.slot) }, "sample for unknown slot")
        if let window = record.window {
            try require(boundedTime(window.start) && boundedTime(window.end) && abs(window.duration - record.seconds) <= 0.000001, "invalid series window")
            if window.start < record.started.monotonic || window.end > record.finished.monotonic { issues.append("incomplete recording envelope") }
        } else { issues.append("missing measurement window") }
        let summaries = try record.expectedSlots.map { slot -> RegisteredProcessSummary in
            let binding = record.bindings.first { $0.registration.slot == slot }
            let points = record.samples.filter { $0.slot == slot }
            try require(points.count <= 602, "too many samples for process slot")
            var local: [String] = [], footprint: [Double] = [], resident: [Double] = []
            if binding == nil { local.append("missing registration") }
            if let window = record.window, let binding, binding.registeredAt > window.start { local.append("process arrival inside window") }
            var previous = -Double.infinity
            for point in points {
                try require(boundedTime(point.readStarted) && boundedTime(point.time) && point.time >= point.readStarted && point.readStarted > previous, "unordered or overlapping process reads")
                previous = point.time
                if point.readStarted < record.started.monotonic || point.time > record.finished.monotonic { local.append("sample outside recording envelope") }
                if let binding, point.state != .notRegistered && point.readStarted < binding.registeredAt { local.append("sample precedes registration") }
                if point.state == .sampled {
                    try require(point.errorCode == nil && point.physicalFootprintBytes != nil && point.residentBytes != nil, "ambiguous successful process sample")
                    let f = point.physicalFootprintBytes!, r = point.residentBytes!
                    try require(f <= 1 << 60 && r <= 1 << 60, "invalid process memory value")
                    if let binding, point.before == binding.registration.identity && point.after == binding.registration.identity {
                        footprint.append(Double(f)); resident.append(Double(r))
                    } else { local.append("sample identity mismatch/reuse") }
                } else {
                    try require(point.physicalFootprintBytes == nil && point.residentBytes == nil, "failed process sample contains metrics")
                    local.append("process \(point.state.rawValue)")
                }
            }
            if let window = record.window {
                if points.isEmpty || points.first!.readStarted - window.start > 0.1 || points.last!.time < window.end || points.last!.time - window.end > 1 { local.append("missing process endpoints") }
                if points.contains(where: { $0.readStarted < window.start || $0.time > window.end + 1 }) { local.append("sample outside acquisition window") }
                if zip(points, points.dropFirst()).contains(where: { $1.readStarted - $0.time > 2 }) { local.append("process sampling gap exceeds 2 seconds") }
                if points.contains(where: { $0.time - $0.readStarted > 1 }) { local.append("process read exceeds one second") }
            } else { local.append("missing process window") }
            local = Array(Set(local)).sorted()
            return RegisteredProcessSummary(slot: slot, registration: binding?.registration, fullWindowComplete: local.isEmpty,
                issues: local, physicalFootprintBytes: footprint.isEmpty ? nil : Distribution(footprint), residentBytes: resident.isEmpty ? nil : Distribution(resident))
        }
        issues = Array(Set(issues)).sorted()
        return ProcessSeriesReport(runID: record.runID, source: record.source, acquisitionComplete: issues.isEmpty && summaries.allSatisfy(\.fullWindowComplete), issues: issues, processes: summaries)
    }
}

extension InstrumentRunner {
    public static func processSeries(plan: ProcessSeriesPlan, expected: IdentityExpectation) throws -> (path: String, valid: Bool) {
        try expected.validate(); try plan.validate(expectedUID: expected.uid)
        let identity = expected.capture()
        let signature = try ProbeSignature.capture()
        try require(signature.valid, "invalidMeasurement: unsafe collector signature; no registered process read")
        let started = try InstrumentClock.stamp()
        var record = ProcessSeriesRecording(source: "measured-registered", runID: plan.runID, seconds: plan.seconds,
            expectedSlots: plan.registrations.map(\.slot), expected: expected, initialIdentity: identity, signature: signature, started: started, finished: started)
        let dataset = try Dataset(runID: plan.runID, role: "process-series")
        // Numeric targets and external provenance are immutable before process metadata/memory reads.
        try dataset.write("intent.json", RegisteredSeriesIntent(plan: plan, expected: expected, identity: identity, signature: signature, clock: started))
        if identity.matches(expected) {
            record.bindings = plan.registrations.map { ProcessSeriesBinding(registration: $0, registeredAt: InstrumentClock.now()) }
            try dataset.write("registry.json", record.bindings)
            collectProcessSeries(&record)
            record.finalIdentity = expected.capture()
        } else { record.errors.append("invalidMeasurement: initial identity; no target read") }
        record.finished = try InstrumentClock.stamp()
        try dataset.write("recording.json", record)
        let report = try ProcessSeriesAnalyzer.evaluate(record)
        try dataset.write("report.json", report)
        return (dataset.path, report.acquisitionComplete)
    }
    static func collectProcessSeries(_ record: inout ProcessSeriesRecording, beforeTick: ((inout ProcessSeriesRecording) -> Void)? = nil) {
        let begin = InstrumentClock.now(), end = begin + record.seconds
        record.window = Window(start: begin, end: end)
        var next = begin
        while true {
            InstrumentClock.wait(until: next)
            beforeTick?(&record)
            for slot in record.expectedSlots {
                if let binding = record.bindings.first(where: { $0.registration.slot == slot }) {
                    record.samples.append(RegisteredProcessReader.native.sample(binding.registration))
                } else {
                    let now = InstrumentClock.now()
                    record.samples.append(ProcessSeriesPoint(slot: slot, readStarted: now, time: now, state: .notRegistered))
                }
            }
            if next >= end { break }
            // Skip missed ticks. Actual read times expose scheduler stalls; never fill gaps with zeros.
            next = min(end, begin + floor(InstrumentClock.now() - begin) + 1)
        }
    }
}
private struct RegisteredSeriesIntent: Codable {
    var plan: ProcessSeriesPlan
    var expected: IdentityExpectation
    var identity: IdentityCheck
    var signature: ProbeSignature
    var clock: ClockStamp
}
