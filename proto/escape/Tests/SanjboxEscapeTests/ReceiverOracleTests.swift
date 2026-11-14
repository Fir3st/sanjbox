import Foundation
import Testing
import SanjboxProbeKit
@testable import SanjboxEscape

@Suite("H6 counterpart oracle cannot infer isolation from silence")
struct ReceiverOracleTests {
    @Test func emptyTCPContactFailsZeroContactOracle() {
        let summary = CounterpartSummary(complete: true, problems: [], tcpConnections: 1, udpDatagrams: 0, bytes: 0, findings: [])
        let evidence = CounterpartEvidence(role: "synthetic zero-byte contact", reportExit: 1, report: summary, eventsJSONL: "", rawPayload: nil)
        #expect(evidence.complete)
        #expect(!evidence.empty)
    }
    @Test func positiveRequiresExactCanaryRawBytesCountsAndCompleteReport() throws {
        let canary = try Canary.make(label: "oracle")
        let summary = CounterpartSummary(complete: true, problems: [], tcpConnections: 1, udpDatagrams: 0,
            bytes: canary.token.utf8.count, findings: [.init(token: canary.token, encoding: "raw")])
        func evidence(_ value: CounterpartSummary, code: Int32 = 1, raw: Data? = nil) -> CounterpartEvidence {
            CounterpartEvidence(role: "synthetic oracle fixture", reportExit: code, report: value, eventsJSONL: "", rawPayload: raw)
        }
        #expect(evidence(summary, raw: Data(canary.token.utf8)).received(canary))
        #expect(!evidence(summary, raw: Data("wrong canary".utf8)).received(canary))
        #expect(!evidence(summary, code: 0, raw: Data(canary.token.utf8)).received(canary))
        for i in 0..<5 {
            var changed = summary
            switch i { case 0: changed.complete = false; case 1: changed.bytes += 1
            case 2: changed.findings = []; case 3: changed.tcpConnections = 2; default: changed.problems = ["missing stopped"] }
            #expect(!evidence(changed, raw: Data(canary.token.utf8)).received(canary))
        }
    }
}
