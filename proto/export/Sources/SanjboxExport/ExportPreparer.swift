import Darwin
import Foundation

/// Fáze 1 a 2: selekce a preview nemění zdroj ani cíl. Explicitní auditní sink může zapisovat.
///
/// Vstupem je explicitní seznam relativních cest. Žádný průchod adresářem: co není
/// vyjmenované, se neexportuje. Každá cesta se vyhodnotí samostatně a odmítnutí
/// je záznam v plánu, ne výjimka — volající vidí celý výsledek najednou.
public struct ExportPreparer: Sendable {
    public let rootPath: String

    public init(rootPath: String) {
        self.rootPath = rootPath
    }

    public func prepare(relativePaths: [String]) throws -> ExportPlan {
        try prepare(relativePaths: relativePaths, audit: nil)
    }

    public func prepare(relativePaths: [String], audit: (any AuditSink)?) throws -> ExportPlan {
        let absoluteRoot = rootPath.hasPrefix("/") ? rootPath : FileManager.default.currentDirectoryPath + "/" + rootPath
        let rootFD: Int32
        switch SafePath.openRoot(absoluteRoot) {
        case let .success(fd): rootFD = fd
        case let .failure(error): throw error
        }
        defer { close(rootFD) }

        // Duplicitní vstupy se sloučí podle normalizované cesty, takže pořadí argumentů
        // na příkazové řádce neovlivní plán ani audit. Neplatné vstupy zůstávají
        // v plánu jako odmítnuté, aby odmítnutí nikdy nezmizelo.
        // Klíč je bajtová podoba cesty, ne `String`: Swift `String` považuje NFC a NFD
        // za stejné, což by u neplatného pořadí argumentů měnilo vybranou cestu.
        var validPaths: [Data: RelativePath] = [:]
        var invalidPaths: [Data: (raw: String, reason: PathParseError)] = [:]
        for raw in relativePaths {
            switch RelativePath.parse(raw) {
            case let .success(parsed): validPaths[Data(parsed.path.utf8)] = parsed
            case let .failure(reason): invalidPaths[Data(raw.utf8)] = (raw, reason)
            }
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(validPaths.count + invalidPaths.count)
        for parsed in validPaths.values {
            candidates.append(decide(parsed: parsed, rootFD: rootFD))
        }
        for value in invalidPaths.values {
            let (raw, reason) = value
            candidates.append(Candidate(
                relativePath: raw,
                accepted: false,
                reason: reason == .empty || reason == .nulByte ? .invalidPath : .outsideRoot,
                detail: reason.detail
            ))
        }
        // Nejdřív sloučit stejnou identitu (např. case varianty téhož jména na
        // case-insensitive APFS), pak odmítnout skutečné kolize různých identit.
        let deduplicated = TargetNames.deduplicateByIdentity(candidates)
        let validated = TargetNames.rejectCollisions(deduplicated)
        let plan = ExportPlan(root: absoluteRoot, candidates: validated, preparedForCopy: true,
                              rootIdentity: try DirectoryIdentity.read(rootFD))

        if let audit {
            for (index, candidate) in plan.candidates.enumerated() {
                try audit.append(AuditRecord(phase: .preview, sequence: index, candidate: candidate))
            }
        }
        return plan
    }

    private func decide(parsed: RelativePath, rootFD: Int32) -> Candidate {
        switch SafePath.openDirectoryChain(rootFD: rootFD, components: parsed.components) {
        case let .failure(rejection):
            return Candidate(
                relativePath: parsed.path,
                accepted: false,
                reason: rejection.reason,
                detail: rejection.detail
            )
        case let .success(chain):
            defer { for fd in chain.opened.reversed() { close(fd) } }
            switch SafePath.inspectAndHash(parentFD: chain.opened.last ?? rootFD, name: chain.name) {
            case let .failure(rejection):
                return Candidate(
                    relativePath: parsed.path,
                    accepted: false,
                    reason: rejection.reason,
                    detail: rejection.detail
                )
            case let .success(snapshot):
                return Candidate(
                    relativePath: parsed.path,
                    accepted: true,
                    reason: .accepted,
                    detail: nil,
                    snapshot: snapshot
                )
            }
        }
    }
}
