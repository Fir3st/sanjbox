import Foundation

/// Proč byla položka přijata, nebo odmítnuta. Stabilní množina kódů pro audit.
public enum SelectionReason: String, Codable, Sendable, CaseIterable {
    /// Soubor je regulérní, unikátní a leží uvnitř kořene.
    case accepted
    /// Cesta je absolutní nebo obsahuje `..`; mimo kořen se nesahe.
    case outsideRoot
    /// Cesta není použitelné relativní jméno (prázdná, s NUL bajtem).
    case invalidPath
    /// Cesta neexistuje.
    case missing
    /// Cesta nebo některá komponenta je symbolický odkaz.
    case symlink
    /// `st_nlink > 1` — tvrdý odkaz. Data nejsou jen v oblasti a kopie by je sdílela.
    case hardlink
    /// FIFO, socket, znakové nebo blokové zařízení.
    case specialFile
    /// Adresář nebo jiný než regulérní soubor.
    case notRegularFile
    /// Jiná I/O chyba (práva, neplatná komponenta, neklasifikovaný `errno`).
    case ioError
}

/// Jedno rozhodnutí o jedné cestě. `snapshot` je vyplněný jen tam, kde ho preview skutečně vidělo.
public struct Candidate: Codable, Sendable, Equatable {
    public let relativePath: String
    public let accepted: Bool
    public let reason: SelectionReason
    public let detail: String?
    public let snapshot: FileSnapshot?

    public init(
        relativePath: String,
        accepted: Bool,
        reason: SelectionReason,
        detail: String? = nil,
        snapshot: FileSnapshot? = nil
    ) {
        self.relativePath = relativePath
        self.accepted = accepted
        self.reason = reason
        self.detail = detail
        self.snapshot = snapshot
    }
}

/// Výsledek fáze preview: co by se zkopírovalo a co ne. Preview nikdy nezapisuje.
public struct ExportPlan: Codable, Sendable, Equatable {
    /// Kanonická cesta kořene, vůči které se relativní cesty vyhodnocují.
    public let root: String
    /// Kandidáti seřazení podle UTF-8 bajtů cesty. Pořadí je součástí kontraktu auditu.
    public let candidates: [Candidate]

    public init(root: String, candidates: [Candidate]) {
        self.root = root
        self.candidates = candidates.sorted { lhs, rhs in
            lhs.relativePath.utf8.lexicographicallyPrecedes(rhs.relativePath.utf8)
        }
    }

    public var accepted: [Candidate] { candidates.filter(\.accepted) }
    public var rejected: [Candidate] { candidates.filter { !$0.accepted } }
    public var isClean: Bool { rejected.isEmpty }
    public var rejectedPaths: [String] { rejected.map(\.relativePath) }

    /// Deterministický JSON plánu (3. část auditu: preview). Používá se i pro `--dry-run` výstup.
    public func jsonData() throws -> Data {
        try ExportJSON.encoder().encode(self)
    }

    public func jsonString() throws -> String {
        String(decoding: try jsonData(), as: UTF8.self)
    }
}

enum ExportJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }
}
