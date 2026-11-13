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
        struct Entry {
            let path: String
            let spelling: Data
            let isFile: Bool
        }
        var groups: [String: [Entry]] = [:]
        for candidate in candidates where candidate.accepted {
            let components = candidate.relativePath.split(separator: "/").map(String.init)
            for count in 1...components.count {
                let prefix = components.prefix(count).joined(separator: "/")
                groups[key(for: prefix), default: []].append(Entry(
                    path: candidate.relativePath, spelling: Data(prefix.utf8), isFile: count == components.count
                ))
            }
        }
        var details: [String: String] = [:]
        for key in groups.keys.sorted(by: compare) {
            guard let group = groups[key], group.count > 1 else { continue }
            // A target cannot be both a file and a directory. Different spellings
            // of a directory are also refused instead of merging source subtrees.
            guard group.contains(where: \.isFile) || Set(group.map(\.spelling)).count > 1 else { continue }
            let names = group.map(\.path).sorted(by: compare)
            let detail = "target names collide: \(names.joined(separator: ", "))"
            for entry in group { details[entry.path] = detail }
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
