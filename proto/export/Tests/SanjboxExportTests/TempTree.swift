import Darwin
import Foundation

/// Dočasný strom pro testy. Vzniká výhradně pod `/private/tmp/h5-export-<uuid>` a `remove()`
/// maže jen ten svůj strom. Žádná testovací cesta neleží v domovském adresáři ani ve sdílených
/// systémových adresářích.
final class TempTree {
    let root: String

    init(label: String = "tree") throws {
        let base = "/private/tmp"
        var candidate = ""
        var created = false
        for _ in 0..<8 {
            candidate = "\(base)/h5-export-\(label)-\(UUID().uuidString.lowercased())"
            if candidate.withCString({ mkdir($0, 0o700) }) == 0 {
                created = true
                break
            }
            if errno != EEXIST { break }
        }
        guard created else {
            throw NSError(domain: "TempTree", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "cannot create temp tree under /private/tmp",
            ])
        }
        root = candidate
    }

    deinit {
        remove()
    }

    func path(_ relative: String) -> String {
        relative.isEmpty ? root : root + "/" + relative
    }

    func makeDirectory(_ relative: String, mode: mode_t = 0o700) throws {
        let target = path(relative)
        if target.withCString({ mkdir($0, mode) }) != 0 && errno != EEXIST {
            throw NSError(domain: "TempTree", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "mkdir \(target) failed",
            ])
        }
    }

    func writeFile(_ relative: String, contents: String, mode: mode_t = 0o644) throws {
        let target = path(relative)
        let parent = (target as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: target, contents: Data(contents.utf8)) else {
            throw NSError(domain: "TempTree", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "cannot write \(target)",
            ])
        }
        chmod(target, mode)
    }

    func writeBytes(_ relative: String, bytes: [UInt8]) throws {
        let target = path(relative)
        let parent = (target as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try Data(bytes).write(to: URL(fileURLWithPath: target))
    }

    func makeSymlink(_ relative: String, target: String) throws {
        let linkPath = path(relative)
        let parent = (linkPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        guard symlink(target, linkPath) == 0 else {
            throw NSError(domain: "TempTree", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "symlink \(linkPath) failed",
            ])
        }
    }

    /// Vytvoří tvrdý odkaz: obě jména ukazují na stejný inode, `st_nlink == 2`.
    func makeHardlink(_ relative: String, to newRelative: String) throws {
        let source = path(relative)
        let destination = path(newRelative)
        let parent = (destination as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        guard link(source, destination) == 0 else {
            throw NSError(domain: "TempTree", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "link \(source) -> \(destination) failed",
            ])
        }
    }

    func makeFIFO(_ relative: String) throws {
        let target = path(relative)
        guard mkfifo(target, 0o600) == 0 else {
            throw NSError(domain: "TempTree", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "mkfifo \(target) failed",
            ])
        }
    }

    func remove() {
        guard root.hasPrefix("/private/tmp/h5-export-") else { return }
        try? FileManager.default.removeItem(atPath: root)
    }

    /// Rekurzivní popis stromu bez obsahu souborů: jméno, druh, velikost, práva, cíle odkazů.
    /// Slouží k tvrzení „preview nic nezapsalo“.
    func structure() -> [String] {
        var entries: [String] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .fileResourceIdentifierKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: keys
        ) else { return entries }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let relative = String(url.path.dropFirst(root.count))
            let kind: String
            if values?.isSymbolicLink == true {
                kind = "link->" + ((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "?")
            } else if values?.isDirectory == true {
                kind = "dir"
            } else {
                kind = "file"
            }
            entries.append("\(relative)|\(kind)|\(values?.fileSize ?? -1)")
        }
        return entries.sorted()
    }

    /// Obsah regulérních souborů podle relativní cesty, aby šlo dokázat, že se bajty nezměnily.
    func contents() -> [String: String] {
        var result: [String: String] = [:]
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)
        else { return result }
        for case let url as URL in enumerator {
            guard let data = try? Data(contentsOf: url) else { continue }
            result[String(url.path.dropFirst(root.count))] = String(decoding: data, as: UTF8.self)
        }
        return result
    }
}
