import Darwin
import Foundation
import SanjboxNetworkProvenance

public enum ProvenanceSender {
    /// One preregistered frame, one socket, one absolute deadline. No DNS, redirects or retries
    /// using another socket. TCP send completion and UDP send completion are only local acceptance.
    public static func run(_ journal: NetworkJournal) throws -> Bool {
        let registration = journal.registration
        try registration.validate(receiver: false)
        let frame = registration.flow.bytes
        let digest = try journal.raw(frame, name: "sent.bin")
        var started = journal.event("attemptStarted"); started.target = registration.endpoint
        started.bytes = frame.count; started.rawFile = "sent.bin"; started.rawSHA256 = digest
        started.localKernelAcceptedBytes = 0
        try journal.append(started)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(registration.durationMilliseconds) * 1_000_000
        var fd: Int32 = -1
        var accepted = 0
        var local: NetworkEndpoint?
        var peer: NetworkEndpoint?
        var reason = "localKernelAcceptedFrame"
        var finished = false
        do {
            fd = try NetworkIO.openSocket(registration)
            var address = try SocketAddress(registration.endpoint)
            let result = address.withSockaddr { connect(fd, $0, $1) }
            guard result == 0 || (result < 0 && errno == EINPROGRESS) else { throw ProvenanceError("connect errno \(errno)") }
            guard try NetworkIO.wait(fd, events: Int16(POLLOUT), until: deadline) else { throw ProvenanceError("connect deadline") }
            var error: Int32 = 0; var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else { throw ProvenanceError("SO_ERROR errno \(errno)") }
            guard error == 0 else { throw ProvenanceError("connect errno \(error)") }
            local = try NetworkIO.endpoint(fd); peer = try NetworkIO.endpoint(fd, peer: true)
            guard peer == registration.endpoint else { throw ProvenanceError("connected peer mismatch") }
            var connected = journal.event("connected"); connected.local = local; connected.remote = peer
            try journal.append(connected)
            try transfer(frame, datagram: registration.transport == .udp, accepted: &accepted, wait: {
                guard try NetworkIO.wait(fd, events: Int16(POLLOUT), until: deadline) else { throw ProvenanceError("send deadline") }
            }, write: { data in
                let count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, data.count, 0) }
                if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { return 0 }
                guard count > 0 else { throw ProvenanceError("send errno \(errno)") }
                return count
            }, progress: { count in
                var progress = journal.event("kernelAccepted"); progress.local = local; progress.remote = peer
                progress.localKernelAcceptedBytes = count
                try journal.append(progress)
            })
            finished = true
        } catch { reason = "\(error)" }
        if fd >= 0 {
            // Even failed connect may have allocated a local tuple. Missing remains unknown.
            if local == nil { local = try? NetworkIO.endpoint(fd) }
            close(fd)
        }
        var ended = journal.event("attemptEnded"); ended.local = local; ended.remote = peer; ended.target = registration.endpoint
        ended.bytes = frame.count; ended.localKernelAcceptedBytes = accepted
        ended.reason = reason; ended.operationFinished = finished
        try journal.append(ended)
        return finished
    }

    /// Pure injected syscall seam for partial/error tests; never exposed as a CLI bypass.
    static func transfer(_ bytes: Data, datagram: Bool, accepted: inout Int,
                         wait: () throws -> Void, write: (Data) throws -> Int,
                         progress: (Int) throws -> Void) throws {
        while accepted < bytes.count {
            try wait()
            let count = try write(Data(bytes.dropFirst(accepted)))
            guard count >= 0, count <= bytes.count - accepted else { throw ProvenanceError("invalid kernel byte count") }
            if count == 0 { continue }
            accepted += count // Preserve accepted bytes even if journal progress or later send fails.
            try progress(accepted)
            if datagram && count != bytes.count { throw ProvenanceError("partial datagram acceptance") }
        }
    }
}
