import Darwin
import Foundation

public enum ProvenanceReceiver {
    /// One listener, at most 16 contacts and 10 seconds; no detached workers or unbounded drain.
    public static func run(_ journal: NetworkJournal) throws -> Bool {
        let registration = journal.registration
        try registration.validate(receiver: true)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(registration.durationMilliseconds) * 1_000_000
        var listener: Int32 = -1
        var contacts = 0
        var matched = false
        var allReadsFinished = true
        var stopReason = "windowElapsed"
        var operationFinished = true
        do {
            listener = try NetworkIO.openSocket(registration)
            var address = try SocketAddress(registration.endpoint)
            guard address.withSockaddr({ bind(listener, $0, $1) }) == 0 else { throw ProvenanceError("bind errno \(errno)") }
            if registration.transport == .tcp {
                guard listen(listener, 8) == 0 else { throw ProvenanceError("listen errno \(errno)") }
            }
            let local = try NetworkIO.endpoint(listener)
            var started = journal.event("receiverStarted"); started.local = local
            try journal.append(started)
            try emitProvenanceJSON(["output": journal.path, "host": local.host, "port": String(local.port)])
            while contacts < registration.maximumContacts, try NetworkIO.wait(listener, events: Int16(POLLIN), until: deadline) {
                if registration.transport == .tcp {
                    let fd = accept(listener, nil, nil)
                    if fd < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                    guard fd >= 0 else { throw ProvenanceError("accept errno \(errno)") }
                    contacts += 1
                    defer { close(fd) }
                    // Accepted contact is durable before configuration or application reads.
                    var accepted = journal.event("accepted"); accepted.contactID = contacts
                    accepted.local = try? NetworkIO.endpoint(fd); accepted.remote = try? NetworkIO.endpoint(fd, peer: true)
                    try journal.append(accepted)
                    let raw = try journal.beginRaw(name: "received-\(contacts).bin")
                    var bytes = Data(); var reason = "peerEOF"; var truncated = false
                    do {
                        try NetworkIO.configure(fd)
                        let readDeadline = min(deadline, DispatchTime.now().uptimeNanoseconds + 500_000_000)
                        var buffer = [UInt8](repeating: 0, count: 4096)
                        while true {
                            guard try NetworkIO.wait(fd, events: Int16(POLLIN), until: readDeadline) else { reason = "readDeadline"; break }
                            let count = Darwin.read(fd, &buffer, min(buffer.count, 4096 - bytes.count))
                            if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                            guard count >= 0 else { throw ProvenanceError("read errno \(errno)") }
                            if count == 0 { break }
                            let chunk = Data(buffer.prefix(count))
                            try raw.append(chunk)
                            bytes.append(chunk)
                            if bytes.count == 4096 { truncated = true; reason = "rawLimit"; break }
                        }
                    } catch {
                        if raw.failed { throw error } // Do not claim a hash/count for a partially persisted chunk.
                        reason = "\(error)"
                    }
                    let finished = reason == "peerEOF" && accepted.local != nil && accepted.remote != nil
                    allReadsFinished = allReadsFinished && finished
                    try record(journal, kind: "closed", contact: contacts, bytes: bytes, local: accepted.local,
                        remote: accepted.remote, truncated: truncated, reason: reason, finished: finished, matched: &matched, rawAlreadySaved: true)
                } else {
                    // recvmsg exposes MSG_TRUNC; bound exact address is the destination (wildcards rejected).
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    var remote = sockaddr_storage()
                    var flags: Int32 = 0
                    var remoteLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
                    let count = withUnsafeMutablePointer(to: &remote) { name in
                        buffer.withUnsafeMutableBytes { raw -> Int in
                            var vector = iovec(iov_base: raw.baseAddress, iov_len: raw.count)
                            return withUnsafeMutablePointer(to: &vector) { vector in
                                var message = msghdr(msg_name: UnsafeMutableRawPointer(name), msg_namelen: remoteLength,
                                    msg_iov: vector, msg_iovlen: 1, msg_control: nil, msg_controllen: 0, msg_flags: 0)
                                let result = recvmsg(listener, &message, 0)
                                flags = message.msg_flags; remoteLength = message.msg_namelen
                                return result
                            }
                        }
                    }
                    if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                    guard count >= 0 else { throw ProvenanceError("recvmsg errno \(errno)") }
                    contacts += 1
                    let truncated = flags & MSG_TRUNC != 0 || count > buffer.count
                    let remoteEndpoint = try? NetworkIO.decode(&remote, length: remoteLength)
                    var contact = journal.event("datagramContact"); contact.contactID = contacts
                    contact.local = local; contact.remote = remoteEndpoint; contact.bytes = min(count, buffer.count); contact.rawTruncated = truncated
                    try journal.append(contact) // Preserve contact before any raw storage/parsing failure.
                    allReadsFinished = allReadsFinished && !truncated && remoteEndpoint != nil
                    try record(journal, kind: "datagram", contact: contacts, bytes: Data(buffer.prefix(min(count, buffer.count))),
                        local: local, remote: remoteEndpoint, truncated: truncated,
                        reason: truncated ? "datagramTruncated" : "datagramReceived", finished: !truncated && remoteEndpoint != nil, matched: &matched)
                }
            }
            if contacts == registration.maximumContacts { stopReason = "contactLimit"; operationFinished = false }
        } catch { stopReason = "\(error)"; operationFinished = false }
        if listener >= 0 { close(listener) }
        var stopped = journal.event("receiverStopped"); stopped.reason = stopReason
        stopped.operationFinished = operationFinished && allReadsFinished; stopped.contactID = contacts
        try journal.append(stopped)
        return stopped.operationFinished == true
    }
    private static func record(_ journal: NetworkJournal, kind: String, contact: Int, bytes: Data,
                               local: NetworkEndpoint?, remote: NetworkEndpoint?, truncated: Bool,
                               reason: String, finished: Bool, matched: inout Bool, rawAlreadySaved: Bool = false) throws {
        let name = "received-\(contact).bin"
        let digest = try rawAlreadySaved ? provenanceDigest(bytes) : journal.raw(bytes, name: name)
        var event = journal.event(kind); event.contactID = contact; event.local = local; event.remote = remote
        event.bytes = bytes.count; event.rawFile = name; event.rawSHA256 = digest; event.rawTruncated = truncated
        event.reason = reason; event.operationFinished = finished
        event.payloadClaims = FlowChallenge.claims(bytes)
        let matches = !truncated && bytes == journal.registration.flow.bytes
        event.matchesRegisteredPayload = matches; event.repeatedRegisteredPayload = matches && matched
        matched = matched || matches
        try journal.append(event)
    }
}
