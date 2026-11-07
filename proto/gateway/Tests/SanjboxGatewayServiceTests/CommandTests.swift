import Foundation
import SanjboxGatewayService
import Synchronization
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
            "model key source: <mock key provider: synthetic model key>"
                + "; real Keychain is not implemented (GUIDE §3)",
            "listener disabled: no socket opened; pass --listen 127.0.0.1:<port> to enable one",
        ])
        XCTAssertTrue(result.output.joined().contains("no socket opened"))
    }

    /// MINOR: modelový mount se skládá s mockem. CLI to musí říct výslovně,
    /// aby `state=enabled` nevypadalo jako skutečná Klíčenka.
    func testModelMockKeySourceIsStatedAndAbsentWithoutModel() async throws {
        let enabled = try temporaryPolicy(Fixture.policyJSON)
        let withModel = await GatewayCommand.run(["--policy", enabled.path])
        XCTAssertTrue(withModel.output.contains(
            "model key source: <mock key provider: synthetic model key>"
                + "; real Keychain is not implemented (GUIDE §3)"))
        XCTAssertTrue(withModel.output.contains { $0.contains("real Keychain is not implemented") })
        XCTAssertFalse(withModel.output.joined().contains(modelKeyText))

        let disabled = try temporaryPolicy(Fixture.policyJSON.replacingOccurrences(
            of: "\"operation\": \"model\",\n      \"enabled\": true,",
            with: "\"operation\": \"model\",\n      \"enabled\": false,"))
        let withoutModel = await GatewayCommand.run(["--policy", disabled.path])
        XCTAssertEqual(withoutModel.exitCode, 0)
        XCTAssertTrue(withoutModel.output.contains("gateway model mount=/model state=disabled"))
        XCTAssertFalse(withoutModel.output.contains { $0.contains("model key source") })
    }

    /// MINOR: potvrzení o listeneru se musí vypsat **před** vstupem do smyčky.
    /// Mock runner neotevírá socket a hned se vrátí, takže test ověří pořadí.
    func testServeEmitsListenerConfirmationBeforeEnteringTheLoop() async throws {
        let url = try temporaryPolicy(Fixture.policyJSON)
        let log = Mutex<[String]>([])
        let result = await GatewayCommand.run(
            ["--policy", url.path, "--listen", "127.0.0.1:18765"],
            emit: { line in log.withLock { $0.append(line) } },
            listener: { address in
                MockListenerRunner { log.withLock { $0.append("mock listener entered \(address.text)") } }
            })
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, [])
        let emitted = log.withLock { $0 }
        XCTAssertEqual(emitted.last, "mock listener entered 127.0.0.1:18765")
        XCTAssertEqual(Array(emitted.dropLast()), [
            "policy zoneID=zone-fixture-01 auditCapacity=256",
            "gateway git mount=/git state=enabled",
            "gateway model mount=/model state=enabled",
            "gateway npm mount=/npm state=enabled",
            "gateway pypi mount=/pypi state=enabled",
            "active: git,model,npm,pypi",
            "model key source: <mock key provider: synthetic model key>"
                + "; real Keychain is not implemented (GUIDE §3)",
            "listener ready: 127.0.0.1:18765 (prototype opt-in; no production use, IMPLEMENTATION §3)",
        ])
        XCTAssertFalse(emitted.contains { $0.contains("prototype listener opt-in") })
    }

    /// Selhání listeneru nesmí vypadat jako úspěch: exit 4 a důvod.
    func testListenerFailureIsReportedAndNotSwallowed() async throws {
        let url = try temporaryPolicy(Fixture.policyJSON)
        let log = Mutex<[String]>([])
        let result = await GatewayCommand.run(
            ["--policy", url.path, "--listen", "127.0.0.1:18765"],
            emit: { line in log.withLock { $0.append(line) } },
            listener: { _ in FailingListener() })
        XCTAssertEqual(result.exitCode, 4)
        XCTAssertEqual(result.output, ["listener stopped: bindFailed"])
        XCTAssertEqual(log.withLock { $0 }.last,
                       "listener stopped: bindFailed", "selhání musí být vidět i v emit")
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

/// Mock listeneru, který selže jako neúspěšný bind. Žádný socket se neotevírá.
private struct FailingListener: ListenerRunner {
    func run(serving service: GatewayService) async throws { throw ConnectionFailure.bindFailed }
}
