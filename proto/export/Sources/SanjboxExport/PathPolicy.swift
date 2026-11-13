import Darwin
import Foundation

/// Kontrola umístění cílového stromu. Cílový strom uvnitř zdrojového kořene by
/// znamenal zápis do zdroje. Jde jen o časnou diagnostiku cest; autoritativní kontrola
/// před zápisem používá `DestinationParent.requireOutside` nad připnutými fd.
public enum ExportPathPolicy {
    /// Kanonická absolutní cesta podle `realpath` existujícího předka.
    /// `..` se nesmí odstranit před vyhodnocením symlinků: `alias/..` je rodič
    /// cíle odkazu, nikoli rodič jeho jména. Neexistující ocas zůstává lexikální.
    public static func canonicalPath(_ path: String) -> String {
        let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        var existing = absolute
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
        return absolute
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
