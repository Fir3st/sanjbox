import CryptoKit
import Foundation

public enum NPMFailure: Error, Equatable, Sendable {
    case configuration, target, metadata, ineligible, changed, integrity, redirect, tooLarge, busy
}

/// Trusted configuration, never filled from a request or a registry-provided URL.
public struct NPMConfiguration: Sendable {
    public let registryHostname: String
    public let artifactHostnames: Set<String>
    public let publicOrigin: String
    public let mount: String
    public let cooldown: TimeInterval
    public let maximumMetadataBytes: Int
    public let maximumArtifactBytes: Int
    public let maximumVersions: Int
    public let maximumCacheBytes: Int
    public let maximumCacheEntries: Int
    public let maximumAuditRecords: Int
    public let maximumOperations: Int
    public let maximumRedirects: Int
    public let lifetime: Duration

    public init(registryHostname: String = "registry.npmjs.org", artifactHostnames: Set<String> = [],
                publicOrigin: String, mount: String = "/npm", cooldown: TimeInterval,
                maximumMetadataBytes: Int = 4_194_304, maximumArtifactBytes: Int = 4_194_304,
                maximumVersions: Int = 10_000, maximumCacheBytes: Int = 16_777_216,
                maximumCacheEntries: Int = 32, maximumAuditRecords: Int = 1_024,
                maximumOperations: Int = 4, maximumRedirects: Int = 3, lifetime: Duration = .seconds(90)) throws {
        guard cooldown.isFinite, cooldown >= 0, maximumMetadataBytes > 0, maximumArtifactBytes > 0,
              maximumVersions > 0, maximumCacheBytes >= 0, maximumCacheEntries >= 0,
              maximumAuditRecords > 0, maximumOperations > 0, (0...5).contains(maximumRedirects),
              lifetime > .zero,
              let origin = URLComponents(string: publicOrigin), origin.scheme == "http",
              origin.host == "127.0.0.1", let port = origin.port, (1...65535).contains(port),
              publicOrigin == "http://127.0.0.1:\(port)",
              mount.hasPrefix("/"), mount.count > 1,
              mount.dropFirst().utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
            throw NPMFailure.configuration
        }
        self.registryHostname = try DestinationPolicy.validatedHostname(registryHostname)
        self.artifactHostnames = try Set(artifactHostnames.map(DestinationPolicy.validatedHostname)).union([self.registryHostname])
        self.publicOrigin = publicOrigin
        self.mount = mount
        self.cooldown = cooldown
        self.maximumMetadataBytes = maximumMetadataBytes
        self.maximumArtifactBytes = maximumArtifactBytes
        self.maximumVersions = maximumVersions
        self.maximumCacheBytes = maximumCacheBytes
        self.maximumCacheEntries = maximumCacheEntries
        self.maximumAuditRecords = maximumAuditRecords
        self.maximumOperations = maximumOperations
        self.maximumRedirects = maximumRedirects
        self.lifetime = lifetime
    }
}

struct NPMName: Hashable, Sendable {
    let value: String
    init(_ value: String) throws {
        guard value.utf8.count <= 214 else { throw NPMFailure.target }
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        let components: [Substring]
        if value.hasPrefix("@"), pieces.count == 2 { components = [pieces[0].dropFirst(), pieces[1]] }
        else if pieces.count == 1 { components = pieces }
        else { throw NPMFailure.target }
        guard components.allSatisfy({ part in
            guard let first = part.utf8.first, (97...122).contains(first) || (48...57).contains(first) else { return false }
            return part.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || "-._".utf8.contains($0) }
        }) else { throw NPMFailure.target }
        self.value = value
    }
    var encoded: String { value.replacingOccurrences(of: "/", with: "%2f") }
    var basename: String { String(value.split(separator: "/").last!) }
    func tarballPath(version: String) -> String { "/\(encoded)/-/\(basename)-\(version).tgz" }
}

func validNPMVersion(_ text: String) -> Bool {
    text.utf8.count <= 128 && text.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$"#, options: .regularExpression) != nil
}

enum NPMTarget: Sendable {
    case packument(NPMName)
    case tarball(NPMName, String)

    init(_ target: String, mount: String) throws {
        guard target.utf8.count <= 1024, target.hasPrefix(mount + "/"), !target.contains("?"),
              !target.contains("#"), !target.contains("\\"),
              let decoded = String(target.dropFirst(mount.count + 1)).removingPercentEncoding,
              !decoded.contains("%") else { throw NPMFailure.target }
        let parts = decoded.components(separatedBy: "/-/")
        let name = try NPMName(parts[0])
        // Only literal name characters and one escaped scoped separator are accepted.
        let rawName = String(target.dropFirst(mount.count + 1)).components(separatedBy: "/-/")[0]
        guard rawName == name.value || rawName == name.encoded || rawName == name.encoded.replacingOccurrences(of: "%2f", with: "%2F") else { throw NPMFailure.target }
        if parts.count == 1 { self = .packument(name); return }
        guard parts.count == 2, parts[1].hasPrefix(name.basename + "-"), parts[1].hasSuffix(".tgz") else { throw NPMFailure.target }
        let version = String(parts[1].dropFirst(name.basename.count + 1).dropLast(4))
        guard validNPMVersion(version), target.hasSuffix("/-/\(name.basename)-\(version).tgz") else { throw NPMFailure.target }
        self = .tarball(name, version)
    }
}

struct NPMArtifactURL: Equatable, Hashable, Sendable {
    let hostname: String
    let path: String
    init(_ text: String, allowedHosts: Set<String>) throws {
        guard text.utf8.count <= 2048, let url = URLComponents(string: text), url.scheme == "https",
              let host = url.host, allowedHosts.contains(host), url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              !url.percentEncodedPath.isEmpty, text == "https://\(host)\(url.percentEncodedPath)",
              url.percentEncodedPath.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || "/@-._~+".utf8.contains($0) }),
              !url.percentEncodedPath.contains("//"), HTTPRequestDecoder.validTarget(url.percentEncodedPath) else { throw NPMFailure.redirect }
        hostname = host
        path = url.percentEncodedPath
    }
    var absolute: String { "https://\(hostname)\(path)" }
}

/// Strict SRI subset: no option suffixes, canonical base64, strongest supported
/// algorithm only. An invalid strong digest never falls back to a weaker one.
struct NPMIntegrity: Equatable, Sendable {
    let algorithm: String
    let digests: [Data]
    init(_ text: String) throws {
        guard text.utf8.count <= 2048 else { throw NPMFailure.integrity }
        let ranks = ["sha1": 1, "sha256": 2, "sha384": 3, "sha512": 4]
        let lengths = ["sha1": 20, "sha256": 32, "sha384": 48, "sha512": 64]
        var candidates: [(String, Data)] = []
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let parts = token.split(separator: "-", maxSplits: 1)
            guard parts.count == 2, let length = lengths[String(parts[0])],
                  let bytes = Data(base64Encoded: String(parts[1])), bytes.count == length,
                  bytes.base64EncodedString() == parts[1] else { throw NPMFailure.integrity }
            candidates.append((String(parts[0]), bytes))
        }
        guard !candidates.isEmpty, candidates.count <= 8,
              let strongest = candidates.max(by: { ranks[$0.0]! < ranks[$1.0]! })?.0,
              strongest != "sha1" else { throw NPMFailure.integrity }
        algorithm = strongest
        digests = candidates.filter { $0.0 == strongest }.map(\.1).sorted { $0.lexicographicallyPrecedes($1) }
    }
    var text: String { digests.map { "\(algorithm)-\($0.base64EncodedString())" }.joined(separator: " ") }
    func verify(_ data: Data) throws {
        let hash: Data
        switch algorithm {
        case "sha512": hash = Data(SHA512.hash(data: data))
        case "sha384": hash = Data(SHA384.hash(data: data))
        default: hash = Data(SHA256.hash(data: data))
        }
        guard digests.contains(hash) else { throw NPMFailure.integrity }
    }
}
