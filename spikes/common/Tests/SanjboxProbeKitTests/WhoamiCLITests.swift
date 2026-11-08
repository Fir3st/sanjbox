import Darwin
import Foundation
import XCTest
import SanjboxProbeKit

/// Launches the built CLI as a child in the caller's own context; no lab identity is asserted.
final class WhoamiCLITests: XCTestCase {
    func testDiagnosticLogsUnclearAndExitsSuccessfully() throws {
        let result = try runWhoami()
        XCTAssertNil(result.report.valid)
        XCTAssertTrue(result.report.mismatches.isEmpty)
        XCTAssertEqual(result.record?.outcome, .unclear)
        XCTAssertEqual(result.status, 0)
    }

    func testDiagnosticWithoutLogRemainsSuccessful() throws {
        let result = try runWhoami(logging: false)
        XCTAssertNil(result.report.valid)
        XCTAssertTrue(result.report.mismatches.isEmpty)
        XCTAssertNil(result.record)
        XCTAssertEqual(result.status, 0)
    }

    func testMatchingExpectationLogsPassed() throws {
        let result = try runWhoami(expectation: ProbeExpectation(effectiveUID: geteuid()))
        XCTAssertEqual(result.report.valid, true)
        XCTAssertTrue(result.report.mismatches.isEmpty)
        XCTAssertEqual(result.record?.outcome, .passed)
        XCTAssertEqual(result.status, 0)
    }

    func testMismatchingExpectationLogsInvalidMeasurement() throws {
        let wrongUID = geteuid() ^ 1
        let result = try runWhoami(expectation: ProbeExpectation(effectiveUID: wrongUID))
        XCTAssertEqual(result.report.valid, false)
        XCTAssertEqual(result.report.mismatches.count, 1)
        let mismatch = try XCTUnwrap(result.report.mismatches.first)
        XCTAssertEqual(mismatch.field, "effectiveUID")
        XCTAssertEqual(mismatch.expected, String(wrongUID))
        XCTAssertEqual(mismatch.actual, String(geteuid()))
        XCTAssertEqual(result.record?.outcome, .invalidMeasurement)
        XCTAssertEqual(result.status, 3)
    }

    private struct Report: Decodable {
        let context: ProbeContext
        let mismatches: [Mismatch]
        let valid: Bool?
    }

    private struct Result {
        let report: Report
        let record: RunRecord?
        let status: Int32
    }

    private enum CLIError: Error { case timedOut, oversizedOutput }

    private func runWhoami(expectation: ProbeExpectation? = nil, logging: Bool = true) throws -> Result {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("sanjbox-whoami-cli-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: directory) }

        // Follow this test bundle, so release and custom --scratch-path builds test their own CLI.
        let binary = Bundle(for: WhoamiCLITests.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("sanjbox-whoami")
        XCTAssertTrue(files.isExecutableFile(atPath: binary.path), "swift test must build sanjbox-whoami")
        let process = Process()
        process.executableURL = binary
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        var arguments: [String] = []
        if let expectation {
            let input = directory.appendingPathComponent("expectation.json")
            try JSONLines.encoder.encode(expectation).write(to: input)
            arguments += ["--expect", input.path]
        }
        let log = directory.appendingPathComponent("run.jsonl")
        if logging { arguments += ["--log", log.path, "--case", "WHOAMI-CLI"] }
        process.arguments = arguments

        // Files avoid a full pipe blocking the child; bounded reads keep failure output small.
        let stdout = directory.appendingPathComponent("stdout.json")
        let stderr = directory.appendingPathComponent("stderr.txt")
        XCTAssertTrue(files.createFile(atPath: stdout.path, contents: nil))
        XCTAssertTrue(files.createFile(atPath: stderr.path, contents: nil))
        let output = try FileHandle(forWritingTo: stdout)
        let errors = try FileHandle(forWritingTo: stderr)
        defer { try? output.close(); try? errors.close() }
        process.standardOutput = output
        process.standardError = errors
        let exited = XCTestExpectation(description: "whoami child exited")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        guard XCTWaiter.wait(for: [exited], timeout: 10) == .completed else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw CLIError.timedOut
        }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertTrue(try boundedRead(stderr).isEmpty, "whoami wrote to stderr")
        let report = try JSONLines.decoder.decode(Report.self, from: boundedRead(stdout))
        XCTAssertEqual(report.context.pid, process.processIdentifier)
        XCTAssertEqual(report.context.parentPID, getpid())
        XCTAssertEqual(report.context.effectiveUID, geteuid())

        var record: RunRecord?
        if logging {
            let lines = try boundedRead(log).split(separator: 0x0A)
            XCTAssertEqual(lines.count, 1)
            record = try JSONLines.decoder.decode(RunRecord.self, from: Data(XCTUnwrap(lines.first)))
            XCTAssertEqual(record?.probe, "sanjbox-whoami")
            XCTAssertEqual(record?.caseID, "WHOAMI-CLI")
            // Compare without printing personal context fields on assertion failure.
            XCTAssertTrue(record?.context == report.context, "log and stdout contexts differ")
            XCTAssertTrue(record?.mismatches == report.mismatches, "log and stdout mismatches differ")
        } else {
            XCTAssertFalse(files.fileExists(atPath: log.path))
        }
        return Result(report: report, record: record, status: process.terminationStatus)
    }

    private func boundedRead(_ url: URL) throws -> Data {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let limit = 64 * 1024
        let data = try input.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CLIError.oversizedOutput }
        return data
    }
}
