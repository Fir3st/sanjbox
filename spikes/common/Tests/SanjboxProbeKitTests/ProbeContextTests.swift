import Darwin
import Foundation
import Testing
@testable import SanjboxProbeKit

/// Smoke test against the real system: runs as the developer in their own session.
@Test func captureReportsTheCallingProcess() throws {
    let context = ProbeContext.capture(groupsOfInterest: [0])
    #expect(context.pid == getpid())
    #expect(context.effectiveUID == geteuid())
    #expect(context.realGID == getgid())
    #expect(context.audit != nil)
    // Membership of a real group must be resolved, never left unknown.
    #expect(context.groupMembership.count == 1)
    #expect(context.groupMembership[0].isMember != nil)
}

@Test func recordRoundTripsAsJSONLines() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sanjbox-run-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let context = ProbeContext.capture()
    let first = RunRecord(
        timestamp: Date(timeIntervalSince1970: 1_800_000_000), probe: "test", caseID: "FS-01",
        outcome: .passed, context: context
    )
    let second = RunRecord(
        timestamp: Date(timeIntervalSince1970: 1_800_000_001), probe: "test", caseID: "FS-02",
        outcome: .invalidMeasurement, context: context,
        mismatches: [Mismatch(field: "effectiveUID", expected: "450", actual: "501")]
    )
    try JSONLines.append(first, to: url)
    try JSONLines.append(second, to: url)
    #expect(try JSONLines.read(RunRecord.self, from: url) == [first, second])
}

@Test func argumentsSeparateFlagsFromPositionals() throws {
    let parsed = try ProbeArguments(["--registry", "r.jsonl", "a.bin", "b.bin"], valueFlags: ["registry"])
    #expect(parsed.options == ["registry": "r.jsonl"])
    #expect(parsed.positional == ["a.bin", "b.bin"])
    #expect(throws: ProbeArgumentError.self) { try ProbeArguments(["--unknown", "x"], valueFlags: ["registry"]) }
    #expect(throws: ProbeArgumentError.self) { try ProbeArguments(["--registry"], valueFlags: ["registry"]) }
}
