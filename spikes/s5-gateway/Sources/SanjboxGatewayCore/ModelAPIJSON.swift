import Foundation

/// Small, bounded JSON value tree. Object insertion rejects duplicate decoded
/// keys (including escaped aliases); no Foundation last-key-wins interpretation.
enum ModelJSON: Sendable, Equatable {
    case object([String: ModelJSON]), array([ModelJSON]), string(String), number(String), bool(Bool), null
    var object: [String: ModelJSON]? { if case .object(let value) = self { value } else { nil } }
    var array: [ModelJSON]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var integer: Int? {
        guard case .number(let text) = self, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(text)
    }
    static func parse(_ data: Data, maximumBytes: Int) throws -> ModelJSON {
        guard data.count <= maximumBytes else { throw ModelAPIFailure.limit }
        var parser = Parser(bytes: Array(data))
        let value = try parser.read(depth: 0)
        parser.space()
        guard parser.index == parser.bytes.count else { throw ModelAPIFailure.schema }
        return value
    }
    func encoded() throws -> Data {
        func native(_ value: ModelJSON) throws -> Any {
            switch value {
            case .object(let values): return try values.mapValues(native)
            case .array(let values): return try values.map(native)
            case .string(let value): return value
            case .number(let value):
                guard let integer = Int(value) else { throw ModelAPIFailure.schema }
                return NSNumber(value: integer)
            case .bool(let value): return value
            case .null: return NSNull()
            }
        }
        return try JSONSerialization.data(withJSONObject: native(self), options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func int(_ value: Int) -> ModelJSON { .number(String(value)) }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var nodes = 0
        mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ expected: UInt8) throws {
            space()
            guard index < bytes.count, bytes[index] == expected else { throw ModelAPIFailure.schema }
            index += 1
        }
        mutating func text() throws -> String {
            space(); let begin = index; try take(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[begin..<index])) }
                if byte == 92 { index += 1 }
            }
            throw ModelAPIFailure.schema
        }
        mutating func read(depth: Int) throws -> ModelJSON {
            nodes += 1
            guard depth <= 16, nodes <= 4096 else { throw ModelAPIFailure.limit }
            if nodes % 128 == 0 { try Task.checkCancellation() }
            space()
            guard index < bytes.count else { throw ModelAPIFailure.schema }
            switch bytes[index] {
            case 123:
                index += 1; space(); var values: [String: ModelJSON] = [:]
                if index < bytes.count, bytes[index] == 125 { index += 1; return .object(values) }
                while true {
                    let key = try text()
                    guard values[key] == nil else { throw ModelAPIFailure.schema }
                    try take(58); values[key] = try read(depth: depth + 1); space()
                    guard index < bytes.count else { throw ModelAPIFailure.schema }
                    if bytes[index] == 125 { index += 1; return .object(values) }
                    try take(44)
                }
            case 91:
                index += 1; space(); var values: [ModelJSON] = []
                if index < bytes.count, bytes[index] == 93 { index += 1; return .array(values) }
                while true {
                    values.append(try read(depth: depth + 1)); space()
                    guard index < bytes.count else { throw ModelAPIFailure.schema }
                    if bytes[index] == 93 { index += 1; return .array(values) }
                    try take(44)
                }
            case 34: return .string(try text())
            default:
                let begin = index
                while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
                let literal = String(decoding: bytes[begin..<index], as: UTF8.self)
                switch literal {
                case "true": return .bool(true)
                case "false": return .bool(false)
                case "null": return .null
                default:
                    guard literal.utf8.count <= 64,
                          literal.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { throw ModelAPIFailure.schema }
                    return .number(literal)
                }
            }
        }
    }
}

func modelObject(_ value: ModelJSON?, required: Set<String>, optional: Set<String> = []) throws -> [String: ModelJSON] {
    guard let object = value?.object, required.isSubset(of: Set(object.keys)),
          Set(object.keys).isSubset(of: required.union(optional)) else { throw ModelAPIFailure.schema }
    return object
}
