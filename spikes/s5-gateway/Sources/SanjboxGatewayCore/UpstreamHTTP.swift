import Foundation

/// Built by a trusted typed handler after validating the operation. This is not
/// a URL API: scheme, authority headers, proxying and automatic redirects do not exist.
public struct UpstreamRequest: Sendable {
    public let hostname: String
    public let method: String
    public let target: String
    public let headers: [String: String]
    public let body: Data

    public init(hostname: String, method: String = "GET", target: String,
                headers: [String: String] = [:], body: Data = Data()) throws {
        self.hostname = try DestinationPolicy.validatedHostname(hostname)
        guard ["GET", "POST"].contains(method), HTTPRequestDecoder.validTarget(target),
              target.utf8.count <= 8_192, body.count <= 1_048_576,
              method != "GET" || body.isEmpty else { throw UpstreamFailure.invalidRequest }
        let reserved: Set<String> = ["host", "connection", "content-length", "transfer-encoding", "te", "trailer",
                                     "upgrade", "expect", "proxy-authorization", "proxy-connection", "accept-encoding"]
        var normalized: [String: String] = [:]
        for (key, value) in headers {
            let key = key.lowercased()
            guard HTTPRequestDecoder.isToken(key), !reserved.contains(key), normalized[key] == nil,
                  value.utf8.allSatisfy({ (32...126).contains($0) }) else { throw UpstreamFailure.invalidRequest }
            normalized[key] = value
        }
        guard normalized.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count + 4 }) <= 8_192 else {
            throw UpstreamFailure.invalidRequest
        }
        self.method = method
        self.target = target
        self.headers = normalized
        self.body = body
    }

    func encoded() -> Data {
        var text = "\(method) \(target) HTTP/1.1\r\nHost: \(hostname)\r\nConnection: close\r\nAccept-Encoding: identity\r\nContent-Length: \(body.count)\r\n"
        for key in headers.keys.sorted() { text += "\(key): \(headers[key]!)\r\n" }
        var wire = Data((text + "\r\n").utf8)
        wire.append(body)
        return wire
    }
}

public struct UpstreamResponseHead: Sendable, Equatable {
    public let status: Int
    /// Metadata for policy decisions only; never blindly forward these headers.
    /// In particular Location does not grant permission to follow a redirect.
    public let headers: [String: String]
}

public struct UpstreamResponse: Sendable {
    public let head: UpstreamResponseHead
    public let body: Data
}

/// One final HTTP/1.1 response, explicit CL or chunked framing, no compression,
/// upgrade, trailers, informational responses or close-delimited success. Body
/// fragments are delivered as they arrive rather than retained inside the parser.
public struct UpstreamResponseDecoder: Sendable {
    private enum State: Sendable { case head, fixed(Int), size, chunk(Int), chunkEnd, trailer, done }
    public let maximumHeaderBytes: Int
    public let maximumBodyBytes: Int
    private var state = State.head
    private var buffer = Data()
    private var bodyBytes = 0
    private var framingBytes = 0
    public private(set) var head: UpstreamResponseHead?
    public var isComplete: Bool { if case .done = state { true } else { false } }

    public init(maximumHeaderBytes: Int = 16_384, maximumBodyBytes: Int = 4_194_304) {
        precondition(maximumHeaderBytes > 0 && maximumBodyBytes >= 0)
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumBodyBytes = maximumBodyBytes
    }

    /// The caller must cap each input read. This cap also bounds the returned batch.
    public mutating func append(_ bytes: Data) throws -> [Data] {
        guard bytes.count <= 16_384 else { throw HTTPFailure.tooLarge }
        if isComplete {
            guard bytes.isEmpty else { throw UpstreamFailure.malformedResponse }
            return []
        }
        buffer.append(bytes)
        var chunks: [Data] = []
        while true {
            switch state {
            case .head:
                guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    guard buffer.count <= maximumHeaderBytes else { throw HTTPFailure.tooLarge }
                    return chunks
                }
                guard separator.upperBound - buffer.startIndex <= maximumHeaderBytes else { throw HTTPFailure.tooLarge }
                let raw = Data(buffer[..<separator.lowerBound])
                consume(separator.upperBound - buffer.startIndex)
                let parsed = try parseHead(raw)
                head = parsed
                if parsed.status == 204 || parsed.status == 304 {
                    guard parsed.headers["transfer-encoding"] == nil,
                          parsed.headers["content-length"] == nil || parsed.headers["content-length"] == "0" else {
                        throw UpstreamFailure.unsupportedResponse
                    }
                    state = .done
                } else if let coding = parsed.headers["transfer-encoding"] {
                    guard coding.lowercased() == "chunked", parsed.headers["content-length"] == nil else {
                        throw UpstreamFailure.unsupportedResponse
                    }
                    state = .size
                } else {
                    guard let text = parsed.headers["content-length"], !text.isEmpty,
                          text.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(text) else {
                        throw UpstreamFailure.unsupportedResponse
                    }
                    guard length <= maximumBodyBytes else { throw HTTPFailure.tooLarge }
                    state = length == 0 ? .done : .fixed(length)
                }
            case .fixed(let remaining), .chunk(let remaining):
                guard !buffer.isEmpty else { return chunks }
                let count = min(remaining, buffer.count)
                guard count <= maximumBodyBytes - bodyBytes else { throw HTTPFailure.tooLarge }
                chunks.append(Data(buffer.prefix(count)))
                consume(count)
                bodyBytes += count
                switch state {
                case .fixed: state = count == remaining ? .done : .fixed(remaining - count)
                default: state = count == remaining ? .chunkEnd : .chunk(remaining - count)
                }
            case .size:
                guard let line = try framingLine() else { return chunks }
                // A strict subset deliberately rejects extensions (not needed by
                // the initial typed upstreams) instead of interpreting opaque metadata.
                guard !line.isEmpty, line.count <= 16,
                      line.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                      let size = Int(line, radix: 16) else { throw UpstreamFailure.malformedResponse }
                guard size <= maximumBodyBytes - bodyBytes else { throw HTTPFailure.tooLarge }
                state = size == 0 ? .trailer : .chunk(size)
            case .chunkEnd:
                guard buffer.count >= 2 else { return chunks }
                guard buffer.prefix(2) == Data("\r\n".utf8) else { throw UpstreamFailure.malformedResponse }
                consume(2)
                state = .size
            case .trailer:
                guard let line = try framingLine() else { return chunks }
                guard line.isEmpty else { throw UpstreamFailure.unsupportedResponse }
                state = .done
            case .done:
                guard buffer.isEmpty else { throw UpstreamFailure.malformedResponse }
                return chunks
            }
        }
    }

    public func finish() throws {
        guard isComplete else { throw UpstreamFailure.truncatedResponse }
    }

    private mutating func consume(_ count: Int) { buffer = Data(buffer.dropFirst(count)) }

    private mutating func framingLine() throws -> String? {
        guard let end = buffer.range(of: Data("\r\n".utf8)) else {
            guard buffer.count <= 128 else { throw HTTPFailure.tooLarge }
            return nil
        }
        let count = end.upperBound - buffer.startIndex
        // Bound framing separately: millions of tiny/empty chunks cannot bypass
        // body limits. The allowance grows with payload but has a fixed ceiling.
        guard count <= maximumHeaderBytes + min(maximumBodyBytes, 1_048_576) - framingBytes else {
            throw HTTPFailure.tooLarge
        }
        framingBytes += count
        let line = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        consume(count)
        return line
    }

    private func parseHead(_ data: Data) throws -> UpstreamResponseHead {
        guard data.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }) else {
            throw UpstreamFailure.malformedResponse
        }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard start.count == 3, start[0] == "HTTP/1.1", start[1].count == 3,
              start[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let status = Int(start[1]), (200...599).contains(status),
              start[2].utf8.allSatisfy({ (32...126).contains($0) }) else { throw UpstreamFailure.malformedResponse }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw UpstreamFailure.malformedResponse }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard HTTPRequestDecoder.isToken(name), headers[name] == nil,
                  value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else {
                throw UpstreamFailure.malformedResponse
            }
            headers[name] = value
        }
        guard headers["upgrade"] == nil, headers["trailer"] == nil,
              headers["content-encoding"] == nil || headers["content-encoding"]?.lowercased() == "identity",
              headers["connection"] == nil || ["close", "keep-alive"].contains(headers["connection"]!.lowercased()) else {
            throw UpstreamFailure.unsupportedResponse
        }
        return UpstreamResponseHead(status: status, headers: headers)
    }
}
