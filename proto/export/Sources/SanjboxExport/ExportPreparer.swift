import Darwin
import Foundation

/// Fáze 1 a 2: selekce a preview. Nikdy nezapisuje — ani do kořene, ani do cíle.
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
        let rootFD: Int32
        switch SafePath.openRoot(rootPath) {
        case let .success(fd): rootFD = fd
        case let .failure(error): throw error
        }
        defer { close(rootFD) }

        // Duplicitní vstupy se sloučí podle normalizované cesty, takže pořadí argumentů
        // na příkazové řádce neovlivní plán ani audit. Neplatné vstupy zůstávají
        // v plánu jako odmítnuté, aby odmítnutí nikdy nezmizelo.
        var validPaths: [String: RelativePath] = [:]
        var invalidPaths: [String: PathParseError] = [:]
        for raw in relativePaths {
            switch RelativePath.parse(raw) {
            case let .success(parsed): validPaths[parsed.path] = parsed
            case let .failure(reason): invalidPaths[raw] = reason
            }
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(validPaths.count + invalidPaths.count)
        for parsed in validPaths.values {
            candidates.append(decide(parsed: parsed, rootFD: rootFD))
        }
        for (raw, reason) in invalidPaths {
            candidates.append(Candidate(
                relativePath: raw,
                accepted: false,
                reason: reason == .empty || reason == .nulByte ? .invalidPath : .outsideRoot,
                detail: reason.detail
            ))
        }
        let plan = ExportPlan(root: rootPath, candidates: candidates)

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
            switch SafePath.inspect(parentFD: chain.opened.last ?? rootFD, name: chain.name) {
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
