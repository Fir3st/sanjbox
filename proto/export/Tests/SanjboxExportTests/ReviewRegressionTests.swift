import Darwin
import XCTest
@testable import SanjboxExport
import SanjboxExportCLI

final class ReviewRegressionTests: XCTestCase {
    func testPinnedParentIsNotRedirectedByAliasRetargeting() throws {
        let source = try TempTree(label: "pinned-source")
        let target = try TempTree(label: "pinned-target")
        try target.makeDirectory("parent")
        try target.makeSymlink("alias", target: target.path("parent"))
        let parent = try DestinationParent(path: target.path("alias/out"))
        XCTAssertEqual(unlink(target.path("alias")), 0)
        try target.makeSymlink("alias", target: source.root)
        let rootFD = try SafePath.openRoot(source.root).get()
        defer { close(rootFD) }
        try parent.requireOutside(rootFD: rootFD, rootPath: source.root)
        let output = try DestinationTree(parent: parent)
        XCTAssertGreaterThanOrEqual(output.rootFD, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path("parent/out")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path("out")))
    }

    func testPinnedParentInsideSourceIsRejectedEvenAfterAliasMovesOutside() throws {
        let source = try TempTree(label: "contained-source")
        let target = try TempTree(label: "contained-target")
        try target.makeSymlink("alias", target: source.root)
        let parent = try DestinationParent(path: target.path("alias/out"))
        XCTAssertEqual(unlink(target.path("alias")), 0)
        try target.makeSymlink("alias", target: target.root)
        let rootFD = try SafePath.openRoot(source.root).get()
        defer { close(rootFD) }
        XCTAssertThrowsError(try parent.requireOutside(rootFD: rootFD, rootPath: source.root)) {
            guard case ExportError.destinationInsideRoot = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path("out")))
    }

    func testSourceRootReplacementCannotReusePreviouslyApprovedFileInode() throws {
        let source = try TempTree(label: "root-replace")
        let target = try TempTree(label: "root-replace-target")
        try source.writeFile("root/a.txt", contents: "canary")
        let plan = try ExportPreparer(rootPath: source.path("root")).prepare(relativePaths: ["a.txt"])
        XCTAssertEqual(rename(source.path("root"), source.path("saved")), 0)
        try source.makeDirectory("root")
        XCTAssertEqual(rename(source.path("saved/a.txt"), source.path("root/a.txt")), 0)
        XCTAssertThrowsError(try ExportCopier().apply(plan, destinationRoot: target.path("out"))) {
            guard case ExportError.invalidRoot(_, ESTALE) = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try FileAuditSink(path: source.path("saved/audit"), excluding: plan)) {
            guard case ExportError.invalidRoot(_, ESTALE) = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path("saved/audit")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path("out")))
    }

    func testUntrackedExistingDestinationDirectoryIsRefused() throws {
        let source = try TempTree(label: "injected-dir")
        let target = try TempTree(label: "injected-dir-target")
        try source.writeFile("a.txt", contents: "a")
        try source.writeFile("sub/b.txt", contents: "b")
        let plan = try ExportPreparer(rootPath: source.root).prepare(relativePaths: ["a.txt", "sub/b.txt"])
        let sink = MutationAuditSink {
            try target.makeDirectory("out/sub")
            try target.writeFile("out/sub/marker", contents: "preserve")
        }
        XCTAssertThrowsError(try ExportCopier().apply(plan, destinationRoot: target.path("out"), audit: sink))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path("out/sub/b.txt")))
        XCTAssertEqual(try String(contentsOfFile: target.path("out/sub/marker"), encoding: .utf8), "preserve")
    }

    func testReplacedTrackedDestinationDirectoryIsRefused() throws {
        let source = try TempTree(label: "replaced-dir")
        let target = try TempTree(label: "replaced-dir-target")
        try source.writeFile("sub/a.txt", contents: "a")
        try source.writeFile("sub/b.txt", contents: "b")
        let plan = try ExportPreparer(rootPath: source.root).prepare(relativePaths: ["sub/a.txt", "sub/b.txt"])
        let sink = MutationAuditSink {
            XCTAssertEqual(rename(target.path("out/sub"), target.path("out/saved")), 0)
            try target.makeDirectory("out/sub")
        }
        XCTAssertThrowsError(try ExportCopier().apply(plan, destinationRoot: target.path("out"), audit: sink))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path("out/sub/b.txt")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path("out/saved/b.txt")))
        XCTAssertEqual(quarantine(ofFile: target.path("out/saved/a.txt")), Quarantine.defaultValue)
    }

    func testReplacedDestinationRootIsRefused() throws {
        let source = try TempTree(label: "replaced-out")
        let target = try TempTree(label: "replaced-out-target")
        try source.writeFile("a.txt", contents: "a")
        try source.writeFile("b.txt", contents: "b")
        let plan = try ExportPreparer(rootPath: source.root).prepare(relativePaths: ["a.txt", "b.txt"])
        let sink = MutationAuditSink {
            XCTAssertEqual(rename(target.path("out"), target.path("saved")), 0)
            try target.makeDirectory("out")
        }
        XCTAssertThrowsError(try ExportCopier().apply(plan, destinationRoot: target.path("out"), audit: sink))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path("out/b.txt")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path("saved/b.txt")))
    }

    func testFileDirectoryPrefixCollisionIsRejectedBeforeCopy() throws {
        let candidates = candidates(["Dir", "dir/file.txt", "safe.txt"])
        let rejected = TargetNames.rejectCollisions(candidates)
        XCTAssertEqual(rejected.filter { !$0.accepted }.map(\.relativePath), ["Dir", "dir/file.txt"])
        let target = try TempTree(label: "prefix-collision")
        let plan = ExportPlan(root: "/unused", candidates: candidates, preparedForCopy: true)
        XCTAssertThrowsError(try ExportCopier().apply(plan, destinationRoot: target.path("out"))) {
            guard case ExportError.destinationNameCollision = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path("out")))
    }

    func testDirectoryAliasCollisionsAreRejectedButSharedDirectoriesAreAllowed() {
        for paths in [["Dir/a.txt", "dir/b.txt"], ["café/a.txt", "cafe\u{301}/b.txt"]] {
            XCTAssertTrue(TargetNames.rejectCollisions(candidates(paths)).allSatisfy { !$0.accepted })
        }
        XCTAssertTrue(TargetNames.rejectCollisions(candidates(["sub/a.txt", "sub/b.txt"])).allSatisfy(\.accepted))
    }

    func testPreviewHashReadsOnlyApprovedSizeAndOneByteWhenSourceGrows() throws {
        let source = try TempTree(label: "bounded-hash")
        try source.writeFile("growing", contents: "a")
        let fd = open(source.path("growing"), O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        // Synthetic sparse growth after size=1 was captured, before hash reads.
        XCTAssertEqual(ftruncate(fd, 1024 * 1024 * 1024), 0)
        XCTAssertThrowsError(try ContentHash.sha256(fileDescriptor: fd, maximumBytes: 1).get())
        XCTAssertEqual(lseek(fd, 0, SEEK_CUR), 2)
    }

    func testNULInRootDestinationAndAuditIsRejectedWithoutTruncation() throws {
        let source = try TempTree(label: "nul-paths")
        let target = try TempTree(label: "nul-target")
        try source.writeFile("a.txt", contents: "canary")
        XCTAssertThrowsError(try ExportPreparer(rootPath: source.root + "\0ignored").prepare(relativePaths: ["a.txt"]))
        let plan = try ExportPreparer(rootPath: source.root).prepare(relativePaths: ["a.txt"])
        XCTAssertThrowsError(try ExportCopier().apply(plan, destinationRoot: target.path("out") + "\0ignored"))
        XCTAssertThrowsError(try FileAuditSink(path: target.path("audit") + "\0ignored"))
        XCTAssertTrue(target.structure().isEmpty)
    }

    func testAuditInsideSourceViaAliasIsRejectedByDescriptorPolicy() throws {
        let source = try TempTree(label: "source-audit")
        let target = try TempTree(label: "audit-alias")
        try target.makeSymlink("alias", target: source.root)
        XCTAssertThrowsError(try FileAuditSink(path: target.path("alias/audit.jsonl"), excludingRoot: source.root)) {
            guard case ExportError.destinationInsideRoot = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(source.structure().isEmpty)
    }

    func testCLIRefusesAuditInsideSourceAndInvalidRootCreatesNoAudit() throws {
        let source = try TempTree(label: "cli-source-audit")
        let target = try TempTree(label: "cli-audit-target")
        try source.writeFile("a.txt", contents: "canary")
        let cli = ExportCLI()
        let inside = cli.run(arguments: ["--root", source.root, "--file", "a.txt", "--apply",
                                        "--dest", target.path("out"), "--audit", source.path("audit")], stdout: { _ in }, stderr: { _ in })
        XCTAssertEqual(inside, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path("audit")))
        let invalid = cli.run(arguments: ["--root", source.path("absent"), "--file", "a.txt", "--apply",
                                         "--dest", target.path("out"), "--audit", target.path("audit")], stdout: { _ in }, stderr: { _ in })
        XCTAssertEqual(invalid, 1)
        XCTAssertTrue(target.structure().isEmpty)
    }

    func testRejectedAbsoluteInputIsRedactedFromGeneratedAudit() throws {
        let source = try TempTree(label: "redacted-audit")
        let sink = RecordingAuditSink()
        _ = try ExportPreparer(rootPath: source.root).prepare(relativePaths: [source.path("canary")], audit: sink)
        XCTAssertEqual(sink.records.first?.relativePath, "<absolute-path>")
        XCTAssertEqual(sink.records.first?.reason, .outsideRoot)
        XCTAssertFalse(try sink.documentString().contains(source.root))
    }

    func testAuditAppendFailureRemovesCurrentFileAndKeepsPriorAuditedFile() throws {
        let source = try TempTree(label: "failed-copy-audit")
        let target = try TempTree(label: "failed-copy-audit-target")
        try source.writeFile("a.txt", contents: "first canary")
        try source.writeFile("b.txt", contents: "second canary")
        let plan = try ExportPreparer(rootPath: source.root).prepare(relativePaths: ["a.txt", "b.txt"])
        let sink = FailingCopyAuditSink()
        XCTAssertThrowsError(try ExportCopier().apply(plan, destinationRoot: target.path("out"), audit: sink)) {
            guard case ExportError.io(_, "injected-audit-failure", ENOSPC) = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(sink.records.map(\.relativePath), ["a.txt"])
        XCTAssertEqual(try String(contentsOfFile: target.path("out/a.txt"), encoding: .utf8), "first canary")
        XCTAssertEqual(quarantine(ofFile: target.path("out/a.txt")), Quarantine.defaultValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path("out/b.txt")))
    }

    private func candidates(_ paths: [String]) -> [Candidate] {
        paths.enumerated().map { index, path in
            Candidate(relativePath: path, accepted: true, reason: .accepted,
                      snapshot: FileSnapshot(device: 1, inode: UInt64(index + 1), size: 1, mode: 0o644,
                                             linkCount: 1, contentHash: "synthetic"))
        }
    }
}

/// Injects a real filesystem mutation after the first completed copy audit.
private final class MutationAuditSink: AuditSink, @unchecked Sendable {
    private var called = false
    private let mutate: () throws -> Void
    init(_ mutate: @escaping () throws -> Void) { self.mutate = mutate }
    func append(_ record: AuditRecord) throws {
        if record.phase == .copy && !called {
            called = true
            try mutate()
        }
    }
}

private final class FailingCopyAuditSink: AuditSink, @unchecked Sendable {
    private(set) var records: [AuditRecord] = []
    func append(_ record: AuditRecord) throws {
        guard records.isEmpty else {
            throw ExportError.io(path: "<synthetic-audit>", operation: "injected-audit-failure", errno: ENOSPC)
        }
        records.append(record)
    }
}
