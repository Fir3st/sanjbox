import Darwin
import Foundation

/// Kontrola umístění cílového stromu. Cílový strom uvnitř zdrojového kořene by
/// znamenal zápis do zdroje, který se právě exportuje; proto se odmítá ještě před
/// jakýmkoli zápisem.
public enum ExportPathPolicy {
    /// Kanonická absolutní cesta: standardizace `.`/`..` a `realpath` existujícího
    /// předka. Neexistující ocas zůstává lexikální. `URL.resolvingSymlinksInPath`
    /// se nepoužívá, protože pro existující a neexistující cestu vrací nekonzistentní
    /// podobu `/tmp` vs `/private/tmp`.
    public static func canonicalPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var existing = standardized
        var tail: [String] = []
        while !existing.isEmpty && existing != "/" {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            if let resolved = realpath(existing, &buffer) {
                let base = String(cString: resolved)
                return tail.isEmpty ? base : base + "/" + tail.reversed().joined(separator: "/")
            }
            tail.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return standardized
    }

    /// `true`, když je `destination` stejný jako `root` nebo leží pod ním.
    public static func isDestination(_ destination: String, insideRoot root: String) -> Bool {
        let child = canonicalPath(destination)
        let parent = canonicalPath(root)
        if child == parent { return true }
        let prefix = parent.hasSuffix("/") ? parent : parent + "/"
        return child.hasPrefix(prefix)
    }
}
