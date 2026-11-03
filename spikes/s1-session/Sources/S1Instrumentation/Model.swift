import Foundation

public struct InstrumentError: Error, CustomStringConvertible {
    public var description: String
    public init(_ text: String) { description = text }
}
func require(_ value: Bool, _ message: String) throws {
    if !value { throw InstrumentError(message) }
}
func boundedTime(_ value: Double) -> Bool { value.isFinite && value >= 0 && value <= 1_000_000_000 }
func identifier(_ value: String) -> Bool {
    (8...96).contains(value.utf8.count) && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
    }
}
public enum Profile: String, Codable, Sendable { case diagnostic, labV1Draft = "lab-v1-draft" }
public enum Kind: String, Codable, Sendable { case presentation, ram }
public struct Phase: Codable, Equatable, Sendable {
    public var name: String
    public var seconds: Double
    public init(_ name: String, _ seconds: Double) { self.name = name; self.seconds = seconds }
}
/// Same-Mac Mach absolute seconds, the clock used by CAMetalDrawable.presentedTime.
public struct Plan: Codable, Equatable, Sendable {
    public var runID: String
    public var profile: Profile
    public var kind: Kind
    public var start: Double
    public var phases: [Phase]
    public init(runID: String, profile: Profile, kind: Kind, start: Double, phases: [Phase]) {
        self.runID = runID; self.profile = profile; self.kind = kind; self.start = start; self.phases = phases
    }
    public var end: Double { start + phases.reduce(0) { $0 + $1.seconds } }
    public func window(_ name: String) -> Window? {
        var cursor = start
        for phase in phases {
            if phase.name == name { return Window(start: cursor, end: cursor + phase.seconds) }
            cursor += phase.seconds
        }
        return nil
    }
    public func validate() throws {
        try require(identifier(runID), "runID: 8...96 ASCII letters, digits, hyphens")
        try require(boundedTime(start) && start > 0 && boundedTime(end), "invalid schedule clock")
        try require((1...5).contains(phases.count), "invalid phase count")
        try require(phases.allSatisfy { $0.seconds.isFinite && (1...600).contains($0.seconds) }, "phase duration outside 1...600 seconds")
        try require(end - start <= 2400, "schedule exceeds 2400 seconds")
        let names = phases.map(\.name)
        if kind == .presentation {
            try require(names == ["warmup", "measurement"], "presentation needs warmup, measurement")
            if profile == .labV1Draft { try require(phases.map(\.seconds) == [5, 600], "LAB presentation is 5 + 600 seconds") }
        } else {
            try require(names == ["measurement"] || names == ["baselineBefore", "settle", "measurement", "cleanup", "baselineAfter"], "RAM needs load or complete W0 phase schedule")
            if profile == .labV1Draft {
                try require(window("measurement")!.duration == 600, "LAB RAM measurement is 600 seconds")
                if phases.count == 5 {
                    try require(phases[0].seconds == 300 && phases[1].seconds == 300 && phases[4].seconds == 300, "LAB W0 baselines/settling are 300 seconds")
                }
            }
        }
        if profile == .diagnostic { try require(phases.allSatisfy { $0.seconds <= 30 }, "diagnostic phases limited to 30 seconds") }
    }
}
public struct Window: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var duration: Double { end - start }
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public func contains(_ value: Double) -> Bool { value >= start && value < end }
}
public struct ClockStamp: Codable, Equatable, Sendable {
    public var monotonic: Double
    public var utc: Double
    public var bootIDHash: String
    public var uncertainty: Double
}
public struct Boundary: Codable, Equatable, Sendable {
    public var phase: String
    public var edge: String
    public var scheduled: Double
    public var actual: ClockStamp
    public var identity: IdentityCheck
}
public struct Frame: Codable, Equatable, Sendable {
    public var sequence: Int
    public var submitted: Double
    /// nil if the presentation callback did not arrive before the bounded drain deadline.
    public var presented: Double?
    public var callback: Double?
}
public struct Visibility: Codable, Equatable, Sendable {
    public var time: Double
    public var visible: Bool
    public var width: Int
    public var height: Int
    public var scale: Double
}
public struct PresentationTrace: Codable, Equatable, Sendable {
    public var frames: [Frame] = []
    public var timeouts: [Double] = []
    public var visibility: [Visibility] = []
    public var recorderStart: Double
    public var recorderEnd: Double
    public var drainEnd: Double
    /// Actual render acquisition around the fixed analysis window, including margins.
    public var measurementAcquisition: Window?
    public var errors: [String] = []
}
public struct RAMSample: Codable, Equatable, Sendable {
    public var time: Double
    public var physicalBytes: UInt64
    public var pageBytes: UInt64
    public var freePages: UInt64
    public var swapUsedBytes: UInt64?
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical; nil/other unknown.
    public var pressure: Int32?
    public var occupiedBytes: Double { Double(physicalBytes) - Double(pageBytes) * Double(freePages) }
}
public struct RAMTrace: Codable, Equatable, Sendable {
    public var samples: [RAMSample] = []
    public var recorderStart: Double
    public var recorderEnd: Double
    public var errors: [String] = []
}
public struct Recording: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var source: String // measured or fixture; fixture never becomes measured evidence
    public var plan: Plan
    public var expected: IdentityExpectation
    public var initialIdentity: IdentityCheck
    public var started: ClockStamp
    public var finished: ClockStamp
    public var boundaries: [Boundary] = []
    public var presentation: PresentationTrace?
    public var ram: RAMTrace?
    public var errors: [String] = []
}
public struct EvidenceBundle: Codable, Sendable {
    public var schemaVersion = 1
    public var recordings: [Recording]
    public init(recordings: [Recording]) { self.recordings = recordings }
}
public func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    return try encoder.encode(value)
}
