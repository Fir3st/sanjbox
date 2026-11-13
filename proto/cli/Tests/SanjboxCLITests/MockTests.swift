import XCTest
import SanjboxContracts
@testable import SanjboxCLI

final class MockTests: XCTestCase {
    private func send(_ request: HelperMessage, to helper: MockHelper) throws -> HelperReply {
        let server = MockXPCServer(helper: helper)
        defer { server.invalidate() }
        return try HelperClient(transport: XPCTransport(endpoint: server.endpoint)).send(request)
    }
    func testPauseBlocksFurtherAdmissionAndKeepsOpaqueHandles() throws {
        let helper = MockHelper()
        let accepted = try send(shellRequest, to: helper)
        XCTAssertEqual(accepted.outcome, .accepted)
        _ = try send(.pauseZone(.init(zoneID: "a1b2")), to: helper)
        assertCLIError(.helperFailed(.invalidState)) { _ = try send(shellRequest, to: helper) }
        XCTAssertEqual(helper.observe().phase, .paused)
        XCTAssertEqual(helper.observe().handles.count, 1)
    }
    func testHandlesAreUniqueAndBoundToOriginalZoneRequests() throws {
        let helper = MockHelper()
        let first = try send(shellRequest, to: helper)
        let request = HelperMessage.run(.init(zoneID: "a1b2", workingRootID: "home", executableRootID: "tools", executablePath: "bin/tool", arguments: ["literal"]))
        let second = try send(request, to: helper)
        XCTAssertNotEqual(first.executionID, second.executionID)
        XCTAssertEqual(helper.observe().handles[first.executionID!], shellRequest)
        XCTAssertEqual(helper.observe().handles[second.executionID!], request)
    }
    func testUnknownZoneAndRootsAreRefused() {
        let helper = MockHelper()
        let badZone = HelperMessage.shell(.init(zoneID: "b2c3", workingRootID: "project"))
        assertCLIError(.helperFailed(.unauthorized)) { _ = try send(badZone, to: helper) }
        let badRoot = HelperMessage.shell(.init(zoneID: "a1b2", workingRootID: "host"))
        assertCLIError(.helperFailed(.invalidRequest)) { _ = try send(badRoot, to: helper) }
        let badExecutable = HelperMessage.run(.init(zoneID: "a1b2", workingRootID: "project", executableRootID: "host", executablePath: "bin/tool"))
        assertCLIError(.helperFailed(.invalidRequest)) { _ = try send(badExecutable, to: helper) }
        XCTAssertTrue(helper.observe().handles.isEmpty)
    }
    func testSnapshotIncludesEveryRootAndRollbackPreservesHostControl() throws {
        let helper = MockHelper(phase: .stopped)
        let baseline = helper.observe().rootValues
        _ = try send(.snapshot(.init(zoneID: "a1b2", snapshotID: "all-roots", rollbackUnitID: "full-state")), to: helper)
        XCTAssertEqual(helper.observe().snapshots["all-roots"], baseline)
        XCTAssertEqual(Set(baseline.keys), ["home", "project", "prefix", "tools", "cache", "tmp"])
        helper.mutateFixture()
        XCTAssertTrue(helper.observe().rootValues.allSatisfy { $0.value != baseline[$0.key] })
        _ = try send(.rollback(.init(zoneID: "a1b2", snapshotID: "all-roots", rollbackUnitID: "full-state")), to: helper)
        XCTAssertEqual(helper.observe().rootValues, baseline)
        XCTAssertEqual(helper.observe().hostPolicy, "changed-host-policy")
        XCTAssertEqual(helper.observe().phase, .stopped)
        XCTAssertTrue(helper.observe().handles.isEmpty)
    }
    func testSnapshotRequiresMockQuiescenceAndDoesNotOverwrite() throws {
        let helper = MockHelper()
        let request = HelperMessage.snapshot(.init(zoneID: "a1b2", snapshotID: "new", rollbackUnitID: "full-state"))
        assertCLIError(.helperFailed(.invalidState)) { _ = try send(request, to: helper) }
        _ = try send(.pauseZone(.init(zoneID: "a1b2")), to: helper)
        _ = try send(request, to: helper)
        helper.mutateFixture()
        assertCLIError(.helperFailed(.invalidState)) { _ = try send(request, to: helper) }
        XCTAssertEqual(helper.observe().snapshots["new"]?["home"], "baseline-home")
    }
    func testRollbackRequiresStoppedFixtureAndKnownFullUnitSnapshot() {
        let request = HelperMessage.rollback(.init(zoneID: "a1b2", snapshotID: "baseline", rollbackUnitID: "full-state"))
        for phase in [MockPhase.running, .paused] {
            assertCLIError(.helperFailed(.invalidState)) { _ = try send(request, to: MockHelper(phase: phase)) }
        }
        let helper = MockHelper(phase: .stopped)
        helper.mutateFixture()
        let before = helper.observe().rootValues
        for body in [SnapshotRequest(zoneID: "a1b2", snapshotID: "baseline", rollbackUnitID: "project"),
                     SnapshotRequest(zoneID: "a1b2", snapshotID: "missing", rollbackUnitID: "full-state")] {
            assertCLIError(.helperFailed(.invalidRequest)) { _ = try send(.rollback(body), to: helper) }
        }
        XCTAssertEqual(helper.observe().rootValues, before)
    }
    func testUnsupportedH1OperationsAreNotExposedByMock() {
        let helper = MockHelper()
        for request in [HelperMessage.startZone(.init(zoneID: "a1b2")), .resumeZone(.init(zoneID: "a1b2")),
                        .createZone(.init(zoneID: "a1b2", uid: 750, gid: 750))] {
            assertCLIError(.helperFailed(.invalidRequest)) { _ = try send(request, to: helper) }
        }
        XCTAssertEqual(helper.observe().phase, .running)
    }
    func testRequestBudgetBoundsMockMemory() throws {
        let helper = MockHelper()
        for _ in 0..<128 { _ = try helper.exchange(shellRequest.encoded()) }
        let refused = try HelperReply.decode(helper.exchange(shellRequest.encoded()))
        XCTAssertEqual(refused.errorCode, .unavailable)
        XCTAssertEqual(helper.observe().received.count, 128)
        XCTAssertEqual(helper.observe().handles.count, 128)
    }
}
