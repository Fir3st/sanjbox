import Foundation

public struct Distribution: Codable, Equatable, Sendable {
    public var count: Int
    public var minimum: Double
    public var median: Double
    public var p95: Double
    public var maximum: Double
    init(_ samples: [Double]) {
        let sorted = samples.sorted()
        count = sorted.count; minimum = sorted.first!; maximum = sorted.last!
        median = sorted[Int(ceil(Double(count) * 0.5)) - 1]
        p95 = sorted[Int(ceil(Double(count) * 0.95)) - 1]
    }
}
public struct FrameBlock: Codable, Equatable, Sendable {
    public var window: Window
    public var presented: Int
    public var submitted: Int
    public var unpresentedInWindow: Int
    public var timeouts: Int
    public var fps: Double
    public var gapsMilliseconds: Distribution
    public var dropSlots: Int
    public var adverseDropSlots: Int
    public var adverseDropFraction: Double
    public var secondsWithoutFrame: Int
    public var visible: Bool
    public var conditionalTargetsMet: Bool?
}
public struct RAMSummary: Codable, Equatable, Sendable {
    public var occupiedBytes: Distribution
    public var baselineBeforeBytes: Double?
    public var baselineAfterBytes: Double?
    public var baselineBytes: Double?
    public var deltaBytes: Distribution?
    public var negativeDeltaCount: Int?
    public var swapGrowthBytes: Double?
    public var pressureNormal: Bool
    public var conditionalTargetsMet: Bool?
}
public struct Analysis: Codable, Sendable {
    public var profile: Profile
    public var source: String
    public var uid: UInt32
    public var evidenceComplete: Bool
    public var issues: [String]
    public var frameBlocks: [FrameBlock]
    public var ram: RAMSummary?
}
public struct BundleReport: Codable, Sendable {
    public var scope = "instrumentation only; LAB-v1 is a draft; no S1 gate verdict"
    public var analyses: [Analysis]
    public var simultaneousPresentationWindow: Window?
    public var concurrencyIssues: [String]
    public var unverifiedPrerequisites = ["operator workload transitions and W0 idle state", "host interactive response", "session/process continuity", "application/keeper/display configuration and F0.8 approval"]
}
public enum Analyzer {
    public static func evaluate(_ bundle: EvidenceBundle) throws -> BundleReport {
        try require(bundle.schemaVersion == 1 && (1...8).contains(bundle.recordings.count), "unsupported bundle schema or recording count")
        let reports = try bundle.recordings.map(evaluate)
        let traces = bundle.recordings.filter { $0.plan.kind == .presentation }
        var issues: [String] = []
        var overlap: Window?
        if traces.count != 4 { issues.append("requires three distinct zone UIDs/ASIDs plus host presentation") }
        if traces.count == 4 {
            if Set(traces.map { $0.expected.uid }).count != 4 || Set(traces.map { $0.expected.auditSessionID }).count != 4 {
                issues.append("UIDs and audit sessions must be distinct")
            }
            if traces.filter({ $0.expected.onConsole }).count != 1 { issues.append("requires exactly one host console") }
            if Set(traces.map { $0.started.bootIDHash }).count != 1 { issues.append("different boot/clock domains") }
            if Set(traces.map { $0.plan }).count != 1 { issues.append("participants have different preregistered schedules") }
            if traces.contains(where: { $0.source != "measured" }) { issues.append("synthetic fixtures do not prove live concurrency") }
            if reports.contains(where: { !$0.evidenceComplete }) { issues.append("incomplete participant evidence") }
            let starts = traces.map { max($0.plan.window("measurement")!.start, $0.presentation?.measurementAcquisition?.start ?? .infinity) }
            let ends = traces.map { min($0.plan.window("measurement")!.end, $0.presentation?.measurementAcquisition?.end ?? -.infinity) }
            let candidate = Window(start: starts.max()!, end: ends.min()!)
            if candidate.duration < traces[0].plan.window("measurement")!.duration { issues.append("insufficient common measurement window") }
            if issues.isEmpty { overlap = candidate }
        }
        // This is composition evidence only. Host input response, process continuity and the
        // operator's workload/visibility evidence remain separate LAB prerequisites.
        return BundleReport(analyses: reports, simultaneousPresentationWindow: overlap, concurrencyIssues: issues)
    }
    public static func evaluate(_ record: Recording) throws -> Analysis {
        try record.plan.validate(); try record.expected.validate()
        try require(record.schemaVersion == 1 && ["measured", "fixture"].contains(record.source), "unsupported recording schema/source")
        try require(record.errors.count <= 64 && record.boundaries.count <= 10, "oversized record")
        var issues = record.errors
        if !record.initialIdentity.matches(record.expected) { issues.append("invalidMeasurement: initial identity") }
        let stamps = [record.started] + record.boundaries.map(\.actual) + [record.finished]
        for stamp in stamps {
            try require(boundedTime(stamp.monotonic) && stamp.utc.isFinite && (0...10_000_000_000).contains(stamp.utc) &&
                stamp.uncertainty.isFinite && (0...1).contains(stamp.uncertainty), "invalid clock value")
            try require(stamp.bootIDHash.count == 64 && stamp.bootIDHash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }, "invalid boot clock domain")
        }
        if Set(stamps.map(\.bootIDHash)).count != 1 { issues.append("boot/clock domain changed") }
        if record.finished.monotonic < record.started.monotonic || record.finished.monotonic - record.started.monotonic > 2800 {
            issues.append("recording clock bounds")
        }
        var prior = record.started.monotonic
        for stamp in stamps {
            if stamp.monotonic < prior || stamp.monotonic < record.started.monotonic || stamp.monotonic > record.finished.monotonic { issues.append("recording envelope or clock order violation") }
            prior = stamp.monotonic
            let drift = abs((stamp.utc - record.started.utc) - (stamp.monotonic - record.started.monotonic))
            if drift > 0.1 + stamp.uncertainty + record.started.uncertainty { issues.append("UTC/monotonic discontinuity (sleep or clock change)"); break }
        }
        var cursor = record.plan.start
        var expectedBoundaries: [(String, String, Double)] = []
        for phase in record.plan.phases {
            expectedBoundaries += [(phase.name, "start", cursor), (phase.name, "end", cursor + phase.seconds)]
            cursor += phase.seconds
        }
        if record.boundaries.count != expectedBoundaries.count { issues.append("missing phase boundaries") }
        for (boundary, expected) in zip(record.boundaries, expectedBoundaries) {
            if boundary.phase != expected.0 || boundary.edge != expected.1 || boundary.scheduled != expected.2 {
                issues.append("phase boundary schedule mismatch")
            }
            if !boundary.identity.matches(record.expected) { issues.append("invalidMeasurement: phase identity") }
            if abs(boundary.actual.monotonic - boundary.scheduled) > 1 { issues.append("late phase boundary") }
        }
        var result = Analysis(profile: record.plan.profile, source: record.source, uid: record.expected.uid,
            evidenceComplete: false, issues: [], frameBlocks: [], ram: nil)
        if record.plan.kind == .presentation {
            if let trace = record.presentation, record.ram == nil {
                if trace.recorderStart < record.started.monotonic || trace.drainEnd > record.finished.monotonic { issues.append("presentation outside recording envelope") }
                result.frameBlocks = try presentation(trace, plan: record.plan,
                    uncertainty: stamps.map(\.uncertainty).max()!, issues: &issues)
            } else { issues.append("missing presentation or unexpected RAM payload") }
        } else if let trace = record.ram, record.presentation == nil {
            if trace.recorderStart < record.started.monotonic || trace.recorderEnd > record.finished.monotonic { issues.append("RAM outside recording envelope") }
            result.ram = try ram(trace, plan: record.plan, issues: &issues)
        } else { issues.append("missing RAM or unexpected presentation payload") }
        result.issues = Array(Set(issues)).sorted(); result.evidenceComplete = issues.isEmpty
        if !result.evidenceComplete {
            for index in result.frameBlocks.indices { result.frameBlocks[index].conditionalTargetsMet = nil }
            result.ram?.conditionalTargetsMet = nil
        }
        return result
    }
    static func presentation(_ trace: PresentationTrace, plan: Plan, uncertainty: Double, issues: inout [String]) throws -> [FrameBlock] {
        let window = plan.window("measurement")!
        try require(trace.frames.count <= 200_000 && trace.timeouts.count <= 3000 && trace.visibility.count <= 3000 && trace.errors.count <= 64, "presentation trace bounds")
        try require([trace.recorderStart, trace.recorderEnd, trace.drainEnd].allSatisfy(boundedTime) && trace.recorderEnd >= trace.recorderStart && trace.drainEnd >= trace.recorderEnd && trace.drainEnd <= plan.end + 5, "presentation recorder time bounds")
        issues += trace.errors
        if trace.recorderStart > window.start || trace.recorderEnd < window.end { issues.append("presentation does not cover fixed measurement window") }
        if let acquisition = trace.measurementAcquisition {
            try require(boundedTime(acquisition.start) && boundedTime(acquisition.end) && acquisition.start >= trace.recorderStart && acquisition.end <= trace.recorderEnd && acquisition.start <= acquisition.end, "invalid measurement acquisition")
            if acquisition.start + uncertainty > window.start || acquisition.end - uncertainty < window.end { issues.append("actual acquisition does not enclose fixed analysis window") }
            if plan.profile == .labV1Draft && acquisition.start - trace.recorderStart < 5 { issues.append("less than five seconds actual render warmup before acquisition") }
        } else { issues.append("missing actual measurement acquisition") }
        var sequences = Set<Int>()
        var previousSubmit = -Double.infinity
        var presentationTimes = Set<Double>()
        for frame in trace.frames {
            try require((0..<200_000).contains(frame.sequence) && sequences.insert(frame.sequence).inserted &&
                boundedTime(frame.submitted) && frame.submitted >= trace.recorderStart && frame.submitted <= trace.recorderEnd && frame.submitted >= previousSubmit, "malformed frame submission")
            previousSubmit = frame.submitted
            try require((frame.presented == nil) == (frame.callback == nil), "partial presentation callback")
            if let time = frame.presented, let callback = frame.callback {
                try require(boundedTime(time) && boundedTime(callback) && time >= frame.submitted && callback >= time && callback <= trace.drainEnd && presentationTimes.insert(time).inserted, "malformed presentation time")
            }
        }
        try require(trace.timeouts.allSatisfy { boundedTime($0) && $0 >= trace.recorderStart && $0 <= trace.recorderEnd }, "invalid drawable timeout")
        let visibility = trace.visibility
        var last = -Double.infinity
        for sample in visibility {
            try require(boundedTime(sample.time) && sample.time > last && sample.time >= trace.recorderStart && sample.time <= trace.drainEnd &&
                (1...16384).contains(sample.width) && (1...16384).contains(sample.height) && sample.scale.isFinite && (0.5...4).contains(sample.scale), "invalid visibility sample")
            last = sample.time
        }
        if visibility.isEmpty || visibility.first!.time > window.start || visibility.last!.time < window.end || zip(visibility.dropFirst(), visibility).contains(where: { $0.time - $1.time > 5 }) {
            issues.append("missing visibility coverage (maximum 5 seconds)")
        }
        if Set(visibility.map { "\($0.width)/\($0.height)/\($0.scale)" }).count > 1 { issues.append("drawable size/scale changed") }
        let allTimes = trace.frames.compactMap(\.presented).sorted()
        let blockSeconds: Double = plan.profile == .labV1Draft ? 60 : window.duration
        let count = Int((window.duration / blockSeconds).rounded())
        return (0..<count).map { block in
            let w = Window(start: window.start + Double(block) * blockSeconds, end: window.start + Double(block + 1) * blockSeconds)
            let times = allTimes.filter(w.contains)
            let endpoints = [w.start] + times + [w.end]
            let gaps = zip(endpoints.dropFirst(), endpoints).map { ($0 - $1) * 1000 }
            let distribution = Distribution(gaps)
            let drops = gaps.reduce(0) { $0 + max(0, Int(floor($1 / (1000 / 60) + 0.5)) - 1) }
            // Each cut boundary can hide at most one extra slot. Always use the adverse bound.
            let adverse = drops + 2
            let fraction = Double(adverse) / Double(times.count + adverse)
            let submissions = trace.frames.filter { w.contains($0.submitted) }
            let unpresented = submissions.filter { $0.presented.map { !w.contains($0) } ?? true }.count
            let relevantVisibility = visibility.filter { $0.time >= w.start - 5 && $0.time <= w.end }
            let visible = !relevantVisibility.isEmpty && relevantVisibility.allSatisfy(\.visible)
            let secondsEmpty = (0..<Int(ceil(w.duration))).filter { second in
                !times.contains { $0 >= w.start + Double(second) && $0 < min(w.end, w.start + Double(second + 1)) }
            }.count
            let fps = Double(times.count) / w.duration
            let met = fps >= 57 && distribution.p95 + 2 * uncertainty * 1000 <= 25 &&
                distribution.maximum + 2 * uncertainty * 1000 <= 100 && fraction <= 0.05 && visible
            return FrameBlock(window: w, presented: times.count, submitted: submissions.count,
                unpresentedInWindow: unpresented, timeouts: trace.timeouts.filter(w.contains).count, fps: fps,
                gapsMilliseconds: distribution, dropSlots: drops, adverseDropSlots: adverse,
                adverseDropFraction: fraction, secondsWithoutFrame: secondsEmpty, visible: visible,
                conditionalTargetsMet: plan.profile == .labV1Draft ? met : nil)
        }
    }
    static func ram(_ trace: RAMTrace, plan: Plan, issues: inout [String]) throws -> RAMSummary? {
        try require(trace.samples.count <= 2500 && trace.errors.count <= 64, "RAM sample bounds")
        try require(boundedTime(trace.recorderStart) && boundedTime(trace.recorderEnd) && trace.recorderStart <= trace.recorderEnd && trace.recorderEnd <= plan.end + 5, "RAM recorder time bounds")
        issues += trace.errors
        let samples = trace.samples
        var previous = -Double.infinity
        for sample in samples {
            try require(boundedTime(sample.time) && sample.time > previous && sample.time >= trace.recorderStart && sample.time <= trace.recorderEnd &&
                sample.physicalBytes > 0 && sample.physicalBytes <= (1 << 50) && [4096, 16384].contains(sample.pageBytes) &&
                sample.freePages <= sample.physicalBytes / sample.pageBytes && (sample.swapUsedBytes ?? 0) <= (1 << 50), "malformed RAM sample")
            previous = sample.time
        }
        if Set(samples.map(\.physicalBytes)).count > 1 || Set(samples.map(\.pageBytes)).count > 1 { issues.append("RAM metric configuration changed") }
        if samples.contains(where: { $0.swapUsedBytes == nil || ![1, 2, 4].contains($0.pressure ?? -1) }) { issues.append("missing swap or pressure evidence") }
        if trace.recorderStart > plan.start || trace.recorderEnd < plan.end { issues.append("RAM recorder does not cover schedule") }
        if samples.isEmpty || samples.first!.time - plan.start > 2 || plan.end - samples.last!.time > 2 || zip(samples.dropFirst(), samples).contains(where: { $0.time - $1.time > 2 }) {
            issues.append("RAM gap exceeds two seconds")
        }
        let measurement = plan.window("measurement")!
        let load = samples.filter { measurement.contains($0.time) }
        guard !load.isEmpty else { issues.append("no RAM measurement samples"); return nil }
        var result = RAMSummary(occupiedBytes: Distribution(load.map(\.occupiedBytes)), pressureNormal: load.allSatisfy { $0.pressure == 1 })
        // Endpoints must bracket the full fixed window, rather than silently shortening it.
        if let before = samples.last(where: { $0.time <= measurement.start }), let after = samples.first(where: { $0.time >= measurement.end }),
           measurement.start - before.time <= 2, after.time - measurement.end <= 2,
           let startSwap = before.swapUsedBytes, let endSwap = after.swapUsedBytes {
            result.swapGrowthBytes = max(0, Double(endSwap) - Double(startSwap))
        } else { issues.append("missing RAM swap endpoint coverage") }
        if let pre = plan.window("baselineBefore"), let post = plan.window("baselineAfter") {
            let before = samples.filter { pre.contains($0.time) }.map(\.occupiedBytes)
            let after = samples.filter { post.contains($0.time) }.map(\.occupiedBytes)
            if before.isEmpty || after.isEmpty { issues.append("missing RAM baseline") }
            else {
                let b0 = Distribution(before).median, b1 = Distribution(after).median
                let baseline = min(b0, b1)
                result.baselineBeforeBytes = b0; result.baselineAfterBytes = b1; result.baselineBytes = baseline
                let delta = load.map { $0.occupiedBytes - baseline }
                result.deltaBytes = Distribution(delta); result.negativeDeltaCount = delta.filter { $0 < 0 }.count
                if abs(b0 - b1) > 512 * 1024 * 1024 { issues.append("RAM baseline drift exceeds 512 MiB") }
                if delta.contains(where: { $0 < 0 }) { issues.append("negative RAM delta requires investigation") }
                result.conditionalTargetsMet = plan.profile == .labV1Draft ? result.deltaBytes!.p95 <= 4.5 * 1024 * 1024 * 1024 : nil
            }
        } else if plan.profile == .labV1Draft {
            result.conditionalTargetsMet = result.pressureNormal && (result.swapGrowthBytes ?? .infinity) <= 1024 * 1024 * 1024
        }
        return result
    }
}
// Identity of all fields including phase order; no randomized hashing enters output.
extension Plan: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(runID); hasher.combine(profile.rawValue); hasher.combine(kind.rawValue); hasher.combine(start)
        for phase in phases { hasher.combine(phase.name); hasher.combine(phase.seconds) }
    }
}
