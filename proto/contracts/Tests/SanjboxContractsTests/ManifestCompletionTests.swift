import Foundation
import Testing
@testable import SanjboxContracts

@Suite("Complete B3 manifest rules")
struct ManifestCompletionTests {
    func base() throws -> StateManifestDocument { try StateManifestSchema.decode(Data(StateManifestTests.base.utf8)) }
    @Test func omittedRulesRejectTypedEncodeAndWireDecode() throws {
        let original = try base()
        var fixtures: [(String, StateManifestDocument)] = []
        var invalid = original
        invalid.containers.append(.init(id: "unused"))
        fixtures.append(("unused-container", invalid))
        invalid = original
        invalid.volumes.append(.init(id: "unused", containerID: "state", mountPoint: "/Volumes/Unused", quota: .init(mode: "limited", limitBytes: 1, reserveBytes: 0)))
        invalid.rollback.volumeIDs.append("unused")
        fixtures.append(("unused-volume", invalid))
        invalid = original
        invalid.roots[1].relativePath = String(repeating: "x", count: 1024)
        fixtures.append(("resolved-path-limit", invalid))
        invalid = original
        invalid.zone.uid = 0
        for i in invalid.roots.indices { invalid.roots[i].ownerUID = 0 }
        fixtures.append(("host-control", invalid))
        invalid = original
        invalid.hostControl.policyFile = "back\\slash"
        fixtures.append(("control-file", invalid))
        invalid = original
        invalid.roots[1].relativePath = "unicode\u{85}control"
        fixtures.append(("root-path", invalid))
        for (code, document) in fixtures {
            let report = StateManifestSchema.report(document)
            #expect(report.findings.contains { $0.code == code && $0.severity == "error" })
            #expect(!report.consistentDesign)
            #expect(throws: ContractError.self) { try StateManifestSchema.validate(document) }
            #expect(throws: ContractError.self) { _ = try StateManifestSchema.encode(document) }
            let bytes = try JSONEncoder().encode(document)
            #expect(throws: ContractError.self) { _ = try StateManifestSchema.decode(bytes) }
        }
    }
    @Test func warningsRemainVisibleWithoutRejectingValidDesigns() throws {
        var document = try base()
        var report = StateManifestSchema.report(document)
        #expect(report.consistentDesign && report.requiredRolesDeclared)
        #expect(report.findings.contains { $0.code == "multi-volume-recovery" && $0.severity == "warning" })
        #expect(report.findings.contains { $0.code == "quotas-oversubscribed" && $0.severity == "warning" })
        #expect(report.plannedRoots.map(\.id) == ["cache", "home", "prefix", "project", "tmp"])
        #expect(report.plannedRoots.first { $0.id == "prefix" }?.plannedPath == "/opt/snj/t1ab")
        #expect(report.plannedVolumes == document.volumes)
        #expect(report.containerBudgets[0].declaredFiniteQuotaSum == 2147483648)
        document.containers[0].planningBudgetBytes = nil
        document.volumes[0].quota = .init(mode: "unresolved", reserveBytes: 0)
        report = StateManifestSchema.report(document)
        #expect(report.findings.contains { $0.code == "container-budget-unresolved" && $0.severity == "warning" })
        #expect(report.findings.contains { $0.code == "quota-unverified" && $0.severity == "warning" })
        #expect(report.consistentDesign && !report.deploymentReady)
        #expect(report.acceptanceStatus == "Neověřeno" && report.observedTopology == "not-inspected")
        #expect(report.containerBudgets[0].hasUnboundedOrUnresolvedVolume)
        #expect(try StateManifestSchema.decode(StateManifestSchema.encode(document)) == document)
    }
    @Test func overflowingTotalsStayUnknownInReportAndRejectAdmission() throws {
        var document = try base()
        for i in document.volumes.indices {
            document.volumes[i].quota.limitBytes = UInt64.max
            document.volumes[i].quota.reserveBytes = UInt64.max
        }
        let report = StateManifestSchema.report(document)
        #expect(report.containerBudgets[0].declaredReserveSum == nil)
        #expect(report.containerBudgets[0].declaredFiniteQuotaSum == nil)
        #expect(report.findings.contains { $0.code == "budget-overflow" && $0.severity == "error" })
        rejection("invalid-range") { try StateManifestSchema.validate(document) }
    }
    @Test func encodedByteLimitIncludesJSONEscaping() throws {
        var document = try base()
        document.volumes[0].mountPoint = "/s"
        while document.roots.count < 64 {
            let id = "extra-\(document.roots.count)"
            document.roots.append(.init(id: id, role: "additional", volumeID: "state",
                relativePath: id, ownerUID: 4501, purpose: "fixture"))
        }
        for i in document.roots.indices {
            if document.roots[i].role != "prefix" {
                document.roots[i].relativePath = String(repeating: "a/", count: 500) + "r\(i)"
            }
            document.roots[i].purpose = String(repeating: "\0", count: 256)
        }
        document.readOnlyInputs = (0..<32).map { i in
            .init(id: "input-\(i)", path: "/public-\(i)/" + String(repeating: "b/", count: 499) + "end",
                  purpose: String(repeating: "\0", count: 256))
        }
        try StateManifestSchema.validate(document)
        let raw = try JSONEncoder().encode(document)
        #expect(raw.count > StateManifestSchema.maxBytes)
        rejection("input-too-large") { _ = try StateManifestSchema.encode(document) }
        rejection("input-too-large") { _ = try StateManifestSchema.decode(raw) }
    }

}
