import CoreFoundation
import Foundation

struct NPMArtifact: Equatable, Sendable {
    let name: NPMName
    let version: String
    let published: Date
    let source: NPMArtifactURL
    let integrity: NPMIntegrity
    func eligible(now: Date, cooldown: TimeInterval) -> Bool {
        now.timeIntervalSince1970.isFinite && published <= now && now.timeIntervalSince(published) >= cooldown
    }
}

/// Only the fields reconstructed here leave the gateway. Registry extension
/// fields, scripts, embedded URLs and arbitrary dependency sources never do.
struct NPMPackument {
    let name: NPMName
    let versions: [String: Any]
    let times: [String: Any]
    let tags: [String: Any]
    let configuration: NPMConfiguration

    init(data: Data, expectedName: NPMName, configuration: NPMConfiguration) throws {
        guard data.count <= configuration.maximumMetadataBytes else { throw NPMFailure.tooLarge }
        var scan = StrictJSONScan(data)
        try scan.validate()
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["name"] as? String == expectedName.value,
              let versions = root["versions"] as? [String: Any], versions.count <= configuration.maximumVersions,
              let times = root["time"] as? [String: Any],
              let tags = root["dist-tags"] as? [String: Any] else { throw NPMFailure.metadata }
        name = expectedName
        self.versions = versions
        self.times = times
        self.tags = tags
        self.configuration = configuration
    }

    func artifact(version: String, now: Date) throws -> NPMArtifact {
        guard validNPMVersion(version), let manifest = versions[version] as? [String: Any],
              manifest["name"] as? String == name.value, manifest["version"] as? String == version,
              let rawDate = times[version] as? String, rawDate.utf8.count <= 64,
              rawDate.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?Z$"#, options: .regularExpression) != nil,
              let published = Self.date(rawDate),
              let dist = manifest["dist"] as? [String: Any], let tarball = dist["tarball"] as? String,
              let integrity = dist["integrity"] as? String else { throw NPMFailure.ineligible }
        // Validate the install metadata subset for direct tarballs too: a lockfile
        // request cannot bypass unsupported dependency-source policy.
        _ = try sanitizedFields(manifest)
        let artifact = try NPMArtifact(name: name, version: version, published: published,
                                       source: NPMArtifactURL(tarball, allowedHosts: configuration.artifactHostnames),
                                       integrity: NPMIntegrity(integrity))
        guard artifact.eligible(now: now, cooldown: configuration.cooldown) else { throw NPMFailure.ineligible }
        return artifact
    }

    func filtered(now: Date) throws -> Data {
        var accepted: [String: Any] = [:]
        var acceptedTimes: [String: String] = [:]
        for version in versions.keys.sorted() {
            try Task.checkCancellation()
            // Unusable versions disappear, not the checks on a requested tarball.
            guard let artifact = try? artifact(version: version, now: now),
                  let original = versions[version] as? [String: Any] else { continue }
            var manifest = try sanitizedFields(original)
            manifest["name"] = name.value
            manifest["version"] = version
            manifest["dist"] = ["tarball": configuration.publicOrigin + configuration.mount + name.tarballPath(version: version),
                                "integrity": artifact.integrity.text]
            accepted[version] = manifest
            acceptedTimes[version] = times[version] as? String
        }
        guard !accepted.isEmpty else { throw NPMFailure.ineligible }
        var acceptedTags: [String: String] = [:]
        for (tag, value) in tags {
            guard tag.utf8.count <= 128, tag.range(of: #"^[a-zA-Z][a-zA-Z0-9._-]*$"#, options: .regularExpression) != nil,
                  let version = value as? String, accepted[version] != nil else { continue }
            acceptedTags[tag] = version
        }
        let data = try JSONSerialization.data(withJSONObject: ["name": name.value, "versions": accepted,
                                                               "time": acceptedTimes, "dist-tags": acceptedTags], options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= configuration.maximumMetadataBytes else { throw NPMFailure.tooLarge }
        return data
    }

    private func sanitizedFields(_ manifest: [String: Any]) throws -> [String: Any] {
        // Bundled dependencies bypass individual tarball issuance; not supported.
        for key in ["bundleDependencies", "bundledDependencies"] {
            if let value = manifest[key] {
                guard let array = value as? [Any], array.isEmpty else { throw NPMFailure.ineligible }
            }
        }
        var output: [String: Any] = [:]
        for field in ["dependencies", "optionalDependencies", "peerDependencies", "engines"] {
            guard let value = manifest[field] else { continue }
            guard let entries = value as? [String: String], entries.count <= 512 else { throw NPMFailure.ineligible }
            for (key, spec) in entries {
                if field != "engines" { _ = try NPMName(key) }
                else if key != "node" && key != "npm" { throw NPMFailure.ineligible }
                guard spec.utf8.count <= 256,
                      spec.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || ".*~^<>=|+ -".utf8.contains($0) }) else { throw NPMFailure.ineligible }
                // npm-package-arg recognizes these as local files/directories
                // even without a slash or a file: scheme. Check a trimmed form
                // too, so client-side whitespace normalization cannot bypass it.
                let classified = spec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !classified.hasPrefix("."),
                      ![".tgz", ".tar.gz", ".tar"].contains(where: classified.hasSuffix) else { throw NPMFailure.ineligible }
            }
            output[field] = entries
        }
        for field in ["os", "cpu", "libc"] {
            guard let value = manifest[field] else { continue }
            guard let entries = value as? [String], entries.count <= 32,
                  entries.allSatisfy({ $0.utf8.count <= 64 && $0.range(of: #"^!?[a-z0-9_-]+$"#, options: .regularExpression) != nil }) else { throw NPMFailure.ineligible }
            output[field] = entries
        }
        if let value = manifest["peerDependenciesMeta"] {
            guard let entries = value as? [String: [String: Any]], entries.count <= 512 else { throw NPMFailure.ineligible }
            var peers: [String: [String: Bool]] = [:]
            for (key, flags) in entries {
                _ = try NPMName(key)
                guard flags.keys.allSatisfy({ $0 == "optional" }), let optional = flags["optional"] as? NSNumber,
                      CFGetTypeID(optional) == CFBooleanGetTypeID() else { throw NPMFailure.ineligible }
                peers[key] = ["optional": optional.boolValue]
            }
            output["peerDependenciesMeta"] = peers
        }
        return output
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let date = formatter.date(from: text) else { return nil }
        // Reject normalized impossible calendar dates (e.g. February 31).
        let whole = ISO8601DateFormatter().string(from: date)
        guard whole.prefix(19) == text.prefix(19) else { return nil }
        return date
    }
}

/// Foundation accepts duplicate JSON object keys; reject ambiguity before using
/// it. Bounds apply also to unknown metadata that will be omitted on output.
struct StrictJSONScan {
    let bytes: [UInt8]
    var index = 0
    var nodes = 0
    init(_ data: Data) { bytes = Array(data) }
    mutating func validate() throws {
        try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw NPMFailure.metadata }
    }
    mutating func whitespace() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
    mutating func take(_ byte: UInt8) throws {
        whitespace()
        guard index < bytes.count, bytes[index] == byte else { throw NPMFailure.metadata }
        index += 1
    }
    mutating func string() throws -> String {
        whitespace()
        let start = index
        try take(34)
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
            if byte == 92 { index += 1 }
        }
        throw NPMFailure.metadata
    }
    mutating func value(depth: Int) throws {
        nodes += 1
        guard depth <= 32, nodes <= 100_000 else { throw NPMFailure.tooLarge }
        if nodes % 1024 == 0 { try Task.checkCancellation() }
        whitespace()
        guard index < bytes.count else { throw NPMFailure.metadata }
        switch bytes[index] {
        case 123:
            index += 1; whitespace()
            if index < bytes.count, bytes[index] == 125 { index += 1; return }
            var keys = Set<String>()
            while true {
                guard keys.insert(try string()).inserted else { throw NPMFailure.metadata }
                try take(58); try value(depth: depth + 1); whitespace()
                guard index < bytes.count else { throw NPMFailure.metadata }
                if bytes[index] == 125 { index += 1; return }
                try take(44)
            }
        case 91:
            index += 1; whitespace()
            if index < bytes.count, bytes[index] == 93 { index += 1; return }
            while true {
                try value(depth: depth + 1); whitespace()
                guard index < bytes.count else { throw NPMFailure.metadata }
                if bytes[index] == 93 { index += 1; return }
                try take(44)
            }
        case 34: _ = try string()
        default:
            let start = index
            while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw NPMFailure.metadata }
        }
    }
}
