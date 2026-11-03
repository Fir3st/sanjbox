import Foundation

/// Append-only JSON Lines files: canary registries and run logs.
public enum JSONLines {
    /// ISO 8601 with milliseconds (sub-millisecond precision is truncated): run protocols are
    /// ordered by these timestamps.
    public static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Encoder for one-line records. `JSONEncoder` is a reference type, so callers that need
    /// other formatting must create their own via `makeEncoder` instead of mutating this one.
    public static let encoder = makeEncoder()

    public static func makeEncoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if prettyPrinted { encoder.outputFormatting.insert(.prettyPrinted) }
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(timestampStyle))
        }
        return encoder
    }

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try timestampStyle.parse(decoder.singleValueContainer().decode(String.self))
        }
        return decoder
    }()

    /// Appends one encoded value as a line, creating the file if needed.
    public static func append<T: Encodable>(_ value: T, to url: URL) throws {
        var line = try encoder.encode(value)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { try decoder.decode(T.self, from: Data($0.utf8)) }
    }
}
