import Foundation
import SanjboxGatewayCore
import SanjboxGatewayService
import XCTest

final class AuditTests: XCTestCase {
    func testAuditOrderAndTextAreDeterministicAcrossRuns() async throws {
        func run() async throws -> String {
            let service = try GatewayService(policy: try Fixture.policy([Fixture.npm(enabled: false)]))
            _ = try await service.dispatch(request("GET", "/npm/library-fixture"))
            _ = try await service.dispatch(request("POST", "/unknown/thing", body: Data("x".utf8)))
            _ = try await service.dispatch(request("GET", "/"))
            return await service.auditText()
        }
        let first = try await run()
        let second = try await run()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.split(separator: "\n").count, 3)
        XCTAssertEqual(first.split(separator: "\n").first,
                       "1|npm|GET|/npm/library-fixture|denied|operationDisabled|403")
    }

    func testAuditNeverContainsRequestBodyHeadersOrKey() async throws {
        let resolver = RefusingResolver()
        let upstream = UpstreamClient(resolver: resolver)
        let policy = try Fixture.policy([Fixture.npm(), Fixture.model()])
        let service = try GatewayService(policy: policy, upstream: upstream)

        _ = try await service.dispatch(request("GET", "/npm/library-fixture",
                                               headers: ["authorization": "Bearer \(canary)"]))
        _ = try await service.dispatch(request("POST", "/model/v1/messages",
                                               headers: ["content-type": "application/json"],
                                               body: try encodeModelRequest()))
        let text = await service.auditText()
        XCTAssertFalse(text.contains(canary))
        XCTAssertFalse(text.contains("Bearer"))
        XCTAssertFalse(text.contains(modelKeyText))
        XCTAssertFalse(text.contains("synthetic prompt"))
        // Modelový požadavek není v auditu "unknown": patří modelové operaci.
        XCTAssertTrue(text.contains("|model|POST|/model/v1/messages|routed||200"))
    }

    func testAuditCapacityIsBoundedAndSaturationIsExplicit() async throws {
        let service = try GatewayService(policy: try Fixture.policy([Fixture.npm()], auditCapacity: 2))
        let first = try await service.dispatch(request("GET", "/nope-1"))
        let second = try await service.dispatch(request("GET", "/nope-2"))
        let third = try await service.dispatch(request("GET", "/nope-3"))
        XCTAssertEqual(status(of: first), 404)
        XCTAssertEqual(status(of: second), 404)
        XCTAssertEqual(status(of: third), 503)
        let records = await service.auditRecords()
        let saturation = await service.auditSaturationCount()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(saturation, 1)
        // Historie se nezahazuje: první dva záznamy zůstávají.
        XCTAssertEqual(records.map(\.sequence), [1, 2])
    }

    func testDenialsAreAuditedBeforeAnyHandlerRuns() async throws {
        let resolver = RefusingResolver()
        let service = try GatewayService(policy: try Fixture.policy([Fixture.npm()]),
                                         upstream: UpstreamClient(resolver: resolver))
        _ = try await service.dispatch(request("GET", "/pypi/simple/fixture/"))
        XCTAssertEqual(resolver.consulted, [])
        let records = await service.auditRecords()
        XCTAssertEqual(records.first?.decision, .denied)
        XCTAssertEqual(records.first?.status, 404)
        XCTAssertEqual(records.first?.path, "/pypi/simple/fixture/")
    }
}
