import Foundation

/// Reject ambiguous duplicate keys (including escaped equivalents) before Foundation decoding.
/// Bounded recursive syntax walk; Foundation remains the value/type decoder.
public enum StrictJSON {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try validate(data)
        return try JSONDecoder().decode(type, from: data)
    }
    public static func validate(_ data: Data) throws {
        try require(!data.isEmpty && data.count <= 32 * 1024 * 1024, "JSON size bound")
        var parser = Walker(bytes: Array(data))
        try parser.value(depth: 0); parser.space()
        try require(parser.cursor == parser.bytes.count, "trailing JSON data")
    }
    private struct Walker {
        let bytes: [UInt8]
        var cursor = 0
        mutating func space() { while cursor < bytes.count && [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 } }
        mutating func consume(_ byte: UInt8) throws {
            space(); try require(cursor < bytes.count && bytes[cursor] == byte, "invalid JSON structure"); cursor += 1
        }
        mutating func string() throws -> String {
            space(); let start = cursor
            try consume(34)
            while cursor < bytes.count {
                let byte = bytes[cursor]; cursor += 1
                if byte == 34 {
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<cursor]))
                }
                if byte == 92 { try require(cursor < bytes.count, "truncated JSON escape"); cursor += 1 }
            }
            throw InstrumentError("unterminated JSON string")
        }
        mutating func value(depth: Int) throws {
            try require(depth <= 24, "JSON nesting exceeds bound")
            space(); try require(cursor < bytes.count, "missing JSON value")
            switch bytes[cursor] {
            case 123:
                cursor += 1; space()
                if cursor < bytes.count && bytes[cursor] == 125 { cursor += 1; return }
                var keys = Set<String>()
                while true {
                    let key = try string()
                    try require(keys.insert(key).inserted, "duplicate JSON key")
                    try consume(58); try value(depth: depth + 1); space()
                    if cursor < bytes.count && bytes[cursor] == 125 { cursor += 1; return }
                    try consume(44)
                }
            case 91:
                cursor += 1; space()
                if cursor < bytes.count && bytes[cursor] == 93 { cursor += 1; return }
                while true {
                    try value(depth: depth + 1); space()
                    if cursor < bytes.count && bytes[cursor] == 93 { cursor += 1; return }
                    try consume(44)
                }
            case 34: _ = try string()
            default:
                let start = cursor
                while cursor < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[cursor]) { cursor += 1 }
                try require(cursor > start, "invalid JSON scalar")
                // Scalar syntax and numeric range are subsequently checked by JSONDecoder.
            }
        }
    }
}
