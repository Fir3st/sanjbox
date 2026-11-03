import Foundation
import SanjboxProbeKit

/// Summary of one counterpart run, computed only from its event log.
///
/// A negative test passes on the counterpart side only when the run is `complete` and nothing
/// was received. An incomplete log proves nothing: the counterpart may not have been listening.
public struct CounterpartReport: Codable, Equatable, Sendable {
    public var complete: Bool
    /// Why the log is incomplete; empty when complete.
    public var problems: [String]
    public var listeners: [Listener]
    public var tcpConnections: Int
    public var udpDatagrams: Int
    public var bytes: Int
    /// Distinct source hosts of all flows.
    public var remoteHosts: [String]
    public var findings: [CanaryScanner.Finding]

    /// Any contact counts, including a TCP connection that carried no byte.
    public var receivedAnything: Bool { tcpConnections + udpDatagrams > 0 }

    public init(events: [CounterpartEvent]) {
        var problems: [String] = []
        if events.first?.kind != .started { problems.append("first event is not started") }
        if events.last?.kind != .stopped { problems.append("last event is not stopped") }
        if events.filter({ $0.kind == .started }).count > 1 { problems.append("more than one started event") }
        if events.filter({ $0.kind == .stopped }).count > 1 { problems.append("more than one stopped event") }

        let accepted = Set(events.filter { $0.kind == .accepted }.compactMap(\.flowID))
        let closed = Set(events.filter { $0.kind == .closed }.compactMap(\.flowID))
        for flow in accepted.subtracting(closed).sorted() { problems.append("flow \(flow) accepted but not closed") }
        for flow in closed.subtracting(accepted).sorted() { problems.append("flow \(flow) closed but not accepted") }

        let ended = events.filter { $0.kind == .closed || $0.kind == .datagram }
        self.problems = problems
        complete = problems.isEmpty
        listeners = events.first { $0.kind == .started }?.listeners ?? []
        tcpConnections = accepted.count
        udpDatagrams = events.filter { $0.kind == .datagram }.count
        bytes = ended.compactMap(\.bytes).reduce(0, +)
        remoteHosts = Set(events.compactMap(\.remote?.host)).sorted()
        findings = Set(ended.flatMap { $0.findings ?? [] }).sorted { ($0.token, $0.encoding) < ($1.token, $1.encoding) }
    }
}
