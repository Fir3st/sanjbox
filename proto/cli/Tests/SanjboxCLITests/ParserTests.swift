import XCTest
import SanjboxContracts
@testable import SanjboxCLI

final class ParserTests: XCTestCase {
    func testFiveCommandsUseH1Kinds() throws {
        let vectors: [([String], HelperMessageKind)] = [
            (["shell", "a1b2"], .shell),
            (["run", "a1b2", "--executable-root", "tools", "--", "bin/probe"], .run),
            (["pause", "a1b2"], .pauseZone),
            (["snapshot", "a1b2", "new", "--restore-unit", "full-state"], .snapshot),
            (["rollback", "a1b2", "baseline", "--restore-unit", "full-state"], .rollback),
        ]
        for (argv, expected) in vectors {
            guard case .request(let request) = try CLICommand.parse(["--mock"] + argv) else { return XCTFail() }
            XCTAssertEqual(request.kind, expected)
            XCTAssertEqual(try HelperMessage.decode(request.encoded()), request)
        }
    }
    func testLiteralArgumentsRoundTripIncludingOptionsAndMetacharacters() throws {
        let literal = ["", "two words", "$(touch NEVER)", "`echo no`", "; false", "*", "a\nb", "é🐈", "--help", "--mock", "--", "-x"]
        let command = try CLICommand.parse(["--mock", "run", "a1b2", "--working-root", "home", "--working-directory", "a b", "--executable-root", "tools", "--", "bin/tool"] + literal)
        guard case .request(.run(let body)) = command else { return XCTFail() }
        XCTAssertEqual(body.arguments, literal)
        XCTAssertEqual(body.executablePath, "bin/tool")
        XCTAssertEqual(body.workingDirectory, "a b")
        XCTAssertEqual(body.workingRootID, "home")
    }
    func testHelpRequiresExactInvocation() throws {
        XCTAssertEqual(try CLICommand.parse(["--help"]), .help)
        XCTAssertThrowsError(try CLICommand.parse(["--help", "extra"]))
    }
    func testMalformedSyntaxRejected() {
        let vectors = [[], ["shell", "a1b2"], ["--mock"], ["--mock", "unknown", "a1b2"],
            ["--mock", "pause", "a1b2", "extra"], ["--mock", "shell", "a1b2", "--"],
            ["--mock", "shell", "a1b2", "--working-root"],
            ["--mock", "shell", "a1b2", "--working-root", "home", "--working-root", "project"],
            ["--mock", "shell", "a1b2", "--uid", "0"],
            ["--mock", "run", "a1b2", "--", "bin/tool"],
            ["--mock", "run", "a1b2", "--executable-root", "tools", "bin/tool"],
            ["--mock", "run", "a1b2", "--executable-root", "tools", "--"],
            ["--mock", "snapshot", "a1b2", "s"],
            ["--mock", "rollback", "a1b2", "s", "--restore-unit", "full-state", "--directory", "project"]]
        for argv in vectors { XCTAssertThrowsError(try CLICommand.parse(argv), "\(argv)") }
    }
    func testInvalidIdentifiersAndPathsRejected() {
        for zone in ["A1B2", "abc", "abcde", "a/b2", "é123"] {
            XCTAssertThrowsError(try CLICommand.parse(["--mock", "pause", zone]))
        }
        for path in ["/tmp", "../x", "a/../b", "a//b", "a\\b", "a\0b"] {
            XCTAssertThrowsError(try CLICommand.parse(["--mock", "shell", "a1b2", "--working-directory", path]))
            XCTAssertThrowsError(try CLICommand.parse(["--mock", "run", "a1b2", "--executable-root", "tools", "--", path]))
        }
        XCTAssertThrowsError(try CLICommand.parse(["--mock", "run", "a1b2", "--executable-root", "tools", "--", "."]))
        XCTAssertThrowsError(try CLICommand.parse(["--mock", "snapshot", "a1b2", "bad/id", "--restore-unit", "full-state"]))
    }
    func testArgvLimitsComeFromH1() throws {
        let prefix = ["--mock", "run", "a1b2", "--executable-root", "tools", "--", "bin/probe"]
        XCTAssertNoThrow(try CLICommand.parse(prefix + Array(repeating: "", count: 64)))
        XCTAssertThrowsError(try CLICommand.parse(prefix + Array(repeating: "", count: 65)))
        XCTAssertNoThrow(try CLICommand.parse(prefix + Array(repeating: String(repeating: "x", count: 1024), count: 32)))
        XCTAssertThrowsError(try CLICommand.parse(prefix + [String(repeating: "é", count: 513)]))
        XCTAssertThrowsError(try CLICommand.parse(prefix + Array(repeating: String(repeating: "x", count: 1024), count: 33)))
        XCTAssertThrowsError(try CLICommand.parse(prefix + ["a\0b"]))
    }
}
