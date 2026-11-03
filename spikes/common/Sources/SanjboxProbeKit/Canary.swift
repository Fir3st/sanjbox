import Darwin
import Foundation

/// A synthetic secret. Tests place canaries in protected roots and look for them on the other
/// side of a boundary; real secrets are never read or used (GUIDE §3).
public struct Canary: Codable, Equatable, Sendable {
    /// `SANJBOX-CANARY-<label>-<32 hex>`, unique per canary.
    public var token: String
    public var label: String
    /// File holding the token, if the canary was written to disk.
    public var path: String?
    public var createdAt: Date

    public static let tokenPrefix = "SANJBOX-CANARY-"

    public init(token: String, label: String, path: String?, createdAt: Date) {
        self.token = token
        self.label = label
        self.path = path
        self.createdAt = createdAt
    }

    /// Creates a canary with a fresh random token.
    /// - Parameter label: 1–32 characters of `a-z`, `0-9`, `-`, starting with a letter or digit;
    ///   names where the canary lives (e.g. `home`, `work-root`).
    public static func make(label: String, now: Date = Date()) throws -> Canary {
        guard isValidLabel(label) else { throw CanaryError.invalidLabel(label) }
        var random = SystemRandomNumberGenerator()
        let suffix = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &random)) }.joined()
        return Canary(token: tokenPrefix + label + "-" + suffix, label: label, path: nil, createdAt: now)
    }

    static func isValidLabel(_ label: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        return (1...32).contains(label.count) && label.first != "-" && label.allSatisfy(allowed.contains)
    }

    /// Writes the token to `<directory>/sanjbox-canary-<label>.txt`.
    ///
    /// Refuses to overwrite anything or to follow a symlink at the target path. The file gets
    /// ordinary 0644 permissions on purpose: a test must show that the *protected root* keeps
    /// it unreadable, not the file mode.
    public func written(to directory: URL) throws -> Canary {
        let path = directory.appendingPathComponent("sanjbox-canary-\(label).txt").path
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw CanaryError.cannotCreate(path, errno: errno) }
        defer { close(fd) }
        let bytes = Array(token.utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else { throw CanaryError.cannotCreate(path, errno: errno) }
        var copy = self
        copy.path = path
        return copy
    }

    /// Removes the canary file only if it is still a regular file owned by the caller and
    /// still holds this token. Missing files count as removed, so cleanup is idempotent.
    public func removeFile() -> RemovalResult {
        guard let path else { return .notOnDisk }
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT ? .alreadyAbsent : .refused("lstat errno \(errno)") }
        guard info.st_mode & S_IFMT == S_IFREG else { return .refused("not a regular file") }
        guard info.st_uid == geteuid() else { return .refused("owned by uid \(info.st_uid)") }
        guard let content = FileManager.default.contents(atPath: path), content == Data(token.utf8) else {
            return .refused("content changed")
        }
        return unlink(path) == 0 ? .removed : .refused("unlink errno \(errno)")
    }

    public enum RemovalResult: Equatable, Sendable {
        case removed, alreadyAbsent, notOnDisk
        case refused(String)
    }
}

public enum CanaryError: Error, Equatable {
    case invalidLabel(String)
    case cannotCreate(String, errno: Int32)
}

/// Finds canary tokens in arbitrary bytes received on the far side of a boundary.
///
/// Matches the raw token and its hex encoding (any case), the form a DNS label can carry.
public struct CanaryScanner: Sendable {
    public struct Finding: Codable, Hashable, Sendable {
        /// The matched token; `Canary.tokenPrefix` alone means some canary, possibly unregistered.
        public var token: String
        public var encoding: String

        public init(token: String, encoding: String) {
            self.token = token
            self.encoding = encoding
        }
    }

    private let patterns: [(token: String, encoding: String, bytes: Data)]

    /// - Parameter matchAnyCanary: also report the bare token prefix, so canaries created after
    ///   the registry was loaded are not missed.
    public init(canaries: [Canary], matchAnyCanary: Bool = false) {
        let tokens = canaries.map(\.token) + (matchAnyCanary ? [Canary.tokenPrefix] : [])
        patterns = tokens.flatMap { token in
            let raw = Data(token.utf8)
            let hex = Data(raw.map { String(format: "%02x", $0) }.joined().utf8)
            return [(token, "raw", raw), (token, "hex", hex)]
        }
    }

    var longestPattern: Int { patterns.map(\.bytes.count).max() ?? 0 }

    public func findings(in data: Data) -> [Finding] {
        // Hex digits are matched case-insensitively by lowercasing ASCII letters of the input.
        let lowered = Data(data.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 })
        return patterns.compactMap { pattern in
            let haystack = pattern.encoding == "hex" ? lowered : data
            return haystack.range(of: pattern.bytes) == nil ? nil : Finding(token: pattern.token, encoding: pattern.encoding)
        }
    }
}

/// Scans data that arrives in chunks: keeps enough of the previous chunk that a token split
/// across a chunk boundary is still found.
public struct CanaryStreamScanner: Sendable {
    private let scanner: CanaryScanner
    private var tail = Data()
    public private(set) var findings: Set<CanaryScanner.Finding> = []

    public init(scanner: CanaryScanner) {
        self.scanner = scanner
    }

    public mutating func feed(_ chunk: Data) {
        let window = tail + chunk
        findings.formUnion(scanner.findings(in: window))
        tail = window.suffix(max(0, scanner.longestPattern - 1))
    }
}
