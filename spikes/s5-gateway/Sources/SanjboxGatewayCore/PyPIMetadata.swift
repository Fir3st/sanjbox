import CoreFoundation
import Foundation

public struct PyPIConfiguration: Sendable {
    public let registryHostname: String
    public let artifactHostnames: Set<String>
    public let publicOrigin: String
    public let mount: String
    public let cooldown: TimeInterval
    public let limits: RegistryLimits
    public init(registryHostname: String = "pypi.org", artifactHostnames: Set<String> = ["files.pythonhosted.org"],
                publicOrigin: String, mount: String = "/pypi", cooldown: TimeInterval,
                limits: RegistryLimits = try! RegistryLimits()) throws {
        guard cooldown.isFinite, cooldown >= 0 else { throw RegistryFailure.configuration }
        self.registryHostname = try DestinationPolicy.validatedHostname(registryHostname)
        self.artifactHostnames = try Set(artifactHostnames.map(DestinationPolicy.validatedHostname))
        self.publicOrigin = try registryOrigin(publicOrigin); self.mount = try registryMount(mount)
        self.cooldown = cooldown; self.limits = limits
    }
}
struct PyPIName: Equatable, Sendable {
    let value: String
    init(_ raw: String) throws {
        guard raw.utf8.count <= 200,
              raw.range(of: #"^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil else { throw RegistryFailure.target }
        value = raw.lowercased().replacingOccurrences(of: #"[-_.]+"#, with: "-", options: .regularExpression)
    }
}
func pypiFilename(_ text: String) -> Bool {
    (1...240).contains(text.utf8.count) && text.first != "." && !text.contains("..") &&
    text.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || "-_.+".utf8.contains($0) } &&
    (text.hasSuffix(".whl") || text.hasSuffix(".tar.gz"))
}
/// Filename identity subset of wheel/sdist conventions; does not inspect or
/// execute archive metadata. PEP 440 resolution remains the client's job.
func pypiVersion(_ filename: String, project: PyPIName) throws -> String {
    let distribution: String
    let version: String
    if filename.hasSuffix(".whl") {
        let parts = String(filename.dropLast(4)).components(separatedBy: "-")
        guard parts.count == 5 || parts.count == 6 else { throw RegistryFailure.denied }
        distribution = parts[0]; version = parts[1]
        if parts.count == 6 {
            guard let first = parts[2].utf8.first, (48...57).contains(first), !parts[2].isEmpty,
                  parts[2].utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else { throw RegistryFailure.denied }
        }
        guard parts.suffix(3).allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || "_.".utf8.contains($0)
        } }) else { throw RegistryFailure.denied }
    } else {
        let stem = String(filename.dropLast(7))
        guard filename.hasSuffix(".tar.gz"), let separator = stem.lastIndex(of: "-") else { throw RegistryFailure.denied }
        distribution = String(stem[..<separator]); version = String(stem[stem.index(after: separator)...])
    }
    guard (try? PyPIName(distribution)) == project, version.utf8.count <= 128,
          version.range(of: #"^[0-9][A-Za-z0-9_.+]*$"#, options: .regularExpression) != nil else { throw RegistryFailure.denied }
    return version
}
enum PyPITarget: Sendable {
    case index(PyPIName), file(PyPIName, String)
    init(_ target: String, mount: String) throws {
        let parts = target.components(separatedBy: "/")
        if parts.count == 5, parts[1] == String(mount.dropFirst()), parts[2] == "simple", parts[4].isEmpty {
            let name = try PyPIName(parts[3])
            guard name.value == parts[3] else { throw RegistryFailure.target }
            self = .index(name)
        } else if parts.count == 5, parts[1] == String(mount.dropFirst()), parts[2] == "files", pypiFilename(parts[4]) {
            let name = try PyPIName(parts[3])
            guard name.value == parts[3] else { throw RegistryFailure.target }
            self = .file(name, parts[4])
        } else { throw RegistryFailure.target }
    }
}
struct PyPIArtifact: Sendable, Equatable {
    let project: PyPIName
    let filename: String
    let version: String
    let uploaded: String
    let published: Date
    let source: NPMArtifactURL
    let sha256: String
    let size: Int
    let requiresPython: String?
    func eligible(now: Date, cooldown: TimeInterval) -> Bool {
        now.timeIntervalSince1970.isFinite && published <= now && now.timeIntervalSince(published) >= cooldown
    }
}
struct PyPISimpleIndex {
    let project: PyPIName
    let files: [[String: Any]]
    let configuration: PyPIConfiguration
    init(data: Data, project: PyPIName, configuration: PyPIConfiguration) throws {
        let root = try registryJSON(data, maximum: configuration.limits.metadataBytes)
        guard let rawName = root["name"] as? String, try PyPIName(rawName) == project,
              let meta = root["meta"] as? [String: Any],
              let version = meta["api-version"] as? String, ["1.1", "1.2", "1.3", "1.4"].contains(version),
              let files = root["files"] as? [[String: Any]], files.count <= configuration.limits.files else { throw RegistryFailure.metadata }
        // Current normative 1.4 schema uses a root dictionary. The pinned
        // specification also retains a legacy example under meta: if either
        // form is present it must explicitly be active; conflicts fail closed.
        if let value = root["project-status"] {
            guard let status = value as? [String: Any], status["status"] as? String == "active" else { throw RegistryFailure.denied }
        }
        if let status = meta["project-status"] { guard status as? String == "active" else { throw RegistryFailure.denied } }
        var names = Set<String>()
        for file in files {
            guard let name = file["filename"] as? String, pypiFilename(name), names.insert(name).inserted else { throw RegistryFailure.metadata }
        }
        self.project = project; self.files = files; self.configuration = configuration
    }
    func artifact(_ filename: String, now: Date) throws -> PyPIArtifact {
        guard let file = files.first(where: { $0["filename"] as? String == filename }),
              let rawDate = file["upload-time"] as? String, let published = registryDate(rawDate),
              let size = registrySize(file["size"]), size <= configuration.limits.artifactBytes,
              let hashes = file["hashes"] as? [String: String], let hash = hashes["sha256"], registryValidDigest(hash),
              let rawURL = file["url"] as? String else { throw RegistryFailure.denied }
        if let yanked = file["yanked"] {
            guard let boolean = yanked as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID(), !boolean.boolValue else { throw RegistryFailure.denied }
        }
        var requires: String?
        if let value = file["requires-python"], !(value is NSNull) {
            guard let text = value as? String, text.utf8.count <= 256,
                  text.utf8.allSatisfy({ (32...126).contains($0) }) else { throw RegistryFailure.denied }
            requires = text
        }
        let source: NPMArtifactURL
        do { source = try NPMArtifactURL(rawURL, allowedHosts: configuration.artifactHostnames) }
        catch { throw RegistryFailure.denied }
        guard source.path.split(separator: "/").last.map(String.init) == filename else { throw RegistryFailure.denied }
        let artifact = try PyPIArtifact(project: project, filename: filename, version: pypiVersion(filename, project: project), uploaded: rawDate, published: published,
                                    source: source, sha256: hash, size: size, requiresPython: requires)
        guard artifact.eligible(now: now, cooldown: configuration.cooldown) else { throw RegistryFailure.denied }
        return artifact
    }
    func filtered(now: Date) throws -> Data {
        var output: [[String: Any]] = []
        for file in files {
            try Task.checkCancellation()
            guard let filename = file["filename"] as? String, let artifact = try? artifact(filename, now: now) else { continue }
            var item: [String: Any] = ["filename": filename, "url": configuration.publicOrigin + configuration.mount + "/files/" + project.value + "/" + filename,
                                       "hashes": ["sha256": artifact.sha256], "size": artifact.size, "upload-time": artifact.uploaded]
            if let requires = artifact.requiresPython { item["requires-python"] = requires }
            output.append(item)
        }
        let data = try JSONSerialization.data(withJSONObject: ["meta": ["api-version": "1.1"], "name": project.value, "files": output], options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= configuration.limits.metadataBytes else { throw RegistryFailure.tooLarge }
        return data
    }
}
