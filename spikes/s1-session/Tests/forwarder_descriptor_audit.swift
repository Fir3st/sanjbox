import Darwin

/// Compile beside Forwarder.swift in a disposable process. Public API only, so this also
/// works unchanged against the original source as a negative control. Never calls serve().
@main
struct ForwarderDescriptorAudit {
    static func main() throws {
        // Limit the inventory to this process's descriptor numbers, not paths or other PIDs.
        // All test sockets are allocated below this ceiling; reject unsuitable environments.
        let ceiling: Int32 = 4096
        let marker = socket(AF_INET, SOCK_STREAM, 0)
        guard marker >= 0 && marker + 64 < ceiling else { fatalError("descriptor ceiling") }
        close(marker)
        func count() -> Int { (0..<ceiling).filter { fcntl($0, F_GETFD) != -1 }.count }
        func discardOne() throws {
            _ = try LoopbackForwarder(listenPort: 0, targetPort: 0)
        }
        let beforeRelease = count()
        for _ in 0..<16 { try discardOne() }
        let releaseDelta = count() - beforeRelease
        print("discarded 16 instances: descriptor delta \(releaseDelta)")

        let blocker = try LoopbackForwarder(listenPort: 0, targetPort: 0)
        let beforeFailure = count()
        var bindRejections = 0
        for _ in 0..<16 {
            do { _ = try LoopbackForwarder(listenPort: blocker.listenPort, targetPort: 0) }
            catch {
                guard String(describing: error).hasPrefix("bind ") else { throw error }
                bindRejections += 1
            }
        }
        let failureDelta = count() - beforeFailure
        withExtendedLifetime(blocker) {}
        print("occupied port: \(bindRejections)/16 rejections, descriptor delta \(failureDelta)")

        // Reserve our own unused loopback port; do not connect or serve even if accepted.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { fatalError("socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { fatalError("bind") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { fatalError("getsockname") }
        close(fd)
        let port = UInt16(bigEndian: address.sin_port)
        var selfRejected = false
        do { _ = try LoopbackForwarder(listenPort: port, targetPort: port) }
        catch {
            guard String(describing: error).hasPrefix("self-target ") else { throw error }
            selfRejected = true
        }
        print("self-target rejected: \(selfRejected)")
        guard releaseDelta == 0, bindRejections == 16, failureDelta == 0, selfRejected else { exit(1) }
        print("PASS 3/3 bounded descriptor/public API checks")
    }
}
