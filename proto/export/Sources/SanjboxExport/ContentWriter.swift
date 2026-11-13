import Darwin
import Foundation

/// Chyba skutečného `write(2)` včetně errno. Testovací zapisovač ji může vyhodit
/// uprostřed kopie a simulovat ENOSPC/EIO, aniž by se mockovala celá kopie.
public struct POSIXWriteError: Error, Equatable, Sendable {
    public let code: Int32

    public init(code: Int32) {
        self.code = code
    }
}

/// Rozhraní pro zápis obsahu do cílového fd. Produkční implementace volá `write(2)`;
/// testy mohou vložit selhání po N bajtech přes stejné rozhraní.
public protocol ContentWriter: Sendable {
    /// Zapíše nejvýše `buffer.count` bajtů a vrátí počet zapsaných bajtů.
    /// Musí vyhodit `POSIXWriteError` (nebo jinou chybu) při selhání.
    func write(fileDescriptor fd: Int32, buffer: UnsafeRawBufferPointer) throws -> Int
}

public struct SystemContentWriter: ContentWriter {
    public init() {}

    public func write(fileDescriptor fd: Int32, buffer: UnsafeRawBufferPointer) throws -> Int {
        let written = Darwin.write(fd, buffer.baseAddress, buffer.count)
        if written < 0 {
            throw POSIXWriteError(code: errno)
        }
        return written
    }
}
