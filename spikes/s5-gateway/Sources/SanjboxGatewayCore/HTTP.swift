import Foundation

public struct HTTPRequest: Sendable {
    public let method: String
    /// Original origin-form target, including query. Never an upstream URL.
    public let target: String
    public let headers: [String: String]
    public let body: Data
    public var path: String { String(target.split(separator: "?", maxSplits: 1)[0]) }
}

public enum HTTPFailure: Error, Equatable, Sendable {
    case malformed, tooLarge, unsupportedFraming
}

/// Deliberately small HTTP/1.1 subset: one bounded request per connection, no
/// transfer coding, trailers, folded headers, upgrade or ambiguous framing.
public struct HTTPRequestDecoder: Sendable {
    public let maximumHeaderBytes: Int
    public let maximumBodyBytes: Int
    private var buffer = Data()
    private var head: (method: String, target: String, headers: [String: String], end: Int, length: Int)?
    private var finished = false

    public init(maximumHeaderBytes: Int = 16_384, maximumBodyBytes: Int = 1_048_576) {
        precondition(maximumHeaderBytes > 0 && maximumBodyBytes >= 0)
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumBodyBytes = maximumBodyBytes
    }

    public mutating func append(_ bytes: Data) throws -> HTTPRequest? {
        guard !finished else { throw HTTPFailure.malformed }
        guard bytes.count <= maximumHeaderBytes + maximumBodyBytes - buffer.count else {
            throw HTTPFailure.tooLarge
        }
        buffer.append(bytes)
        if head == nil {
            guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                guard buffer.count <= maximumHeaderBytes else { throw HTTPFailure.tooLarge }
                return nil
            }
            guard separator.upperBound <= maximumHeaderBytes else { throw HTTPFailure.tooLarge }
            let raw = buffer[..<separator.lowerBound]
            guard raw.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }) else {
                throw HTTPFailure.malformed
            }
            let lines = String(decoding: raw, as: UTF8.self).components(separatedBy: "\r\n")
            let start = lines[0].split(separator: " ", omittingEmptySubsequences: false)
            guard start.count == 3, start[2] == "HTTP/1.1",
                  Self.isToken(String(start[0])), Self.validTarget(String(start[1])) else {
                throw HTTPFailure.malformed
            }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw HTTPFailure.malformed }
                let name = String(line[..<colon]).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                guard Self.isToken(name), headers[name] == nil,
                      value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else {
                    throw HTTPFailure.malformed
                }
                headers[name] = value
            }
            guard let host = headers["host"], !host.isEmpty else { throw HTTPFailure.malformed }
            guard headers["transfer-encoding"] == nil, headers["expect"] == nil,
                  headers["upgrade"] == nil else { throw HTTPFailure.unsupportedFraming }
            if let connection = headers["connection"],
               !["close", "keep-alive"].contains(connection.lowercased()) {
                throw HTTPFailure.unsupportedFraming
            }
            let text = headers["content-length"] ?? "0"
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = Int(text) else { throw HTTPFailure.malformed }
            guard length <= maximumBodyBytes else { throw HTTPFailure.tooLarge }
            head = (String(start[0]), String(start[1]), headers, separator.upperBound, length)
        }
        guard let head else { return nil }
        guard buffer.count <= head.end + head.length else { throw HTTPFailure.malformed }
        guard buffer.count == head.end + head.length else { return nil }
        finished = true
        return HTTPRequest(method: head.method, target: head.target, headers: head.headers,
                           body: Data(buffer[head.end...]))
    }

    static func isToken(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || "!#$%&'*+-.^_`|~".utf8.contains($0)
        }
    }

    static func validTarget(_ target: String) -> Bool {
        guard target.hasPrefix("/"), !target.hasPrefix("//"),
              !target.contains("#"), !target.contains("\\"),
              target.utf8.allSatisfy({ (33...126).contains($0) }),
              let decoded = target.removingPercentEncoding,
              !decoded.contains("\\"), decoded.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }) else { return false }
        let path = decoded.split(separator: "?", maxSplits: 1)[0]
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains {
            $0 == "." || $0 == ".."
        }
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let contentType: String
    public let body: Data
    /// Local transport accepted the full response, or sending failed. Not a client receipt.
    let completion: (@Sendable (Bool) async -> Void)?

    public init(status: Int = 200, contentType: String = "application/json", body: Data,
                completion: (@Sendable (Bool) async -> Void)? = nil) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.completion = completion
    }

    public static func error(_ status: Int) -> HTTPResponse {
        HTTPResponse(status: status, body: Data("{\"error\":\(status)}\n".utf8))
    }

    func encoded() throws -> Data {
        guard (200...599).contains(status),
              !contentType.isEmpty, contentType.utf8.allSatisfy({ (32...126).contains($0) }) else {
            throw HTTPFailure.malformed
        }
        // Do not reflect request targets, credentials or handler errors in responses.
        var data = Data("HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n".utf8)
        data.append(body)
        return data
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 408: "Request Timeout"
        case 413: "Content Too Large"
        case 503: "Service Unavailable"
        default: "Response"
        }
    }
}
