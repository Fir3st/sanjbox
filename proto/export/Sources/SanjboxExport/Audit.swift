import Foundation

/// Fáze, ve které rozhodnutí vzniklo.
public enum AuditPhase: String, Codable, Sendable, CaseIterable {
    /// Rozhodnutí ze selekce/preview.
    case preview
    /// Rozhodnutí z kopie.
    case copy

    var rank: Int {
        switch self {
        case .preview: return 0
        case .copy: return 1
        }
    }
}

public enum AuditDecision: String, Codable, Sendable {
    case accept
    case reject
}

/// Jeden záznam auditu. Neobsahuje čas ani cestu k domovskému adresáři volajícího;
/// obojí doplní konsolidace s formátem z WP1.H1.
public struct AuditRecord: Codable, Sendable, Equatable {
    public let scheme: String
    public let phase: AuditPhase
    public let sequence: Int
    public let relativePath: String
    public let decision: AuditDecision
    public let reason: SelectionReason
    public let detail: String?
    public let size: Int64?
    public let mode: UInt16?
    public let device: UInt64?
    public let inode: UInt64?
    public let linkCount: UInt64?
    public let destination: String?
    public let bytesCopied: Int64?

    public init(
        scheme: String = ExportAudit.scheme,
        phase: AuditPhase,
        sequence: Int,
        relativePath: String,
        decision: AuditDecision,
        reason: SelectionReason,
        detail: String? = nil,
        snapshot: FileSnapshot? = nil,
        destination: String? = nil,
        bytesCopied: Int64? = nil
    ) {
        self.scheme = scheme
        self.phase = phase
        self.sequence = sequence
        self.relativePath = relativePath
        self.decision = decision
        self.reason = reason
        self.detail = detail
        self.size = snapshot?.size
        self.mode = snapshot?.mode
        self.device = snapshot?.device
        self.inode = snapshot?.inode
        self.linkCount = snapshot?.linkCount
        self.destination = destination
        self.bytesCopied = bytesCopied
    }

    /// Záznam odvozený z rozhodnutí preview.
    public init(phase: AuditPhase, sequence: Int, candidate: Candidate, destination: String? = nil, bytesCopied: Int64? = nil) {
        self.init(
            phase: phase,
            sequence: sequence,
            relativePath: candidate.relativePath,
            decision: candidate.accepted ? .accept : .reject,
            reason: candidate.reason,
            detail: candidate.detail,
            snapshot: candidate.snapshot,
            destination: destination,
            bytesCopied: bytesCopied
        )
    }
}

/// Cílové rozhraní pro auditní záznam. Konsolidace s formátem z WP1.H1 (audit log oblasti)
/// je navazující krok; tady jde o provizorní lokální záznam za protokolem.
public protocol AuditSink: Sendable {
    func append(_ record: AuditRecord) throws
}

/// Sběrač záznamů v paměti. Používá ho CLI i testy; sám nic nezapisuje na disk.
public final class RecordingAuditSink: AuditSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AuditRecord] = []

    public init() {}

    public func append(_ record: AuditRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.append(record)
    }

    public var records: [AuditRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Deterministický JSON dokument všech dosud sebraných záznamů.
    public func document() throws -> Data {
        try ExportAudit.document(records: records)
    }

    public func documentString() throws -> String {
        String(decoding: try document(), as: UTF8.self)
    }
}

public enum ExportAudit {
    /// Verze provizorního formátu. Změna formátu = nový identifikátor.
    public static let scheme = "sanjbox.export.audit.v0"

    public struct Document: Codable, Sendable, Equatable {
        public let scheme: String
        public let records: [AuditRecord]
    }

    /// Seriálizuje záznamy ve stabilním pořadí: fáze (preview před copy), pak `sequence`,
    /// pak UTF-8 bajty relativní cesty. Dva stejné běhy proto dají stejné bajty.
    public static func document(records: [AuditRecord]) throws -> Data {
        let ordered = records.sorted { lhs, rhs in
            if lhs.phase.rank != rhs.phase.rank { return lhs.phase.rank < rhs.phase.rank }
            if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
            return lhs.relativePath.utf8.lexicographicallyPrecedes(rhs.relativePath.utf8)
        }
        let encoder = ExportJSON.encoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(Document(scheme: scheme, records: ordered))
        data.append(0x0A)
        return data
    }
}
