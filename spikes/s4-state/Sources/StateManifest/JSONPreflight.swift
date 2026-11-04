import Foundation

/// Rejects duplicate decoded object keys before either Foundation decoder can select a value.
/// This does not replace JSONDecoder's grammar/type checks; it bounds nesting, arrays and strings.
struct JSONPreflight {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 256 * 1024 else { throw ManifestError("JSON input byte limit exceeded") }
        bytes = Array(data)
    }

    mutating func check() throws {
        try value(depth: 0)
        whitespace()
        guard offset == bytes.count else { throw ManifestError("trailing JSON input") }
    }

    private mutating func value(depth: Int) throws {
        guard depth <= 16 else { throw ManifestError("JSON nesting limit exceeded") }
        whitespace()
        guard offset < bytes.count else { throw ManifestError("unexpected JSON end") }
        switch bytes[offset] {
        case 123: // object
            offset += 1
            whitespace()
            if consume(125) { return }
            var keys = Set<String>()
            while true {
                whitespace()
                let key = try string()
                guard keys.insert(key).inserted else { throw ManifestError("duplicate decoded JSON key") }
                guard keys.count <= 128 else { throw ManifestError("JSON object field limit exceeded") }
                whitespace()
                guard consume(58) else { throw ManifestError("missing JSON colon") }
                try value(depth: depth + 1)
                whitespace()
                if consume(125) { return }
                guard consume(44) else { throw ManifestError("missing JSON object separator") }
            }
        case 91: // array
            offset += 1
            whitespace()
            if consume(93) { return }
            var count = 0
            while true {
                count += 1
                guard count <= 128 else { throw ManifestError("JSON array limit exceeded") }
                try value(depth: depth + 1)
                whitespace()
                if consume(93) { return }
                guard consume(44) else { throw ManifestError("missing JSON array separator") }
            }
        case 34: _ = try string()
        case 116: try literal("true")
        case 102: try literal("false")
        case 110: try literal("null")
        case 45, 48...57:
            // Full JSON number syntax and integer range are checked by JSONDecoder afterward.
            while offset < bytes.count && ([43, 45, 46, 69, 101].contains(bytes[offset]) || (48...57).contains(bytes[offset])) { offset += 1 }
        default: throw ManifestError("invalid JSON value")
        }
    }

    private mutating func string() throws -> String {
        let start = offset
        guard consume(34) else { throw ManifestError("expected JSON string") }
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if byte == 92 { // Skip one escaped byte here; JSONDecoder validates \u and all escape syntax.
                guard offset < bytes.count else { throw ManifestError("unterminated JSON escape") }
                offset += 1
            } else if byte == 34 {
                let decoded: String
                do { decoded = try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) }
                catch { throw ManifestError("invalid JSON string") }
                guard decoded.utf8.count <= 4096 else { throw ManifestError("JSON decoded string limit exceeded") }
                return decoded
            }
        }
        throw ManifestError("unterminated JSON string")
    }

    private mutating func literal(_ text: String) throws {
        let expected = Array(text.utf8)
        guard offset + expected.count <= bytes.count,
              Array(bytes[offset..<(offset + expected.count)]) == expected else { throw ManifestError("invalid JSON literal") }
        offset += expected.count
    }

    private mutating func whitespace() {
        while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }
}
