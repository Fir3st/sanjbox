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

    func testInvalidRootFails() throws {
        XCTAssertThrowsError(try ExportPreparer(rootPath: tree.path("does-not-exist")).prepare(relativePaths: ["a"])) { error in
            guard case let ExportError.invalidRoot(_, code) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(code, ENOENT)
        }
    }
}
