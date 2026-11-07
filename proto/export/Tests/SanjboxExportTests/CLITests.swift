import XCTest
import SanjboxExport
@testable import SanjboxExportCLI

/// CLI: `--dry-run` je výchozí režim, exit kódy jsou dokumentované v README.
/// Testy volají knihovní runner, ne proces — ověřují stejnou cestu, kterou používá
/// tenký `main.swift`.
final class CLITests: XCTestCase {
    private var tree: TempTree!

    override func setUpWithError() throws {
        tree = try TempTree(label: "cli")
        try tree.writeFile("notes/a.txt", contents: "kanarek")
        try tree.writeFile("notes/b.bin", contents: "druhy")
    }

    override func tearDown() {
        tree?.remove()
        tree = nil
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
        let destination = tree.path("out")
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
        let destination = tree.path("out")
        let audit = tree.path("audit.json")
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
        XCTAssertTrue(auditText.contains("\"phase\" : \"preview\""))
        XCTAssertTrue(auditText.contains("\"phase\" : \"copy\""))
        XCTAssertTrue(auditText.contains("\"scheme\" : \"sanjbox.export.audit.v0\""))
    }

    func testPolicyRejectionExitCodeThreeAndNoCopy() throws {
        try tree.makeSymlink("notes/link.txt", target: "a.txt")
        let destination = tree.path("out")
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
        let audit = tree.path("audit.json")
        try tree.writeFile("audit.json", contents: "stary zaznam")
        let destination = tree.path("out")
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
        try tree.makeDirectory("out")
        let result = run([
            "--root", tree.root,
            "--file", "notes/a.txt",
            "--dest", tree.path("out"),
            "--apply",
        ])
        XCTAssertEqual(result.code, ExportExitCode.failure.rawValue)
        XCTAssertTrue(result.stderr.contains("destination already exists"))
    }

    func testAuditIsWrittenEvenWhenApplyFails() throws {
        // Cílový kořen existuje → apply skončí exit 1, ale záznam o rozhodnutích musí zůstat.
        try tree.makeDirectory("out")
        let audit = tree.path("audit-failure.json")
        let result = run([
            "--root", tree.root,
            "--file", "notes/a.txt",
            "--dest", tree.path("out"),
            "--audit", audit,
            "--apply",
        ])
        XCTAssertEqual(result.code, ExportExitCode.failure.rawValue)
        let text = try String(contentsOfFile: audit, encoding: .utf8)
        XCTAssertTrue(text.contains("\"phase\" : \"preview\""))
        XCTAssertFalse(text.contains("\"phase\" : \"copy\""))
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
