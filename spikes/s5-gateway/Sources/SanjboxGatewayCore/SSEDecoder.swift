import Foundation

/// Incremental UTF-8 SSE, including BOM, CR/LF/CRLF, comments and sticky event IDs.
/// No automatic reconnect, Last-Event-ID request or retry scheduling is performed.
public struct SSEDecoder: Sendable {
    public let maximumEventBytes: Int
    private var line = Data()
    private var eventBytes = 0
    private var dataLines: [String] = []
    private var event: String?
    private var lastID: String?
    private var firstLine = true
    private var skipLF = false

    public init(maximumEventBytes: Int = 65_536) {
        precondition(maximumEventBytes > 0)
        self.maximumEventBytes = maximumEventBytes
    }

    public mutating func append(_ bytes: Data) throws -> [SSEEvent] {
        guard bytes.count <= 16_384 else { throw HTTPFailure.tooLarge }
        var result: [SSEEvent] = []
        for byte in bytes {
            if skipLF {
                skipLF = false
                if byte == 10 { continue }
            }
            eventBytes += 1
            guard eventBytes <= maximumEventBytes else { throw HTTPFailure.tooLarge }
            if byte == 10 || byte == 13 {
                if let next = try completeLine() { result.append(next) }
                skipLF = byte == 13
            } else { line.append(byte) }
        }
        return result
    }

    /// Reject an unfinished final event. A typed API handler must separately
    /// enforce its provider's completion marker if semantic completion is required.
    public func finish() throws {
        guard line.isEmpty && dataLines.isEmpty && event == nil else { throw UpstreamFailure.truncatedResponse }
    }

    private mutating func completeLine() throws -> SSEEvent? {
        guard var text = String(data: line, encoding: .utf8) else { throw UpstreamFailure.unexpectedSSE }
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if text.hasPrefix("\u{feff}") { text.removeFirst() }
        }
        if text.isEmpty {
            defer { dataLines.removeAll(keepingCapacity: true); event = nil; eventBytes = 0 }
            guard !dataLines.isEmpty else { return nil }
            return SSEEvent(data: dataLines.joined(separator: "\n"), event: event, id: lastID)
        }
        if text.hasPrefix(":") { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch parts[0] {
        case "data": dataLines.append(value)
        case "event": event = value.isEmpty ? nil : value
        case "id": if !value.contains("\0") { lastID = value }
        default: break // retry and unknown fields do not grant any network action.
        }
        return nil
    }
}
