import Foundation
import SanjboxGatewayCore
import SanjboxGatewayService
import Synchronization
import XCTest

/// Integrace přes skutečné aktéry ze `spikes/s5-gateway`. Jediná "síťová" část
/// je `RefusingResolver` (mock), který každé volání odmítne: testy tak dokazují,
/// že složení dojde až do politiky upstreamu skutečného handleru, ale žádný
/// socket se neotevře a žádný balíček se neinstaluje.
final class HandlerIntegrationTests: XCTestCase {
    private func service(_ rules: [GatewayRule], resolver: RefusingResolver) throws -> GatewayService {
        try GatewayService(policy: try Fixture.policy(rules),
                           upstream: UpstreamClient(resolver: resolver))
    }

    func testNPMHandlerRunsAndUpstreamPolicyRefusesBeforeAnySocket() async throws {
        let resolver = RefusingResolver()
        let service = try service([Fixture.npm()], resolver: resolver)
        let reply = try await service.dispatch(request("GET", "/npm/library-fixture"))
        XCTAssertEqual(status(of: reply), 502)
        XCTAssertEqual(resolver.consulted, ["registry.example"])

        let records = await service.auditRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.operation, "npm")
        XCTAssertEqual(records.first?.decision, .routed)
        XCTAssertEqual(records.first?.status, 502)
    }

    func testNPMHandlerOwnHeaderPolicyRefusesCredentialBeforeUpstream() async throws {
        let resolver = RefusingResolver()
        let service = try service([Fixture.npm()], resolver: resolver)
        let reply = try await service.dispatch(request("GET", "/npm/library-fixture",
                                                       headers: ["authorization": "Bearer \(canary)"]))
        XCTAssertEqual(status(of: reply), 403)
        XCTAssertEqual(resolver.consulted, [], "handler must refuse before any DNS/dial policy")
        // Odmítl handler, ne brána: audit to musí říct i s důvodem.
        let text = await service.auditText()
        XCTAssertEqual(text, "1|npm|GET|/npm/library-fixture|deniedByHandler|handlerForbidden|403")
    }

    func testPyPIHandlerRunsThroughComposedPolicy() async throws {
        let resolver = RefusingResolver()
        let service = try service([Fixture.pypi()], resolver: resolver)
        let reply = try await service.dispatch(request("GET", "/pypi/simple/fixture/"))
        XCTAssertEqual(status(of: reply), 502)
        XCTAssertEqual(resolver.consulted, ["pypi.example"])
    }

    func testGitHandlerServesOnlyItsFixedProjectAndRefusesPush() async throws {
        let resolver = RefusingResolver()
        let service = try service([Fixture.git()], resolver: resolver)

        let fetch = try await service.dispatch(
            request("GET", "/git/project.git/info/refs?service=git-upload-pack"))
        XCTAssertEqual(status(of: fetch), 502)
        XCTAssertEqual(resolver.consulted, ["github.example"])

        let push = try await service.dispatch(request("POST", "/git/project.git/git-receive-pack",
                                                      headers: ["content-type": "application/x-git-receive-pack-request"],
                                                      body: Data("0000".utf8)))
        XCTAssertEqual(status(of: push), 403)
        // push odmítl sám handler (allowPush=false), ne brána.
        XCTAssertEqual(resolver.consulted, ["github.example"])

        let otherRepository = try await service.dispatch(
            request("GET", "/git/other.git/info/refs?service=git-upload-pack"))
        XCTAssertEqual(status(of: otherRepository), 400)

        let records = await service.auditRecords()
        // Fetch došel k upstreamu (routed), push a cizí projekt odmítl handler.
        XCTAssertEqual(records.map(\.decision), [.routed, .deniedByHandler, .deniedByHandler])
        XCTAssertEqual(records.map(\.reason), ["", "handlerForbidden", "handlerRejected"])
        XCTAssertEqual(records.map(\.status), [502, 403, 400])
    }

    func testModelHandlerProducesStreamThatUpstreamPolicyRefuses() async throws {
        let resolver = RefusingResolver()
        let service = try service([Fixture.model()], resolver: resolver)
        let reply = try await service.dispatch(request("POST", "/model/v1/messages",
                                                       headers: ["content-type": "application/json"],
                                                       body: try encodeModelRequest()))
        guard case .events(let producer) = reply else {
            return XCTFail("model handler must answer with an SSE producer")
        }
        let emitted = Mutex(0)
        do {
            try await producer { _ in emitted.withLock { $0 += 1 } }
            XCTFail("stream must not succeed without an upstream")
        } catch {
            // Modelový handler zabalí chybu upstreamu do vlastního typu; důležité
            // je, že producent nic nevyrobil a resolver byl dotázán.
            XCTAssertTrue(error is ModelAPIFailure, "unexpected error: \(error)")
        }
        XCTAssertEqual(emitted.withLock { $0 }, 0)
        XCTAssertEqual(resolver.consulted, ["api.anthropic.com"])
        let text = await service.auditText()
        XCTAssertFalse(text.contains(modelKeyText))
    }

    func testModelHandlerRefusesDisallowedModelWithoutUpstream() async throws {
        let resolver = RefusingResolver()
        let service = try service([Fixture.model()], resolver: resolver)
        let reply = try await service.dispatch(request("POST", "/model/v1/messages",
                                                       headers: ["content-type": "application/json"],
                                                       body: try encodeModelRequest(model: "not-allowed")))
        XCTAssertEqual(status(of: reply), 403)
        XCTAssertEqual(resolver.consulted, [])
    }

    func testRouterMethodPolicyIsEnforcedByHandlerNotBypassed() async throws {
        let resolver = RefusingResolver()
        let service = try service([Fixture.npm(), Fixture.git()], resolver: resolver)
        // npm handler povoluje jen GET; POST odmítne sám handler.
        let post = try await service.dispatch(request("POST", "/npm/library-fixture", body: Data("x".utf8)))
        XCTAssertEqual(status(of: post), 403)
        XCTAssertEqual(resolver.consulted, [])
        let records = await service.auditRecords()
        XCTAssertEqual(records.map(\.operation), ["npm"])
        XCTAssertEqual(records.map(\.decision), [.deniedByHandler])
        XCTAssertEqual(records.map(\.reason), [DenialReason.handlerForbidden.rawValue])
    }
}
