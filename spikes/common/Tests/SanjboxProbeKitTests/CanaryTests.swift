import Darwin
import Foundation
import Testing
@testable import SanjboxProbeKit

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sanjbox-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func tokenHasPrefixLabelAndRandomSuffix() throws {
    let first = try Canary.make(label: "home")
    let second = try Canary.make(label: "home")
    #expect(first.token.hasPrefix("SANJBOX-CANARY-home-"))
    #expect(first.token.count == "SANJBOX-CANARY-home-".count + 32)
    #expect(first.token != second.token)
}

@Test(arguments: ["", "-home", "Home", "home/..", "a b", String(repeating: "a", count: 33)])
func invalidLabelsAreRejected(label: String) {
    #expect(throws: CanaryError.invalidLabel(label)) { try Canary.make(label: label) }
}

@Test func scannerFindsRawAndHexInAnyCase() throws {
    let canary = try Canary.make(label: "work-root")
    let hex = canary.token.utf8.map { String(format: "%02X", $0) }.joined()
    let scanner = CanaryScanner(canaries: [canary])

    #expect(scanner.findings(in: Data("GET /?q=\(canary.token) HTTP/1.1".utf8)).map(\.encoding) == ["raw"])
    #expect(scanner.findings(in: Data("\(hex).exfil.example.".utf8)).map(\.encoding) == ["hex"])
    #expect(scanner.findings(in: Data("SANJBOX-CANARY-work-root-but-not-the-token".utf8)).isEmpty)
}

@Test func writtenCanaryRoundTripsThroughRegistryAndIsRemoved() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = directory.appendingPathComponent("registry.jsonl")

    let canary = try Canary.make(label: "home", now: Date(timeIntervalSince1970: 1_800_000_000.125))
        .written(to: directory)
    try JSONLines.append(canary, to: registry)
    let loaded = try JSONLines.read(Canary.self, from: registry)

    #expect(loaded == [canary])
    #expect(FileManager.default.contents(atPath: try #require(canary.path)) == Data(canary.token.utf8))
    #expect(loaded[0].removeFile() == .removed)
    #expect(loaded[0].removeFile() == .alreadyAbsent)
}

@Test func creationRefusesExistingFileAndSymlink() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("elsewhere.txt")
    FileManager.default.createFile(atPath: target.path, contents: Data("keep".utf8))

    _ = try Canary.make(label: "dup").written(to: directory)
    #expect(throws: CanaryError.self) { try Canary.make(label: "dup").written(to: directory) }

    try FileManager.default.createSymbolicLink(
        at: directory.appendingPathComponent("sanjbox-canary-link.txt"), withDestinationURL: target
    )
    #expect(throws: CanaryError.self) { try Canary.make(label: "link").written(to: directory) }
    #expect(FileManager.default.contents(atPath: target.path) == Data("keep".utf8))
}

@Test func cleanupRefusesChangedContentAndSymlinks() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let changed = try Canary.make(label: "changed").written(to: directory)
    try Data("someone else's data".utf8).write(to: URL(fileURLWithPath: try #require(changed.path)))
    #expect(changed.removeFile() == .refused("content changed"))

    let swapped = try Canary.make(label: "swapped").written(to: directory)
    let path = try #require(swapped.path)
    let target = directory.appendingPathComponent("victim.txt")
    FileManager.default.createFile(atPath: target.path, contents: Data(swapped.token.utf8))
    unlink(path)
    try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target.path)
    #expect(swapped.removeFile() == .refused("not a regular file"))
    #expect(FileManager.default.fileExists(atPath: target.path))
}

@Test func streamScannerFindsTokensSplitAcrossChunks() throws {
    let canary = try Canary.make(label: "stream")
    let hex = Data(canary.token.utf8.map { String(format: "%02x", $0) }.joined().utf8)
    var stream = CanaryStreamScanner(scanner: CanaryScanner(canaries: [canary]))

    // One byte per chunk: no chunk ever holds a whole token.
    for byte in Data("x\(canary.token)y".utf8) + hex { stream.feed(Data([byte])) }

    #expect(stream.findings == [
        CanaryScanner.Finding(token: canary.token, encoding: "raw"),
        CanaryScanner.Finding(token: canary.token, encoding: "hex"),
    ])
}

@Test func anyCanaryMatchingReportsUnregisteredTokens() throws {
    let unregistered = try Canary.make(label: "late")
    let data = Data(unregistered.token.utf8)

    #expect(CanaryScanner(canaries: []).findings(in: data).isEmpty)
    #expect(CanaryScanner(canaries: [], matchAnyCanary: true).findings(in: data) == [
        CanaryScanner.Finding(token: Canary.tokenPrefix, encoding: "raw"),
    ])
}
