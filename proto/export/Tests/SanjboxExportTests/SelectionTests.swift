import XCTest
@testable import SanjboxExport

/// Fáze 1–2: selekce a preview. Všechny stromy jsou vlastní dočasné adresáře v `/private/tmp`.
final class SelectionTests: XCTestCase {
    private var tree: TempTree!

    override func setUpWithError() throws {
        tree = try TempTree(label: "selection")
    }

    override func tearDown() {
        tree?.remove()
        tree = nil
    }

    private func plan(_ paths: [String]) throws -> ExportPlan {
        try ExportPreparer(rootPath: tree.root).prepare(relativePaths: paths)
    }

    func testRegularFileAcceptedWithSnapshot() throws {
        try tree.writeFile("notes/a.txt", contents: "synteticky kanarek", mode: 0o640)

        let result = try plan(["notes/a.txt"])
        XCTAssertEqual(result.candidates.count, 1)
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertTrue(candidate.accepted)
        XCTAssertEqual(candidate.reason, .accepted)
        XCTAssertEqual(candidate.snapshot?.size, 18)
        XCTAssertEqual(candidate.snapshot?.mode, 0o640)
        XCTAssertEqual(candidate.snapshot?.linkCount, 1)
        XCTAssertEqual(candidate.snapshot?.contentHash.count, 64, "preview nese SHA-256 obsahu")
        XCTAssertTrue(result.isClean)
    }

    func testSymlinkRejected() throws {
        try tree.writeFile("real.txt", contents: "x")
        try tree.makeSymlink("link.txt", target: "real.txt")

        let result = try plan(["link.txt", "real.txt"])
        let link = try XCTUnwrap(result.candidates.first { $0.relativePath == "link.txt" })
        XCTAssertFalse(link.accepted)
        XCTAssertEqual(link.reason, .symlink)
        XCTAssertNil(link.snapshot, "odmítnutý symlink nesmí mít metadata cíle")
        let real = try XCTUnwrap(result.candidates.first { $0.relativePath == "real.txt" })
        XCTAssertTrue(real.accepted)
    }

    func testSymlinkDirectoryComponentRejected() throws {
        try tree.writeFile("inside/secret.txt", contents: "x")
        try tree.makeSymlink("alias", target: "inside")

        let result = try plan(["alias/secret.txt"])
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertFalse(candidate.accepted)
        XCTAssertEqual(candidate.reason, .symlink)
        XCTAssertEqual(candidate.detail, "'alias' is a symlink")
    }

    func testHardlinkRejected() throws {
        try tree.writeFile("original.txt", contents: "x")
        try tree.makeHardlink("original.txt", to: "second.txt")

        let result = try plan(["original.txt", "second.txt"])
        XCTAssertEqual(result.candidates.count, 2)
        for candidate in result.candidates {
            XCTAssertFalse(candidate.accepted, "\(candidate.relativePath) nesmí projít: nlink=2")
            XCTAssertEqual(candidate.reason, .hardlink)
            XCTAssertEqual(candidate.detail, "nlink=2 at \(candidate.relativePath.split(separator: "/").last!)")
        }
    }

    func testPathsOutsideRootRejectedWithoutTouchingThem() throws {
        try tree.writeFile("ok.txt", contents: "x")

        let result = try plan(["../outside.txt", "/etc/passwd", "a/../../b", "./ok.txt"])
        XCTAssertEqual(result.candidates.count, 4)
        for candidate in result.rejected {
            XCTAssertEqual(candidate.reason, .outsideRoot, "cesta \(candidate.relativePath)")
            XCTAssertNil(candidate.snapshot)
        }
        XCTAssertEqual(result.accepted.map(\.relativePath), ["ok.txt"])
    }

    func testEmptyPathRejected() throws {
        let result = try plan([""])
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertFalse(candidate.accepted)
        XCTAssertEqual(candidate.reason, .invalidPath)
    }

    func testMissingPathRejected() throws {
        let result = try plan(["nope.txt"])
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.reason, .missing)
        XCTAssertFalse(candidate.accepted)
    }

    func testDirectoryTargetRejected() throws {
        try tree.makeDirectory("subdir")
        let result = try plan(["subdir"])
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.reason, .notRegularFile)
        XCTAssertEqual(candidate.detail, "'subdir' is a directory")
    }

    func testFIFORejected() throws {
        try tree.makeFIFO("pipe.fifo")
        let result = try plan(["pipe.fifo"])
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.reason, .specialFile)
        XCTAssertEqual(candidate.detail, "'pipe.fifo' is a fifo")
    }

    func testOrderIsStableAndIndependentOfArgumentOrder() throws {
        for name in ["b.txt", "a.txt", "c/d.txt"] {
            try tree.writeFile(name, contents: name)
        }
        let first = try plan(["b.txt", "a.txt", "c/d.txt"])
        let second = try plan(["c/d.txt", "b.txt", "a.txt"])
        XCTAssertEqual(first.candidates.map(\.relativePath), ["a.txt", "b.txt", "c/d.txt"])
        XCTAssertEqual(first, second)
        XCTAssertEqual(try first.jsonData(), try second.jsonData())
    }

    func testDuplicateArgumentsCollapse() throws {
        try tree.writeFile("a.txt", contents: "x")
        let result = try plan(["a.txt", "./a.txt", "a.txt"])
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates.first?.relativePath, "a.txt")
    }

    func testPreviewWritesNothing() throws {
        try tree.writeFile("a.txt", contents: "kanarek")
        try tree.writeFile("sub/b.txt", contents: "druhy")
        try tree.makeSymlink("link", target: "a.txt")
        try tree.makeHardlink("a.txt", to: "hard.txt")

        let structureBefore = tree.structure()
        let contentsBefore = tree.contents()
        _ = try plan(["a.txt", "sub/b.txt", "link", "hard.txt", "missing.txt"])
        _ = try plan(["a.txt"])
        XCTAssertEqual(tree.structure(), structureBefore, "preview nesmí změnit strom")
        XCTAssertEqual(tree.contents(), contentsBefore, "preview nesmí změnit obsah")
    }

    /// Case varianty téhož souboru jsou na case-insensitive APFS stejná identita.
    /// Plán musí být deterministický i při opačném pořadí argumentů.
    func testCaseVariantPathsDeduplicateByIdentity() throws {
        try tree.writeFile("CI.txt", contents: "kanarek")
        var first = stat()
        var second = stat()
        guard lstat(tree.path("CI.txt"), &first) == 0,
              lstat(tree.path("ci.txt"), &second) == 0,
              first.st_dev == second.st_dev,
              first.st_ino == second.st_ino else {
            throw XCTSkip("filesystem nerozlišuje case; test identity dedupu nelze sestrojit")
        }

        let planA = try plan(["CI.txt", "ci.txt"])
        let planB = try plan(["ci.txt", "CI.txt"])
        XCTAssertEqual(planA.candidates.count, 1)
        XCTAssertEqual(planA.candidates.first?.relativePath, "CI.txt", "UTF-8 pořadí rozhoduje")
        XCTAssertTrue(planA.isClean)
        XCTAssertEqual(planA, planB)
        XCTAssertEqual(try planA.jsonData(), try planB.jsonData())
    }

    /// NFC a NFD zápis téhož jména je na APFS stejná identita; dedup je podle inode.
    func testUnicodeNormalizedPathsDeduplicateByIdentity() throws {
        let nfc = "kav\u{e1}.txt"
        let nfd = "kava\u{301}.txt"
        try tree.writeFile(nfc, contents: "kanarek")
        var first = stat()
        var second = stat()
        guard lstat(tree.path(nfc), &first) == 0,
              lstat(tree.path(nfd), &second) == 0,
              first.st_dev == second.st_dev,
              first.st_ino == second.st_ino else {
            throw XCTSkip("filesystem nerozlišuje Unicode normalizaci; test identity dedupu nelze sestrojit")
        }

        let planA = try plan([nfd, nfc])
        let planB = try plan([nfc, nfd])
        XCTAssertEqual(planA.candidates.count, 1)
        XCTAssertTrue(planA.isClean)
        XCTAssertEqual(planA, planB)
        XCTAssertEqual(try planA.jsonData(), try planB.jsonData())
    }

    /// Kolize cílových jmen různých identit se odmítne v plánu.
    func testTargetCollisionRejectsBothCandidates() {
        let first = FileSnapshot(
            device: 1, inode: 1, size: 1, mode: 0o644, linkCount: 1, contentHash: "aa"
        )
        let second = FileSnapshot(
            device: 1, inode: 2, size: 1, mode: 0o644, linkCount: 1, contentHash: "bb"
        )
        let candidates = [
            Candidate(relativePath: "A.txt", accepted: true, reason: .accepted, snapshot: first),
            Candidate(relativePath: "a.txt", accepted: true, reason: .accepted, snapshot: second),
        ]
        let rejected = TargetNames.rejectCollisions(candidates)
        XCTAssertEqual(rejected.map(\.reason), [.destinationCollision, .destinationCollision])
        XCTAssertFalse(rejected.contains { $0.accepted })
    }

    /// Meziadresář klasifikovaný `fstatat` a otevřený `openat` musí být stejný inode.
    func testOpenedDirectoryIdentityGuardFailsWhenOpenatReturnsAnotherDirectory() throws {
        try tree.makeDirectory("a")
        try tree.makeDirectory("b")
        let rootFD = open(tree.root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(rootFD, 0)
        defer { close(rootFD) }

        let result = SafePath.openDirectoryChain(
            rootFD: rootFD,
            components: ["a", "file.txt"],
            openDirectory: { _, _ in
                open(self.tree.path("b"), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            }
        )
        switch result {
        case .success:
            XCTFail("guard nesmí přijmout jiný inode, než klasifikoval fstatat")
        case let .failure(rejection):
            XCTAssertEqual(rejection.reason, .ioError)
            XCTAssertTrue(rejection.detail?.contains("changed between fstatat and openat") == true)
        }
    }

    func testInvalidRootFails() throws {
        XCTAssertThrowsError(try ExportPreparer(rootPath: tree.path("does-not-exist")).prepare(relativePaths: ["a"])) { error in
            guard case let ExportError.invalidRoot(_, code) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(code, ENOENT)
        }
    }
}
