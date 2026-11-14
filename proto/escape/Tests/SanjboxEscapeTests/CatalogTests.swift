import Foundation
import Testing
@testable import SanjboxEscape

// Hand-pinned acceptance contract from COVERAGE §3 at base 5d2005a. Never generated from Catalog.
let expectedIDs = """
GUI-01 GUI-02 GUI-03 GUI-04 GUI-05 GUI-06 GUI-07 GUI-08 GUI-09 GUI-10 GUI-11 GUI-12
GUI-13 GUI-14 GUI-15 GUI-16 GUI-17 GUI-18 GUI-19 GUI-20 GUI-21 GUI-22 GUI-23 GUI-24
FS-01 FS-02 FS-03 FS-04 FS-05 FS-06 FS-07 FS-08 FS-09 FS-10 FS-11 FS-12
ID-01 ID-02 ID-03 ID-04 ID-05 ID-06 ID-07 ID-08 ID-09 ID-10 ID-11
LC-01 LC-02 LC-03 LC-04 LC-05 LC-06 LC-07 LC-08 LC-09 LC-10 LC-11
NET-01 NET-02 NET-03 NET-04 NET-05 NET-06 NET-07 NET-08 NET-09 NET-10 NET-11 NET-12
NET-13 NET-14 NET-15 NET-16 NET-17 NET-18 NET-19 NET-20 NET-21 NET-22 NET-23 NET-24 NET-25 NET-26 NET-27
GW-01 GW-02 GW-03 GW-04 GW-05 GW-06 GW-07 GW-08 GW-09 GW-10 GW-11 GW-12 GW-13 GW-14 GW-15 GW-16 GW-17 GW-18 GW-19 GW-20
RB-01 RB-02 RB-03 RB-04 RB-05 RB-06 RB-07 RB-08 RB-09 RB-10
SG-01 SG-02 SG-03 SG-04 SG-05 SG-06 SG-07 SG-08 SG-09 SG-10 SG-11
HB-01 HB-02 HB-03 HB-04 HB-05 HB-06 HB-07
DK-01 DK-02 DK-03 DK-04 DK-05 DK-06 DK-07 DK-08 DK-09 DK-10
POS-01 POS-02 POS-03 POS-04 POS-05 POS-06 POS-07 POS-08 POS-09
PERF-01 PERF-02 PERF-03
""".split(whereSeparator: { $0.isWhitespace }).map(String.init)

let repoRoot = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }

@Suite("H6 catalog and acceptance separation")
struct CatalogTests {
    @Test func exactCatalogMatchesIndependentPinnedIDs() throws {
        let catalog = try Catalog.load()
        #expect(expectedIDs.count == 155)
        #expect(Set(expectedIDs).count == 155)
        #expect(catalog.map(\.id) == expectedIDs)
        #expect(Set(catalog.map(\.id)).count == 155)
    }
    @Test func coverageAlsoMatchesPinnedIDsAndMetadata() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("docs/COVERAGE.md"), encoding: .utf8)
        let section = try #require(text.components(separatedBy: "## 3. Testové případy").last)
            .components(separatedBy: "## 4.")[0]
        let rows = section.split(separator: "\n").filter { $0.range(of: #"^\| (GUI|FS|ID|LC|NET|GW|RB|SG|HB|DK|POS|PERF)-[0-9]{2} \|"#, options: .regularExpression) != nil }
        let parsed = rows.map { $0.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } }
        #expect(parsed.map { $0[1] } == expectedIDs)
        for (row, item) in zip(parsed, try Catalog.load()) {
            #expect(row[2] == item.title)
            #expect(row[3] == item.requirements)
            #expect(row[4] == item.gate)
        }
    }
    @Test func catalogRejectsMissingDuplicateAndUnboundProbes() throws {
        let valid = try Catalog.load()
        #expect(throws: (any Error).self) { try Catalog.validate(Array(valid.dropLast())) }
        var changed = valid; changed[1] = changed[0]
        #expect(throws: (any Error).self) { try Catalog.validate(changed) }
        changed = valid; changed[0].probe = .foreignRead
        #expect(throws: (any Error).self) { try Catalog.validate(changed) }
        changed = valid; changed[0].oracle = " "
        #expect(throws: (any Error).self) { try Catalog.validate(changed) }
    }
    @Test func implementedSubsetIsExplicitAndEachRowHasActionableDocumentation() throws {
        let catalog = try Catalog.load()
        #expect(catalog.filter { $0.mode == .synthetic }.map(\.id) == ["FS-01", "FS-07", "FS-08", "LC-06", "LC-11", "NET-02", "NET-12", "SG-09"])
        for item in catalog {
            #expect(item.step.count >= 50)
            #expect(item.oracle.count >= 50)
            #expect(!item.reference.isEmpty && !item.limitation.isEmpty)
        }
    }
    @Test func manualAndUnsupportedIgnoreEvenAClaimedPerfectObservation() throws {
        let observation = Observation(oracleSatisfied: true, detail: "fabricated caller claim")
        for item in try Catalog.load() where item.mode != .synthetic {
            let result = Evaluation.evaluate(item, observation: observation)
            #expect(result.status == (item.mode == .manual ? .manualRequired : .unsupported))
            #expect(result.acceptanceStatus == "unverified")
        }
    }
    @Test func positiveNegativeAndEveryIncompleteDimension() throws {
        let item = try #require(Catalog.load().first { $0.id == "FS-01" })
        let positive = Observation(oracleSatisfied: true, detail: "complete measured fixture")
        #expect(Evaluation.evaluate(item, observation: positive).status == .syntheticPassed)
        #expect(Evaluation.evaluate(item, observation: Observation(oracleSatisfied: false, detail: "canary leaked")).status == .syntheticFailed)
        #expect(Evaluation.evaluate(item, observation: nil).status == .incomplete)
        for i in 0..<4 {
            var partial = positive
            switch i { case 0: partial.identityValid = false; case 1: partial.attempted = false
            case 2: partial.controlValid = false; default: partial.complete = false }
            #expect(Evaluation.evaluate(item, observation: partial).status == .incomplete)
        }
    }
    @Test func aggregateCannotHideUnexecutedCases() throws {
        let results = try Catalog.load().map { Evaluation.evaluate($0, observation: Observation(oracleSatisfied: true, detail: "synthetic fixture")) }
        let report = try HarnessReport(results: results, counterpart: [], audit: [], cleanupVerified: true)
        #expect(report.exitCode == 3)
        #expect(report.summary == "incomplete")
        #expect(report.counts["syntheticPassed"] == 8)
        #expect(report.results.allSatisfy { $0.acceptanceStatus == "unverified" })
    }
}
