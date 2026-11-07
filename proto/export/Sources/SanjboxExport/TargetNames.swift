import Foundation

/// Sémantika cílového jména. Cílový strom je na macOS obvykle case-insensitive APFS,
/// který navíc nerozlišuje kanonicky ekvivalentní Unicode (NFC/NFD). Dvě různé
/// identity se stejným klíčem by v cíli kolidovaly na `O_EXCL` až uprostřed kopie;
/// proto se odmítají už v plánu.
enum TargetNames {
    static func key(for relativePath: String) -> String {
        relativePath.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func compare(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    /// Kolizní skupiny podle klíče cílového jména. Vrací detail pro každou kolidující
    /// cestu; pořadí jmen v detailu je UTF-8 deterministické.
    static func collisionDetails(for candidates: [Candidate]) -> [String: String] {
        var groups: [String: [Candidate]] = [:]
        for candidate in candidates where candidate.accepted {
            groups[key(for: candidate.relativePath), default: []].append(candidate)
        }
        var details: [String: String] = [:]
        for group in groups.values where group.count > 1 {
            let names = group.map(\.relativePath).sorted(by: compare)
            let detail = "target names collide: \(names.joined(separator: ", "))"
            for candidate in group {
                details[candidate.relativePath] = detail
            }
        }
        return details
    }

    /// Přijaté kandidáty se stejným `(dev, inode)` sloučí. Ponechá se první cesta
    /// v UTF-8 pořadí, takže výsledek nezávisí na pořadí argumentů.
    static func deduplicateByIdentity(_ candidates: [Candidate]) -> [Candidate] {
        let rejected = candidates.filter { !$0.accepted }
        let accepted = candidates.filter(\.accepted).sorted { compare($0.relativePath, $1.relativePath) }
        var seen: Set<String> = []
        var kept: [Candidate] = []
        for candidate in accepted {
            guard let snapshot = candidate.snapshot else {
                // Bez snapshotu nelze identitu určit; necháváme rozhodnutí na kopii.
                kept.append(candidate)
                continue
            }
            let identity = "\(snapshot.device):\(snapshot.inode)"
            if seen.insert(identity).inserted {
                kept.append(candidate)
            }
        }
        return rejected + kept
    }

    /// Odmítne všechny kandidáty, jejichž cílová jména kolidují. Odmítnutí je
    /// v plánu, takže apply se vůbec nespustí.
    static func rejectCollisions(_ candidates: [Candidate]) -> [Candidate] {
        let details = collisionDetails(for: candidates)
        guard !details.isEmpty else { return candidates }
        return candidates.map { candidate in
            guard let detail = details[candidate.relativePath], candidate.accepted else {
                return candidate
            }
            return Candidate(
                relativePath: candidate.relativePath,
                accepted: false,
                reason: .destinationCollision,
                detail: detail,
                snapshot: nil
            )
        }
    }
}
