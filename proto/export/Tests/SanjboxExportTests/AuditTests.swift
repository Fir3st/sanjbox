import XCTest
@testable import SanjboxExport

/// Audit: deterministický JSON se stabilním pořadím záznamů.
final class AuditTests: XCTestCase {
    private var tree: TempTree!

    override func setUpWithError() throws {
        tree = try TempTree(label: "audit")
        try tree.writeFile("b.txt", contents: "bbb")
        try tree.writeFile("a.txt", contents: "aa")
        try tree.writeFile("sub/c.txt", contents: "c")
        try tree.makeSymlink("link.txt", target: "a.txt")
    }

    override func tearDown() {
        tree?.remove()
        tree = nil
    }

    func testPreviewAuditIsByteIdenticalAcrossRuns() throws {
        let first = RecordingAuditSink()
        let second = RecordingAuditSink()
        let paths = ["b.txt", "a.txt", "sub/c.txt", "link.txt", "nope.txt"]

        _ = try ExportPreparer(rootPath: tree.root).prepare(relativePaths: paths, audit: first)
        _ = try ExportPreparer(rootPath: tree.root).prepare(relativePaths: paths.reversed(), audit: second)

        XCTAssertEqual(try first.document(), try second.document())
        XCTAssertEqual(try first.documentString(), try second.documentString())
    }

    func testAuditRecordsFollowPlanOrderAndSequence() throws {
        let sink = RecordingAuditSink()
        let plan = try ExportPreparer(rootPath: tree.root)
            .prepare(relativePaths: ["sub/c.txt", "link.txt", "a.txt", "b.txt"], audit: sink)

        XCTAssertEqual(sink.records.map(\.relativePath), ["a.txt", "b.txt", "link.txt", "sub/c.txt"])
        XCTAssertEqual(sink.records.map(\.sequence), [0, 1, 2, 3])
        XCTAssertEqual(sink.records.map(\.phase), Array(repeating: .preview, count: 4))
        XCTAssertEqual(sink.records.map(\.decision), [.accept, .accept, .reject, .accept])
        XCTAssertEqual(sink.records.map(\.reason), [.accepted, .accepted, .symlink, .accepted])
        XCTAssertEqual(sink.records, plan.candidates.enumerated().map { index, candidate in
            AuditRecord(phase: .preview, sequence: index, candidate: candidate)
        })
    }

    func testAuditDocumentHasStableSchemaAndNoTimestamps() throws {
        let sink = RecordingAuditSink()
        _ = try ExportPreparer(rootPath: tree.root).prepare(relativePaths: ["a.txt"], audit: sink)
        let text = try sink.documentString()

        XCTAssertTrue(text.contains("\"scheme\""))
        XCTAssertTrue(text.contains("\"records\""))
        XCTAssertFalse(text.contains("timestamp"), "provizorní formát nenese čas; ten doplní H1")
        XCTAssertFalse(text.contains("\"root\""), "audit neobsahuje absolutní cesty; ty nese plán")
        XCTAssertTrue(text.hasSuffix("}\n"))

        // Dokument je validní JSON se všemi očekávanými klíči.
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        XCTAssertEqual(object?["scheme"] as? String, ExportAudit.scheme)
        let records = try XCTUnwrap(object?["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["phase"] as? String, "preview")
        XCTAssertEqual(records[0]["decision"] as? String, "accept")
        XCTAssertEqual(records[0]["relativePath"] as? String, "a.txt")
        XCTAssertEqual(records[0]["size"] as? Int, 2)
        XCTAssertEqual(records[0]["linkCount"] as? Int, 1)
        XCTAssertNotNil(records[0]["inode"])
        XCTAssertNil(records[0]["destination"])
        XCTAssertNil(records[0]["bytesCopied"])
    }

    func testCopyAuditAppendsAfterPreviewInDeterministicOrder() throws {
        let destination = tree.path("out-alpha")
        let first = RecordingAuditSink()
        let second = RecordingAuditSink()
        let paths = ["b.txt", "sub/c.txt", "a.txt"]

        let planA = try ExportPreparer(rootPath: tree.root).prepare(relativePaths: paths, audit: first)
        _ = try ExportCopier().apply(planA, destinationRoot: destination, audit: first)

        let destinationB = tree.path("out-beta")
        let planB = try ExportPreparer(rootPath: tree.root).prepare(relativePaths: paths, audit: second)
        _ = try ExportCopier().apply(planB, destinationRoot: destinationB, audit: second)

        let recordsA = first.records
        XCTAssertEqual(recordsA.map(\.phase), [.preview, .preview, .preview, .copy, .copy, .copy])
        XCTAssertEqual(recordsA.map(\.relativePath), ["a.txt", "b.txt", "sub/c.txt", "a.txt", "b.txt", "sub/c.txt"])
        XCTAssertEqual(recordsA.filter { $0.phase == .copy }.map(\.bytesCopied), [2, 3, 1])
        XCTAssertEqual(recordsA.filter { $0.phase == .copy }.map(\.destination).count, 3)

        // Cílové cesty se liší, takže se dokumenty liší jen v nich.
        let textA = try first.documentString().replacingOccurrences(of: destination, with: "<DEST>")
        let textB = try second.documentString().replacingOccurrences(of: destinationB, with: "<DEST>")
        XCTAssertEqual(textA, textB)
    }

    func testRejectedRecordCarriesReasonAndNoSnapshot() throws {
        let sink = RecordingAuditSink()
        _ = try ExportPreparer(rootPath: tree.root).prepare(relativePaths: ["link.txt", "../escape"], audit: sink)
        let link = try XCTUnwrap(sink.records.first { $0.relativePath == "link.txt" })
        XCTAssertEqual(link.decision, .reject)
        XCTAssertEqual(link.reason, .symlink)
        XCTAssertNil(link.size)
        XCTAssertNil(link.inode)

        let escape = try XCTUnwrap(sink.records.first { $0.relativePath == "../escape" })
        XCTAssertEqual(escape.reason, .outsideRoot)
    }

    func testDocumentSortsRecordsByPhaseThenSequenceThenPath() throws {
        let snapshot = FileSnapshot(device: 1, inode: 2, size: 3, mode: 0o644, linkCount: 1)
        let records = [
            AuditRecord(phase: .copy, sequence: 0, relativePath: "z.txt", decision: .accept, reason: .accepted, snapshot: snapshot),
            AuditRecord(phase: .preview, sequence: 1, relativePath: "b.txt", decision: .accept, reason: .accepted, snapshot: snapshot),
            AuditRecord(phase: .preview, sequence: 0, relativePath: "a.txt", decision: .accept, reason: .accepted, snapshot: snapshot),
        ]
        let document = try ExportAudit.document(records: records)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: document) as? [String: Any])
        let ordered = try XCTUnwrap(object["records"] as? [[String: Any]])
        XCTAssertEqual(ordered.compactMap { $0["relativePath"] as? String }, ["a.txt", "b.txt", "z.txt"])

        let reversed = try ExportAudit.document(records: records.reversed())
        XCTAssertEqual(document, reversed, "pořadí vstupu nesmí ovlivnit dokument")
    }
}
