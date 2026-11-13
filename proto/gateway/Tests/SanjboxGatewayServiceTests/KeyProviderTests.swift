import Foundation
import SanjboxGatewayCore
import SanjboxGatewayService
import XCTest

final class KeyProviderTests: XCTestCase {
    func testMockProviderIsTheOnlyKeySourceAndIsRedacted() {
        let provider: any KeyProvider = MockKeyProvider()
        XCTAssertNotNil(provider.key(for: .model))
        XCTAssertNil(provider.key(for: .npm))
        XCTAssertNil(provider.key(for: .pypi))
        XCTAssertNil(provider.key(for: .git))

        let described = String(describing: provider)
        let reflected = String(reflecting: provider)
        XCTAssertEqual(described, "<mock key provider: synthetic model key>")
        XCTAssertFalse(described.contains(modelKeyText))
        XCTAssertFalse(reflected.contains(modelKeyText))
        // Klíč sám se také nesmí vypsat ani v popisu/debugu.
        let key = provider.key(for: .model)
        XCTAssertEqual(key?.description, "<synthetic model API key>")
        XCTAssertEqual(key?.debugDescription, "<synthetic model API key>")
    }

    func testUnavailableMockProviderComposesNoModelGateway() throws {
        XCTAssertNil(MockKeyProvider.unavailable.key(for: .model))
        XCTAssertEqual(String(describing: MockKeyProvider.unavailable),
                       "<mock key provider: model key unavailable>")
        XCTAssertFalse(String(describing: MockKeyProvider.unavailable).contains(modelKeyText))
    }

    func testComposedServiceNeverExposesKeyThroughSummaryOrAudit() async throws {
        let service = try GatewayService(policy: try Fixture.policy([Fixture.model()]))
        let summary = service.runtime.summaryLines.joined(separator: "\n")
        let description = String(describing: service)
        let reflected = String(reflecting: service)
        let text = await service.auditText()
        for value in [summary, description, reflected, text] {
            XCTAssertFalse(value.contains(modelKeyText))
        }
        XCTAssertTrue(summary.contains("gateway model mount=/model state=enabled"))
    }

    func testMockKeySatisfiesHandlerContract() throws {
        // Syntetický klíč splňuje přísný formát WP1.D3; nic se neposílá.
        XCTAssertThrowsError(try ModelAPITestKey("real-looking-secret-value-0000")) { _ in }
        XCTAssertEqual(MockKeyProvider.defaultModelKeyText.hasPrefix("sanjbox-test-"), true)
    }
}
