import Darwin
import Foundation
import Testing
import SanjboxContracts
@testable import SanjboxEscape

@Suite("H6 owned fixtures and H1 audit")
struct FixtureTests {
    @Test func cleanupIsIdempotentAndDoesNotFollowOutsideSymlink() throws {
        let fixture = try OwnedFixture(); let outside = try OwnedFixture()
        defer { try? fixture.cleanup(); try? outside.cleanup() }
        let sentinel = outside.url.appendingPathComponent("sentinel")
        try Data("owned control".utf8).write(to: sentinel)
        #expect(symlink(outside.url.path, fixture.url.appendingPathComponent("alias").path) == 0)
        try fixture.cleanup(); try fixture.cleanup()
        #expect(try Data(contentsOf: sentinel) == Data("owned control".utf8))
    }
    @Test func cleanupRefusesReplacedRoot() throws {
        let fixture = try OwnedFixture()
        let moved = fixture.url.appendingPathExtension("moved")
        #expect(rename(fixture.url.path, moved.path) == 0)
        #expect(mkdir(fixture.url.path, 0o700) == 0)
        #expect(throws: (any Error).self) { try fixture.cleanup() }
        #expect(rmdir(fixture.url.path) == 0)
        #expect(rename(moved.path, fixture.url.path) == 0)
        try fixture.cleanup()
    }
    @Test func mockTreeRejectsTraversalUnknownRootAndSpecialFiles() throws {
        let fixture = try OwnedFixture(); defer { try? fixture.cleanup() }
        let boundary = TreeBoundary(zone: fixture.url)
        for (root, path) in [("host", "canary"), ("zone", "../canary"), ("zone", "a/b"), ("zone", "."), ("zone", "\0")] {
            #expect(try boundary.read(root: root, name: path) == nil)
        }
        #expect(mkfifo(fixture.url.appendingPathComponent("fifo").path, 0o600) == 0)
        #expect(try boundary.read(root: "zone", name: "fifo") == nil)
    }
    @Test func missingFileIsNotSuccessfulDenial() throws {
        let fixture = try OwnedFixture(); defer { try? fixture.cleanup() }
        #expect(throws: (any Error).self) { _ = try TreeBoundary(zone: fixture.url).read(root: "zone", name: "missing") }
    }
    @Test func counterpartRejectsSetIDAndSymlinkExecutable() throws {
        let fixture = try OwnedFixture(); defer { try? fixture.cleanup() }
        let binary = fixture.url.appendingPathComponent("fake")
        try Data("not executed".utf8).write(to: binary)
        #expect(chmod(binary.path, 0o4700) == 0)
        #expect(throws: (any Error).self) { _ = try LoopbackCounterpart(executable: binary) }
        let alias = fixture.url.appendingPathComponent("alias")
        #expect(symlink("/usr/bin/false", alias.path) == 0)
        #expect(throws: (any Error).self) { _ = try LoopbackCounterpart(executable: alias) }
    }
    @Test func auditUsesH1StrictEncoderAndDecoder() throws {
        let records = [AuditRecord(sequence: 1, timestampUTC: "2026-11-14T00:00:00.000Z", zoneID: "h6zz", actorUID: 501,
                                   action: .zoneCreated, outcome: .allowed, detail: "synthetic fixture")]
        let report = try HarnessReport(results: [], counterpart: [], audit: records, cleanupVerified: true)
        #expect(try AuditLog.decode(Data(report.auditJSON.utf8)) == records)
        var invalid = records; invalid[0].sequence = 2
        #expect(throws: (any Error).self) { _ = try HarnessReport(results: [], counterpart: [], audit: invalid, cleanupVerified: true) }
        let foreignAction = report.auditJSON.replacingOccurrences(of: "zone.created", with: "escape.passed")
        #expect(throws: (any Error).self) { _ = try AuditLog.decode(Data(foreignAction.utf8)) }
    }
    @Test func identityMismatchStopsAllProbesBeforeAnyEffects() throws {
        let result = try SyntheticRunner.run(counterpart: URL(fileURLWithPath: "/does-not-exist"), faults: [.wrongIdentity])
        #expect(result.counts["incomplete"] == 8)
        #expect(result.counterpart.isEmpty)
        #expect(try AuditLog.decode(Data(result.auditJSON.utf8)).isEmpty)
        #expect(result.cleanupVerified && result.exitCode == 3)
    }
}
