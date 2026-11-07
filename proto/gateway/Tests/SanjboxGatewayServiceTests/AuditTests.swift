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

    /// BLOCKER regrese: `reserved` se musí po úspěšné rezervaci inkrementovat,
    /// jinak saturace přestane platit a záznam se tiše zahodí. S kapacitou 1
    /// smí projít právě jeden požadavek; druhý dostane 503 a handler se nezavolá.
    func testAuditSaturationFailsClosedBeforeHandlerRuns() async throws {
        let resolver = RefusingResolver()
        let service = try GatewayService(
            policy: try Fixture.policy([Fixture.npm()], auditCapacity: 1),
            upstream: UpstreamClient(resolver: resolver))

        let first = try await service.dispatch(request("GET", "/npm/library-fixture"))
        XCTAssertEqual(status(of: first), 502)
        let second = try await service.dispatch(request("GET", "/npm/library-fixture"))
        XCTAssertEqual(status(of: second), 503)

        // Handler se podruhé nezavolal: resolver (jediná cesta k síti) byl dotázán
        // jen jednou. Kdyby se záznam jen zahodil, odpověď by byla 502.
        XCTAssertEqual(resolver.consulted, ["registry.example"])
        let records = await service.auditRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.status, 502)
        XCTAssertEqual(records.first?.decision, .routed)
        let saturation = await service.auditSaturationCount()
        XCTAssertEqual(saturation, 1)
    }

    /// MINOR: saturace je nevratná a je to zdokumentované omezení prototypu.
    /// Test to pinuje: dokud nevznikne nová služba, brána nic neobslouží, ale
    /// historii nezahazuje ani nepřepisuje. Nová služba (rotace = nový proces)
    /// se vrátí do provozu.
    func testAuditSaturationIsIrreversibleUntilServiceIsRecreated() async throws {
        let policy = try Fixture.policy([Fixture.npm()], auditCapacity: 1)
        let resolver = RefusingResolver()
        let service = try GatewayService(policy: policy, upstream: UpstreamClient(resolver: resolver))
        let first = try await service.dispatch(request("GET", "/npm/library-fixture"))
        XCTAssertEqual(status(of: first), 502)
        for attempt in 1...3 {
            let saturated = try await service.dispatch(request("GET", "/npm/library-fixture"))
            XCTAssertEqual(status(of: saturated), 503, "attempt \(attempt)")
        }
        XCTAssertEqual(resolver.consulted, ["registry.example"], "handler už se nesmí zavolat")
        let records = await service.auditRecords()
        XCTAssertEqual(records.map(\.sequence), [1])
        let saturation = await service.auditSaturationCount()
        XCTAssertEqual(saturation, 3)

        // Rotace auditu = nová služba nad stejnou politikou (nový proces).
        let rotated = try GatewayService(policy: policy,
                                         upstream: UpstreamClient(resolver: RefusingResolver()))
        let afterRotation = try await rotated.dispatch(request("GET", "/npm/library-fixture"))
        XCTAssertEqual(status(of: afterRotation), 502)
        let rotatedRecords = await rotated.auditRecords()
        XCTAssertEqual(rotatedRecords.map(\.sequence), [1])
    }

    /// MAJOR: `path` i `method` jsou řízené klientem a dřív se vkládaly do
    /// `|`-formátu bez escapování. Vložená `|denied|operationDisabled|403`
    /// vyrobila 10 polí a podvrhla rozhodnutí. Dnes: 400, audit, jednoznačný řádek.
    func testPipeInPathOrMethodIsRejectedAndCannotForgeRecordFields() async throws {
        let resolver = RefusingResolver()
        let service = try GatewayService(policy: try Fixture.policy([Fixture.npm()]),
                                         upstream: UpstreamClient(resolver: resolver))
        let forgedPath = "/npm/x|denied|operationDisabled|403"
        let pathReply = try await service.dispatch(request("GET", forgedPath))
        XCTAssertEqual(status(of: pathReply), 400)
        let methodReply = try await service.dispatch(request("GE|T", "/npm/x"))
        XCTAssertEqual(status(of: methodReply), 400)
        XCTAssertEqual(resolver.consulted, [], "podvržený požadavek se nesmí dostat k handleru")

        let records = await service.auditRecords()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.path), [forgedPath, "/npm/x"])
        XCTAssertEqual(records.map(\.method), ["GET", "GE|T"])
        XCTAssertEqual(records.map(\.decision), [.denied, .denied])
        XCTAssertEqual(records.map(\.reason), ["invalidRequestTarget", "invalidRequestTarget"])
        // Podvržená pole zůstanou uvnitř jednoho (escapovaného) pole.
        XCTAssertTrue(records[0].canonicalLine.contains("/npm/x%7Cdenied%7CoperationDisabled%7C403"))
        XCTAssertTrue(records[1].canonicalLine.contains("|GE%7CT|/npm/x|"))
        for record in records {
            let line = record.canonicalLine
            XCTAssertEqual(line.split(separator: "|", omittingEmptySubsequences: false).count, 7, line)
            XCTAssertEqual(line.split(separator: "|", omittingEmptySubsequences: false)[4], "denied", line)
            XCTAssertEqual(AuditRecord.parse(line), record, line)
            XCTAssertEqual(AuditRecord.fieldList(record).count, AuditRecord.fieldCount)
        }
    }

    /// Round-trip: každý záznam (i s `%`, `|` a řídicím znakem) se rozparsuje
    /// zpět na 7 polí a na stejný záznam.
    func testEveryCanonicalLineParsesBackToExactlySevenFields() async throws {
        let service = try GatewayService(policy: try Fixture.allEnabled(),
                                         upstream: UpstreamClient(resolver: RefusingResolver()))
        _ = try await service.dispatch(request("GET", "/npm/library-fixture"))
        _ = try await service.dispatch(request("GET", "/npm/100%25|pipe"))
        _ = try await service.dispatch(request("GET", "/nope"))
        _ = try await service.dispatch(request("POST", "/model/v1/messages",
                                               headers: ["content-type": "application/json"],
                                               body: try encodeModelRequest()))
        let records = await service.auditRecords()
        XCTAssertEqual(records.count, 4)
        for record in records {
            let line = record.canonicalLine
            XCTAssertEqual(line.split(separator: "|", omittingEmptySubsequences: false).count,
                           AuditRecord.fieldCount, line)
            XCTAssertEqual(AuditRecord.parse(line), record, line)
        }
        // Běžná cesta zůstává čitelná bez escapování.
        XCTAssertEqual(records[0].canonicalLine, "1|npm|GET|/npm/library-fixture|routed||502")
        // `%` i `|` projdou escapem a zpět.
        XCTAssertTrue(records[1].canonicalLine.hasSuffix("|denied|invalidRequestTarget|400"))
        XCTAssertTrue(records[1].canonicalLine.contains("/npm/100%2525%7Cpipe"))
        XCTAssertEqual(AuditRecord.parse(records[1].canonicalLine)?.path, "/npm/100%25|pipe")
    }

    /// Řídicí znak v auditním poli se escapuje, takže ani ručně sestavený
    /// záznam nerozbije sedmipolí formát.
    func testControlCharactersAreEscapedInCanonicalLine() throws {
        let record = AuditRecord(sequence: 7, operation: "npm", method: "GET",
                                 path: "/npm/a\nb", decision: .denied,
                                 reason: "invalidRequestTarget", status: 400)
        let line = record.canonicalLine
        XCTAssertFalse(line.contains("\n"))
        XCTAssertEqual(line.split(separator: "|", omittingEmptySubsequences: false).count, 7)
        XCTAssertEqual(AuditRecord.parse(line), record)
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
