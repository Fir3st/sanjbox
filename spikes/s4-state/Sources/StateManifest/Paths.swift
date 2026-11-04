import Foundation

// These functions deliberately never call realpath/stat or resolve a declared filesystem path.
func designPath(_ value: String, absolute: Bool) -> Bool {
    guard value.utf8.count <= 1024, !value.isEmpty,
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
          !value.contains("\\") else { return false }
    if !absolute && value == "." { return true }
    guard value.hasPrefix("/") == absolute else { return false }
    let components = (absolute ? String(value.dropFirst()) : value).split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
    if absolute {
        // These common aliases must not receive a false lexical separation verdict.
        for alias in ["/tmp", "/var", "/etc", "/System/Volumes/Data"] {
            if foldedPath(value) == foldedPath(alias) || foldedPath(value).hasPrefix(foldedPath(alias) + "/") { return false }
        }
    }
    return true
}

func foldedPath(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
}

func overlaps(_ left: String, _ right: String) -> Bool {
    let a = foldedPath(left), b = foldedPath(right)
    return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
}

func joined(_ mount: String, _ relative: String) -> String { relative == "." ? mount : mount + "/" + relative }

func identifier(_ text: String) -> Bool {
    (1...32).contains(text.utf8.count) && text.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
}
