import Foundation

/// Small bounded JSON recognizer used BEFORE JSONDecoder. Identity files must not have
/// duplicate decoded keys, unknown fields, float/coerced numbers, or ambiguous booleans.
private indirect enum Node {
    case object([String: Node]), array([Node]), string, integer, boolean, null
}

private struct Parser {
    let bytes: [UInt8]
    var offset = 0
    mutating func whitespace() { while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
    mutating func take(_ byte: UInt8) -> Bool {
        whitespace()
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1; return true
    }
    mutating func string() throws -> String {
        whitespace(); let start = offset
        guard take(34) else { throw S8Error.refused("JSON string required") }
        var escaped = false
        while offset < bytes.count && offset - start <= 1024 {
            let b = bytes[offset]; offset += 1
            if b == 34 && !escaped {
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
            }
            if b == 92 && !escaped { escaped = true } else { escaped = false }
        }
        throw S8Error.refused("unterminated or excessive JSON string")
    }
    mutating func value(depth: Int = 0) throws -> Node {
        guard depth <= 4 else { throw S8Error.refused("JSON nesting limit") }
        whitespace()
        guard offset < bytes.count else { throw S8Error.refused("missing JSON value") }
        if take(123) {
            var values: [String: Node] = [:]
            if take(125) { return .object(values) }
            repeat {
                let key = try string()
                guard values[key] == nil, values.count < 24, take(58) else { throw S8Error.refused("duplicate/extra JSON key or missing colon") }
                values[key] = try value(depth: depth + 1)
                if take(125) { return .object(values) }
                guard take(44) else { throw S8Error.refused("JSON object separator") }
            } while true
        }
        if take(91) {
            var values: [Node] = []
            if take(93) { return .array(values) }
            repeat {
                guard values.count < 256 else { throw S8Error.refused("JSON array bound") }
                values.append(try value(depth: depth + 1))
                if take(93) { return .array(values) }
                guard take(44) else { throw S8Error.refused("JSON array separator") }
            } while true
        }
        if bytes[offset] == 34 { _ = try string(); return .string }
        for (literal, node): (String, Node) in [("true", .boolean), ("false", .boolean), ("null", .null)] {
            let word = Array(literal.utf8)
            if bytes[offset...].starts(with: word) { offset += word.count; return node }
        }
        let start = offset
        while offset < bytes.count && (48...57).contains(bytes[offset]) { offset += 1 }
        guard offset > start, offset - start <= 10,
              offset - start == 1 || bytes[start] != 48 else { throw S8Error.refused("unsigned decimal JSON integer required") }
        return .integer
    }
}

public func decodeExpectation(_ data: Data) throws -> S8Expectation {
    guard data.count <= 16_384, String(data: data, encoding: .utf8) != nil else { throw S8Error.refused("expectation byte/UTF8 bound") }
    var parser = Parser(bytes: Array(data))
    guard case .object(let object) = try parser.value() else { throw S8Error.refused("expectation object required") }
    parser.whitespace()
    guard parser.offset == parser.bytes.count else { throw S8Error.refused("trailing JSON or noninteger number") }
    let integers = ["realUID", "effectiveUID", "realGID", "effectiveGID", "auditSessionID", "auditUID", "launchdManagerUID"]
    let strings = ["userName", "launchdManagerName"]
    let arrays = ["kernelGroups", "requiredGroups", "forbiddenGroups"]
    let keys = Set(integers + strings + arrays + ["windowSession", "requiresWindowSession"])
    guard Set(object.keys) == keys else { throw S8Error.refused("missing or unknown expectation key") }
    for key in integers { guard case .integer = object[key] else { throw S8Error.refused("integer required for \(key)") } }
    for key in strings { guard case .string = object[key] else { throw S8Error.refused("string required for \(key)") } }
    for key in arrays {
        guard case .array(let list) = object[key] else { throw S8Error.refused("group array required") }
        for item in list { guard case .integer = item else { throw S8Error.refused("group integer required") } }
    }
    guard case .boolean = object["requiresWindowSession"] else { throw S8Error.refused("boolean required") }
    if case .object(let window) = object["windowSession"] {
        guard Set(window.keys) == ["userID", "userName", "auditSessionID", "onConsole", "loginDone"],
              case .integer = window["userID"], case .integer = window["auditSessionID"],
              case .string = window["userName"], case .boolean = window["onConsole"], case .boolean = window["loginDone"] else {
            throw S8Error.refused("complete typed window expectation required")
        }
    } else if case .null = object["windowSession"] { /* explicitly absent */ }
    else { throw S8Error.refused("window expectation must be object or explicit null") }
    return try JSONDecoder().decode(S8Expectation.self, from: data)
}

public func readExpectation(_ path: String) throws -> S8Expectation {
    let prefix = "/private/tmp/sanjbox-s8-inputs-"
    let suffix = "/s8-expectation.json"
    guard path.hasPrefix(prefix), path.hasSuffix(suffix),
          UUID(uuidString: String(path.dropFirst(prefix.count).dropLast(suffix.count))) != nil else {
        throw S8Error.refused("expectation must be own /private/tmp/sanjbox-s8-inputs-UUID/s8-expectation.json")
    }
    try requireOwnedDirectory(String(path.dropLast(suffix.count)))
    return try decodeExpectation(readOwnedFile(path, maximum: 16_384))
}
