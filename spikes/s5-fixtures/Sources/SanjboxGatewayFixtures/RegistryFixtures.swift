import CryptoKit
import Foundation
import SanjboxGatewayCore

public enum FixtureFailure: Error, Equatable, Sendable {
    case invalidInput, limit, duplicate, exhausted, unexpectedRequest, scriptedFailure, incomplete
}

func fixtureCheck(_ condition: Bool, _ failure: FixtureFailure = .invalidInput) throws {
    guard condition else { throw failure }
}

func identifier(_ text: String, maximum: Int = 80) -> Bool {
    !text.isEmpty && text.utf8.count <= maximum && text.utf8.allSatisfy {
        (97...122).contains($0) || (48...57).contains($0) || $0 == 45
    }
}

func json<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

public struct PackageKey: Hashable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) throws {
        let pieces = name.split(separator: "/", omittingEmptySubsequences: false)
        let validName = pieces.count == 1 ? identifier(name) :
            (pieces.count == 2 && pieces[0].first == "@" &&
             identifier(String(pieces[0].dropFirst())) && identifier(String(pieces[1])))
        let numbers = version.split(separator: ".", omittingEmptySubsequences: false)
        try fixtureCheck(validName && name.utf8.count <= 160 && numbers.count == 3 && numbers.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 4 && $0.utf8.allSatisfy { (48...57).contains($0) }
                && ($0 == "0" || $0.first != "0")
        })
        self.name = name
        self.version = version
    }

    public var upstreamPackumentTarget: String { "/" + name.replacingOccurrences(of: "/", with: "%2f") }
    public var upstreamTarballTarget: String { "/\(name)/-/\(name.split(separator: "/").last!)-\(version).tgz" }
    public var packumentTarget: String { "/npm" + upstreamPackumentTarget }
    public var tarballTarget: String { "/npm" + upstreamTarballTarget }
}

public struct SyntheticArtifact: Sendable {
    public let key: PackageKey
    /// Unix seconds; nil intentionally omits this version from the packument time map.
    public let publishedAt: Int64?
    public let archive: Data
    public let integrity: String
    public let manifest: Data

    public init(key: PackageKey, publishedAt: Int64?) throws {
        try fixtureCheck(publishedAt == nil || (0...4_102_444_800).contains(publishedAt!))
        self.key = key
        self.publishedAt = publishedAt
        manifest = try json(PackageManifest(name: key.name, version: key.version))
        archive = try SyntheticArchive.make(manifest: manifest)
        integrity = "sha512-" + Data(SHA512.hash(data: archive)).base64EncodedString()
    }
}

struct PackageManifest: Codable { let name: String; let version: String }

/// A constrained origin: generated URLs are either inert fixture HTTPS or exact loopback HTTP.
/// It cannot name live registries, accept userinfo, or carry a query/path.
public struct FixtureOrigin: Sendable, Equatable {
    public let value: String
    public let mount: String
    public static let upstream = FixtureOrigin(value: "https://registry.fixture.invalid", mount: "")
    public static let cdn = FixtureOrigin(value: "https://cdn.fixture.invalid", mount: "")
    private init(value: String, mount: String) { self.value = value; self.mount = mount }
    public static func loopback(port: UInt16) throws -> FixtureOrigin {
        try fixtureCheck(port > 0)
        return FixtureOrigin(value: "http://127.0.0.1:\(port)", mount: "/npm")
    }
}

public struct RegistryFixtures: Sendable {
    public static let now: Int64 = 1_767_225_600 // 2026-01-01T00:00:00Z
    public static let cooldown: Int64 = 604_800 // fixed 7-day fixture policy, not product configuration
    public let artifacts: [SyntheticArtifact]

    public init(artifacts: [SyntheticArtifact]) throws {
        try fixtureCheck(!artifacts.isEmpty && artifacts.count <= 32, .limit)
        try fixtureCheck(Set(artifacts.map(\.key)).count == artifacts.count, .duplicate)
        self.artifacts = artifacts
    }

    public static func standard() throws -> RegistryFixtures {
        var artifacts: [SyntheticArtifact] = []
        for name in ["fixture-bead", "@fixture/bead"] {
            for (version, age): (String, Int64?) in [
                ("1.0.0", cooldown + 1), ("1.1.0", cooldown), ("1.2.0", cooldown - 1), ("1.3.0", nil),
            ] {
                artifacts.append(try SyntheticArtifact(key: PackageKey(name: name, version: version),
                                                      publishedAt: age.map { now - $0 }))
            }
        }
        return try RegistryFixtures(artifacts: artifacts)
    }

    public func artifact(_ key: PackageKey) throws -> SyntheticArtifact {
        guard let artifact = artifacts.first(where: { $0.key == key }) else { throw FixtureFailure.invalidInput }
        return artifact
    }

    /// Deliberately UNFILTERED upstream metadata. No cooldown policy is implemented here.
    public func packument(name: String, origin: FixtureOrigin = .upstream) throws -> Data {
        let matching = artifacts.filter { $0.key.name == name }.sorted {
            $0.key.version.split(separator: ".").map { Int($0)! }
                .lexicographicallyPrecedes($1.key.version.split(separator: ".").map { Int($0)! })
        }
        try fixtureCheck(!matching.isEmpty)
        var versions: [String: ManifestWithDist] = [:]
        var time: [String: String] = [:]
        let formatter = ISO8601DateFormatter()
        for artifact in matching {
            versions[artifact.key.version] = ManifestWithDist(name: name, version: artifact.key.version,
                dist: Dist(tarball: origin.value + origin.mount + artifact.key.upstreamTarballTarget, integrity: artifact.integrity))
            if let publishedAt = artifact.publishedAt {
                time[artifact.key.version] = formatter.string(from: Date(timeIntervalSince1970: Double(publishedAt)))
            }
        }
        return try json(Packument(name: name, versions: versions, time: time,
                                  distTags: ["latest": matching.last!.key.version]))
    }

    /// A real lockfile v3 for one exact synthetic dependency, with a non-registry-default resolved URL.
    /// Its presence is not a permission to issue that artifact from a gateway.
    public func project(key: PackageKey, origin: FixtureOrigin) throws -> LockedProject {
        let artifact = try artifact(key)
        let dependencies = [key.name: key.version]
        return LockedProject(
            packageJSON: try json(ProjectManifest(name: "fixture-consumer", version: "1.0.0", dependencies: dependencies)),
            lockfile: try json(Lockfile(name: "fixture-consumer", version: "1.0.0", lockfileVersion: 3,
                packages: ["": LockEntry(name: "fixture-consumer", version: "1.0.0", dependencies: dependencies),
                           "node_modules/" + key.name: LockEntry(version: key.version,
                               resolved: origin.value + origin.mount + key.upstreamTarballTarget, integrity: artifact.integrity)])))
    }
}

public struct LockedProject: Sendable { public let packageJSON: Data; public let lockfile: Data }
private struct Dist: Encodable { let tarball: String; let integrity: String }
private struct ManifestWithDist: Encodable { let name: String; let version: String; let dist: Dist }
private struct Packument: Encodable {
    let name: String; let versions: [String: ManifestWithDist]; let time: [String: String]; let distTags: [String: String]
    enum CodingKeys: String, CodingKey { case name, versions, time; case distTags = "dist-tags" }
}
private struct ProjectManifest: Encodable { let name: String; let version: String; let dependencies: [String: String] }
private struct Lockfile: Encodable { let name: String; let version: String; let lockfileVersion: Int; let packages: [String: LockEntry] }
private struct LockEntry: Encodable {
    var name: String? = nil
    let version: String
    var resolved: String? = nil
    var integrity: String? = nil
    var dependencies: [String: String]? = nil
}

/// Small deterministic ustar + gzip (stored DEFLATE block), containing only package/package.json
/// and package/README.txt. No executable, lifecycle scripts, dependencies, links or generated timestamps.
enum SyntheticArchive {
    static func make(manifest: Data) throws -> Data {
        var tar = Data()
        for (name, body) in [("package/package.json", manifest),
                             ("package/README.txt", Data("Synthetic Sanjbox fixture. No executable code.\n".utf8))] {
            var header = [UInt8](repeating: 0, count: 512)
            func put(_ value: String, at offset: Int) {
                for (index, byte) in value.utf8.enumerated() { header[offset + index] = byte }
            }
            put(name, at: 0); put("0000644\0", at: 100); put("0000000\0", at: 108); put("0000000\0", at: 116)
            put(String(repeating: "0", count: 11 - String(body.count, radix: 8).count) + String(body.count, radix: 8) + "\0", at: 124)
            put("00000000000\0", at: 136); put("        ", at: 148); put("0", at: 156)
            put("ustar\0", at: 257); put("00", at: 263)
            let checksum = String(header.reduce(0) { $0 + Int($1) }, radix: 8)
            put(String(repeating: "0", count: 6 - checksum.count) + checksum + "\0 ", at: 148)
            tar.append(contentsOf: header); tar.append(body)
            tar.append(Data(repeating: 0, count: (512 - body.count % 512) % 512))
        }
        tar.append(Data(repeating: 0, count: 1024))
        try fixtureCheck(tar.count <= 65_535, .limit)
        let size = UInt16(tar.count), inverse = ~size
        var gzip = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255, 1,
                         UInt8(size & 255), UInt8(size >> 8), UInt8(inverse & 255), UInt8(inverse >> 8)])
        gzip.append(tar)
        var crc: UInt32 = 0xffff_ffff
        for byte in tar {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
        }
        for word in [~crc, UInt32(tar.count)] {
            for shift in stride(from: 0, through: 24, by: 8) { gzip.append(UInt8((word >> shift) & 255)) }
        }
        return gzip
    }
}
