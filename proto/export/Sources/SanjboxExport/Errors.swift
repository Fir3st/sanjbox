import Foundation

/// Chyby řízeného exportu. Každá chyba znamená **fail-closed**: export nesmí pokračovat
/// s částečným nebo neověřeným výsledkem.
public enum ExportError: Error, Equatable, CustomStringConvertible {
    /// Kořen exportu nelze otevřít jako adresář.
    case invalidRoot(path: String, errno: Int32)
    /// Plán obsahuje odmítnuté položky; apply se neprovede vůbec.
    case planNotClean(paths: [String])
    /// Cílový kořen už existuje. Cílový strom se nikdy nepoužívá opakovaně.
    case destinationExists(path: String)
    /// Cílový kořen nelze vytvořit nebo není adresář.
    case destinationInvalid(path: String, errno: Int32)
    /// Soubor se mezi preview a kopií změnil (inode/dev/size/nlink). TOCTOU detekováno.
    case identityMismatch(path: String, expected: FileSnapshot, actual: FileSnapshot)
    /// Soubor už v okamžiku kopie nejde bezpečně otevřít (zmizel, je z něj symlink,
    /// přibyl mu hardlink, změnil se typ). Rozhodnutí preview už neplatí.
    case sourceUnavailable(path: String, reason: SelectionReason, detail: String?)
    /// Cílový soubor už existuje; nepřepisujeme.
    case overwriteRefused(path: String)
    /// Karanténu nelze nastavit nebo ověřit. Export končí chybou, žádný tichý fallback.
    case quarantineFailed(path: String, errno: Int32)
    /// Jiná I/O chyba.
    case io(path: String, operation: String, errno: Int32)

    public var description: String {
        switch self {
        case let .invalidRoot(path, code):
            return "invalid root \(path): \(SyscallErrorText.text(code))"
        case let .planNotClean(paths):
            return "plan contains rejected entries: \(paths.joined(separator: ", "))"
        case let .destinationExists(path):
            return "destination already exists: \(path)"
        case let .destinationInvalid(path, code):
            return "destination invalid \(path): \(SyscallErrorText.text(code))"
        case let .identityMismatch(path, expected, actual):
            return "source changed between preview and copy at \(path): "
                + "expected dev=\(expected.device) ino=\(expected.inode) size=\(expected.size) nlink=\(expected.linkCount), "
                + "got dev=\(actual.device) ino=\(actual.inode) size=\(actual.size) nlink=\(actual.linkCount)"
        case let .sourceUnavailable(path, reason, detail):
            let suffix = detail.map { " (\($0))" } ?? ""
            return "source is no longer usable at copy time: \(path): \(reason.rawValue)\(suffix)"
        case let .overwriteRefused(path):
            return "refusing to overwrite existing destination file: \(path)"
        case let .quarantineFailed(path, code):
            return "cannot set or verify quarantine on \(path): \(SyscallErrorText.text(code))"
        case let .io(path, operation, code):
            return "\(operation) failed for \(path): \(SyscallErrorText.text(code))"
        }
    }
}

enum SyscallErrorText {
    static func text(_ code: Int32) -> String {
        let message = String(cString: strerror(code))
        return "errno \(code) (\(message))"
    }
}
