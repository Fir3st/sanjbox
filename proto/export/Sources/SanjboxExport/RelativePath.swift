import Foundation

/// Kódované jméno souboru nebo adresáře uvnitř kořene exportu.
///
/// Cesta se nikdy nebere jako syrový řetězec pro `open(2)`. Rozpadne se na komponenty
/// a každá komponenta se otevírá zvlášť relativně k už otevřenému fd rodiče.
public struct RelativePath: Hashable, Sendable, CustomStringConvertible {
    public let components: [String]

    public var path: String { components.joined(separator: "/") }
    public var description: String { path }

    public init?(components: [String]) {
        guard !components.isEmpty else { return nil }
        self.components = components
    }

    /// Rozbor vstupní cesty. Odmítne absolutní cesty, `..` a prázdné jméno.
    /// `""` a `.` znamenají kořen, a ten exportovat nelze.
    public static func parse(_ raw: String) -> Result<RelativePath, PathParseError> {
        guard !raw.isEmpty else { return .failure(.empty) }
        guard !raw.hasPrefix("/") else { return .failure(.absolute) }
        guard !raw.utf8.contains(0) else { return .failure(.nulByte) }

        var components: [String] = []
        for component in raw.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { return .failure(.parentComponent) }
            components.append(String(component))
        }
        guard !components.isEmpty, let parsed = RelativePath(components: components) else {
            return .failure(.empty)
        }
        return .success(parsed)
    }
}

public enum PathParseError: Error, Equatable, Sendable {
    case empty
    case absolute
    case parentComponent
    case nulByte

    /// Text pro audit. Neobsahuje vstupní cestu — ta je v záznamu zvlášť.
    public var detail: String {
        switch self {
        case .empty: return "empty path"
        case .absolute: return "absolute path escapes the export root"
        case .parentComponent: return "path with '..' escapes the export root"
        case .nulByte: return "path contains a NUL byte"
        }
    }
}

extension Array where Element == String {
    /// Porovnání v UTF-8 bajtovém pořadí. `String.<` je pořadí podle Unicode a pro
    /// stabilní řazení auditu se nehodí.
    static func isOrderedBefore(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.joined(separator: "/").utf8.lexicographicallyPrecedes(rhs.joined(separator: "/").utf8)
    }
}
