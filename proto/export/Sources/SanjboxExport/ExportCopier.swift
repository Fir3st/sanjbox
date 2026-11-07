import Darwin
import Foundation

/// Jeden zkopírovaný soubor s ověřenými metadaty.
public struct CopiedFile: Codable, Sendable, Equatable {
    public let relativePath: String
    /// Cílový kořen + relativní cesta. Cílový kořen je nový strom vytvořený tímto během.
    public let destination: String
    public let bytesCopied: Int64
    public let snapshot: FileSnapshot
    public let quarantineValue: String

    public init(
        relativePath: String,
        destination: String,
        bytesCopied: Int64,
        snapshot: FileSnapshot,
        quarantineValue: String
    ) {
        self.relativePath = relativePath
        self.destination = destination
        self.bytesCopied = bytesCopied
        self.snapshot = snapshot
        self.quarantineValue = quarantineValue
    }
}

public struct ExportResult: Codable, Sendable, Equatable {
    public let destinationRoot: String
    public let copied: [CopiedFile]

    public init(destinationRoot: String, copied: [CopiedFile]) {
        self.destinationRoot = destinationRoot
        self.copied = copied
    }

    public func jsonData() throws -> Data {
        try ExportJSON.encoder().encode(self)
    }
}

/// Fáze 3 a 4: kopie do nového cílového stromu a karanténa.
///
/// Vlastnosti, které se nemění:
/// - plán musí být čistý (`planNotClean`), jinak se nezkopíruje nic,
/// - cílový kořen musí být nový; existující cíl se nikdy nepoužije (`destinationExists`),
/// - každý soubor se otevře znovu přes `openat(O_NOFOLLOW)` a `fstat` se porovná se snapshotem
///   z preview (`identityMismatch`),
/// - cílový soubor vzniká `O_CREAT|O_EXCL`, takže nikdy nepřepíše existující soubor,
/// - karanténa se nastavuje na fd a hned se ověřuje; selhání = `quarantineFailed`.
///
/// Co prototyp **nedělá**: nekopíruje ACL, rozšířené atributy kromě karantény, vlastníka ani
/// časové značky. Neuklízí částečný cílový strom po chybě (volající ho smaže sám, protože
/// je to jeho nový temp adresář).
public struct ExportCopier: Sendable {
    public struct Configuration: Sendable {
        public var quarantineValue: String
        public var quarantineWriter: any QuarantineWriter
        /// Velikost bloku pro `read`/`write`.
        public var bufferSize: Int

        public init(
            quarantineValue: String = Quarantine.defaultValue,
            quarantineWriter: any QuarantineWriter = SystemQuarantineWriter(),
            bufferSize: Int = 64 * 1024
        ) {
            self.quarantineValue = quarantineValue
            self.quarantineWriter = quarantineWriter
            self.bufferSize = bufferSize
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func apply(_ plan: ExportPlan, destinationRoot: String) throws -> ExportResult {
        try apply(plan, destinationRoot: destinationRoot, audit: nil)
    }

    public func apply(
        _ plan: ExportPlan,
        destinationRoot: String,
        audit: (any AuditSink)?
    ) throws -> ExportResult {
        guard plan.isClean else {
            throw ExportError.planNotClean(paths: plan.rejectedPaths)
        }
        guard !plan.accepted.isEmpty else {
            return ExportResult(destinationRoot: destinationRoot, copied: [])
        }

        let rootFD: Int32
        switch SafePath.openRoot(plan.root) {
        case let .success(fd): rootFD = fd
        case let .failure(error): throw error
        }
        defer { close(rootFD) }

        let destinationFD = try createDestinationRoot(destinationRoot)
        defer { close(destinationFD) }

        var copied: [CopiedFile] = []
        copied.reserveCapacity(plan.accepted.count)

        for (index, candidate) in plan.accepted.enumerated() {
            guard let expected = candidate.snapshot else {
                throw ExportError.io(path: candidate.relativePath, operation: "apply-without-snapshot", errno: EINVAL)
            }
            guard case let .success(parsed) = RelativePath.parse(candidate.relativePath) else {
                throw ExportError.io(path: candidate.relativePath, operation: "reparse", errno: EINVAL)
            }
            let file = try copyOne(
                candidate: candidate,
                parsed: parsed,
                expected: expected,
                rootFD: rootFD,
                destinationFD: destinationFD,
                destinationRoot: destinationRoot
            )
            copied.append(file)
            try audit?.append(
                AuditRecord(
                    phase: .copy,
                    sequence: index,
                    candidate: candidate,
                    destination: file.destination,
                    bytesCopied: file.bytesCopied
                )
            )
        }

        return ExportResult(destinationRoot: destinationRoot, copied: copied)
    }

    private func createDestinationRoot(_ path: String) throws -> Int32 {
        let created = path.withCString { mkdir($0, 0o700) }
        guard created == 0 else {
            let code = errno
            if code == EEXIST {
                throw ExportError.destinationExists(path: path)
            }
            throw ExportError.destinationInvalid(path: path, errno: code)
        }
        let fd = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            let code = errno
            throw ExportError.destinationInvalid(path: path, errno: code)
        }
        var status = stat()
        guard fstat(fd, &status) == 0, FileKind(mode: status.st_mode) == .directory else {
            let code = errno
            close(fd)
            throw ExportError.destinationInvalid(path: path, errno: code)
        }
        return fd
    }

    private func copyOne(
        candidate: Candidate,
        parsed: RelativePath,
        expected: FileSnapshot,
        rootFD: Int32,
        destinationFD: Int32,
        destinationRoot: String
    ) throws -> CopiedFile {
        let chain: (opened: [Int32], name: String)
        switch SafePath.openDirectoryChain(rootFD: rootFD, components: parsed.components) {
        case let .success(value): chain = value
        case let .failure(rejection):
            throw ExportError.sourceUnavailable(
                path: candidate.relativePath,
                reason: rejection.reason,
                detail: rejection.detail
            )
        }
        defer { for fd in chain.opened.reversed() { close(fd) } }

        let sourceFD: Int32
        let actual: FileSnapshot
        switch SafePath.openForCopy(parentFD: chain.opened.last ?? rootFD, name: chain.name) {
        case let .success(value):
            (sourceFD, actual) = value
        case let .failure(rejection):
            throw ExportError.sourceUnavailable(
                path: candidate.relativePath,
                reason: rejection.reason,
                detail: rejection.detail
            )
        }
        defer { close(sourceFD) }

        // TOCTOU: soubor mezi preview a kopií musí být tentýž a stejně velký.
        guard actual.matchesIdentity(expected) else {
            throw ExportError.identityMismatch(path: candidate.relativePath, expected: expected, actual: actual)
        }

        let destChain = try openDestinationDirectories(
            destinationFD: destinationFD,
            components: Array(parsed.components.prefix(max(parsed.components.count - 1, 0))),
            relativePath: candidate.relativePath
        )
        // Zavíráme všechny otevřené mezilehlé adresáře, jinak by každý soubor prosakoval fd.
        defer { for fd in destChain.opened.reversed() { close(fd) } }
        let destParentFD = destChain.deepest

        let destinationPath = destinationRoot + "/" + parsed.path
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let destFD = chain.name.withCString { openat(destParentFD, $0, flags, mode_t(expected.mode)) }
        guard destFD >= 0 else {
            let code = errno
            if code == EEXIST {
                throw ExportError.overwriteRefused(path: destinationPath)
            }
            throw ExportError.io(path: destinationPath, operation: "openat-create", errno: code)
        }
        defer { close(destFD) }

        // `openat` mode je maskované umaskem; prototyp práva srovnává explicitně.
        // setuid/setgid/sticky se na výsledek nepřenáší — export nikdy nevyrábí privilegovaný soubor.
        guard fchmod(destFD, mode_t(expected.mode & 0o777)) == 0 else {
            throw ExportError.io(path: destinationPath, operation: "fchmod", errno: errno)
        }

        let written = try copyBytes(from: sourceFD, to: destFD, path: candidate.relativePath)
        guard written == expected.size else {
            throw ExportError.identityMismatch(
                path: candidate.relativePath,
                expected: expected,
                actual: FileSnapshot(
                    device: actual.device,
                    inode: actual.inode,
                    size: written,
                    mode: actual.mode,
                    linkCount: actual.linkCount
                )
            )
        }

        // Zdroj se nesmí změnit ani během kopie.
        var after = stat()
        guard fstat(sourceFD, &after) == 0 else {
            throw ExportError.io(path: candidate.relativePath, operation: "fstat-after-copy", errno: errno)
        }
        let afterSnapshot = FileSnapshot(fromStat: after)
        guard afterSnapshot.matchesIdentity(expected) else {
            throw ExportError.identityMismatch(path: candidate.relativePath, expected: expected, actual: afterSnapshot)
        }

        try applyQuarantine(fileDescriptor: destFD, destinationPath: destinationPath)

        var destStatus = stat()
        guard fstat(destFD, &destStatus) == 0 else {
            throw ExportError.io(path: destinationPath, operation: "fstat-destination", errno: errno)
        }
        guard FileKind(mode: destStatus.st_mode) == .regular, destStatus.st_nlink == 1 else {
            throw ExportError.io(path: destinationPath, operation: "verify-destination", errno: EINVAL)
        }
        guard destStatus.st_size == expected.size else {
            throw ExportError.io(path: destinationPath, operation: "verify-destination-size", errno: EINVAL)
        }

        return CopiedFile(
            relativePath: candidate.relativePath,
            destination: destinationPath,
            bytesCopied: written,
            snapshot: expected,
            quarantineValue: configuration.quarantineValue
        )
    }

    /// Vytvoří mezilehlé adresáře v novém cílovém stromu a vrátí fd nejhlubšího z nich
    /// spolu se seznamem fd k zavření. Cílový strom je nový, takže `EEXIST` znamená kolizi.
    private func openDestinationDirectories(
        destinationFD: Int32,
        components: [String],
        relativePath: String
    ) throws -> (deepest: Int32, opened: [Int32]) {
        var currentFD = destinationFD
        var opened: [Int32] = []
        for component in components {
            let created = component.withCString { mkdirat(currentFD, $0, 0o700) }
            if created != 0 && errno != EEXIST {
                for fd in opened.reversed() { close(fd) }
                throw ExportError.io(path: relativePath, operation: "mkdirat \(component)", errno: errno)
            }
            let fd = component.withCString {
                openat(currentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard fd >= 0 else {
                let code = errno
                for openFD in opened.reversed() { close(openFD) }
                throw ExportError.io(path: relativePath, operation: "openat-destination \(component)", errno: code)
            }
            opened.append(fd)
            currentFD = fd
        }
        return (currentFD, opened)
    }

    private func applyQuarantine(fileDescriptor fd: Int32, destinationPath: String) throws {
        do {
            try configuration.quarantineWriter.writeQuarantine(value: configuration.quarantineValue, fileDescriptor: fd)
            try configuration.quarantineWriter.verifyQuarantine(value: configuration.quarantineValue, fileDescriptor: fd)
        } catch let error as QuarantineWriteError {
            // Žádný tichý fallback: bez karantény export nekončí úspěchem.
            throw ExportError.quarantineFailed(path: destinationPath, errno: error.code)
        }
    }

    private func copyBytes(from sourceFD: Int32, to destFD: Int32, path: String) throws -> Int64 {
        var buffer = [UInt8](repeating: 0, count: max(configuration.bufferSize, 4096))
        var total: Int64 = 0
        while true {
            let readCount = buffer.withUnsafeMutableBytes { raw in
                read(sourceFD, raw.baseAddress, raw.count)
            }
            if readCount == 0 { break }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw ExportError.io(path: path, operation: "read", errno: errno)
            }
            var offset = 0
            while offset < readCount {
                let written = buffer.withUnsafeBytes { raw in
                    write(destFD, raw.baseAddress!.advanced(by: offset), readCount - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ExportError.io(path: path, operation: "write", errno: errno)
                }
                offset += written
            }
            total += Int64(readCount)
        }
        return total
    }
}
