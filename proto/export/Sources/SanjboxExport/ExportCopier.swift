import CryptoKit
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
/// - plán musí být připravený v tomto procesu (`planNotPrepared`) a čistý (`planNotClean`),
/// - cílový kořen musí být nový a mimo zdrojový kořen (`destinationExists`,
///   `destinationInsideRoot`); kolize cílových jmen se odmítne před kopií,
/// - každý soubor se otevře znovu přes `openat(O_NOFOLLOW)`, porovná se `fstat`
///   a SHA-256 proti preview (`identityMismatch`),
/// - cílový soubor vzniká `O_CREAT|O_EXCL`, takže nikdy nepřepíše existující soubor,
/// - karanténa se nastaví na fd prázdného souboru hned po vytvoření, obsah se pak zapíše
///   a na konci se karanténa jen znovu ověří; selhání = `quarantineFailed`,
/// - selhání kopie nebo auditu uklidí aktuální soubor, pokud jeho jméno stále odpovídá fd.
///
/// Volající musí zajistit soukromý a stabilní cílový prostor. Kontroly fd nejsou atomická
/// obrana proti aktérovi, který smí přesouvat připnuté rodiče nebo nahrazovat jejich obsah.
///
/// Co prototyp **nedělá**: nekopíruje ACL, rozšířené atributy kromě karantény, vlastníka ani
/// časové značky. Neuklízí částečný cílový strom po chybě (volající ho smaže sám, protože
/// je to jeho nový temp adresář).
public struct ExportCopier: Sendable {
    public struct Configuration: Sendable {
        public var quarantineValue: String
        public var quarantineWriter: any QuarantineWriter
        /// Zapisovač obsahu. Testy přes něj injektují selhání uprostřed kopie.
        public var contentWriter: any ContentWriter
        /// Velikost bloku pro `read`/`write`.
        public var bufferSize: Int

        public init(
            quarantineValue: String = Quarantine.defaultValue,
            quarantineWriter: any QuarantineWriter = SystemQuarantineWriter(),
            contentWriter: any ContentWriter = SystemContentWriter(),
            bufferSize: Int = 64 * 1024
        ) {
            self.quarantineValue = quarantineValue
            self.quarantineWriter = quarantineWriter
            self.contentWriter = contentWriter
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
        guard plan.isAuthorizedForCopy else {
            throw ExportError.planNotPrepared
        }
        guard plan.isClean else {
            throw ExportError.planNotClean(paths: plan.rejectedPaths)
        }
        guard !ExportPathPolicy.isDestination(destinationRoot, insideRoot: plan.root) else {
            throw ExportError.destinationInsideRoot(destination: destinationRoot, root: plan.root)
        }
        let collisionDetails = TargetNames.collisionDetails(for: plan.candidates)
        if !collisionDetails.isEmpty {
            throw ExportError.destinationNameCollision(paths: collisionDetails.keys.sorted(by: TargetNames.compare))
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

        guard try DirectoryIdentity.read(rootFD) == plan.rootIdentity else {
            throw ExportError.invalidRoot(path: plan.root, errno: ESTALE)
        }
        let destinationParent = try DestinationParent(path: destinationRoot)
        try destinationParent.requireOutside(rootFD: rootFD, rootPath: plan.root)
        let destination = try DestinationTree(parent: destinationParent)

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
                destination: destination,
                destinationRoot: destinationRoot,
                audit: audit,
                sequence: index
            )
            copied.append(file)
        }

        return ExportResult(destinationRoot: destinationRoot, copied: copied)
    }

    private func copyOne(
        candidate: Candidate,
        parsed: RelativePath,
        expected: FileSnapshot,
        rootFD: Int32,
        destination: DestinationTree,
        destinationRoot: String,
        audit: (any AuditSink)?,
        sequence: Int
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

        // TOCTOU: soubor mezi preview a kopií musí být tentýž a stejně velký;
        // obsah se ověří hashem až při čtení.
        guard actual.matchesMetadata(expected) else {
            throw ExportError.identityMismatch(path: candidate.relativePath, expected: expected, actual: actual)
        }

        let destParentFD = try destination.directory(
            components: Array(parsed.components.dropLast()),
            relativePath: candidate.relativePath
        )

        let destinationPath = destinationRoot + "/" + parsed.path
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let destFD = chain.name.withCString { openat(destParentFD, $0, flags, mode_t(0o600)) }
        guard destFD >= 0 else {
            let code = errno
            if code == EEXIST {
                throw ExportError.overwriteRefused(path: destinationPath)
            }
            throw ExportError.io(path: destinationPath, operation: "openat-create", errno: code)
        }
        defer { close(destFD) }

        var completed = false
        defer {
            if !completed {
                // Úklid pouze vlastního inode; známou náhradu pod stejným jménem nemažeme.
                // Předpoklad stabilního cílového prostoru viz dokumentace typu.
                var linked = stat()
                var opened = stat()
                if fstat(destFD, &opened) == 0,
                   fstatat(destParentFD, chain.name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                   linked.st_dev == opened.st_dev, linked.st_ino == opened.st_ino {
                    _ = unlinkat(destParentFD, chain.name, 0)
                }
            }
        }

        // `openat` mode je maskované umaskem; prototyp práva srovnává explicitně.
        // setuid/setgid/sticky se na výsledek nepřenáší — export nikdy nevyrábí privilegovaný soubor.
        guard fchmod(destFD, mode_t(expected.mode & 0o777)) == 0 else {
            throw ExportError.io(path: destinationPath, operation: "fchmod", errno: errno)
        }

        // Karanténa patří na fd prázdného souboru hned po `O_CREAT|O_EXCL`.
        // Kdyby proces spadl během zápisu, v cíli nezůstane nekaranténovaný částečný soubor.
        try applyQuarantine(fileDescriptor: destFD, destinationPath: destinationPath)

        let copy = try copyBytes(from: sourceFD, to: destFD, path: candidate.relativePath, maximumBytes: expected.size)
        guard copy.bytes == expected.size, copy.hash == expected.contentHash else {
            throw ExportError.identityMismatch(
                path: candidate.relativePath,
                expected: expected,
                actual: FileSnapshot(
                    device: actual.device,
                    inode: actual.inode,
                    size: copy.bytes,
                    mode: actual.mode,
                    linkCount: actual.linkCount,
                    contentHash: copy.hash
                )
            )
        }

        // Zdroj se nesmí změnit ani během kopie; hash pokrývá i přepis na místě.
        var after = stat()
        guard fstat(sourceFD, &after) == 0 else {
            throw ExportError.io(path: candidate.relativePath, operation: "fstat-after-copy", errno: errno)
        }
        let afterSnapshot = FileSnapshot(fromStat: after, contentHash: copy.hash)
        guard afterSnapshot.matchesIdentity(expected) else {
            throw ExportError.identityMismatch(path: candidate.relativePath, expected: expected, actual: afterSnapshot)
        }

        // Obsah je zapsaný; karanténa se jen znovu ověří.
        try verifyQuarantine(fileDescriptor: destFD, destinationPath: destinationPath)

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

        _ = try destination.directory(components: Array(parsed.components.dropLast()), relativePath: candidate.relativePath)
        var linked = stat()
        guard fstatat(destParentFD, chain.name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              linked.st_dev == destStatus.st_dev, linked.st_ino == destStatus.st_ino else {
            throw ExportError.io(path: destinationPath, operation: "destination-file-changed", errno: ESTALE)
        }
        try audit?.append(AuditRecord(phase: .copy, sequence: sequence, candidate: candidate,
                                      destination: candidate.relativePath, bytesCopied: copy.bytes))
        completed = true
        return CopiedFile(
            relativePath: candidate.relativePath,
            destination: destinationPath,
            bytesCopied: copy.bytes,
            snapshot: expected,
            quarantineValue: configuration.quarantineValue
        )
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

    private func verifyQuarantine(fileDescriptor fd: Int32, destinationPath: String) throws {
        do {
            try configuration.quarantineWriter.verifyQuarantine(value: configuration.quarantineValue, fileDescriptor: fd)
        } catch let error as QuarantineWriteError {
            throw ExportError.quarantineFailed(path: destinationPath, errno: error.code)
        }
    }

    /// Zkopíruje nejvýše schválené bajty a současně počítá SHA-256 zdroje.
    /// Počet přečtených bajtů zahrnuje při růstu i nezapsaný kontrolní bajt,
    /// aby volající neshodu ohlásil jako `identityMismatch`.
    private func copyBytes(
        from sourceFD: Int32, to destFD: Int32, path: String, maximumBytes: Int64
    ) throws -> (bytes: Int64, hash: String) {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: max(configuration.bufferSize, 4096))
        var total: Int64 = 0
        while true {
            // Nejvýše schválené bajty a jeden kontrolní bajt pro detekci růstu.
            // Rostoucí (i řídký) zdroj nesmí neomezeně plnit cílový disk.
            let remaining = maximumBytes - total
            let readLimit = remaining >= Int64(buffer.count) ? buffer.count : Int(remaining) + 1
            let readCount = buffer.withUnsafeMutableBytes { raw in
                read(sourceFD, raw.baseAddress, readLimit)
            }
            if readCount == 0 { break }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw ExportError.io(path: path, operation: "read", errno: errno)
            }
            if Int64(readCount) > remaining {
                // Kontrolní bajt nikdy nezapisujeme. Volající ohlásí identityMismatch
                // a odstraní soubor stejně jako při jiné neshodě obsahu.
                hasher.update(data: Data(buffer[0..<readCount]))
                let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                return (total + Int64(readCount), hash)
            }
            var offset = 0
            while offset < readCount {
                let slice = buffer.withUnsafeBytes { raw in
                    UnsafeRawBufferPointer(rebasing: raw[offset..<readCount])
                }
                let written: Int
                do {
                    written = try configuration.contentWriter.write(fileDescriptor: destFD, buffer: slice)
                } catch let error as POSIXWriteError {
                    if error.code == EINTR { continue }
                    throw ExportError.io(path: path, operation: "write", errno: error.code)
                } catch {
                    throw ExportError.io(path: path, operation: "write", errno: EIO)
                }
                guard written > 0, written <= readCount - offset else {
                    throw ExportError.io(path: path, operation: "write", errno: EIO)
                }
                offset += written
            }
            hasher.update(data: Data(buffer[0..<readCount]))
            total += Int64(readCount)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (total, hash)
    }
}
