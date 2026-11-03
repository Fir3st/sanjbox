import Foundation

/// Minimal DNS query parsing for canary detection.
///
/// A canary leaked through a resolver arrives hex-encoded and split across labels, and the wire
/// format separates labels with length bytes, so scanning the raw datagram alone misses it.
enum DNSQuestion {
    /// Bytes of the first question name's labels joined without separators, or `nil` when the
    /// datagram is not a well-formed query. Compression pointers do not occur in a question.
    static func joinedLabels(in datagram: Data) -> Data? {
        let bytes = [UInt8](datagram)
        let headerLength = 12
        guard bytes.count > headerLength,
              bytes[2] & 0x80 == 0,  // QR = 0: query
              (Int(bytes[4]) << 8 | Int(bytes[5])) >= 1  // QDCOUNT
        else { return nil }

        var joined = [UInt8]()
        var offset = headerLength
        var nameLength = 0
        while offset < bytes.count {
            let length = Int(bytes[offset])
            if length == 0 { return Data(joined) }
            nameLength += length + 1
            guard length <= 63, nameLength <= 255, offset + 1 + length <= bytes.count else { return nil }
            joined += bytes[(offset + 1)...(offset + length)]
            offset += 1 + length
        }
        return nil
    }
}
