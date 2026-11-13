import Foundation

/// JSONDecoder discards duplicate keys and can round non-integral number tokens
/// into integers. Validate the original bytes before typed policy decoding.
struct PolicyJSON {
    static let maximumBytes = 65_536
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw PolicyError.malformed }
        bytes = Array(data)
    }

    mutating func check() throws {
        try value(depth: 0)
        whitespace()
        guard offset == bytes.count else { throw PolicyError.malformed }
    }

    private mutating func value(depth: Int, field: String? = nil) throws {
        guard depth <= 8 else { throw PolicyError.malformed }
        whitespace()
        guard offset < bytes.count else { throw PolicyError.malformed }
        switch bytes[offset] {
        case 123:
            offset += 1
            whitespace()
            if consume(125) { return }
            var keys = Set<String>()
            while true {
                whitespace()
                let key = try string()
                guard keys.insert(key).inserted else { throw PolicyError.malformed }
                whitespace()
                guard consume(58) else { throw PolicyError.malformed }
                try value(depth: depth + 1, field: key)
                whitespace()
                if consume(125) { return }
                guard consume(44) else { throw PolicyError.malformed }
            }
        case 91:
            offset += 1
            whitespace()
            if consume(93) { return }
            while true {
                try value(depth: depth + 1)
                whitespace()
                if consume(93) { return }
                guard consume(44) else { throw PolicyError.malformed }
            }
        case 34: _ = try string()
        case 116: try literal("true")
        case 102: try literal("false")
        case 110: try literal("null")
        case 45, 48...57:
            let start = offset
            while offset < bytes.count,
                  (48...57).contains(bytes[offset]) || [43, 45, 46, 69, 101].contains(bytes[offset]) {
                offset += 1
            }
            let token = bytes[start..<offset]
            // Only cooldownSeconds is floating point in draft v1. Typed decoding
            // still validates JSON number grammar, overflow and all field ranges.
            if field != "cooldownSeconds", !token.allSatisfy({ (48...57).contains($0) }) {
                throw PolicyError.malformed
            }
        default: throw PolicyError.malformed
        }
    }

    private mutating func string() throws -> String {
        let start = offset
        guard consume(34) else { throw PolicyError.malformed }
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if byte == 92 {
                guard offset < bytes.count else { throw PolicyError.malformed }
                offset += 1
            } else if byte == 34 {
                // Decoding keys makes "enabled" and "\u0065nabled" identical.
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
            }
        }
        throw PolicyError.malformed
    }

    private mutating func literal(_ text: String) throws {
        for byte in text.utf8 {
            guard consume(byte) else { throw PolicyError.malformed }
        }
    }

    private mutating func whitespace() {
        while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }
}
