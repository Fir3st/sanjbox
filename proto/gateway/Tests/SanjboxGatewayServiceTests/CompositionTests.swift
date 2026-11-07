import Foundation
import SanjboxGatewayCore
import SanjboxGatewayService
import XCTest

final class CompositionTests: XCTestCase {
    func testComposesExactlyTheEnabledOperations() async throws {
        let service = try GatewayService(policy: try Fixture.allEnabled())
        XCTAssertEqual(service.runtime.activeOperations, [.git, .model, .npm, .pypi])
        XCTAssertEqual(service.runtime.entries.map(\.mount), ["/git", "/model", "/npm", "/pypi"])
        XCTAssertEqual(service.runtime.classify(path: "/npm"), .active(.npm))
        XCTAssertEqual(service.runtime.classify(path: "/npm/library-fixture"), .active(.npm))
        XCTAssertEqual(service.runtime.classify(path: "/npmfoo"), .unknown)
        XCTAssertEqual(service.runtime.classify(path: "/brew/api/formula"), .unknown)
    }

    func testDisabledOperationIsNotComposedAndIsDeniedDeterministically() async throws {
        let policy = try Fixture.policy([Fixture.npm(enabled: false), Fixture.pypi()])
        let service = try GatewayService(policy: policy)
        XCTAssertEqual(service.runtime.activeOperations, [.pypi])
        XCTAssertEqual(service.runtime.classify(path: "/npm/library-fixture"), .disabled(.npm))

        let reply = try await service.dispatch(request("GET", "/npm/library-fixture"))
        XCTAssertEqual(status(of: reply), 403)
        let records = await service.auditRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.decision, .denied)
        XCTAssertEqual(records.first?.reason, DenialReason.operationDisabled.rawValue)
        XCTAssertEqual(records.first?.operation, "npm")
        XCTAssertEqual(records.first?.status, 403)
        XCTAssertEqual(records.first?.sequence, 1)
    }

    func testUnknownOperationPathIsDeniedAndAuditedWithoutPassthrough() async throws {
        let service = try GatewayService(policy: try Fixture.policy([Fixture.npm()]))
        for path in ["/", "/git/project.git/info/refs", "/model/v1/messages", "/npmfoo"] {
            let reply = try await service.dispatch(request("GET", path))
            XCTAssertEqual(status(of: reply), 404, path)
        }
        let records = await service.auditRecords()
        XCTAssertEqual(records.count, 4)
        XCTAssertTrue(records.allSatisfy { $0.decision == .denied })
        XCTAssertTrue(records.allSatisfy { $0.reason == DenialReason.operationNotConfigured.rawValue })
        XCTAssertTrue(records.allSatisfy { $0.operation == "unknown" })
        XCTAssertEqual(records.map(\.sequence), [1, 2, 3, 4])

        // Mount z politiky není "neznámá" cesta: dorazí do handleru a ten ho
        // odmítne vlastní politikou (chybějící cíl = 400). Audit to musí
        // rozlišit od "brána pustila": rozhodnutí je `deniedByHandler`.
        for path in ["/npm", "/npm/"] {
            let reply = try await service.dispatch(request("GET", path))
            XCTAssertEqual(status(of: reply), 400, path)
        }
        let handled = await service.auditRecords()
        XCTAssertEqual(handled.suffix(2).map(\.decision), [.deniedByHandler, .deniedByHandler])
        XCTAssertEqual(handled.suffix(2).map(\.reason), ["handlerRejected", "handlerRejected"])
        XCTAssertEqual(handled.suffix(2).map(\.operation), ["npm", "npm"])
    }

    /// MAJOR: odmítnutí uvnitř brány nesmí vypadat jako `routed` s prázdným
    /// důvodem; jinak audit nerozliší "pustili jsme" od "my jsme odmítli".
    func testHandlerRefusalIsAuditedAsDeniedByHandlerWithReason() async throws {
        let resolver = RefusingResolver()
        let service = try GatewayService(policy: try Fixture.policy([Fixture.npm(), Fixture.git()]),
                                         upstream: UpstreamClient(resolver: resolver))
        // npm povoluje jen GET, POST odmítne sám handler.
        let forbidden = try await service.dispatch(request("POST", "/npm/library-fixture",
                                                           body: Data("x".utf8)))
        XCTAssertEqual(status(of: forbidden), 403)
        // Git odmítne push vlastní politikou (allowPush=false).
        let push = try await service.dispatch(
            request("POST", "/git/project.git/git-receive-pack",
                    headers: ["content-type": "application/x-git-receive-pack-request"],
                    body: Data("0000".utf8)))
        XCTAssertEqual(status(of: push), 403)
        XCTAssertEqual(resolver.consulted, [], "obě odmítnutí jsou před upstreamem")

        let records = await service.auditRecords()
        XCTAssertEqual(records.map(\.decision), [.deniedByHandler, .deniedByHandler])
        XCTAssertEqual(records.map(\.reason), ["handlerForbidden", "handlerForbidden"])
        XCTAssertEqual(records.map(\.status), [403, 403])
        XCTAssertTrue(records.allSatisfy { !$0.reason.isEmpty })
        XCTAssertFalse(records.contains { $0.decision == .routed })
    }

    func testPolicyThatHandlerRejectsFailsComposition() async throws {
        // IP literál jako upstream hostname: handler ho odmítne, brána se nesloží.
        let policy = try Fixture.policy([Fixture.npm(upstream: "127.0.0.1")])
        XCTAssertThrowsError(try GatewayService(policy: policy)) { error in
            XCTAssertEqual(error as? CompositionError, .handlerConfiguration(.npm))
        }
    }

    func testMissingModelKeyStopsComposition() async throws {
        let policy = try Fixture.policy([Fixture.npm(), Fixture.model()])
        XCTAssertThrowsError(try GatewayService(policy: policy, keyProvider: MockKeyProvider.unavailable)) { error in
            XCTAssertEqual(error as? CompositionError, .keyUnavailable(.model))
        }
        // Vypnuté modelové API klíč nepotřebuje.
        let disabled = try Fixture.policy([Fixture.npm(), Fixture.model(enabled: false)])
        let service = try GatewayService(policy: disabled, keyProvider: MockKeyProvider.unavailable)
        XCTAssertEqual(service.runtime.activeOperations, [.npm])
    }

    func testModelKeyInsideZoneOrModelListIsRejected() async throws {
        let policy = try GatewayPolicy(
            zoneID: zoneID,
            gateways: [
                .npm(NPMRule(publicOrigin: Fixture.origin)),
                .model(ModelRule(allowedModels: [MockKeyProvider.defaultModelKeyText], budgetUnits: 10)),
            ])
        XCTAssertThrowsError(try GatewayService(policy: policy)) { error in
            XCTAssertEqual(error as? CompositionError, .handlerConfiguration(.model))
        }
    }

    func testSummaryLinesAreDeterministic() async throws {
        let first = try GatewayService(policy: try Fixture.allEnabled())
        let second = try GatewayService(policy: try Fixture.allEnabled())
        let firstLines = first.runtime.summaryLines
        let secondLines = second.runtime.summaryLines
        XCTAssertEqual(firstLines, secondLines)
        XCTAssertEqual(firstLines, [
            "policy zoneID=zone-fixture-01 auditCapacity=256",
            "gateway git mount=/git state=enabled",
            "gateway model mount=/model state=enabled",
            "gateway npm mount=/npm state=enabled",
            "gateway pypi mount=/pypi state=enabled",
        ])
    }

    func testPolicyWithEveryOperationDisabledComposesNothingAndDeniesEverything() async throws {
        let service = try GatewayService(policy: try Fixture.policy([
            Fixture.npm(enabled: false), Fixture.pypi(enabled: false),
            Fixture.git(enabled: false), Fixture.model(enabled: false),
        ]), keyProvider: MockKeyProvider.unavailable)
        XCTAssertTrue(service.runtime.activeOperations.isEmpty)
        for path in ["/npm/library-fixture", "/pypi/simple/fixture/", "/git/project.git/info/refs",
                     "/model/v1/messages", "/anything"] {
            let reply = try await service.dispatch(request("GET", path))
            XCTAssertEqual(status(of: reply), path == "/anything" ? 404 : 403, path)
        }
    }
}
