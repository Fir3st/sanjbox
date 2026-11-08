import Darwin
import Foundation
import SanjboxProbeKit

/// Summary of one counterpart run, computed only from its event log.
///
/// A negative test passes on the counterpart side only when the run is `complete` and nothing
/// was received. Invalid or incomplete logs prove nothing. Their counters remain best-effort
/// observations, not validated totals; positive bytes and findings are never discarded.
public struct CounterpartReport: Codable, Equatable, Sendable {
    public var complete: Bool
    /// Why the log is invalid or incomplete; empty when complete. At most 100 diagnostics.
    public var problems: [String]
    public var listeners: [Listener]
    /// Accepted records, plus closed records without a preceding acceptance of that ID.
    public var tcpConnections: Int
    public var udpDatagrams: Int
    /// Sum of nonnegative observed byte counts, saturated at Int.max on invalid overflow.
    public var bytes: Int
    /// Distinct source hosts of all flows, including malformed records.
    public var remoteHosts: [String]
    public var findings: [CanaryScanner.Finding]

    /// Any contact counts, including empty flows and receipt evidence on malformed records.
    /// Separate comparisons also remain safe for a report decoded from untrusted JSON.
    public var receivedAnything: Bool {
        tcpConnections > 0 || udpDatagrams > 0 || bytes > 0 || !findings.isEmpty
    }

    public init(events: [CounterpartEvent]) {
        var validation = ReportValidation()
        if events.first?.kind != .started { validation.problem("first event is not started") }
        if events.last?.kind != .stopped { validation.problem("last event is not stopped") }

        for (index, event) in events.enumerated() {
            validation.consume(event, position: index + 1)
        }
        validation.finish()

        problems = validation.problems
        complete = problems.isEmpty
        listeners = validation.listeners
        tcpConnections = validation.tcpConnections
        udpDatagrams = validation.udpDatagrams
        bytes = validation.bytes
        remoteHosts = validation.remoteHosts.sorted()
        findings = validation.findings.sorted { ($0.token, $0.encoding) < ($1.token, $1.encoding) }
    }
}

/// One pass over the records; IDs are dictionary keys, never array indices or loop bounds.
private struct ReportValidation {
    var problems: [String] = []
    var listeners: [Listener] = []
    var tcpConnections = 0
    var udpDatagrams = 0
    var bytes = 0
    var remoteHosts: Set<String> = []
    var findings: Set<CanaryScanner.Finding> = []

    private var started = false
    private var stopped = false
    private var listenerAddresses: [ListenerKey: Set<NumericAddress>] = [:]
    private var flowIDs: Set<Int> = []
    private var accepted: [Int: CounterpartEvent] = [:]
    private var closed: Set<Int> = []

    mutating func problem(_ message: String) {
        // Keep processing observations after the diagnostic budget is exhausted.
        if problems.count < 99 { problems.append(message) }
        else if problems.count == 99 { problems.append("additional problems omitted") }
    }

    mutating func consume(_ event: CounterpartEvent, position: Int) {
        let prefix = "event \(position) (\(event.kind.rawValue)): "
        func message(_ detail: String) -> String { prefix + detail }

        // Collect evidence before validating: malformed IDs or fields must not erase contact.
        if let host = event.remote?.host { remoteHosts.insert(host) }
        findings.formUnion(event.findings ?? [])
        if let count = event.bytes {
            if count < 0 {
                problem(message("negative bytes"))
            } else {
                let (total, overflow) = bytes.addingReportingOverflow(count)
                bytes = overflow ? Int.max : total
                if overflow { problem(message("byte total exceeds Int.max")) }
            }
        }

        if !event.timestamp.timeIntervalSinceReferenceDate.isFinite {
            problem(message("nonfinite timestamp"))
        }
        let fields = EventField.present(in: event)
        let required = event.kind.requiredFields
        let allowed = event.kind.allowedFields
        for field in EventField.allCases {
            if required.contains(field), !fields.contains(field) {
                problem(message("missing \(field.rawValue)"))
            } else if fields.contains(field), !allowed.contains(field) {
                problem(message("forbidden \(field.rawValue)"))
            }
        }

        switch event.kind {
        case .started:
            if started { problem(message("more than one started event")) }
            if position != 1 { problem(message("started is not first")) }
            if !started {
                listeners = event.listeners ?? []
                validateListeners()
            }
            started = true
        case .stopped:
            if stopped { problem(message("more than one stopped event")) }
            if !started { problem(message("stopped before started")) }
            stopped = true
        case .accepted, .closed, .datagram:
            if !started || stopped { problem(message("flow event outside started/stopped interval")) }
            validateFlow(event, prefix: prefix)
        }
    }

    private mutating func validateListeners() {
        if listeners.isEmpty { problem("started has no listeners") }
        for (index, listener) in listeners.enumerated() {
            guard listener.endpoint.port > 0, let address = NumericAddress(listener.endpoint.host) else {
                problem("listener \(index + 1) has an invalid numeric endpoint or zero port")
                continue
            }
            let key = ListenerKey(transport: listener.transport, port: listener.endpoint.port)
            if !listenerAddresses[key, default: []].insert(address).inserted {
                problem("listener \(index + 1) duplicates a listener")
            }
        }
    }

    private mutating func validateFlow(_ event: CounterpartEvent, prefix: String) {
        let expectedTransport: CounterpartEvent.Transport = event.kind == .datagram ? .udp : .tcp
        if event.transport != expectedTransport { problem(prefix + "wrong transport for kind") }
        if let local = event.local {
            if let address = NumericAddress(local.host), local.port > 0 {
                let candidates = listenerAddresses[ListenerKey(transport: expectedTransport, port: local.port)] ?? []
                // TCP getsockname reports the concrete destination; UDP records its bound listener.
                let matches = candidates.contains(address) || (event.kind != .datagram
                    && !address.isUnspecified && candidates.contains(address.wildcard))
                if !matches || (event.kind != .datagram && address.isUnspecified) {
                    problem(prefix + "local endpoint does not match a listener")
                }
            } else {
                problem(prefix + "invalid local endpoint")
            }
        }
        if let remote = event.remote {
            // A UDP sender may legally omit its source port (zero).
            if let address = NumericAddress(remote.host) {
                if expectedTransport == .tcp && (remote.port == 0 || address.isUnspecified) {
                    problem(prefix + "invalid remote endpoint")
                }
                if let local = event.local, let localAddress = NumericAddress(local.host) {
                    // Mapped IPv4 and native IPv6 both occupy 16 bytes, but cannot be opposite
                    // ends of one TCP connection or a datagram to a concrete listener. UDP's
                    // local address is the bind, so :: can receive either domain; Darwin can
                    // also report a plain IPv4 source on a mapped IPv6 UDP listener.
                    let sameDomain = address.octets.count == localAddress.octets.count
                        && address.isMappedIPv4 == localAddress.isMappedIPv4
                    let udpWildcard = expectedTransport == .udp && localAddress.octets.count == 16
                        && localAddress.isUnspecified
                    let udpMappedWithIPv4Source = expectedTransport == .udp && localAddress.isMappedIPv4
                        && address.octets.count == 4
                    if !sameDomain && !udpWildcard && !udpMappedWithIPv4Source {
                        problem(prefix + "local and remote address families differ")
                    }
                }
            } else {
                problem(prefix + "invalid remote endpoint")
            }
        }

        let flow = event.flowID
        let validID = flow.map { $0 > 0 } ?? false
        if let flow, !validID { problem(prefix + "flowID must be positive (got \(flow))") }
        switch event.kind {
        case .accepted:
            tcpConnections += 1
            if let flow, validID {
                if !flowIDs.insert(flow).inserted { problem(prefix + "flowID \(flow) reused") }
                // Keep the first acceptance as the identity oracle even after a malformed duplicate.
                if accepted[flow] == nil { accepted[flow] = event }
            }
        case .closed:
            if let flow, validID, let opening = accepted[flow] {
                if !closed.insert(flow).inserted { problem(prefix + "flow \(flow) closed more than once") }
                if event.transport != opening.transport || event.local != opening.local || event.remote != opening.remote {
                    problem(prefix + "flow \(flow) identity differs from accepted")
                }
            } else {
                tcpConnections += 1
                problem(prefix + "closed without a preceding accepted event")
            }
            if let reason = event.endReason, !validEndReason(reason) { problem(prefix + "invalid endReason") }
            validateReceipt(event, prefix: prefix)
        case .datagram:
            udpDatagrams += 1
            if let flow, validID, !flowIDs.insert(flow).inserted { problem(prefix + "flowID \(flow) reused") }
            // The producer reads into a 64 KiB buffer and never reports more than it received.
            if let count = event.bytes, count > 64 << 10 { problem(prefix + "datagram exceeds receive buffer") }
            validateReceipt(event, prefix: prefix)
        case .started, .stopped:
            break
        }
    }

    private mutating func validateReceipt(_ event: CounterpartEvent, prefix: String) {
        if let found = event.findings {
            let encodings: Set<String> = event.kind == .datagram
                ? ["raw", "hex", "dns-qname-raw", "dns-qname-hex"] : ["raw", "hex"]
            if found.contains(where: { !encodings.contains($0.encoding) }) {
                problem(prefix + "unknown finding encoding")
            }
            if Set(found).count != found.count { problem(prefix + "duplicate findings") }
        }
        guard let count = event.bytes, count >= 0 else { return }
        if event.rawTruncated != (count > Counterpart.rawLimit) {
            problem(prefix + "rawTruncated disagrees with bytes")
        }
        if count == 0 {
            if event.rawFile != nil { problem(prefix + "rawFile on an empty receipt") }
        } else if let flow = event.flowID, let transport = event.transport, let local = event.local {
            let expected = "\(flow)-\(transport.rawValue)-\(local.port).bin"
            if event.rawFile != expected { problem(prefix + "rawFile does not match flow identity") }
        } else if event.rawFile == nil {
            problem(prefix + "missing rawFile for received bytes")
        }
    }

    mutating func finish() {
        // Bounded by the number of records, even when an input ID is Int.max.
        for flow in accepted.keys.sorted() where !closed.contains(flow) {
            problem("flow \(flow) accepted but not closed")
        }
        // IDs are allocated from 1 without gaps, but allocation and log order can differ across threads.
        if let maximum = flowIDs.max(), maximum != flowIDs.count {
            problem("flow IDs are not contiguous from 1")
        }
    }
}

private enum EventField: String, CaseIterable {
    case listeners, flowID, transport, local, remote, bytes, findings, rawFile, rawTruncated, endReason

    static func present(in event: CounterpartEvent) -> Set<Self> {
        var fields: Set<Self> = []
        if event.listeners != nil { fields.insert(.listeners) }
        if event.flowID != nil { fields.insert(.flowID) }
        if event.transport != nil { fields.insert(.transport) }
        if event.local != nil { fields.insert(.local) }
        if event.remote != nil { fields.insert(.remote) }
        if event.bytes != nil { fields.insert(.bytes) }
        if event.findings != nil { fields.insert(.findings) }
        if event.rawFile != nil { fields.insert(.rawFile) }
        if event.rawTruncated != nil { fields.insert(.rawTruncated) }
        if event.endReason != nil { fields.insert(.endReason) }
        return fields
    }
}

private extension CounterpartEvent.Kind {
    var requiredFields: Set<EventField> {
        switch self {
        case .started: [.listeners]
        case .stopped: []
        case .accepted: [.flowID, .transport, .local, .remote]
        case .closed: [.flowID, .transport, .local, .remote, .bytes, .findings, .rawTruncated, .endReason]
        case .datagram: [.flowID, .transport, .local, .remote, .bytes, .findings, .rawTruncated]
        }
    }

    var allowedFields: Set<EventField> {
        (self == .closed || self == .datagram) ? requiredFields.union([.rawFile]) : requiredFields
    }
}

private struct ListenerKey: Hashable {
    var transport: CounterpartEvent.Transport
    var port: UInt16
}

/// Parse numeric addresses without DNS/interface lookups. getnameinfo may append an IPv6 scope.
private struct NumericAddress: Hashable {
    var octets: [UInt8]
    var scope: String?

    var isUnspecified: Bool { octets.allSatisfy { $0 == 0 } }
    var isMappedIPv4: Bool {
        octets.count == 16 && octets.prefix(10).allSatisfy { $0 == 0 } && octets[10] == 255 && octets[11] == 255
    }
    var wildcard: Self { Self(octets: [UInt8](repeating: 0, count: octets.count), scope: nil) }

    private init(octets: [UInt8], scope: String?) {
        self.octets = octets
        self.scope = scope
    }

    init?(_ host: String) {
        guard !host.utf8.contains(0), host.utf8.count < Int(NI_MAXHOST) else { return nil }
        let parts = host.split(separator: "%", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        var v4 = in_addr()
        if parts.count == 1, inet_pton(AF_INET, host, &v4) == 1 {
            self.init(octets: withUnsafeBytes(of: v4) { Array($0) }, scope: nil)
            return
        }
        var v6 = in6_addr()
        guard let address = parts.first, inet_pton(AF_INET6, String(address), &v6) == 1 else { return nil }
        var scope: String?
        if parts.count == 2 {
            let suffix = parts[1]
            guard !suffix.isEmpty, suffix.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 95 || $0 == 45 || $0 == 46
            }) else { return nil }
            scope = String(suffix)
        }
        self.init(octets: withUnsafeBytes(of: v6) { Array($0) }, scope: scope)
    }
}

private func validEndReason(_ reason: String) -> Bool {
    if ["peerClosed", "counterpartStopped", "counterpartStopped (drain limit reached)"].contains(reason) { return true }
    let prefix = "read errno "
    guard reason.hasPrefix(prefix), let code = Int32(reason.dropFirst(prefix.count)), code > 0 else { return false }
    return reason == "\(prefix)\(code)"
}
