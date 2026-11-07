import Foundation

/// Bounded JSON preflight: rejects duplicate decoded object keys, excessive nesting/arrays and
/// trailing bytes before either Foundation decoder can pick a value. It does not replace the
/// grammar/type checks of `JSONDecoder`; it closes the gaps `JSONDecoder` leaves open.
struct JSONPreflight {
    private let bytes: [UInt8]
    private let limit: Int
    private var offset = 0

    init(_ data: Data, limit: Int) throws {
        guard !data.isEmpty else { throw ContractError.invalidJSON("empty input") }
        guard data.count <= limit else { throw ContractError.inputTooLarge("\(data.count) > \(limit)") }
        bytes = Array(data)
        self.limit = limit
    }

    mutating func check() throws {
        try value(depth: 0)
        whitespace()
        guard offset == bytes.count else { throw ContractError("trailing-input", "\(bytes.count - offset) trailing bytes") }
    }

    private mutating func value(depth: Int) throws {
        guard depth <= 16 else { throw ContractError("nesting-limit", "depth \(depth)") }
        whitespace()
        guard offset < bytes.count else { throw ContractError.invalidJSON("unexpected end") }
        switch bytes[offset] {
        case 123: // {
            offset += 1
            whitespace()
            if consume(125) { return }
            var keys = Set<String>()
            while true {
                whitespace()
                let key = try string()
                guard keys.insert(key).inserted else { throw ContractError("duplicate-key", key) }
                guard keys.count <= 128 else { throw ContractError("collection-limit", "object field count") }
                whitespace()
                guard consume(58) else { throw ContractError.invalidJSON("missing colon") }
                try value(depth: depth + 1)
                whitespace()
                if consume(125) { return }
                guard consume(44) else { throw ContractError.invalidJSON("missing object separator") }
            }
        case 91: // [
            offset += 1
            whitespace()
            if consume(93) { return }
            var count = 0
            while true {
                count += 1
                guard count <= 128 else { throw ContractError("collection-limit", "array element count") }
                try value(depth: depth + 1)
                whitespace()
                if consume(93) { return }
                guard consume(44) else { throw ContractError.invalidJSON("missing array separator") }
            }
        case 34: _ = try string()
        case 116: try literal("true")
        case 102: try literal("false")
        case 110: try literal("null")
        case 45, 48...57:
            // Number grammar and integer width are checked by JSONDecoder afterwards; the shape
            // check bounds declared byte counts before that.
            while offset < bytes.count, [43, 45, 46, 69, 101].contains(bytes[offset]) || (48...57).contains(bytes[offset]) {
                offset += 1
            }
        default: throw ContractError.invalidJSON("invalid value at byte \(offset)")
        }
    }

    private mutating func string() throws -> String {
        let start = offset
        guard consume(34) else { throw ContractError.invalidJSON("expected string") }
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if byte == 92 {
                guard offset < bytes.count else { throw ContractError.invalidJSON("unterminated escape") }
                offset += 1
            } else if byte == 34 {
                let decoded: String
                do { decoded = try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) }
                catch { throw ContractError.invalidJSON("invalid string") }
                guard decoded.utf8.count <= 4096 else { throw ContractError("string-limit", "\(decoded.utf8.count) > 4096") }
                return decoded
            }
        }
        throw ContractError.invalidJSON("unterminated string")
    }

    private mutating func literal(_ text: String) throws {
        let expected = Array(text.utf8)
        guard offset + expected.count <= bytes.count,
              Array(bytes[offset..<(offset + expected.count)]) == expected else {
            throw ContractError.invalidJSON("invalid literal")
        }
        offset += expected.count
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

/// Closed key set for one object. Every decoding entry point in this package names its keys
/// explicitly, so an unknown or misspelled field is a rejection, not a silently ignored value.
indirect enum Shape: Sendable {
    case scalar(maxBytes: Int)
    case optionalScalar(maxBytes: Int)
    case integer(minimum: UInt64, maximum: UInt64)
    case optionalInteger(minimum: UInt64, maximum: UInt64)
    case object([String: Shape])
    case array(Shape, max: Int)

    func check(_ value: Any, path: String, depth: Int = 0) throws {
        guard depth <= 16 else { throw ContractError("nesting-limit", path) }
        switch self {
        case .scalar(let maxBytes):
            guard !(value is NSNull) else { throw ContractError.invalidValue(path) }
            try Self.checkScalar(value, path: path, maxBytes: maxBytes)
        case .optionalScalar(let maxBytes):
            if value is NSNull { return }
            try Self.checkScalar(value, path: path, maxBytes: maxBytes)
        case .integer(let minimum, let maximum):
            guard !(value is NSNull), Self.checkInteger(value, minimum: minimum, maximum: maximum) else {
                throw ContractError.invalidRange(path)
            }
        case .optionalInteger(let minimum, let maximum):
            if value is NSNull { return }
            guard Self.checkInteger(value, minimum: minimum, maximum: maximum) else {
                throw ContractError.invalidRange(path)
            }
        case .object(let fields):
            guard let object = value as? [String: Any] else { throw ContractError.invalidValue(path) }
            for (key, child) in object {
                guard let childShape = fields[key] else { throw ContractError.unknownField("\(path).\(key)") }
                try childShape.check(child, path: "\(path).\(key)", depth: depth + 1)
            }
            for (key, childShape) in fields {
                switch childShape {
                case .optionalScalar, .optionalInteger: continue
                default: break
                }
                guard object[key] != nil else { throw ContractError.missingField("\(path).\(key)") }
            }
        case .array(let element, let max):
            guard let array = value as? [Any] else { throw ContractError.invalidValue(path) }
            guard array.count <= max else { throw ContractError("collection-limit", "\(path): \(array.count) > \(max)") }
            for (index, child) in array.enumerated() {
                try element.check(child, path: "\(path)[\(index)]", depth: depth + 1)
            }
        }
    }

    private static func checkScalar(_ value: Any, path: String, maxBytes: Int) throws {
        if let string = value as? String {
            guard string.utf8.count <= maxBytes else { throw ContractError("string-limit", "\(path): \(string.utf8.count) > \(maxBytes)") }
            return
        }
        // Reject nested containers in scalar positions; text tokens keep the value type check to
        // JSONDecoder, which refuses booleans/numbers where a String is declared.
        guard !(value is [String: Any]), !(value is [Any]) else { throw ContractError.invalidValue(path) }
    }

    private static func checkInteger(_ value: Any, minimum: UInt64, maximum: UInt64) -> Bool {
        guard let number = value as? NSNumber else { return false }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded() else { return false }
        guard double >= 0, double <= Double(maximum) else { return false }
        // Doubles are exact up to 2^53; every documented range in this contract is below that.
        guard maximum < (1 << 53) else { return false }
        let integer = UInt64(double)
        return integer >= minimum && integer <= maximum
    }
}

enum StrictJSON {
    /// Preflight (duplicate keys, size, nesting) → closed key set → typed `Decodable`.
    static func decode<T: Decodable>(_ data: Data, shape: Shape, limit: Int, as type: T.Type) throws -> T {
        var preflight = try JSONPreflight(data, limit: limit)
        try preflight.check()
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ContractError.invalidJSON("grammar")
        }
        try shape.check(any, path: "$")
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as DecodingError {
            throw ContractError.invalidValue(Self.describe(error))
        } catch {
            throw ContractError.invalidValue("typed decode")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context): return "dataCorrupted/\(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .keyNotFound(let key, _): return "keyNotFound/\(key.stringValue)"
        case .typeMismatch(_, let context): return "typeMismatch/\(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .valueNotFound(_, let context): return "valueNotFound/\(context.codingPath.map(\.stringValue).joined(separator: "."))"
        @unknown default: return "unknown"
        }
    }
}
