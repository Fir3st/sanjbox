import Foundation
import Testing

/// Included in the ordinary H1 Swift test target so CI cannot omit the independent B3 oracle.
/// Source files and checked-in synthetic examples are the only inputs; the harness never opens
/// a declared path, runs a probe or imports B3's system-facing command/recovery modules.
@Suite("Current B3 source parity")
struct B3ParityTests {
    @Test func completeReportsMatchCurrentB3() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = package.appendingPathComponent("tools/test_manifest_parity.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-B", script.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let diagnostic = String(decoding: data, as: UTF8.self)
        #expect(process.terminationStatus == 0, "B3 parity failed: \(diagnostic)")
        #expect(diagnostic.contains("PASS: 140 synthetic cases; all 48 B3 finding codes and complete reports match."))
    }
}
