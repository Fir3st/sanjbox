import Foundation

public enum SyntheticApplication: String, Codable, Sendable { case xcodeSimulator, androidEmulator, electron, safari }
public enum SuppliedOutcome: String, Codable, Sendable { case success, failure, unknown }
public enum WorkloadObservationKind: String, Codable, Sendable {
    case changingOutput, inputResponse, presentedOutput, acceleratedBackend, webglCheck, processContinuity
}
public struct ApplicationCycle: Codable, Sendable {
    public var index: Int
    public var start: Double
    public var end: Double
    public var launch: SuppliedOutcome
    public var build: SuppliedOutcome?
    public var run: SuppliedOutcome
    public var artifactSHA256: String
}
public struct WorkloadObservation: Codable, Sendable {
    public var kind: WorkloadObservationKind
    public var time: Double
    public var outcome: SuppliedOutcome
    /// Hash of externally retained synthetic output, never a path, URL, screenshot or file read.
    public var artifactSHA256: String
}
public struct ExternalProcessBinding: Codable, Sendable {
    public var pid: Int32
    public var uid: UInt32
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64
    public var role: String
    public var artifactSHA256: String
}
public struct ApplicationWorkload: Codable, Sendable {
    public var schemaVersion = 1
    public var runID: String
    public var source: String // fixture or external-synthetic, never measured by this intake
    public var profile: Profile
    public var workload: String // WX / WA / WE / WS / WM
    public var application: SyntheticApplication
    public var applicationVersion: String
    public var runtimeVersion: String
    public var fixtureSHA256: String
    public var preregistrationSHA256: String
    public var widthPixels: Int
    public var heightPixels: Int
    public var scale: Double
    public var expected: IdentityExpectation
    public var initialIdentity: IdentityCheck
    public var finalIdentity: IdentityCheck
    public var started: ClockStamp
    public var finished: ClockStamp
    public var window: Window
    public var cycles: [ApplicationCycle]
    public var processes: [ExternalProcessBinding]
    public var observations: [WorkloadObservation]
}
public struct ApplicationWorkloadReport: Codable, Sendable {
    public var runID: String
    public var source: String
    public var application: SyntheticApplication
    public var workload: String
    public var recordComplete: Bool
    public var issues: [String]
    public var reportedFailures: [String]
    public var artifactsVerified = false
    public var unverifiedPrerequisites = ["all referenced output/calibration/preregistration hashes and provenance require external review; no referenced data was opened",
        "real application execution, rendering, input, acceleration and continuity are externally supplied claims",
        "three distinct zone sessions plus interactive host for entire LAB window", "WM rotation and both Electron/Safari windows", "display/client/keeper configuration and F0.8 approval"]
}

extension SupplementaryAnalyzer {
    static func workloads(_ values: [ApplicationWorkload]) throws -> [ApplicationWorkloadReport] {
        try require((1...128).contains(values.count), "workload record count bound")
        var runs = Set<String>()
        return try values.map { r in
            try require(r.schemaVersion == 1 && identifier(r.runID) && runs.insert(r.runID).inserted &&
                ["fixture", "external-synthetic"].contains(r.source), "unsupported workload schema/source or duplicate run")
            let profileApp: [String: SyntheticApplication] = ["WX": .xcodeSimulator, "WA": .androidEmulator, "WE": .electron, "WS": .safari]
            try require(r.workload == "WM" || profileApp[r.workload] == r.application, "workload/application mismatch")
            for version in [r.applicationVersion, r.runtimeVersion] {
                try require((1...80).contains(version.utf8.count) && version.utf8.allSatisfy({ (32...126).contains($0) }), "invalid application version label")
            }
            try require(digest(r.fixtureSHA256) && digest(r.preregistrationSHA256), "invalid workload provenance hash")
            try require((1...16384).contains(r.widthPixels) && (1...16384).contains(r.heightPixels) && r.scale.isFinite && (0.5...4).contains(r.scale), "invalid workload display dimensions")
            try require(boundedTime(r.window.start) && boundedTime(r.window.end) && r.window.duration >= 1 &&
                (r.profile == .labV1Draft ? r.window.duration == 600 : r.window.duration <= 30), "invalid workload fixed window")
            try require(r.cycles.count <= 3 && r.processes.count <= 32 && r.observations.count <= 6000, "workload collection bound")
            try r.expected.validate()
            var issues = try clockIssues(r.started, r.finished), failures: [String] = []
            if !r.initialIdentity.matches(r.expected) || !r.finalIdentity.matches(r.expected) || r.expected.onConsole { issues.append("invalid workload zone identity") }
            if r.window.start < r.started.monotonic || r.window.end > r.finished.monotonic { issues.append("incomplete workload clock envelope") }
            func outcome(_ value: SuppliedOutcome, _ label: String) {
                if value == .failure { failures.append(label) }
                if value == .unknown { issues.append("unknown outcome: " + label) }
            }
            var previous = r.started.monotonic
            for (i, cycle) in r.cycles.enumerated() {
                try require(cycle.index == i + 1 && boundedTime(cycle.start) && boundedTime(cycle.end) && cycle.start >= previous &&
                    cycle.end >= cycle.start && cycle.end <= r.window.start && digest(cycle.artifactSHA256), "invalid start/build/run cycle sequence")
                previous = cycle.end
                outcome(cycle.launch, "cycle \(cycle.index) launch"); outcome(cycle.run, "cycle \(cycle.index) run")
                if r.application == .xcodeSimulator {
                    if let build = cycle.build { outcome(build, "cycle \(cycle.index) build") }
                    else { issues.append("missing Xcode build outcome") }
                } else { try require(cycle.build == nil, "build outcome only supported for Xcode") }
            }
            if r.cycles.count != 3 { issues.append("requires three start/run cycles") }
            var processes = Set<String>(), roles = Set<String>()
            let permittedRoles: Set<String> = ["application", "coreSimulatorService", "emulator", "renderer"]
            for p in r.processes {
                try require(p.pid > 0 && p.uid > 0 && p.startSeconds > 0 && p.startMicroseconds < 1_000_000 &&
                    permittedRoles.contains(p.role) && digest(p.artifactSHA256), "invalid external process binding")
                // Same PID may not be relabelled with a different start/role to appear twice.
                try require(processes.insert(String(p.pid)).inserted, "duplicate external process PID")
                roles.insert(p.role)
                if p.uid != r.expected.uid { issues.append("external process UID differs from zone") }
            }
            if !roles.contains("application") { issues.append("missing application process binding") }
            if r.application == .xcodeSimulator && !roles.contains("coreSimulatorService") { issues.append("missing CoreSimulatorService binding") }
            if r.application == .androidEmulator && !roles.contains("emulator") { issues.append("missing emulator binding") }
            previous = -Double.infinity
            var observationKeys = Set<String>()
            for item in r.observations {
                try require(boundedTime(item.time) && item.time >= previous && item.time >= r.window.start && item.time <= r.window.end && digest(item.artifactSHA256), "invalid workload observation time/hash")
                try require(observationKeys.insert("\(item.kind.rawValue)-\(item.time)").inserted, "duplicate workload observation")
                previous = item.time
                outcome(item.outcome, item.kind.rawValue)
            }
            let required: [WorkloadObservationKind] = [.changingOutput, .inputResponse, .presentedOutput, .acceleratedBackend, .processContinuity] +
                ([.electron, .safari].contains(r.application) ? [.webglCheck] : [])
            for kind in required {
                let events = r.observations.filter { $0.kind == kind }
                // Both ends explicitly represented; no inference from a single rAF/process sighting.
                if events.first.map({ $0.time <= r.window.start + 1 }) != true || events.last.map({ $0.time >= r.window.end - 1 }) != true {
                    issues.append("missing beginning/end evidence: " + kind.rawValue)
                }
                if kind == .processContinuity {
                    let times = [r.window.start] + events.map(\.time) + [r.window.end]
                    if zip(times, times.dropFirst()).contains(where: { $1 - $0 > 2 }) { issues.append("process continuity observation gap exceeds 2 seconds") }
                }
            }
            return ApplicationWorkloadReport(runID: r.runID, source: r.source, application: r.application, workload: r.workload,
                recordComplete: issues.isEmpty, issues: issues, reportedFailures: failures)
        }
    }
}
