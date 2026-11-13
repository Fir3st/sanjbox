import Darwin
import Foundation

/// Karanténní příznak, který macOS nastavuje staženým souborům (Gatekeeper).
/// Export z oblasti ho nastavuje explicitně, aby výsledek nebyl „důvěryhodný“ jen tím,
/// že vznikl lokální kopií.
public enum Quarantine {
    public static let xattrName = "com.apple.quarantine"

    /// `0081` = příznak „quarantine + data ze sítě“, `00000000` = neznámé časové razítko,
    /// `Sanjbox` = jméno agenta. Formát je `<flags>;<timestamp>;<agent>;`.
    public static let defaultValue = "0081;00000000;Sanjbox;"

    /// Přečte aktuální hodnotu xattr z otevřeného fd, nebo `nil`.
    public static func read(fileDescriptor fd: Int32) -> String? {
        let size = fgetxattr(fd, xattrName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(size))
        let read = buffer.withUnsafeMutableBytes { raw in
            fgetxattr(fd, xattrName, raw.baseAddress, raw.count, 0, 0)
        }
        guard read == size else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// Rozhraní pro zápis karantény. Jediné systémové volání, které jde v testech nahradit mockem —
/// test `quarantineFailureAbortsExport` používá **mock**, který zápis odmítne, a ověřuje,
/// že export skončí chybou místo tichého fallbacku.
public protocol QuarantineWriter: Sendable {
    /// Nastaví `com.apple.quarantine` na otevřený fd. Musí selhat, když xattr nelze zapsat.
    func writeQuarantine(value: String, fileDescriptor fd: Int32) throws
    /// Ověří, že hodnota na fd skutečně je. Musí selhat, když se hodnota liší.
    func verifyQuarantine(value: String, fileDescriptor fd: Int32) throws
}

public struct QuarantineWriteError: Error, Equatable, CustomStringConvertible {
    /// `errno`, nebo `QuarantineWriteError.mismatchCode` při neshodě po zápisu.
    public let code: Int32
    public let detail: String

    public static let mismatchCode: Int32 = -1

    public var description: String { detail }
}

public struct SystemQuarantineWriter: QuarantineWriter {
    public init() {}

    public func writeQuarantine(value: String, fileDescriptor fd: Int32) throws {
        let bytes = Array(value.utf8)
        let result = bytes.withUnsafeBufferPointer { buffer in
            fsetxattr(fd, Quarantine.xattrName, buffer.baseAddress, buffer.count, 0, 0)
        }
        guard result == 0 else {
            throw QuarantineWriteError(
                code: errno,
                detail: "fsetxattr(\(Quarantine.xattrName)) failed: \(SyscallErrorText.text(errno))"
            )
        }
    }

    public func verifyQuarantine(value: String, fileDescriptor fd: Int32) throws {
        guard let current = Quarantine.read(fileDescriptor: fd) else {
            throw QuarantineWriteError(
                code: QuarantineWriteError.mismatchCode,
                detail: "\(Quarantine.xattrName) is missing after write"
            )
        }
        guard current == value else {
            throw QuarantineWriteError(
                code: QuarantineWriteError.mismatchCode,
                detail: "\(Quarantine.xattrName) is '\(current)', expected '\(value)'"
            )
        }
    }
}
