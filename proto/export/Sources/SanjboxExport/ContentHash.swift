import CryptoKit
import Foundation

/// SHA-256 obsahu souboru. Identita souboru nestačí: přepis na místě se stejnou
/// velikostí a stejným inode by jinak prošel a export by vyvezl jiné bajty než preview.
enum ContentHash {
    /// Přečte celý soubor z fd od jeho aktuální pozice a vrátí hex SHA-256.
    /// Chyby čtení vrací jako `SafePath.Rejection`, aby je volající klasifikoval stejně
    /// jako ostatní I/O selhání.
    static func sha256(fileDescriptor fd: Int32, maximumBytes: Int64, bufferSize: Int = 64 * 1024) -> Result<String, SafePath.Rejection> {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: max(bufferSize, 4096))
        var total: Int64 = 0
        while true {
            let remaining = maximumBytes - total
            let limit = remaining >= Int64(buffer.count) ? buffer.count : Int(remaining) + 1
            let count = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, limit)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(SafePath.rejection(
                    errno: errno,
                    component: "<content>",
                    operation: "read"
                ))
            }
            guard Int64(count) <= remaining else {
                return .failure(SafePath.Rejection(reason: .ioError, detail: "source grew while hashing"))
            }
            total += Int64(count)
            hasher.update(data: Data(buffer[0..<count]))
        }
        guard total == maximumBytes else {
            return .failure(SafePath.Rejection(reason: .ioError, detail: "source shrank while hashing"))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .success(digest)
    }
}
