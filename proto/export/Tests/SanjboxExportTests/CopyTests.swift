import Darwin
import XCTest
@testable import SanjboxExport

/// Fáze 3–4: kopie a karanténa. Cílový strom je vždy nový adresář pod `/private/tmp`.
final class CopyTests: XCTestCase {
    private var tree: TempTree!
    private var destination: String!

    override func setUpWithError() throws {
        tree = try TempTree(label: "copy")
        destination = tree.path("out")
    }

    override func tearDown() {
        // Cílový strom leží uvnitř vlastního temp stromu, takže ho smaže `TempTree.remove()`.
        tree?.remove()
        tree = nil
        destination = nil
    }

    private func prepare(_ paths: [String]) throws -> ExportPlan {
        try ExportPreparer(rootPath: tree.root).prepare(relativePaths: paths)
    }

    func testCopiesContentModeAndQuarantines() throws {
        try tree.writeFile("notes/a.txt", contents: "synteticky kanarek", mode: 0o640)
        try tree.writeFile("notes/sub/b.txt", contents: "druhy kanarek", mode: 0o600)
        let plan = try prepare(["notes/a.txt", "notes/sub/b.txt"])

        let result = try ExportCopier().apply(plan, destinationRoot: destination)

        XCTAssertEqual(result.copied.map(\.relativePath), ["notes/a.txt", "notes/sub/b.txt"])
        let copiedA = destination + "/notes/a.txt"
        XCTAssertEqual(try String(contentsOfFile: copiedA, encoding: .utf8), "synteticky kanarek")
        XCTAssertEqual(try String(contentsOfFile: destination + "/notes/sub/b.txt", encoding: .utf8), "druhy kanarek")

        let mode = try XCTUnwrap(fileMode(copiedA))
        XCTAssertEqual(mode & 0o777, 0o640)
        XCTAssertEqual(try XCTUnwrap(fileMode(destination + "/notes/sub/b.txt")) & 0o777, 0o600)

        // Karanténa je skutečná xattr na výsledku, ne jen pole ve výsledkové struktuře.
        XCTAssertEqual(quarantine(ofFile: copiedA), Quarantine.defaultValue)
        XCTAssertEqual(result.copied.first?.quarantineValue, Quarantine.defaultValue)

        // Zdroj zůstal beze změny a bez karantény.
        XCTAssertNil(quarantine(ofFile: tree.path("notes/a.txt")))
        XCTAssertEqual(countOfHardlinks(copiedA), 1, "kopie nesmí být hardlink")
    }

    func testDestinationRootIsCreatedFreshAndNeverReused() throws {
        try tree.writeFile("a.txt", contents: "x")
        let plan = try prepare(["a.txt"])
        _ = try ExportCopier().apply(plan, destinationRoot: destination)

        XCTAssertThrowsError(try ExportCopier().apply(plan, destinationRoot: destination)) { error in
            guard case let ExportError.destinationExists(path) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(path, destination)
        }
    }

    func testDestinationSymlinkRefused() throws {
        try tree.writeFile("a.txt", contents: "x")
        try tree.makeDirectory("elsewhere")
        try tree.makeSymlink("linked-out", target: "elsewhere")

        let plan = try prepare(["a.txt"])
        XCTAssertThrowsError(
            try ExportCopier().apply(plan, destinationRoot: tree.path("linked-out"))
        ) { error in
            guard case ExportError.destinationExists = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testPlanWithRejectionRefusesToCopyAnything() throws {
        try tree.writeFile("real.txt", contents: "x")
        try tree.makeSymlink("link.txt", target: "real.txt")
        let plan = try prepare(["real.txt", "link.txt"])
        XCTAssertFalse(plan.isClean)

        XCTAssertThrowsError(try ExportCopier().apply(plan, destinationRoot: destination)) { error in
            guard case let ExportError.planNotClean(paths) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(paths, ["link.txt"])
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination),
            "při odmítnutém plánu nesmí vzniknout ani cílový kořen"
        )
    }

    /// TOCTOU: soubor se mezi preview a kopií vymění za jiný inode se stejným obsahem.
    func testInodeSwapBetweenPreviewAndCopyIsDetected() throws {
        try tree.writeFile("target.txt", contents: "puvodni obsah")
        let plan = try prepare(["target.txt"])
        let expected = try XCTUnwrap(plan.candidates.first?.snapshot)

        // Náhrada proběhne přejmenováním souběžně existujícího souboru, takže nový inode
        // je zaručeně jiný než ten z preview.
        try tree.writeFile("replacement.tmp", contents: "puvodni obsah")
        XCTAssertEqual(rename(tree.path("replacement.tmp"), tree.path("target.txt")), 0)

        XCTAssertThrowsError(try ExportCopier().apply(plan, destinationRoot: destination)) { error in
            guard case let ExportError.identityMismatch(path, expectedSnapshot, actual) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(path, "target.txt")
            XCTAssertEqual(expectedSnapshot, expected)
            XCTAssertNotEqual(actual.inode, expected.inode)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination + "/target.txt"),
            "vyměněný soubor se nesmí zkopírovat"
        )
    }

    /// TOCTOU varianta bez výměny inode: soubor naroste mezi preview a kopií.
    func testSizeChangeBetweenPreviewAndCopyIsDetected() throws {
        try tree.writeFile("grow.txt", contents: "abc")
        let plan = try prepare(["grow.txt"])

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tree.path("grow.txt")))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("def".utf8))
        try handle.close()

        XCTAssertThrowsError(try ExportCopier().apply(plan, destinationRoot: destination)) { error in
            guard case let ExportError.identityMismatch(_, expected, actual) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(expected.size, 3)
            XCTAssertEqual(actual.size, 6)
            XCTAssertEqual(actual.inode, expected.inode)
        }
    }

    /// Soubor, kterému mezi preview a kopií přibyl hardlink, se nekopíruje.
    func testHardlinkCreatedAfterPreviewIsDetected() throws {
        try tree.writeFile("a.txt", contents: "x")
        let plan = try prepare(["a.txt"])
        try tree.makeHardlink("a.txt", to: "b.txt")

        XCTAssertThrowsError(try ExportCopier().apply(plan, destinationRoot: destination)) { error in
            guard case let ExportError.sourceUnavailable(path, reason, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(path, "a.txt")
            XCTAssertEqual(reason, .hardlink)
        }
    }

    /// Soubor, který mezi preview a kopií zmizel, se nekopíruje.
    func testFileRemovedAfterPreviewIsDetected() throws {
        try tree.writeFile("gone.txt", contents: "x")
        let plan = try prepare(["gone.txt"])
        XCTAssertEqual(unlink(tree.path("gone.txt")), 0)

        XCTAssertThrowsError(try ExportCopier().apply(plan, destinationRoot: destination)) { error in
            guard case let ExportError.sourceUnavailable(path, reason, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(path, "gone.txt")
            XCTAssertEqual(reason, .missing)
        }
    }

    /// Mock: karanténu nelze nastavit. Export musí selhat, ne tiše pokračovat.
    func testQuarantineFailureAbortsExport() throws {
        try tree.writeFile("a.txt", contents: "x")
        let plan = try prepare(["a.txt"])
        let mock = MockFailingQuarantineWriter()

        let copier = ExportCopier(configuration: .init(quarantineWriter: mock))
        XCTAssertThrowsError(try copier.apply(plan, destinationRoot: destination)) { error in
            guard case let ExportError.quarantineFailed(path, code) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(path, destination + "/a.txt")
            XCTAssertEqual(code, EPERM)
        }
        XCTAssertEqual(mock.writeCount, 1)
    }

    /// Mock: zápis projde, ale ověření xattr selže (někdo ji hned odstranil).
    func testQuarantineVerificationFailureAbortsExport() throws {
        try tree.writeFile("a.txt", contents: "x")
        let plan = try prepare(["a.txt"])
        let mock = MockVerifyFailingQuarantineWriter()

        let copier = ExportCopier(configuration: .init(quarantineWriter: mock))
        XCTAssertThrowsError(try copier.apply(plan, destinationRoot: destination)) { error in
            guard case ExportError.quarantineFailed = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertEqual(mock.verifyCount, 1)
    }

    func testEmptyPlanOnRejectedOnlyInputThrows() throws {
        try tree.makeFIFO("pipe")
        let plan = try prepare(["pipe"])
        XCTAssertThrowsError(try ExportCopier().apply(plan, destinationRoot: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
    }

    func testSourcePermissionsAreNotRequiredForPreview() throws {
        try tree.writeFile("secret.txt", contents: "x", mode: 0o000)
        defer { chmod(tree.path("secret.txt"), 0o600) }
        let plan = try prepare(["secret.txt"])
        // Vlastník vidí metadata i bez práva čtení; rozhoduje open fáze kopie.
        XCTAssertTrue(plan.isClean)
        XCTAssertThrowsError(try ExportCopier().apply(plan, destinationRoot: destination))
    }

    /// Export nesmí vyrábět privilegovaný soubor: setuid/setgid bity se nepřenášejí.
    func testSpecialModeBitsAreNotPropagated() throws {
        try tree.writeFile("tool.sh", contents: "#!/bin/sh\n", mode: 0o4755)
        let plan = try prepare(["tool.sh"])
        XCTAssertEqual(plan.candidates.first?.snapshot?.mode, 0o4755, "preview hlásí zdrojová práva")

        _ = try ExportCopier().apply(plan, destinationRoot: destination)
        let copied = try XCTUnwrap(fileMode(destination + "/tool.sh"))
        XCTAssertEqual(copied & 0o7777, 0o755, "setuid se na výsledek nepřenáší")
    }

    func testEmptyFileCopied() throws {
        try tree.writeBytes("empty.bin", bytes: [])
        let plan = try prepare(["empty.bin"])
        let result = try ExportCopier().apply(plan, destinationRoot: destination)
        XCTAssertEqual(result.copied.first?.bytesCopied, 0)
        XCTAssertEqual(try XCTUnwrap(fileSize(destination + "/empty.bin")), 0)
        XCTAssertEqual(quarantine(ofFile: destination + "/empty.bin"), Quarantine.defaultValue)
    }

    func testBinaryPayloadCopiedByteForByte() throws {
        let bytes = (0..<200_000).map { UInt8($0 % 251) }
        try tree.writeBytes("blob.bin", bytes: bytes)
        let plan = try prepare(["blob.bin"])
        _ = try ExportCopier().apply(plan, destinationRoot: destination)
        let copied = try Data(contentsOf: URL(fileURLWithPath: destination + "/blob.bin"))
        XCTAssertEqual([UInt8](copied), bytes)
    }
}

// MARK: - Mock rozhraní karantény (ne skutečný zápis xattr)

/// MOCK: zápis karantény vždy selže s `EPERM`. Nedokazuje nic o skutečném xattr.
final class MockFailingQuarantineWriter: QuarantineWriter, @unchecked Sendable {
    private(set) var writeCount = 0
    private(set) var verifyCount = 0

    func writeQuarantine(value: String, fileDescriptor fd: Int32) throws {
        writeCount += 1
        throw QuarantineWriteError(code: EPERM, detail: "mock: writeQuarantine refused")
    }

    func verifyQuarantine(value: String, fileDescriptor fd: Int32) throws {
        verifyCount += 1
    }
}

/// MOCK: zápis projde, ověření hlásí chybějící xattr.
final class MockVerifyFailingQuarantineWriter: QuarantineWriter, @unchecked Sendable {
    private(set) var verifyCount = 0

    func writeQuarantine(value: String, fileDescriptor fd: Int32) throws {}

    func verifyQuarantine(value: String, fileDescriptor fd: Int32) throws {
        verifyCount += 1
        throw QuarantineWriteError(code: QuarantineWriteError.mismatchCode, detail: "mock: verify failed")
    }
}

// MARK: - Pomocné kontroly metadat

func fileMode(_ path: String) -> mode_t? {
    var status = stat()
    guard lstat(path, &status) == 0 else { return nil }
    return status.st_mode
}

func fileSize(_ path: String) -> Int64? {
    var status = stat()
    guard lstat(path, &status) == 0 else { return nil }
    return Int64(status.st_size)
}

func countOfHardlinks(_ path: String) -> UInt64? {
    var status = stat()
    guard lstat(path, &status) == 0 else { return nil }
    return UInt64(status.st_nlink)
}

func quarantine(ofFile path: String) -> String? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    return Quarantine.read(fileDescriptor: fd)
}
