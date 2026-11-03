import CryptoKit
import Darwin
import Foundation
import Security

public enum EntitlementState: String, Codable, Sendable {
    case absent, present, unknown
}

public struct SignatureObservation: Codable, Sendable {
    public var fixture: String
    public var sha256: String
    public var validationStatus: Int32
    public var informationStatus: Int32
    public var flags: UInt32?
    public var identifier: String?
    public var getTaskAllow: EntitlementState
    public var otherEntitlements: Bool?
    public var adHoc: Bool?
    public var hardenedRuntime: Bool?
    public var issues: [String]
    /// This only describes this immutable synthetic thin executable at inspection time.
    /// It never grants broker access or proves signing identity, attach resistance, or TCC.
    public var syntheticStaticPolicySatisfied: Bool { issues.isEmpty }
}

public enum SignaturePolicy {
    /// Explicitly absent is required; even a false-valued get-task-allow key is rejected.
    /// This preparation fixture profile permits no entitlements at all.
    public static func issues(validity: Int32, information: Int32, flags: UInt32?,
                              identifier: String?, entitlementState: EntitlementState,
                              otherEntitlements: Bool?) -> [String] {
        var issues: [String] = []
        if validity != errSecSuccess { issues.append("signature invalid or unknown") }
        if information != errSecSuccess || flags == nil || identifier == nil { issues.append("incomplete signature metadata") }
        if flags.map({ $0 & SecCodeSignatureFlags.runtime.rawValue != 0 }) != true { issues.append("hardened runtime absent or unknown") }
        if flags.map({ $0 & SecCodeSignatureFlags.adhoc.rawValue != 0 }) != true { issues.append("only own ad-hoc fixtures admitted") }
        if entitlementState != .absent { issues.append("get-task-allow present or unknown") }
        if otherEntitlements != false { issues.append("unexpected or unknown entitlements") }
        return issues
    }

    public static func entitlementState(dictionary: [String: Any]?, rawBlobPresent: Bool) -> (EntitlementState, Bool?) {
        if let dictionary {
            let prohibited = ["com.apple.security.get-task-allow", "get-task-allow"]
            return (prohibited.contains(where: { dictionary[$0] != nil }) ? .present : .absent,
                    !Set(dictionary.keys).subtracting(prohibited).isEmpty)
        }
        // A missing dictionary does NOT mean absent when Security reports an undecoded blob.
        return rawBlobPresent ? (.unknown, nil) : (.absent, false)
    }
}

/// Inspect only the calling process. A SwiftPM debug build may inject get-task-allow;
/// no fixture work may run until the caller has been sealed with the preparation profile.
public func selfSignatureIssues() -> [String] {
    var code: SecCode?
    let created = SecCodeCopySelf([], &code)
    guard created == errSecSuccess, let code else { return ["caller signature unavailable"] }
    let validity = SecCodeCheckValidity(code, .noNetworkAccess, nil)
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return ["caller static metadata unavailable"] }
    var info: CFDictionary?
    let information = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
    let dictionary = info as? [String: Any]
    let flags = (dictionary?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
    let state = SignaturePolicy.entitlementState(dictionary: dictionary?[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
                                                rawBlobPresent: dictionary?[kSecCodeInfoEntitlements as String] != nil)
    return SignaturePolicy.issues(validity: validity, information: information, flags: flags,
                                  identifier: dictionary?[kSecCodeInfoIdentifier as String] as? String,
                                  entitlementState: state.0, otherEntitlements: state.1)
}

public func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Finite owned-file reader: reject symlinks, hardlinks, group/world writable files and devices.
/// No directory enumeration or content reads outside explicitly selected synthetic inputs.
public func readOwnedFile(_ path: String, maximum: Int) throws -> Data {
    guard maximum > 0, maximum <= SyntheticFixtures.maximumBinaryBytes,
          path.hasPrefix("/"), canonicalPath(path) == path else {
        throw S8Error.refused("noncanonical or symlinked input path")
    }
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw S8Error.refused("cannot open selected synthetic file") }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
          st.st_uid == geteuid(), st.st_nlink == 1, st.st_mode & 0o022 == 0, st.st_flags == 0,
          st.st_size >= 0, st.st_size <= maximum else { throw S8Error.refused("unsafe type, owner, mode, links or size") }
    try requireNoExtendedACL(fd: fd)
    var linked = stat()
    guard lstat(path, &linked) == 0, sameMetadata(st, linked) else { throw S8Error.refused("path identity changed") }
    var bytes = [UInt8](repeating: 0, count: maximum + 1)
    var total = 0
    while total <= maximum {
        let n = bytes.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress!.advanced(by: total), maximum + 1 - total) }
        if n == 0 { break }
        if n < 0 { if errno == EINTR { continue }; throw S8Error.refused("synthetic read failed") }
        total += n
    }
    var after = stat(); var afterPath = stat()
    guard total <= maximum, total == st.st_size, fstat(fd, &after) == 0, lstat(path, &afterPath) == 0,
          sameMetadata(st, after), sameMetadata(st, afterPath) else { throw S8Error.refused("file changed or exceeded bound") }
    try requireNoExtendedACL(fd: fd)
    return Data(bytes.prefix(total))
}

private func canonicalPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func sameMetadata(_ a: stat, _ b: stat) -> Bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid &&
    a.st_gid == b.st_gid && a.st_nlink == b.st_nlink && a.st_size == b.st_size && a.st_flags == b.st_flags &&
    a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
    a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
}

func requireNoExtendedACL(fd: Int32) throws {
    guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
        // On Darwin an open valid fd without extended ACL returns ENOENT. The caller
        // holds and verifies the fd; missing paths are not handled by this function.
        guard errno == ENOENT else { throw S8Error.refused("cannot inspect ACL") }
        return
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    let result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
    // Darwin reports -1/EINVAL for an empty ACL; any actual entry is refused.
    guard result == -1, errno == EINVAL else { throw S8Error.refused("extended ACL present or unknown") }
}

func requireOwnedDirectory(_ path: String) throws {
    guard canonicalPath(path) == path else { throw S8Error.refused("symlink directory") }
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
    guard fd >= 0 else { throw S8Error.refused("directory unavailable") }
    defer { close(fd) }
    var st = stat(); var linked = stat()
    guard fstat(fd, &st) == 0, lstat(path, &linked) == 0, sameMetadata(st, linked), st.st_uid == geteuid(),
          st.st_mode & 0o7777 == 0o700, st.st_flags == 0 else { throw S8Error.refused("unsafe private directory") }
    try requireNoExtendedACL(fd: fd)
}

public struct FixtureManifest: Codable, Sendable {
    public var schema = 1
    public var ownerUID: UInt32
    public var ownerGID: UInt32
    public var sourceSHA256: String
    public var hashes: [String: String]
}

public enum SyntheticFixtures {
    public static let names = ["plain", "hardened", "unsigned", "tampered"]
    public static let source = "volatile const char s8_marker[] = \"SANJBOX_S8_SYNTHETIC_PAYLOAD_V1\"; int main(void) { return s8_marker[0] == 'S' ? 0 : 1; }\n"
    public static let maximumBinaryBytes = 8 * 1024 * 1024

    /// Only creates a fresh 0700 UUID root beneath /private/tmp; never accepts a destination.
    /// No certificate, identity discovery, keychain, timestamp service, or fixture execution.
    public static func prepare() throws -> String {
        let root = "/private/tmp/sanjbox-s8-fixtures-\(UUID().uuidString.lowercased())"
        guard mkdir(root, 0o700) == 0 else { throw S8Error.refused("cannot create fresh fixture root") }
        var originalRoot = stat()
        guard lstat(root, &originalRoot) == 0 else { throw S8Error.refused("new root metadata unavailable") }
        // If a tool fails, preserve the owned root for inspection; report it, do not recursively delete.
        do {
            let sourcePath = root + "/fixture.c"
            try Data(source.utf8).write(to: URL(fileURLWithPath: sourcePath), options: .withoutOverwriting)
            guard chmod(sourcePath, 0o600) == 0 else { throw S8Error.refused("source chmod failed") }
            _ = try BoundedTool.run("/usr/bin/xcrun", ["clang", "-arch", "arm64", "-O0", sourcePath, "-o", root + "/plain"], seconds: 10)
            _ = try BoundedTool.run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--identifier", "org.sanjbox.s8.synthetic", root + "/plain"])
            let plain = try readOwnedFile(root + "/plain", maximum: maximumBinaryBytes)
            try plain.write(to: URL(fileURLWithPath: root + "/hardened"), options: .withoutOverwriting)
            _ = try BoundedTool.run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--options", "runtime", "--identifier", "org.sanjbox.s8.synthetic", root + "/hardened"])
            let hardened = try readOwnedFile(root + "/hardened", maximum: maximumBinaryBytes)
            try hardened.write(to: URL(fileURLWithPath: root + "/unsigned"), options: .withoutOverwriting)
            _ = try BoundedTool.run("/usr/bin/codesign", ["--remove-signature", root + "/unsigned"])
            var tampered = hardened
            let marker = Data("SANJBOX_S8_SYNTHETIC_PAYLOAD_V1".utf8)
            guard let range = tampered.range(of: marker), tampered.range(of: marker, in: range.upperBound..<tampered.endIndex) == nil else {
                throw S8Error.refused("unique synthetic marker unavailable")
            }
            tampered[range.lowerBound] ^= 1
            try tampered.write(to: URL(fileURLWithPath: root + "/tampered"), options: .withoutOverwriting)
            var hashes: [String: String] = [:]
            for name in names {
                hashes[name] = sha256(try readOwnedFile(root + "/" + name, maximum: maximumBinaryBytes))
                guard chmod(root + "/" + name, 0o500) == 0 else { throw S8Error.refused("fixture chmod failed") }
            }
            let manifest = FixtureManifest(ownerUID: geteuid(), ownerGID: originalRoot.st_gid, sourceSHA256: sha256(Data(source.utf8)), hashes: hashes)
            try JSONEncoder().encode(manifest).write(to: URL(fileURLWithPath: root + "/manifest.json"), options: .withoutOverwriting)
            guard chmod(root + "/manifest.json", 0o400) == 0 else { throw S8Error.refused("manifest chmod failed") }
            return root
        } catch { throw S8Error.refused("fixture preparation incomplete at \(root): \(error)") }
    }

    public static func verifyRoot(_ path: String, allowMissingFiles: Bool = false) throws -> FixtureManifest {
        guard path.hasPrefix("/private/tmp/sanjbox-s8-fixtures-"),
              UUID(uuidString: String(path.dropFirst("/private/tmp/sanjbox-s8-fixtures-".count))) != nil,
              canonicalPath(path) == path else {
            throw S8Error.refused("expected exact private synthetic UUID root")
        }
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == geteuid(), st.st_mode & 0o777 == 0o700 else {
            throw S8Error.refused("unsafe fixture root")
        }
        try requireOwnedDirectory(path)
        let contents = try FileManager.default.contentsOfDirectory(atPath: path)
        let known = Set(names + ["fixture.c", "manifest.json"])
        guard (allowMissingFiles ? Set(contents).isSubset(of: known) && contents.contains("manifest.json") : Set(contents) == known) else {
            throw S8Error.refused("unexpected or incomplete fixture contents")
        }
        let manifest = try JSONDecoder().decode(FixtureManifest.self, from: readOwnedFile(path + "/manifest.json", maximum: 4096))
        guard manifest.schema == 1, manifest.ownerUID == geteuid(), manifest.ownerGID == st.st_gid, Set(manifest.hashes.keys) == Set(names),
              manifest.sourceSHA256 == sha256(Data(source.utf8)) else {
            throw S8Error.refused("synthetic source or manifest mismatch")
        }
        if contents.contains("fixture.c"), sha256(try readOwnedFile(path + "/fixture.c", maximum: 4096)) != manifest.sourceSHA256 {
            throw S8Error.refused("synthetic source changed")
        }
        for name in names where contents.contains(name) {
            guard sha256(try readOwnedFile(path + "/" + name, maximum: maximumBinaryBytes)) == manifest.hashes[name] else {
                throw S8Error.refused("synthetic fixture hash changed")
            }
        }
        for name in names + ["fixture.c", "manifest.json"] where contents.contains(name) {
            let expectedMode: mode_t = name == "fixture.c" ? 0o600 : (name == "manifest.json" ? 0o400 : 0o500)
            var metadata = stat()
            guard lstat(path + "/" + name, &metadata) == 0, metadata.st_mode & 0o7777 == expectedMode,
                  metadata.st_uid == manifest.ownerUID, metadata.st_gid == manifest.ownerGID, metadata.st_nlink == 1, metadata.st_flags == 0 else {
                throw S8Error.refused("fixture permission or ownership changed")
            }
        }
        return manifest
    }

    public static func inspect(root: String, name: String) throws -> SignatureObservation {
        guard names.contains(name) else { throw S8Error.refused("fixture name is not allowed") }
        let manifest = try verifyRoot(root)
        let path = root + "/" + name
        let data = try readOwnedFile(path, maximum: maximumBinaryBytes)
        var beforeMetadata = stat()
        guard lstat(path, &beforeMetadata) == 0 else { throw S8Error.refused("fixture metadata unavailable") }
        // MH_MAGIC_64, CPU_TYPE_ARM64; reject universal and other formats, since signing
        // information reflects one slice even with all-slice validity checking enabled.
        guard data.count >= 32, Array(data.prefix(8)) == [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1] else {
            throw S8Error.refused("only generated thin arm64 Mach-O accepted")
        }
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
        var validity = created; var information = created; var info: CFDictionary?
        if let code, created == errSecSuccess {
            validity = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | SecCSFlags.noNetworkAccess.rawValue), nil)
            information = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        }
        let dictionary = info as? [String: Any]
        let flags = (dictionary?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
        let identifier = dictionary?[kSecCodeInfoIdentifier as String] as? String
        let entitlements = SignaturePolicy.entitlementState(
            dictionary: dictionary?[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
            rawBlobPresent: dictionary?[kSecCodeInfoEntitlements as String] != nil
        )
        let after = try verifyRoot(root)
        var afterMetadata = stat()
        guard after.hashes == manifest.hashes, lstat(path, &afterMetadata) == 0,
              sameMetadata(beforeMetadata, afterMetadata) else { throw S8Error.refused("fixture changed during static inspection") }
        return .init(fixture: name, sha256: sha256(data), validationStatus: validity, informationStatus: information,
                     flags: flags, identifier: identifier, getTaskAllow: entitlements.0, otherEntitlements: entitlements.1,
                     adHoc: flags.map { $0 & SecCodeSignatureFlags.adhoc.rawValue != 0 },
                     hardenedRuntime: flags.map { $0 & SecCodeSignatureFlags.runtime.rawValue != 0 },
                     issues: SignaturePolicy.issues(validity: validity, information: information, flags: flags,
                                                    identifier: identifier, entitlementState: entitlements.0, otherEntitlements: entitlements.1))
    }

    /// No recursive delete. Entire manifest validated before the first unlink; mismatches refuse.
    /// Intended only for quiescent own fixtures, not hostile same-UID concurrent modification.
    public static func cleanup(root: String, apply: Bool = true) throws {
        guard root.hasPrefix("/private/tmp/sanjbox-s8-fixtures-"),
              UUID(uuidString: String(root.dropFirst("/private/tmp/sanjbox-s8-fixtures-".count))) != nil else {
            throw S8Error.refused("invalid cleanup root")
        }
        var metadata = stat()
        if lstat(root, &metadata) != 0, errno == ENOENT { return } // idempotent after successful removal
        try requireOwnedDirectory(root)
        // Recover the narrow crash window after the last unlink and before rmdir.
        // This can only remove an empty, canonical, owned 0700 UUID directory.
        if try FileManager.default.contentsOfDirectory(atPath: root).isEmpty {
            if apply, rmdir(root) != 0 { throw S8Error.refused("empty-root cleanup failed") }
            return
        }
        _ = try verifyRoot(root, allowMissingFiles: true)
        guard apply else { return }
        for name in names + ["fixture.c", "manifest.json"] {
            guard unlink(root + "/" + name) == 0 || errno == ENOENT else { throw S8Error.refused("cleanup incomplete; inspect selected root") }
        }
        guard rmdir(root) == 0 else { throw S8Error.refused("cleanup root not empty") }
    }
}
