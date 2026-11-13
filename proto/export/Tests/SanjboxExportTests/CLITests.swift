import XCTest
import SanjboxExport
@testable import SanjboxExportCLI

/// CLI: `--dry-run` je výchozí režim, exit kódy jsou dokumentované v README.
/// Většina testů volá knihovní runner, stejnou cestu jako tenký `main.swift`.
/// Regrese blokujícího auditního open běží v procesech s časovým limitem.
final class CLITests: XCTestCase {
    private var tree: TempTree!
    private var destTree: TempTree!

    override func setUpWithError() throws {
        tree = try TempTree(label: "cli")
        destTree = try TempTree(label: "cli-dest")
        try tree.writeFile("notes/a.txt", contents: "kanarek")
        try tree.writeFile("notes/b.bin", contents: "druhy")
    }

    override func tearDown() {
        tree?.remove()
        destTree?.remove()
        tree = nil
        destTree = nil
    }

    private struct Run {
        var code: Int32
        var stdout: String
        var stderr: String
    }

    private func run(_ arguments: [String]) -> Run {
        final class Buffer: @unchecked Sendable {
            var text = ""
        }
        let out = Buffer()
        let err = Buffer()
        let code = ExportCLI().run(arguments: arguments, stdout: { out.text += $0 }, stderr: { err.text += $0 })
        return Run(code: code, stdout: out.text, stderr: err.text)
    }

    func testDryRunIsDefaultAndWritesNothing() throws {
        let destination = destTree.path("out")
        let structureBefore = tree.structure()
        let contentsBefore = tree.contents()

        let result = run(["--root", tree.root, "--file", "notes/a.txt", "--file", "notes/b.bin", "--dest", destination])

        XCTAssertEqual(result.code, ExportExitCode.ok.rawValue, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("\"relativePath\" : \"notes/a.txt\""))
        XCTAssertTrue(result.stderr.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination), "dry-run nesmí vytvořit cíl")
        XCTAssertEqual(tree.structure(), structureBefore, "dry-run nesmí zapsat do zdrojového stromu")
        XCTAssertEqual(tree.contents(), contentsBefore)
    }

    func testApplyCopiesQuarantinesAndWritesAudit() throws {
        let destination = destTree.path("out")
        let audit = destTree.path("audit.json")
        let result = run([
            "--root", tree.root,
            "--file", "notes/a.txt",
            "--dest", destination,
            "--audit", audit,
            "--apply",
        ])

        XCTAssertEqual(result.code, ExportExitCode.ok.rawValue, "stderr: \(result.stderr)")
        XCTAssertEqual(
            try String(contentsOfFile: destination + "/notes/a.txt", encoding: .utf8),
            "kanarek"
        )
        XCTAssertEqual(quarantine(ofFile: destination + "/notes/a.txt"), Quarantine.defaultValue)

        let auditText = try String(contentsOfFile: audit, encoding: .utf8)
        XCTAssertTrue(auditText.contains("\"phase\":\"preview\""))
        XCTAssertTrue(auditText.contains("\"phase\":\"copy\""))
        XCTAssertTrue(auditText.contains("\"scheme\":\"sanjbox.export.audit.v0\""))
        XCTAssertEqual(auditText.split(separator: "\n").count, 2, "jeden záznam na řádek")
    }

    func testPolicyRejectionExitCodeThreeAndNoCopy() throws {
        try tree.makeSymlink("notes/link.txt", target: "a.txt")
        let destination = destTree.path("out")
        let result = run(["--root", tree.root, "--file", "notes/link.txt", "--dest", destination, "--apply"])

        XCTAssertEqual(result.code, ExportExitCode.policyRejection.rawValue)
        XCTAssertTrue(result.stderr.contains("refusing to copy"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination), "odmítnutý plán se nekopíruje")
    }

    func testDryRunWithRejectionAlsoReturnsThree() throws {
        try tree.makeFIFO("pipe.fifo")
        let result = run(["--root", tree.root, "--file", "pipe.fifo"])
        XCTAssertEqual(result.code, ExportExitCode.policyRejection.rawValue)
        XCTAssertTrue(result.stdout.contains("\"reason\" : \"specialFile\""))
    }

    func testUsageErrorsExitTwo() throws {
        XCTAssertEqual(run([]).code, ExportExitCode.usage.rawValue)
        XCTAssertEqual(run(["--root", tree.root]).code, ExportExitCode.usage.rawValue)
        XCTAssertEqual(
            run(["--root", tree.root, "--file", "notes/a.txt", "--apply"]).code,
            ExportExitCode.usage.rawValue
        )
        XCTAssertEqual(
            run(["--root", tree.root, "--file", "notes/a.txt", "--apply", "--dry-run"]).code,
            ExportExitCode.usage.rawValue
        )
        XCTAssertEqual(run(["--root"]).code, ExportExitCode.usage.rawValue)
        XCTAssertEqual(run(["--root", tree.root, "--file", "a", "--bogus"]).code, ExportExitCode.usage.rawValue)
        let usage = run(["--help"])
        XCTAssertEqual(usage.code, ExportExitCode.ok.rawValue)
        XCTAssertTrue(usage.stdout.contains("exit 3"))
    }

    func testExistingAuditFileIsNotOverwritten() throws {
        let audit = destTree.path("audit.json")
        try destTree.writeFile("audit.json", contents: "stary zaznam")
        let destination = destTree.path("out")
        let result = run([
            "--root", tree.root,
            "--file", "notes/a.txt",
            "--dest", destination,
            "--audit", audit,
            "--apply",
        ])
        XCTAssertEqual(result.code, ExportExitCode.failure.rawValue)
        XCTAssertEqual(try String(contentsOfFile: audit, encoding: .utf8), "stary zaznam")
    }

    func testApplyFailureReturnsOneAndReportsReason() throws {
        // Cílový kořen existuje → export nesmí pokračovat.
        try destTree.makeDirectory("out")
        let result = run([
            "--root", tree.root,
            "--file", "notes/a.txt",
            "--dest", destTree.path("out"),
            "--apply",
        ])
        XCTAssertEqual(result.code, ExportExitCode.failure.rawValue)
        XCTAssertTrue(result.stderr.contains("destination already exists"))
    }

    func testAuditIsWrittenEvenWhenApplyFails() throws {
        // Cílový kořen existuje → apply skončí exit 1, ale záznam o rozhodnutích musí zůstat.
        try destTree.makeDirectory("out")
        let audit = destTree.path("audit-failure.json")
        let result = run([
            "--root", tree.root,
            "--file", "notes/a.txt",
            "--dest", destTree.path("out"),
            "--audit", audit,
            "--apply",
        ])
        XCTAssertEqual(result.code, ExportExitCode.failure.rawValue)
        let text = try String(contentsOfFile: audit, encoding: .utf8)
        XCTAssertTrue(text.contains("\"phase\":\"preview\""))
        XCTAssertFalse(text.contains("\"phase\":\"copy\""))
    }

    /// Dry-run s --audit nesmí na disk zapsat nic; audit jde jen na stdout.
    func testDryRunAuditNeverCreatesFile() throws {
        let audit = destTree.path("dry-audit.json")
        let structureBefore = tree.structure()
        let result = run([
            "--root", tree.root,
            "--file", "notes/a.txt",
            "--audit", audit,
        ])
        XCTAssertEqual(result.code, ExportExitCode.ok.rawValue, "stderr: \(result.stderr)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audit), "dry-run nesmí vytvořit audit")
        XCTAssertEqual(tree.structure(), structureBefore)
        XCTAssertTrue(result.stdout.contains("\"scheme\" : \"sanjbox.export.audit.v0\""))
    }

    func testDestinationInsideRootIsUsageError() throws {
        let inside = tree.path("out")
        let result = run([
            "--root", tree.root,
            "--file", "notes/a.txt",
            "--dest", inside,
            "--apply",
        ])
        XCTAssertEqual(result.code, ExportExitCode.usage.rawValue)
        XCTAssertTrue(result.stderr.contains("is inside --root"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inside))
    }

    func testAuditWriteErrorReportsActualErrnoForDirectory() throws {
        try destTree.makeDirectory("audit-dir")
        let result = run([
            "--root", tree.root,
            "--file", "notes/a.txt",
            "--dest", destTree.path("out"),
            "--audit", destTree.path("audit-dir"),
            "--apply",
        ])
        XCTAssertEqual(result.code, ExportExitCode.failure.rawValue)
        XCTAssertTrue(result.stderr.contains("errno 21"), "skutečné EISDIR, ne vždy EEXIST: \(result.stderr)")
        XCTAssertTrue(result.stderr.contains("Is a directory"))
    }

    func testAuditWriteErrorReportsActualErrnoForMissingParent() throws {
        let result = run([
            "--root", tree.root,
            "--file", "notes/a.txt",
            "--dest", destTree.path("out"),
            "--audit", destTree.path("missing/audit.json"),
            "--apply",
        ])
        XCTAssertEqual(result.code, ExportExitCode.failure.rawValue)
        XCTAssertTrue(result.stderr.contains("errno 2"), "skutečné ENOENT, ne vždy EEXIST: \(result.stderr)")
        XCTAssertTrue(result.stderr.contains("No such file or directory"))
    }

    func testDestinationThroughSymlinkThenParentIsRejectedBeforeAuditCreation() throws {
        try tree.makeDirectory("nested")
        try destTree.makeSymlink("alias", target: tree.path("nested"))
        let audit = destTree.path("audit-alias.jsonl")
        let result = run([
            "--root", tree.root, "--file", "notes/a.txt",
            "--dest", destTree.path("alias") + "/../out", "--audit", audit, "--apply",
        ])
        XCTAssertEqual(result.code, ExportExitCode.usage.rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path("out")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audit))
    }

    func testExistingAuditFIFOIsRefusedWithoutBlocking() throws {
        try destTree.makeFIFO("audit.fifo")
        try assertAuditPathRefusedByProcess(destTree.path("audit.fifo"))
    }

    func testExistingAuditSymlinkToFIFOIsRefusedWithoutFollowingIt() throws {
        try destTree.makeFIFO("audit-target.fifo")
        try destTree.makeSymlink("audit-link", target: "audit-target.fifo")
        try assertAuditPathRefusedByProcess(destTree.path("audit-link"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destTree.path("audit-link")),
                       "audit-target.fifo")
    }

    /// Proces je ohraničený: regrese blokujícího open nesmí zaseknout test runner.
    private func assertAuditPathRefusedByProcess(_ audit: String) throws {
        let binary = Bundle(for: CLITests.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("sanjbox-export")
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--root", tree.root, "--file", "notes/a.txt",
                             "--dest", destTree.path("out"), "--audit", audit, "--apply"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        guard exited.wait(timeout: .now() + 3) == .success else {
            return XCTFail("CLI se zablokovalo na existujícím auditním objektu")
        }
        let error = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, ExportExitCode.failure.rawValue, error)
        XCTAssertTrue(error.contains("errno 17"), error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destTree.path("out")))
    }

    func testArgumentOrderDoesNotAffectOutput() throws {
        let first = run(["--root", tree.root, "--file", "notes/b.bin", "--file", "notes/a.txt"])
        let second = run(["--file", "notes/a.txt", "--root", tree.root, "--file", "notes/b.bin"])
        XCTAssertEqual(first.code, ExportExitCode.ok.rawValue)
        XCTAssertEqual(first.stdout, second.stdout)
    }

    func testInvalidRootReturnsOne() throws {
        let result = run(["--root", tree.path("nope"), "--file", "a.txt"])
        XCTAssertEqual(result.code, ExportExitCode.failure.rawValue)
        XCTAssertTrue(result.stderr.contains("invalid root"))
    }
}
