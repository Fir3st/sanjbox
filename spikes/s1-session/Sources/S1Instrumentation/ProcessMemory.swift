import Darwin
import Foundation

public struct ProcessMemoryPlan: Codable, Equatable, Sendable {
    public var runID: String
    public var seconds: Double
    /// Fixed owned synthetic allocation, touched before measurement. Includes recorder overhead.
    public var fixtureMiB: Int
    public func validate() throws {
        try require(identifier(runID) && seconds.isFinite && (1...600).contains(seconds) && (0...64).contains(fixtureMiB), "invalid process-memory plan")
    }
}
public struct ProcessRegistration: Codable, Equatable, Hashable, Sendable {
    public var pid: Int32
    public var uid: UInt32
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64
    public var role: String
    func validate() throws {
        try require(pid > 0 && uid > 0 && startSeconds > 0 && startMicroseconds < 1_000_000 && role == "owned-recorder-fixture", "invalid registered process")
    }
}
public struct ProcessMemoryPoint: Codable, Equatable, Sendable {
    public var time: Double
    public var physicalFootprintBytes: UInt64?
    public var residentBytes: UInt64?
    public var error: String?
}
public struct ProcessMemoryRecording: Codable, Sendable {
    public var schemaVersion = 1
    public var source: String
    public var plan: ProcessMemoryPlan
    public var expected: IdentityExpectation
    public var initialIdentity: IdentityCheck
    public var finalIdentity: IdentityCheck?
    public var signature: ProbeSignature
    public var registration: ProcessRegistration?
    public var started: ClockStamp
    public var finished: ClockStamp
    public var window: Window?
    public var samples: [ProcessMemoryPoint] = []
    public var errors: [String] = []
}
public struct ProcessMemoryReport: Codable, Sendable {
    public var scope = "registered own fixture process only; diagnostic attribution, never sum with RSS or system RAM delta"
    public var fullSessionAttributionComplete = false
    public var processes: [ProcessMemorySummary]
}
public struct ProcessMemorySummary: Codable, Sendable {
    public var runID: String
    public var source: String
    public var registration: ProcessRegistration?
    public var evidenceComplete: Bool
    public var issues: [String]
    public var physicalFootprintBytes: Distribution?
    public var residentBytes: Distribution?
}

/// Deliberately no PID parameter and no process enumeration/path/name/environment access.
/// This can only sample the process executing this code, after preregistration in intent.json.
enum OwnProcessMemory {
    static func registration() throws -> ProcessRegistration {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        try require(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size &&
            info.pbi_pid == UInt32(getpid()) && info.pbi_uid == geteuid() && info.pbi_ruid == getuid() && geteuid() == getuid(), "own process identity unavailable")
        return ProcessRegistration(pid: getpid(), uid: geteuid(), startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec, role: "owned-recorder-fixture")
    }
    static func sameInstance(_ expected: ProcessRegistration, _ before: ProcessRegistration, _ after: ProcessRegistration) -> Bool {
        expected == before && before == after
    }
    static func sample(_ expected: ProcessRegistration) -> ProcessMemoryPoint {
        do {
            let before = try registration()
            try require(before == expected, "registered process identity changed before sample")
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
            }
            try require(status == 0, "own process memory unavailable")
            try require(sameInstance(expected, before, try registration()), "registered process identity changed during sample")
            return ProcessMemoryPoint(time: InstrumentClock.now(), physicalFootprintBytes: usage.ri_phys_footprint, residentBytes: usage.ri_resident_size)
        } catch {
            return ProcessMemoryPoint(time: InstrumentClock.now(), error: String(describing: error))
        }
    }
}

extension InstrumentRunner {
    public static func processMemory(plan: ProcessMemoryPlan, expected: IdentityExpectation) throws -> (path: String, valid: Bool) {
        try plan.validate(); try expected.validate()
        let identity = expected.capture()
        let signature = try ProbeSignature.capture()
        try require(signature.valid, "invalidMeasurement: unsafe own signature; no process probe started")
        let started = try InstrumentClock.stamp()
        var record = ProcessMemoryRecording(source: "measured", plan: plan, expected: expected, initialIdentity: identity,
            signature: signature, started: started, finished: started)
        if identity.matches(expected) { record.registration = try OwnProcessMemory.registration() }
        else { record.errors.append("invalidMeasurement: initial identity; no process probe started") }
        let dataset = try Dataset(runID: plan.runID, role: "process-memory")
        // Registration is saved before memory sampling or allocation. No external target is permitted.
        try dataset.write("intent.json", record)
        if let registration = record.registration {
            let bytes = plan.fixtureMiB * 1024 * 1024
            let allocation = UnsafeMutableRawPointer.allocate(byteCount: max(1, bytes), alignment: 16384)
            defer { allocation.deallocate() }
            memset(allocation, 0x5a, bytes)
            let begin = InstrumentClock.now()
            let end = begin + plan.seconds
            record.window = Window(start: begin, end: end)
            record.samples.append(OwnProcessMemory.sample(registration))
            var next = begin + 1
            while next < end {
                InstrumentClock.wait(until: next)
                record.samples.append(OwnProcessMemory.sample(registration))
                next = begin + floor(InstrumentClock.now() - begin) + 1
            }
            InstrumentClock.wait(until: end)
            record.samples.append(OwnProcessMemory.sample(registration))
            // Observable read keeps the synthetic allocation alive through the last sample.
            if bytes > 0 && allocation.load(as: UInt8.self) != 0x5a { record.errors.append("fixture changed unexpectedly") }
            record.finalIdentity = expected.capture()
            if !record.finalIdentity!.matches(expected) { record.errors.append("invalidMeasurement: final identity") }
        }
        record.finished = try InstrumentClock.stamp()
        try dataset.write("recording.json", SupplementaryBundle(memory: [record]))
        let report = try SupplementaryAnalyzer.memory([record])
        return (dataset.path, report.processes.allSatisfy(\.evidenceComplete))
    }
}

extension SupplementaryAnalyzer {
    static func memory(_ records: [ProcessMemoryRecording]) throws -> ProcessMemoryReport {
        try require((1...128).contains(records.count), "process record count bound")
        var instances = Set<String>(), runs = Set<String>()
        let summaries = try records.map { record -> ProcessMemorySummary in
            try record.plan.validate(); try record.expected.validate()
            try require(record.schemaVersion == 1 && ["measured", "fixture", "external-synthetic"].contains(record.source), "process evidence schema/source")
            try require(runs.insert(record.plan.runID).inserted && record.samples.count <= 602 && record.errors.count <= 64 &&
                record.errors.allSatisfy({ $0.utf8.count <= 256 }), "duplicate run or oversized process evidence")
            var issues = record.errors + (try clockIssues(record.started, record.finished))
            if !record.initialIdentity.matches(record.expected) || record.finalIdentity?.matches(record.expected) != true { issues.append("invalid process recorder identity") }
            if !record.signature.valid { issues.append("unsafe recorder signature") }
            if let registration = record.registration {
                try registration.validate()
                let key = "\(record.started.bootIDHash)-\(registration.pid)-\(registration.startSeconds)-\(registration.startMicroseconds)"
                try require(instances.insert(key).inserted, "duplicate process instance; no double counting")
                if registration.uid != record.expected.uid { issues.append("registered process owner differs") }
            } else { issues.append("missing process registration") }
            var footprint: [Double] = [], resident: [Double] = []
            var previous = -Double.infinity
            for sample in record.samples {
                try require(boundedTime(sample.time) && sample.time > previous, "unordered process samples")
                previous = sample.time
                if sample.time < record.started.monotonic || sample.time > record.finished.monotonic { issues.append("sample outside recorder envelope") }
                if let error = sample.error {
                    try require(!error.isEmpty && error.utf8.count <= 256 && sample.physicalFootprintBytes == nil && sample.residentBytes == nil, "ambiguous failed process sample")
                    issues.append("unreadable process sample")
                } else if let f = sample.physicalFootprintBytes, let r = sample.residentBytes {
                    try require(f <= 1 << 60 && r <= 1 << 60, "process memory value out of bounds")
                    footprint.append(Double(f)); resident.append(Double(r))
                } else { issues.append("missing process memory sample") }
            }
            if let w = record.window {
                try require(boundedTime(w.start) && boundedTime(w.end) && abs(w.duration - record.plan.seconds) <= 0.000001, "invalid process window")
                if w.start < record.started.monotonic || w.end > record.finished.monotonic { issues.append("incomplete process recorder envelope") }
                let times = record.samples.map(\.time)
                if times.contains(where: { $0 < w.start || $0 > w.end + 1 }) { issues.append("process sample outside measurement acquisition") }
                if times.isEmpty || times.first! - w.start > 0.1 || times.last! < w.end || times.last! - w.end > 1 { issues.append("missing process endpoints") }
                if zip(times, times.dropFirst()).contains(where: { $1 - $0 > 2 }) { issues.append("process sample gap exceeds 2 seconds") }
            } else { issues.append("missing process measurement window") }
            return ProcessMemorySummary(runID: record.plan.runID, source: record.source, registration: record.registration,
                evidenceComplete: issues.isEmpty, issues: issues,
                physicalFootprintBytes: footprint.isEmpty ? nil : Distribution(footprint), residentBytes: resident.isEmpty ? nil : Distribution(resident))
        }
        return ProcessMemoryReport(processes: summaries)
    }
}
