import Foundation
import SanjboxProbeKit

/// One line of the counterpart's event log. Flat with optional fields so the log stays easy to
/// read and filter; which fields are set depends on `kind`.
public struct CounterpartEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// All listeners are bound; nothing received before this line was observed.
        case started
        /// A TCP connection reached the counterpart; recorded before any byte is read.
        case accepted
        case closed
        case datagram
        /// Every flow was drained and closed; written last, only on an orderly stop.
        case stopped
    }

    public enum Transport: String, Codable, Sendable {
        case tcp, udp
    }

    public var timestamp: Date
    public var kind: Kind
    /// Bound listeners (`started`).
    public var listeners: [Listener]?
    /// Ties `accepted` to `closed` and names the raw capture file.
    public var flowID: Int?
    public var transport: Transport?
    public var local: Endpoint?
    public var remote: Endpoint?
    /// Bytes received in the flow (`closed`, `datagram`).
    public var bytes: Int?
    public var findings: [CanaryScanner.Finding]?
    /// Raw capture file name inside the raw directory; absent when no byte arrived.
    public var rawFile: String?
    /// The raw capture stopped at `Counterpart.rawLimit`; `bytes` and `findings` still cover everything.
    public var rawTruncated: Bool?
    /// Why a TCP flow ended: `peerClosed`, `counterpartStopped`, or an errno.
    public var endReason: String?

    public init(
        timestamp: Date = Date(), kind: Kind, listeners: [Listener]? = nil, flowID: Int? = nil,
        transport: Transport? = nil, local: Endpoint? = nil, remote: Endpoint? = nil, bytes: Int? = nil,
        findings: [CanaryScanner.Finding]? = nil, rawFile: String? = nil, rawTruncated: Bool? = nil,
        endReason: String? = nil
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.listeners = listeners
        self.flowID = flowID
        self.transport = transport
        self.local = local
        self.remote = remote
        self.bytes = bytes
        self.findings = findings
        self.rawFile = rawFile
        self.rawTruncated = rawTruncated
        self.endReason = endReason
    }
}

public struct Endpoint: Codable, Hashable, Sendable, CustomStringConvertible {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

public struct Listener: Codable, Equatable, Sendable {
    public var transport: CounterpartEvent.Transport
    public var endpoint: Endpoint
}
