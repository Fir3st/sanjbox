import Darwin
import Foundation
import Testing
import SanjboxContracts
@testable import SanjboxEscape

@Suite("H6 real local counterpart and CLI", .serialized)
struct IntegrationTests {
    @Test func actualCounterpartPositiveNegativeIncompleteAndCLI() throws {
        let fixture = try OwnedFixture(); defer { try? fixture.cleanup() }
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let common = repoRoot.appendingPathComponent("spikes/common")
        let scratch = fixture.url.appendingPathComponent("common-build")
        let buildArgs = ["build", "--package-path", common.path, "--scratch-path", scratch.path, "-c", configuration]
        let build = try ChildProcess(executable: URL(fileURLWithPath: "/usr/bin/swift"),
            arguments: buildArgs + ["--product", "sanjbox-counterpart"], directory: fixture.url, label: "build")
        #expect(try build.wait(seconds: 150) == 0)
        let bin = try ChildProcess(executable: URL(fileURLWithPath: "/usr/bin/swift"),
            arguments: buildArgs + ["--show-bin-path"], directory: fixture.url, label: "bin-path")
        #expect(try bin.wait(seconds: 20) == 0)
        let binaryDirectory = String(decoding: try bin.outputData(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let counterpart = URL(fileURLWithPath: binaryDirectory).appendingPathComponent("sanjbox-counterpart")
        #expect(FileManager.default.isExecutableFile(atPath: counterpart.path))

        let report = try SyntheticRunner.run(counterpart: counterpart)
        #expect(report.counts["syntheticPassed"] == 8, "\(report.results.filter { $0.status == .incomplete })")
        #expect(report.counts["manualRequired"] == 133)
        #expect(report.counts["unsupported"] == 14)
        #expect(report.cleanupVerified && report.exitCode == 3)
        #expect(report.counterpart.count == 4)
        #expect(report.counterpart.map(\.reportExit) == [1, 0, 1, 1])
        #expect(report.counterpart.allSatisfy { $0.complete })
        #expect(report.counterpart[1].empty)
        #expect(report.counterpart[0].rawPayload != nil && report.counterpart[2].rawPayload != nil)
        let audit = try AuditLog.decode(Data(report.auditJSON.utf8))
        #expect(audit.map(\.action) == [.zoneCreated, .gateRequestDenied, .zoneCleaned])
        #expect(audit.map(\.sequence) == [1, 2, 3])
        #expect(audit.allSatisfy { $0.actorUID == geteuid() && $0.zoneID == "h6zz" })
        #expect(audit[1].subjectID == "net-02" && audit[1].outcome == .denied)

        for (fault, id, status) in [(Fault.networkBypass, "NET-02", SyntheticStatus.syntheticFailed),
                                  (.missingStopped, "NET-02", .incomplete),
                                  (.foreignReadAllowed, "FS-01", .syntheticFailed)] {
            let failed = try SyntheticRunner.run(counterpart: counterpart, faults: [fault])
            #expect(failed.results.first { $0.id == id }?.status == status)
            #expect(failed.exitCode == (status == .syntheticFailed ? 1 : 3))
            #expect(failed.cleanupVerified)
            if fault == .networkBypass {
                #expect(failed.counterpart[1].report.bytes > 0)
                #expect(failed.counterpart[1].reportExit == 1)
            }
            if fault == .missingStopped {
                #expect(!failed.counterpart[1].complete)
                #expect(failed.counterpart[1].reportExit == 3)
            }
        }
        let cli = try cliExecutable()
        let plan = try ChildProcess(executable: cli, arguments: [], directory: fixture.url, label: "plan")
        #expect(try plan.wait(seconds: 5) == 0)
        let planned = try JSONDecoder().decode([AcceptanceCase].self, from: plan.outputData())
        #expect(planned.map(\.id) == expectedIDs)
        let misuse = try ChildProcess(executable: cli, arguments: ["run", "--counterpart", counterpart.path], directory: fixture.url, label: "misuse")
        #expect(try misuse.wait(seconds: 5) == 2)
        let run = try ChildProcess(executable: cli, arguments: ["run", "--apply", "--counterpart", counterpart.path], directory: fixture.url, label: "run")
        #expect(try run.wait(seconds: 30) == 3)
        let object = try #require(JSONSerialization.jsonObject(with: run.outputData()) as? [String: Any])
        #expect(object["summary"] as? String == "incomplete")
        #expect((object["counts"] as? [String: Int])?["syntheticPassed"] == 8)
        #expect((object["results"] as? [[String: Any]])?.count == 155)
    }
    @Test func childDeadlineTerminatesOwnedProcess() throws {
        let fixture = try OwnedFixture(); defer { try? fixture.cleanup() }
        let child = try ChildProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"],
                                     directory: fixture.url, label: "timeout")
        #expect(throws: (any Error).self) { _ = try child.wait(seconds: 0.05) }
        #expect(!child.process.isRunning)
    }
}

private final class TestBundleAnchor: NSObject {}

private func cliExecutable() throws -> URL {
    var directory = Bundle(for: TestBundleAnchor.self).bundleURL.deletingLastPathComponent()
    for _ in 0..<5 {
        let candidate = directory.appendingPathComponent("sanjbox-escape")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        directory.deleteLastPathComponent()
    }
    throw HarnessError.invalid("built sanjbox-escape executable not found next to test product")
}
