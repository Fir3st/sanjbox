import Foundation
import SanjboxContracts
import Synchronization
import XCTest
@testable import SanjboxGatewayCore
@testable import SanjboxGatewayService

final class H1AdapterTests: XCTestCase {
    private func gate(_ type: GateType, id: String = "fixture", request: UInt32 = 1_048_576,
                      response: UInt32 = 4_194_304) -> TypedGate {
        let host: String
        switch type {
        case .npm: host = "registry.example"
        case .pypi: host = "pypi.example"
        case .git: host = "github.example"
        case .modelAPI: host = "api.anthropic.com"
        case .brew: host = "brew.example"
        }
        return TypedGate(id: id, type: type, upstream: host, methods: type == .modelAPI ? ["POST"] : [],
                         requestBytesLimit: request, responseBytesLimit: response)
    }

    private func adapt(_ gate: TypedGate, _ rule: GatewayRule) throws -> H1GatewayAdapter {
        try H1GatewayAdapter(networkPolicy: NetworkPolicy(zoneID: "a1b2", gates: [gate]),
                             configuration: H1GatewayConfiguration(auditCapacity: 32, rulesByGateID: [gate.id: rule]))
    }

    private func pypi() -> GatewayRule {
        .pypi(PyPIRule(publicOrigin: Fixture.origin, upstreamHostname: "pypi.example",
                       artifactHostnames: ["pypi.example"]))
    }

    private func service(_ adapter: H1GatewayAdapter, upstream: OfflineUpstream) throws -> GatewayService {
        try GatewayService(adapting: adapter, upstreamFactory: { upstream.client(limits: $0) })
    }

    private func limits(_ bytes: Int) throws -> RegistryRuleLimits {
        try RegistryRuleLimits(metadataBytes: bytes, artifactBytes: bytes)
    }

    func testWirePolicyComposesAllFourBindingsAndPreservesH1Identity() throws {
        let gates = [gate(.npm, id: "registry"), gate(.pypi, id: "python"), gate(.git, id: "source"), gate(.modelAPI, id: "inference")]
        let policy = NetworkPolicy(zoneID: "a1b2", gates: gates)
        let adapter = try H1GatewayAdapter.decode(policy.encoded(), configuration: H1GatewayConfiguration(
            auditCapacity: 7, rulesByGateID: ["registry": Fixture.npm(mount: "/packages"), "python": pypi(),
                                           "source": Fixture.git(), "inference": Fixture.model()]))
        let service = try GatewayService(adapting: adapter, resolver: RefusingResolver())
        XCTAssertEqual(service.networkPolicy, policy)
        XCTAssertEqual(service.runtime.zoneID, "a1b2")
        XCTAssertEqual(service.runtime.auditCapacity, 7)
        XCTAssertEqual(service.runtime.activeOperations, [.git, .model, .npm, .pypi])
        XCTAssertEqual(service.runtime.classify(path: "/packages/fixture"), .active(.npm))
        XCTAssertEqual(service.runtime.classify(path: "/npm/fixture"), .unknown)
    }

    func testEmptyH1PolicyIsDenyAllWithoutInventedHandlers() async throws {
        let adapter = try H1GatewayAdapter(networkPolicy: NetworkPolicy(zoneID: "a1b2", gates: []),
            configuration: H1GatewayConfiguration(auditCapacity: 1, rulesByGateID: [:]))
        let resolver = RefusingResolver()
        let service = try GatewayService(adapting: adapter, resolver: resolver)
        let reply = try await service.dispatch(request("GET", "/npm/fixture"))
        XCTAssertEqual(status(of: reply), 404)
        XCTAssertEqual(body(of: reply), Data())
        XCTAssertEqual(service.runtime.activeOperations, [])
        let saturated = try await service.dispatch(request("GET", "/model"))
        XCTAssertEqual(status(of: saturated), 503)
        XCTAssertEqual(body(of: saturated), Data())
        XCTAssertEqual(resolver.consulted, [])
    }

    func testMutatedDTOIsRevalidatedBeforeComposition() throws {
        var policies: [NetworkPolicy] = []
        let good = NetworkPolicy(zoneID: "a1b2", gates: [gate(.npm)])
        var changed = good; changed.defaultAction = "allow"; policies.append(changed)
        changed = good; changed.zoneID = "zone-fixture-01"; policies.append(changed)
        changed = good; changed.gates[0].upstream = "127.0.0.1"; policies.append(changed)
        changed = good; changed.gates[0].requestBytesLimit = 0; policies.append(changed)
        changed = good; changed.gates[0].methods = ["POST"]; policies.append(changed)
        changed = good; changed.schema = "future"; policies.append(changed)
        for policy in policies {
            XCTAssertThrowsError(try H1GatewayAdapter(networkPolicy: policy,
                configuration: H1GatewayConfiguration(auditCapacity: 1, rulesByGateID: ["fixture": Fixture.npm()]))) {
                XCTAssertEqual($0 as? H1AdapterError, .invalidPolicy)
            }
        }
    }

    func testWireRejectsMalformedDuplicateUnknownMissingAndInexactNumbers() throws {
        let text = String(decoding: try NetworkPolicy(zoneID: "a1b2", gates: [gate(.npm)]).encoded(), as: UTF8.self)
        let config = H1GatewayConfiguration(auditCapacity: 1, rulesByGateID: ["fixture": Fixture.npm()])
        let cases = [
            text.replacingOccurrences(of: "\"zoneID\":\"a1b2\"", with: "\"zoneID\":\"a1b2\",\"z\\u006fneID\":\"c3d4\""),
            text.replacingOccurrences(of: "\"defaultAction\":\"deny\",", with: ""),
            text.replacingOccurrences(of: "\"requestBytesLimit\":1048576", with: "\"requestBytesLimit\":1e6"),
            text.replacingOccurrences(of: "\"requestBytesLimit\":1048576", with: "\"requestBytesLimit\":1.00000000000000001"),
            text.replacingOccurrences(of: "\"requestBytesLimit\":1048576", with: "\"requestBytesLimit\":1048576,\"extra\":true"),
            text + "true", String(text.dropLast()), String(repeating: " ", count: NetworkPolicy.maxBytes + 1),
        ]
        for malformed in cases {
            XCTAssertNotEqual(malformed, text)
            XCTAssertThrowsError(try H1GatewayAdapter.decode(Data(malformed.utf8), configuration: config))
        }
    }

    func testExactBindingsRejectMissingExtraWrongTypeAndDuplicateOperations() throws {
        let policy = NetworkPolicy(zoneID: "a1b2", gates: [gate(.npm)])
        for bindings: [String: GatewayRule] in [[:], ["wrong": Fixture.npm()],
                                                ["fixture": Fixture.npm(), "extra": Fixture.git()]] {
            XCTAssertThrowsError(try H1GatewayAdapter(networkPolicy: policy,
                configuration: H1GatewayConfiguration(auditCapacity: 1, rulesByGateID: bindings))) {
                XCTAssertEqual($0 as? H1AdapterError, .gateBindings)
            }
        }
        XCTAssertThrowsError(try adapt(gate(.npm), Fixture.git())) {
            XCTAssertEqual($0 as? H1AdapterError, .typeMismatch)
        }
        XCTAssertThrowsError(try H1GatewayAdapter(networkPolicy: NetworkPolicy(zoneID: "a1b2",
            gates: [gate(.npm, id: "one"), gate(.npm, id: "two")]), configuration: H1GatewayConfiguration(
                auditCapacity: 1, rulesByGateID: ["one": Fixture.npm(), "two": Fixture.npm(mount: "/second")]))) {
            XCTAssertEqual($0 as? H1AdapterError, .gateBindings)
        }
    }

    func testBrewDisabledAndInvalidSupplementaryConfigurationAreRejected() throws {
        XCTAssertThrowsError(try adapt(gate(.brew), Fixture.npm())) { XCTAssertEqual($0 as? H1AdapterError, .unsupportedType) }
        XCTAssertThrowsError(try adapt(gate(.npm), Fixture.npm(enabled: false))) { XCTAssertEqual($0 as? H1AdapterError, .disabledGate) }
        XCTAssertThrowsError(try adapt(gate(.npm), Fixture.npm(mount: "/nested/path")))
        XCTAssertThrowsError(try adapt(gate(.npm), Fixture.npm(cooldown: .nan)))
        XCTAssertThrowsError(try adapt(gate(.modelAPI), .model(ModelRule(allowedModels: [], budgetUnits: 1))))
        XCTAssertThrowsError(try adapt(gate(.git), .git(GitRule(upstreamHostname: "github.example", repositoryPath: "/other.git"))))
        XCTAssertThrowsError(try H1GatewayAdapter(networkPolicy: NetworkPolicy(zoneID: "a1b2", gates: []),
            configuration: H1GatewayConfiguration(auditCapacity: 0, rulesByGateID: [:])))
    }

    func testNoDestinationOrArtifactHostCanBeAddedBySupplement() throws {
        for (type, rule) in [(GateType.npm, Fixture.npm()), (.pypi, pypi()), (.git, Fixture.git()), (.modelAPI, Fixture.model())] {
            var other = gate(type); other.upstream = "other.example"
            XCTAssertThrowsError(try adapt(other, rule)) { XCTAssertEqual($0 as? H1AdapterError, .upstreamMismatch) }
        }
        for rule in [GatewayRule.npm(NPMRule(publicOrigin: Fixture.origin, upstreamHostname: "registry.example",
                                            artifactHostnames: ["cdn.example"])), Fixture.pypi()] {
            XCTAssertThrowsError(try adapt(gate(rule.operation == .npm ? .npm : .pypi), rule)) {
                XCTAssertEqual($0 as? H1AdapterError, .upstreamMismatch)
            }
        }
    }

    func testModelGETOrMixedMethodGrantIsExplicitlyUnsupported() throws {
        for methods in [["GET"], ["GET", "POST"], ["POST", "GET"]] {
            var changed = gate(.modelAPI); changed.methods = methods
            XCTAssertThrowsError(try adapt(changed, Fixture.model())) { XCTAssertEqual($0 as? H1AdapterError, .unsupportedMethods) }
        }
        XCTAssertNoThrow(try adapt(gate(.modelAPI), Fixture.model()))
    }

    func testLargerHandlerLimitsAreRejectedInsteadOfClampedOrIgnored() throws {
        for (type, rule) in [(GateType.npm, Fixture.npm()), (.pypi, pypi()), (.git, Fixture.git()), (.modelAPI, Fixture.model())] {
            XCTAssertThrowsError(try adapt(gate(type, response: 1), rule)) { XCTAssertEqual($0 as? H1AdapterError, .responseLimit) }
        }
        for (type, rule) in [(GateType.git, Fixture.git()), (.modelAPI, Fixture.model())] {
            XCTAssertThrowsError(try adapt(gate(type, request: 1), rule)) { XCTAssertEqual($0 as? H1AdapterError, .requestLimit) }
        }
        let metadataOnly = try RegistryRuleLimits(metadataBytes: 2, artifactBytes: 1)
        let artifactOnly = try RegistryRuleLimits(metadataBytes: 1, artifactBytes: 2)
        for bounds in [metadataOnly, artifactOnly] {
            XCTAssertThrowsError(try adapt(gate(.npm, response: 1), .npm(NPMRule(publicOrigin: Fixture.origin,
                upstreamHostname: "registry.example", limits: bounds))))
        }
    }

    func testExtremeH1BoundsAreAcceptedOnlyWithCompatibleExplicitHandlerLimits() throws {
        let tiny = try adapt(gate(.npm, request: 1, response: 1), .npm(NPMRule(publicOrigin: Fixture.origin,
            upstreamHostname: "registry.example", limits: limits(1))))
        XCTAssertEqual(tiny.upstreamResponseBytesLimit, 1)
        XCTAssertEqual(tiny.upstreamLimits.streamBytes, 1)
        XCTAssertEqual(tiny.upstreamLimits.eventBytes, 1)
        let large = try adapt(gate(.modelAPI, request: TypedGate.maxRequestBytesLimit,
                                  response: TypedGate.maxResponseBytesLimit), Fixture.model())
        XCTAssertEqual(large.upstreamResponseBytesLimit, 4_194_304)
        let mixed = try H1GatewayAdapter(networkPolicy: NetworkPolicy(zoneID: "a1b2",
            gates: [gate(.npm, id: "small", response: 1), gate(.modelAPI, id: "large")]),
            configuration: H1GatewayConfiguration(auditCapacity: 2, rulesByGateID: [
                "small": .npm(NPMRule(publicOrigin: Fixture.origin, upstreamHostname: "registry.example", limits: limits(1))),
                "large": Fixture.model()]))
        XCTAssertEqual(mixed.upstreamResponseBytesLimit, 1, "shared upstream parser only tightens larger grants")
    }

    func testActualNPMAndPyPIArtifactHandlersSucceedOnlyOnBoundHost() async throws {
        for isPyPI in [false, true] {
            let upstream = try artifactUpstream(pypi: isPyPI, artifactHostname: "pypi.example")
            let adapter = try adapt(gate(isPyPI ? .pypi : .npm), isPyPI ? pypi() : Fixture.npm())
            let service = try service(adapter, upstream: upstream)
            let target = isPyPI ? "/pypi/files/fixture/" + wheelFilename : "/npm/fixture/-/fixture-1.0.0.tgz"
            let reply = try await service.dispatch(request("GET", target))
            XCTAssertEqual(status(of: reply), 200)
            XCTAssertEqual(body(of: reply), artifactBytes)
            XCTAssertEqual(upstream.calls.count, 3)
            XCTAssertEqual(Set(upstream.calls.compactMap { $0.headers["host"] }), [isPyPI ? "pypi.example" : "registry.example"])
            XCTAssertEqual(Set(upstream.calls.map(\.method)), ["GET"])
            if case .response(let response) = reply { await response.completeTransport(true) }
            let states = isPyPI ? await service.pypiDownloadRecords().map { $0.state.rawValue }
                               : await service.npmDownloadRecords().map { $0.state.rawValue }
            XCTAssertEqual(states, ["transportAccepted"])
        }
    }

    func testCrossHostPyPIArtifactIsRefusedWithoutDialingIt() async throws {
        let upstream = try artifactUpstream(pypi: true) // files.example is absent from the H1 grant.
        let service = try service(adapt(gate(.pypi), pypi()), upstream: upstream)
        let reply = try await service.dispatch(request("GET", "/pypi/files/fixture/" + wheelFilename))
        XCTAssertEqual(status(of: reply), 403)
        XCTAssertEqual(upstream.calls.count, 1)
        XCTAssertEqual(upstream.calls.first?.headers["host"], "pypi.example")
    }

    func testGitRequestAndResponseBoundaryIsEnforcedBeforeUpstreamAndBeforeDelivery() async throws {
        for bytes in [4, 5] {
            let upstream = OfflineUpstream { _ in responseWire(Data("0000".utf8), type: "application/x-git-upload-pack-result") }
            let adapter = try adapt(gate(.git, request: 4, response: 4), .git(GitRule(upstreamHostname: "github.example",
                maximumRequestBytes: 4, limits: limits(4))))
            let service = try service(adapter, upstream: upstream)
            let reply = try await service.dispatch(request("POST", "/git/project.git/git-upload-pack",
                headers: ["content-type": "application/x-git-upload-pack-request"], body: Data(repeating: 48, count: bytes)))
            XCTAssertEqual(status(of: reply), bytes == 4 ? 200 : 413)
            XCTAssertEqual(upstream.calls.count, bytes == 4 ? 1 : 0)
            XCTAssertLessThanOrEqual(body(of: reply)?.count ?? 0, 4)
            let records = await service.auditRecords()
            XCTAssertEqual(records.last?.reason, bytes == 4 ? "" : "h1RequestLimit")
        }
        for bytes in [16, 17] {
            let upstream = OfflineUpstream { _ in responseWire(Data(repeating: 48, count: bytes), type: "application/x-git-upload-pack-advertisement") }
            let service = try service(adapt(gate(.git, response: 16), .git(GitRule(upstreamHostname: "github.example", limits: limits(16)))), upstream: upstream)
            let reply = try await service.dispatch(request("GET", "/git/project.git/info/refs?service=git-upload-pack"))
            XCTAssertEqual(status(of: reply), bytes == 16 ? 200 : 502)
            XCTAssertLessThanOrEqual(body(of: reply)?.count ?? 0, 16)
        }
    }

    func testGitPushNeedsExplicitSupplementAndNeverChangesRepository() async throws {
        for allow in [false, true] {
            let upstream = OfflineUpstream { _ in responseWire(Data("0000".utf8), type: "application/x-git-receive-pack-result") }
            let service = try service(adapt(gate(.git), Fixture.git(allowPush: allow)), upstream: upstream)
            let reply = try await service.dispatch(request("POST", "/git/project.git/git-receive-pack",
                headers: ["content-type": "application/x-git-receive-pack-request"], body: Data("0000".utf8)))
            XCTAssertEqual(status(of: reply), allow ? 200 : 403)
            XCTAssertEqual(upstream.calls.count, allow ? 1 : 0)
            if allow { XCTAssertEqual(upstream.calls.first?.target, "/project.git/git-receive-pack") }
            let other = try await service.dispatch(request("GET", "/git/other.git/info/refs?service=git-upload-pack"))
            XCTAssertEqual(status(of: other), 400)
            XCTAssertEqual(upstream.calls.count, allow ? 1 : 0)
        }
    }

    func testModelSuccessUsesFixedHostPOSTAndMockKeyWithBoundedSSE() async throws {
        let wire = try modelStreamWire()
        let upstream = OfflineUpstream { _ in wire }
        let adapter = try adapt(gate(.modelAPI, response: 4_096), .model(ModelRule(allowedModels: ["fixture-model"], budgetUnits: 2, maximumOutputBytes: 4_096)))
        let service = try service(adapter, upstream: upstream)
        let emitted = Mutex(Data())
        guard case .events(let produce) = try await service.dispatch(request("POST", "/model/v1/messages",
            headers: ["content-type": "application/json"], body: encodeModelRequest())) else { return XCTFail("stream") }
        try await produce { event in let bytes = try event.encoded(); emitted.withLock { $0.append(bytes) } }
        XCTAssertTrue(String(decoding: emitted.withLock { $0 }, as: UTF8.self).contains("message_stop"))
        XCTAssertLessThanOrEqual(emitted.withLock { $0.count }, 4_096)
        XCTAssertEqual(upstream.calls.count, 1)
        XCTAssertEqual(upstream.calls.first?.headers["host"], "api.anthropic.com")
        XCTAssertEqual(upstream.calls.first?.headers["x-api-key"], modelKeyText)
        XCTAssertEqual(upstream.calls.first?.method, "POST")
        XCTAssertEqual(upstream.calls.first?.target, "/v1/messages")
        let audit = await service.auditText()
        XCTAssertFalse(audit.contains(modelKeyText))
        let denied = try await service.dispatch(request("GET", "/model/v1/messages"))
        XCTAssertNotEqual(status(of: denied), 200)
        XCTAssertEqual(upstream.calls.count, 1)
    }

    func testModelInputBoundaryAndMalformedBodiesCannotStartUpstream() async throws {
        let input = try encodeModelRequest()
        let canonical = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: input), options: [.sortedKeys, .withoutEscapingSlashes])
        let ceiling = max(input.count, canonical.count)
        let adapter = try adapt(gate(.modelAPI, request: UInt32(ceiling)), .model(ModelRule(allowedModels: ["fixture-model"], budgetUnits: 10, maximumInputBytes: ceiling)))
        let wire = try modelStreamWire()
        let upstream = OfflineUpstream { _ in wire }
        let service = try service(adapter, upstream: upstream)
        let reply = try await service.dispatch(request("POST", "/model/v1/messages", headers: ["content-type": "application/json"], body: input))
        guard case .events(let produce) = reply else { return XCTFail("exact boundary") }
        try await produce { _ in }
        for body in [input + Data(repeating: 32, count: ceiling - input.count + 1), Data("null".utf8), Data("[]".utf8), Data("{".utf8), Data("true".utf8)] {
            let denied = try await service.dispatch(request("POST", "/model/v1/messages", headers: ["content-type": "application/json"], body: body))
            XCTAssertNotEqual(status(of: denied), nil)
            XCTAssertEqual(upstream.calls.count, 1)
        }
    }

    func testSmallResponseCeilingAlsoBoundsLocalAndBeforeEventErrors() async throws {
        let wire = try modelStreamWire()
        let upstream = OfflineUpstream { _ in wire }
        let service = try service(adapt(gate(.modelAPI, response: 1), .model(ModelRule(allowedModels: ["fixture-model"], budgetUnits: 1, maximumOutputBytes: 1))), upstream: upstream)
        let channel = MockChannel(inbound: requestWire("POST", "/model/v1/messages", body: try encodeModelRequest()))
        try await LoopbackConnection(channel: channel).serve(serving: service)
        let sent = String(decoding: channel.sent, as: UTF8.self)
        XCTAssertTrue(sent.hasPrefix("HTTP/1.1 502 "))
        XCTAssertTrue(sent.contains("Content-Length: 0\r\n"))
        XCTAssertTrue(sent.hasSuffix("\r\n\r\n"))
        let denied = try await service.dispatch(request("POST", "/model/other", body: Data("{}".utf8)))
        XCTAssertEqual(body(of: denied), Data())
    }

    func testCredentialsAndRegistryWriteMethodsStayDeniedBeforeDNS() async throws {
        let resolver = RefusingResolver()
        let service = try GatewayService(adapting: adapt(gate(.npm), Fixture.npm()), resolver: resolver)
        for (method, headers) in [("POST", [:]), ("GET", ["authorization": "Bearer synthetic-canary"]), ("DELETE", [:])] {
            let reply = try await service.dispatch(request(method, "/npm/fixture", headers: headers))
            XCTAssertEqual(status(of: reply), 403)
        }
        XCTAssertEqual(resolver.consulted, [])
        let allowed = try await service.dispatch(request("GET", "/npm/fixture"))
        XCTAssertEqual(status(of: allowed), 502)
        XCTAssertEqual(resolver.consulted, ["registry.example"])
    }
    func testModelJSONReencodingStaysInsideH1RequestCeiling() async throws {
        // Escaped and literal Unicode exercise the actual D3 reconstruction, not
        // merely the inbound body count; the outgoing request is captured below.
        let input = Data(#"{"model":"fixture-model","messages":[{"role":"user","content":"\u2028\/é😀"}],"max_tokens":32,"stream":true}"#.utf8)
        let canonical = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: input), options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertNotEqual(input, canonical)
        let maximum = max(input.count, canonical.count)
        let wire = try modelStreamWire()
        for ceiling in [input.count - 1, maximum] {
            let upstream = OfflineUpstream { _ in wire }
            let service = try service(adapt(gate(.modelAPI, request: UInt32(ceiling)), .model(ModelRule(
                allowedModels: ["fixture-model"], budgetUnits: 1, maximumInputBytes: ceiling))), upstream: upstream)
            let reply = try await service.dispatch(request("POST", "/model/v1/messages", headers: ["content-type": "application/json"], body: input))
            if ceiling < input.count {
                XCTAssertEqual(status(of: reply), 413)
                XCTAssertEqual(upstream.calls.count, 0)
            } else {
                guard case .events(let produce) = reply else { return XCTFail("canonical boundary") }
                try await produce { _ in }
                XCTAssertEqual(upstream.calls.first?.body, canonical)
                XCTAssertLessThanOrEqual(upstream.calls.first?.body.count ?? Int.max, ceiling)
            }
        }
    }

    func testRawUpstreamSSECeilingIncludesDiscardedPingBytes() async throws {
        var decoder = UpstreamResponseDecoder()
        var payload = Data()
        for part in try modelStreamWire() {
            for body in try decoder.append(part) { payload.append(body) }
        }
        let ping = try SSEEvent(data: "{\"type\":\"ping\"}", event: "ping").encoded()
        // Pings produce no client output, but must still consume the upstream byte budget.
        payload = Data(Array(repeating: ping, count: 20).joined()) + payload
        let ceiling = payload.count
        for extra in [false, true] {
            let bytes = payload + (extra ? ping : Data())
            let upstream = OfflineUpstream { _ in responseWire(bytes, type: "text/event-stream") }
            let service = try service(adapt(gate(.modelAPI, response: UInt32(ceiling)), .model(ModelRule(
                allowedModels: ["fixture-model"], budgetUnits: 1, maximumOutputBytes: ceiling))), upstream: upstream)
            let channel = MockChannel(inbound: requestWire("POST", "/model/v1/messages", body: try encodeModelRequest()))
            try await LoopbackConnection(channel: channel).serve(serving: service)
            let sent = String(decoding: channel.sent, as: UTF8.self)
            XCTAssertTrue(sent.hasPrefix("HTTP/1.1 \(extra ? 502 : 200) "), sent)
            XCTAssertEqual(sent.contains("message_stop"), !extra)
            let audit = await service.auditRecords()
            XCTAssertEqual(audit.last?.decision, extra ? .failed : .routed)
        }
    }

    func testModelOutputCeilingStopsPartialSSEAndPreservesFailureAudit() async throws {
        let wire = try modelStreamWire()
        let upstream = OfflineUpstream { _ in wire }
        // H1 response limit bounds raw upstream; an explicitly stricter output limit
        // bounds the independently reconstructed client stream.
        let service = try service(adapt(gate(.modelAPI, response: 4_096), .model(ModelRule(
            allowedModels: ["fixture-model"], budgetUnits: 1, maximumOutputBytes: 400))), upstream: upstream)
        let channel = MockChannel(inbound: requestWire("POST", "/model/v1/messages", body: try encodeModelRequest()))
        try await LoopbackConnection(channel: channel).serve(serving: service)
        let sent = String(decoding: channel.sent, as: UTF8.self)
        XCTAssertTrue(sent.hasPrefix("HTTP/1.1 200 "))
        XCTAssertTrue(sent.contains("message_start"))
        XCTAssertFalse(sent.contains("message_stop"))
        XCTAssertFalse(sent.hasSuffix("0\r\n\r\n"))
        let records = await service.auditRecords()
        XCTAssertEqual(records.map(\.decision), [.failed])
    }

}
