import Foundation

public struct IngressError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

indirect enum Shape: Sendable {
    case scalar, array(Shape), object([String: Shape])
    func check(_ value: Any, at path: String = "$") throws {
        if value is NSNull { return } // Codable decides whether null is permitted.
        switch self {
        case .scalar:
            guard !(value is [String: Any]), !(value is [Any]) else { throw IngressError("non-scalar at \(path)") }
        case .array(let item):
            guard let values = value as? [Any], values.count <= 256 else { throw IngressError("invalid array at \(path)") }
            for value in values { try item.check(value, at: path + "[]") }
        case .object(let keys):
            guard let object = value as? [String: Any] else { throw IngressError("expected object at \(path)") }
            for (key, value) in object {
                guard let shape = keys[key] else { throw IngressError("unknown key \(path).\(key)") }
                try shape.check(value, at: path + "." + key)
            }
        }
    }
}

/// Reject duplicate keys before Foundation's decoder can silently collapse them.
/// JSONSerialization subsequently checks the complete JSON grammar and numeric syntax.
private struct DuplicateScanner {
    let bytes: [UInt8]
    var index = 0
    mutating func whitespace() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
    mutating func string() throws -> String {
        let start = index
        guard index < bytes.count && bytes[index] == 34 else { throw IngressError("expected JSON string") }
        index += 1
        while index < bytes.count {
            if bytes[index] == 92 { index += 2; continue }
            if bytes[index] == 34 {
                index += 1
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            }
            index += 1
        }
        throw IngressError("unterminated JSON string")
    }
    mutating func value(depth: Int = 0) throws {
        guard depth < 24 else { throw IngressError("JSON nesting limit") }
        whitespace()
        guard index < bytes.count else { throw IngressError("missing JSON value") }
        switch bytes[index] {
        case 34: _ = try string()
        case 123, 91:
            let object = bytes[index] == 123
            let end: UInt8 = object ? 125 : 93
            index += 1; whitespace()
            if index < bytes.count && bytes[index] == end { index += 1; return }
            var keys = Set<String>(); var count = 0
            while true {
                count += 1
                guard count <= 256 else { throw IngressError("JSON collection limit") }
                if object {
                    let key = try string()
                    guard keys.insert(key).inserted else { throw IngressError("duplicate JSON key") }
                    whitespace()
                    guard index < bytes.count && bytes[index] == 58 else { throw IngressError("missing colon") }
                    index += 1
                }
                try value(depth: depth + 1); whitespace()
                guard index < bytes.count else { throw IngressError("unterminated collection") }
                if bytes[index] == end { index += 1; return }
                guard bytes[index] == 44 else { throw IngressError("missing comma") }
                index += 1; whitespace()
            }
        default:
            let start = index
            while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw IngressError("invalid JSON value") }
        }
    }
}

func strictDecode<T: Decodable>(_ type: T.Type, data: Data, shape: Shape) throws -> T {
    guard !data.isEmpty, data.count <= 1_048_576 else { throw IngressError("JSON size limit (1 MiB)") }
    var scanner = DuplicateScanner(bytes: Array(data))
    try scanner.value(); scanner.whitespace()
    guard scanner.index == scanner.bytes.count else { throw IngressError("trailing JSON input") }
    try shape.check(JSONSerialization.jsonObject(with: data))
    return try JSONDecoder().decode(type, from: data)
}

public func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(value)
}
