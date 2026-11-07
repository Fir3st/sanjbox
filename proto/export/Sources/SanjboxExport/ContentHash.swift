import CryptoKit
import Foundation

/// SHA-256 obsahu souboru. Identita souboru nestačí: přepis na místě se stejnou
/// velikostí a stejným inode by jinak prošel a export by vyvezl jiné bajty než preview.
enum ContentHash {
    /// Přečte celý soubor z fd od jeho aktuální pozice a vrátí hex SHA-256.
    /// Chyby čtení vrací jako `SafePath.Rejection`, aby je volající klasifikoval stejně
    /// jako ostatní I/O selhání.
    static func sha256(fileDescriptor fd: Int32, bufferSize: Int = 64 * 1024) -> Result<String, SafePath.Rejection> {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: max(bufferSize, 4096))
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, raw.count)
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
            hasher.update(data: Data(buffer[0..<count]))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .success(digest)
    }
}
