import Foundation

/// Lexical identifier rules shared by every v0 message. These are text checks only: no identifier
/// is looked up on the host, no UID/GID is resolved and no name is normalised through the
/// filesystem. `sanjbox.state-manifest.v1` uses the same shapes (see README, drift risk).
public enum Identifier {
    /// Zone short prefix: exactly four lowercase ASCII letters/digits (e.g. `a1b2`).
    public static func isValidZoneID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 4 else { return false }
        return bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
    }

    /// Plan/collection identifier: 1...32 lowercase ASCII letters, digits or hyphens.
    public static func isValidPlanID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...32).contains(bytes.count) else { return false }
        return bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    /// Single filename (no path separator, no `.`/`..`), 1...128 UTF-8 bytes.
    public static func isValidFileName(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count), !value.contains("/"), value != ".", value != ".." else { return false }
        return !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    /// DNS hostname used as a gate upstream: lowercase LDH labels, no scheme/port/path/wildcard.
    public static func isValidHostname(_ value: String) -> Bool {
        guard (1...253).contains(value.utf8.count) else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        // A DNS upstream is never an IPv4 literal, including inet_aton-style shortened,
        // octal or hexadecimal dotted forms. IPv6 syntax already fails the LDH rule below.
        let numericLabels = labels.allSatisfy { label in
            if label.hasPrefix("0x") {
                let digits = label.dropFirst(2)
                // Darwin's legacy numeric parser also treats a bare "0x" component as zero.
                // Empty digits must therefore remain numeric-looking and be excluded here.
                return digits.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            }
            return label.utf8.allSatisfy { (48...57).contains($0) }
        }
        guard !numericLabels else { return false }
        return labels.allSatisfy { label in
            let bytes = Array(label.utf8)
            guard (1...63).contains(bytes.count) else { return false }
            guard bytes.first != 45, bytes.last != 45 else { return false }
            return bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}
