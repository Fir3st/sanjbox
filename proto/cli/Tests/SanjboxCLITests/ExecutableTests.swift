import XCTest
import Foundation
@testable import SanjboxCLI

final class ExecutableTests: XCTestCase {
    private func executable() throws -> URL {
        var directory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("sanjbox")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw CLIError.connectionLost
    }
    private func run(_ arguments: [String]) throws -> (Int32, String, String) {
        let process = Process(), output = Pipe(), error = Pipe(), done = DispatchSemaphore(value: 0)
        process.executableURL = try executable()
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + 6) != .success {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
            XCTFail("owned CLI child exceeded deadline")
            throw CLIError.timeout
        }
        return (process.terminationStatus,
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    func testExecutableAllFiveCommandsAndAcceptanceSemantics() throws {
        let vectors: [([String], String)] = [
            (["shell", "a1b2"], "accepted kind=zone.shell"),
            (["run", "a1b2", "--executable-root", "tools", "--", "bin/never-executed", "", "a b", "$(false)", "--help"], "accepted kind=zone.run"),
            (["pause", "a1b2"], "completed kind=zone.pause"),
            (["snapshot", "a1b2", "new", "--restore-unit", "full-state"], "completed kind=zone.snapshot"),
            (["rollback", "a1b2", "baseline", "--restore-unit", "full-state"], "completed kind=zone.rollback"),
        ]
        for (arguments, expected) in vectors {
            let (code, stdout, stderr) = try run(["--mock"] + arguments)
            XCTAssertEqual(code, 0, stderr)
            XCTAssertTrue(stdout.contains("mock " + expected), stdout)
            XCTAssertEqual(stderr, "")
            if expected.hasPrefix("accepted") {
                XCTAssertTrue(stdout.contains("execution=mock-exec-1"))
                XCTAssertTrue(stdout.contains("process completion unknown (no process executed)"))
            }
        }
    }
    func testExecutableUsageAndRefusalsHaveDistinctExitCodes() throws {
        let vectors: [([String], Int32)] = [
            ([], 64), (["shell", "a1b2"], 64), (["--mock", "pause", "../x"], 64),
            (["--mock", "shell", "a1b2", "--uid", "0"], 64),
            (["--mock", "shell", "b2c3"], 70),
            (["--mock", "rollback", "a1b2", "missing", "--restore-unit", "full-state"], 70),
            (["--mock", "snapshot", "a1b2", "new", "--restore-unit", "project"], 70),
        ]
        for (arguments, expected) in vectors {
            let (code, stdout, stderr) = try run(arguments)
            XCTAssertEqual(code, expected)
            XCTAssertEqual(stdout, "")
            XCTAssertTrue(stderr.hasPrefix("sanjbox: "))
        }
    }
    func testExecutableHelpDocumentsMockAndExitScope() throws {
        let (code, stdout, stderr) = try run(["--help"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(stderr, "")
        XCTAssertTrue(stdout.contains("real local XPC"))
        XCTAssertTrue(stdout.contains("never a child process exit status"))
    }
    func testInputDiagnosticsDoNotEchoUntrustedArguments() {
        let result = SanjboxMain.run(["--mock", "shell", "a1b2", "--working-directory", "\u{1b}[31m\nATTACK"])
        XCTAssertEqual(result.code, 64)
        XCTAssertFalse(result.stderr.contains("ATTACK"))
        XCTAssertFalse(result.stderr.contains("\u{1b}"))
    }
}
