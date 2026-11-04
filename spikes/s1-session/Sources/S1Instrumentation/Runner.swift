import Foundation
import S1Probe

public struct Intent: Codable, Sendable {
    public var plan: Plan
    public var expected: IdentityExpectation
    public var initialIdentity: IdentityCheck
    public var clock: ClockStamp
    public var status: String
}
public enum InstrumentRunner {
    /// No launch, installation, privilege change, IPC, or files shared with another UID.
    /// The operator starts each identity-gated probe using the same preregistered clock schedule.
    @MainActor
    public static func record(plan: Plan, expected: IdentityExpectation) throws -> (path: String, valid: Bool) {
        try plan.validate(); try expected.validate()
        // First measurement operation: current credentials and exact session expectation.
        let identity = expected.capture()
        let stamp = try InstrumentClock.stamp()
        let dataset = try Dataset(runID: plan.runID, role: plan.kind.rawValue)
        var record = Recording(source: "measured", plan: plan, expected: expected, initialIdentity: identity, started: stamp, finished: stamp)
        try dataset.write("intent.json", Intent(plan: plan, expected: expected, initialIdentity: identity, clock: stamp,
            status: identity.matches(expected) ? "armed" : "invalidMeasurement"))
        guard identity.matches(expected) else {
            record.errors.append("invalidMeasurement: identity mismatch; no workload started")
            try dataset.write("recording.json", EvidenceBundle(recordings: [record]))
            return (dataset.path, false)
        }
        guard plan.start - stamp.monotonic >= 2 && plan.start - stamp.monotonic <= 300 else {
            record.errors.append("invalidMeasurement: schedule must start 2...300 seconds in future")
            try dataset.write("recording.json", EvidenceBundle(recordings: [record]))
            return (dataset.path, false)
        }
        // Sleep only before setup; the recorder is running before the fixed phase window.
        InstrumentClock.wait(until: plan.start - 3)
        var presentation: LivePresentation?
        var ram = RAMTrace(recorderStart: InstrumentClock.now(), recorderEnd: 0)
        var nextSample = plan.start - 0.1
        var valid = true
        do {
            if plan.kind == .presentation { presentation = try LivePresentation(measurement: plan.window("measurement")!) }
            var edges: [(String, String, Double)] = []
            var cursor = plan.start
            for phase in plan.phases {
                edges.append((phase.name, "start", cursor)); cursor += phase.seconds
                edges.append((phase.name, "end", cursor))
            }
            var index = 0
            while InstrumentClock.now() <= plan.end + 0.1 {
                let now = InstrumentClock.now()
                while index < edges.count && now >= edges[index].2 {
                    let edge = edges[index]
                    let boundaryStamp = try InstrumentClock.stamp()
                    let check = expected.capture()
                    record.boundaries.append(Boundary(phase: edge.0, edge: edge.1, scheduled: edge.2, actual: boundaryStamp, identity: check))
                    index += 1
                    if !check.matches(expected) {
                        record.errors.append("invalidMeasurement: identity changed at phase boundary")
                        valid = false; break
                    }
                }
                if !valid { break }
                if plan.kind == .ram && now >= nextSample {
                    ram.samples.append(try SystemRAM.sample())
                    // Skip missed deadlines rather than fabricate samples to fill a gap.
                    nextSample = plan.start + floor((InstrumentClock.now() - plan.start) + 1)
                }
                if let presentation { presentation.tick() }
                else { Thread.sleep(forTimeInterval: 0.005) }
            }
            if plan.kind == .ram {
                // A real final sample brackets measurement and baseline endpoints.
                ram.samples.append(try SystemRAM.sample()); ram.recorderEnd = InstrumentClock.now()
                record.ram = ram
            }
        } catch {
            record.errors.append(String(describing: error)); valid = false
            if plan.kind == .ram { ram.recorderEnd = InstrumentClock.now(); record.ram = ram }
        }
        if let presentation { record.presentation = presentation.finish(end: min(plan.end, InstrumentClock.now())) }
        record.finished = try InstrumentClock.stamp()
        try dataset.write("recording.json", EvidenceBundle(recordings: [record]))
        return (dataset.path, valid)
    }
}

public struct OffscreenRecording: Codable, Sendable {
    public var scope = "serial offscreen only; manual paired LAB interpretation; no S1 verdict"
    public var runID: String
    public var expected: IdentityExpectation
    public var initialIdentity: IdentityCheck
    public var finalIdentity: IdentityCheck?
    public var started: ClockStamp
    public var finished: ClockStamp?
    public var result: OffscreenResult?
    /// Preserve every numeric field as text if the legacy result cannot be safely encoded.
    public var invalidResult: [String: String]?
    public var errors: [String] = []
}
extension InstrumentRunner {
    public static func offscreen(runID: String, expected: IdentityExpectation) throws -> (path: String, valid: Bool) {
        try expected.validate()
        let identity = expected.capture()
        let started = try InstrumentClock.stamp()
        let dataset = try Dataset(runID: runID, role: "offscreen")
        var record = OffscreenRecording(runID: runID, expected: expected, initialIdentity: identity, started: started)
        try dataset.write("intent.json", record)
        if identity.matches(expected) {
            do { record.accept(try OffscreenWorkload.run()) }
            catch { record.errors.append(String(describing: error)) }
            record.finalIdentity = expected.capture()
            if !record.finalIdentity!.matches(expected) { record.errors.append("invalidMeasurement: final identity") }
        } else { record.errors.append("invalidMeasurement: initial identity; no GPU work started") }
        record.finished = try InstrumentClock.stamp()
        try dataset.write("recording.json", record)
        return (dataset.path, record.errors.isEmpty)
    }
}

extension OffscreenRecording {
    mutating func accept(_ value: OffscreenResult) {
        let metrics = [value.gpuMillisecondsMedian, value.gpuMillisecondsP95, value.wallSeconds, value.gigaIterationsPerSecond]
        guard metrics.allSatisfy({ $0.isFinite && $0 > 0 }), value.gpuMillisecondsP95 >= value.gpuMillisecondsMedian else {
            result = nil
            invalidResult = ["device": value.device, "width": String(value.width), "height": String(value.height),
                "iterationsPerPixel": String(value.iterationsPerPixel), "frames": String(value.frames),
                "gpuMillisecondsMedian": String(value.gpuMillisecondsMedian), "gpuMillisecondsP95": String(value.gpuMillisecondsP95),
                "wallSeconds": String(value.wallSeconds), "gigaIterationsPerSecond": String(value.gigaIterationsPerSecond),
                "verifiedPixels": String(value.verifiedPixels), "mismatchedPixels": String(value.mismatchedPixels)]
            errors.append("invalidOffscreenTimings: nonfinite, nonpositive or inconsistent timing; raw strings preserved")
            return
        }
        result = value
    }
}
