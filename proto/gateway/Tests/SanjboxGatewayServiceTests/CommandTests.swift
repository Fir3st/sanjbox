import Foundation
import SanjboxGatewayService
import XCTest

final class CommandTests: XCTestCase {
    private func temporaryPolicy(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("h4-policy-\(UUID().uuidString).json")
        try Data(contents.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testParseRequiresPolicyAndValidListener() throws {
        XCTAssertEqual(try GatewayCommand.parse(["--help"]), .help)
        XCTAssertEqual(try GatewayCommand.parse(["--policy", "/tmp/p.json"]),
                       .compose(policyPath: "/tmp/p.json"))
        XCTAssertEqual(try GatewayCommand.parse(["--policy", "/tmp/p.json", "--listen", "127.0.0.1:18765"]),
                       .serve(policyPath: "/tmp/p.json",
                              address: LoopbackListener.Address(text: "127.0.0.1:18765")!))

        for arguments in [[], ["--listen", "127.0.0.1:18765"], ["--policy"]] {
            XCTAssertThrowsError(try GatewayCommand.parse(arguments), "\(arguments)") { error in
                guard case .usage = error as? CommandFailure else {
                    return XCTFail("expected usage failure for \(arguments)")
                }
            }
        }
        for arguments in [["--policy", "p", "--listen", "0.0.0.0:80"],
                          ["--policy", "p", "--listen", "127.0.0.1:0"],
                          ["--policy", "p", "--listen", "example.test:80"],
                          ["--policy", "p", "--mode", "serve"]] {
            XCTAssertThrowsError(try GatewayCommand.parse(arguments), "\(arguments)")
        }
    }

    func testComposeWithoutListenOpensNoSocket() async throws {
        let url = try temporaryPolicy(Fixture.policyJSON)
        let result = await GatewayCommand.run(["--policy", url.path])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, [
            "policy zoneID=zone-fixture-01 auditCapacity=256",
            "gateway git mount=/git state=enabled",
            "gateway model mount=/model state=enabled",
            "gateway npm mount=/npm state=enabled",
            "gateway pypi mount=/pypi state=enabled",
            "active: git,model,npm,pypi",
            "listener disabled: no socket opened; pass --listen 127.0.0.1:<port> to enable one",
        ])
        XCTAssertTrue(result.output.joined().contains("no socket opened"))
    }

    func testInvalidPolicyIsRejectedWithExitCodeThree() async throws {
        let url = try temporaryPolicy(Fixture.policyJSON.replacingOccurrences(
            of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 7"))
        let result = await GatewayCommand.run(["--policy", url.path])
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.output, ["policy rejected: policy.schemaVersion 7 is not supported"])
    }

    func testMissingPolicyFileAndMissingArguments() async throws {
        let missing = await GatewayCommand.run(["--policy", "/tmp/h4-does-not-exist-\(UUID().uuidString).json"])
        XCTAssertEqual(missing.exitCode, 2)
        XCTAssertEqual(missing.output.count, 1)
        XCTAssertTrue(missing.output[0].hasPrefix("cannot read policy file: "))

        let usage = await GatewayCommand.run([])
        XCTAssertEqual(usage.exitCode, 2)
        XCTAssertEqual(usage.output.first, "--policy <file> is required")
        XCTAssertEqual(Array(usage.output.dropFirst()), GatewayCommand.usageLines)
    }

    func testHelpOutputIsStable() async throws {
        let result = await GatewayCommand.run(["--help"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, GatewayCommand.usageLines)
        XCTAssertTrue(result.output.joined().contains("--listen"))
    }
}
