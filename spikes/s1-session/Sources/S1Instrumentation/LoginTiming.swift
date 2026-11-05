import Foundation

public enum LoginMode: String, Codable, Sendable { case firstRun, cold, warm, resume, reconnect }
public enum LoginEvent: String, Codable, Sendable { case start, clientConnected, desktop, firstFrame, ready, timeout }
public struct LoginMarkerRequest: Codable, Equatable, Sendable {
    public var runID: String
    public var attemptID: String
    public var configurationSHA256: String
    public var mode: LoginMode
    public var event: LoginEvent
    public var targetUID: UInt32
    public var order: Int
    public var activeOtherZones: Int
    public func validate() throws {
        try require(identifier(runID) && identifier(attemptID) && digest(configurationSHA256) && targetUID > 0 &&
            (1...3).contains(order) && (0...2).contains(activeOtherZones), "invalid login marker request")
    }
}
public struct LoginMarker: Codable, Sendable {
    public var schemaVersion = 1
    public var request: LoginMarkerRequest
    public var source: String
    public var expected: IdentityExpectation
    public var identity: IdentityCheck
    public var signature: ProbeSignature
    public var clock: ClockStamp
    /// External acquisition only. Bounds event-to-stamp delay, not just clock resolution.
    public var eventDelayBoundSeconds: Double?
    public var calibrationSHA256: String?
    public var observationSHA256: String?
}
public struct LoginAttempt: Codable, Sendable { public var markers: [LoginMarker] }
public struct LoginAttemptReport: Codable, Sendable {
    public var attemptID: String
    public var mode: LoginMode
    public var targetUID: UInt32
    public var sources: [String]
    public var configurationSHA256: String
    public var order: Int
    public var activeOtherZones: Int
    public var outcome: String
    public var markerIntervalSeconds: Double?
    public var eventDurationUpperSeconds: Double?
    public var uncertaintySeconds: Double?
    public var timingEvidenceComplete: Bool
    public var issues: [String]
}
public struct LoginReport: Codable, Sendable {
    public var scope = "marker interval or externally supplied synthetic timing; no automatic login/ready observation or S1 verdict"
    public var attempts: [LoginAttemptReport]
    public var unverifiedPrerequisites = ["calibration and synthetic UI output provenance", "cold reboot/prepared-profile and warm residual-process state", "10 cold / 30 warm per UID and rotated order", "resume construction and safe UID pause", "F0.8 approval"]
}

extension InstrumentRunner {
    public static func loginMarker(request: LoginMarkerRequest, expected: IdentityExpectation) throws -> (path: String, valid: Bool) {
        try request.validate(); try expected.validate()
        let identity = expected.capture()
        let signature = try ProbeSignature.capture()
        try require(signature.valid, "invalidMeasurement: unsafe own signature; no login marker captured")
        let marker = LoginMarker(request: request, source: "measured-marker", expected: expected, identity: identity,
            signature: signature, clock: try InstrumentClock.stamp())
        let dataset = try Dataset(runID: request.runID, role: "login-marker")
        try dataset.write("recording.json", marker)
        return (dataset.path, identity.matches(expected) && markerRoleMatches(marker))
    }
}
private func markerRoleMatches(_ marker: LoginMarker) -> Bool {
    switch marker.request.event {
    case .start, .timeout: return marker.expected.onConsole && marker.expected.uid != marker.request.targetUID
    case .ready: return !marker.expected.onConsole && marker.expected.uid == marker.request.targetUID
    default: return marker.expected.onConsole || marker.expected.uid == marker.request.targetUID
    }
}
extension SupplementaryAnalyzer {
    static func login(_ attempts: [LoginAttempt]) throws -> LoginReport {
        try require((1...300).contains(attempts.count), "login attempt count bound")
        var attemptsSeen = Set<String>(), markerRuns = Set<String>()
        let reports = try attempts.map { attempt -> LoginAttemptReport in
            try require((1...6).contains(attempt.markers.count), "login marker count bound")
            let first = attempt.markers[0], request = first.request
            try require(attemptsSeen.insert(request.attemptID).inserted, "duplicate login attempt")
            var issues: [String] = [], seen = Set<LoginEvent>(), previous = -Double.infinity
            for marker in attempt.markers {
                try marker.request.validate(); try marker.expected.validate(); try validateStamp(marker.clock)
                let r = marker.request
                try require(marker.schemaVersion == 1 && ["measured-marker", "external-synthetic", "fixture"].contains(marker.source), "unsupported login marker schema/source")
                try require(markerRuns.insert(r.runID).inserted && seen.insert(r.event).inserted, "duplicate login marker run/event")
                try require(r.attemptID == request.attemptID && r.configurationSHA256 == request.configurationSHA256 && r.mode == request.mode &&
                    r.targetUID == request.targetUID && r.order == request.order && r.activeOtherZones == request.activeOtherZones, "mixed login attempt configuration")
                if !marker.identity.matches(marker.expected) || !markerRoleMatches(marker) { issues.append("invalid login marker identity/role") }
                if !marker.signature.valid { issues.append("unsafe marker signature") }
                if marker.clock.monotonic < previous { issues.append("unordered login markers") }
                previous = marker.clock.monotonic
                issues += try clockIssues(first.clock, marker.clock)
                if let bound = marker.eventDelayBoundSeconds {
                    try require(bound.isFinite && (0...60).contains(bound), "invalid event delay bound")
                }
                for hash in [marker.calibrationSHA256, marker.observationSHA256].compactMap({ $0 }) {
                    try require(digest(hash), "invalid login provenance hash")
                }
                if marker.source == "measured-marker" {
                    try require(marker.eventDelayBoundSeconds == nil && marker.calibrationSHA256 == nil && marker.observationSHA256 == nil,
                        "manual CLI markers cannot claim calibrated event coupling")
                }
            }
            let terminal = attempt.markers.last!
            let hasTerminal = terminal.request.event == .ready || terminal.request.event == .timeout
            if first.request.event != .start || !hasTerminal || (seen.contains(.ready) && seen.contains(.timeout)) { issues.append("missing or conflicting login endpoints") }
            let interval = first.request.event == .start && hasTerminal ? terminal.clock.monotonic - first.clock.monotonic : nil
            var uncertainty: Double?
            if let a = first.eventDelayBoundSeconds, let b = terminal.eventDelayBoundSeconds,
               first.calibrationSHA256 != nil, terminal.calibrationSHA256 != nil,
               first.observationSHA256 != nil, terminal.observationSHA256 != nil {
                uncertainty = a + b + first.clock.uncertainty + terminal.clock.uncertainty
            } else { issues.append("event-to-marker uncertainty/provenance unknown; CLI interval is not login time") }
            if [.warm, .resume].contains(request.mode) && (uncertainty == nil || uncertainty! > 0.010) { issues.append("warm/resume uncertainty exceeds 10 ms or is unknown") }
            if terminal.request.event == .timeout && (interval ?? 0) < 60 { issues.append("timeout before 60-second observation") }
            if request.mode == .warm && request.activeOtherZones != 2 { issues.append("warm login requires two other active zones") }
            let upper = interval.flatMap { elapsed in uncertainty.map { elapsed + $0 } }
            let outcome = !hasTerminal ? "incomplete" : terminal.request.event == .timeout ? "timeout" : (interval ?? 0) > 60 ? "ready-after-timeout" : "ready"
            return LoginAttemptReport(attemptID: request.attemptID, mode: request.mode, targetUID: request.targetUID,
                sources: Array(Set(attempt.markers.map(\.source))).sorted(), configurationSHA256: request.configurationSHA256,
                order: request.order, activeOtherZones: request.activeOtherZones, outcome: outcome, markerIntervalSeconds: interval, eventDurationUpperSeconds: upper, uncertaintySeconds: uncertainty,
                timingEvidenceComplete: issues.isEmpty, issues: issues)
        }
        return LoginReport(attempts: reports)
    }
}
