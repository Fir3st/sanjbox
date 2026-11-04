import Darwin
import Foundation

/// Fixed, append-only record owned by the service, never supplied by a request or returned as a reply.
final class FixtureServerRecord: @unchecked Sendable {
    private let fd: Int32
    let clientCodeHash: String
    private let controlDirectory: URL
    private let lock = NSLock()
    private var sequence = 0
    init() throws {
        let root = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Control", isDirectory: true)
        controlDirectory = directory
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw BoundaryError.io("owned service record directory unavailable") }
        defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700
        else { throw BoundaryError.invalid("service record directory ownership/mode mismatch") }
        let policy = openat(parent, "client-codehash", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard policy >= 0 else { throw BoundaryError.invalid("fixed client hash preregistration missing") }
        defer { close(policy) }
        var policyInfo = stat()
        guard fstat(policy, &policyInfo) == 0, policyInfo.st_uid == geteuid(),
              policyInfo.st_mode & S_IFMT == S_IFREG, policyInfo.st_mode & 0o7777 == 0o400,
              policyInfo.st_nlink == 1, policyInfo.st_size == 40
        else { throw BoundaryError.invalid("fixed client hash preregistration ownership/type/mode mismatch") }
        var bytes = [UInt8](repeating: 0, count: 41)
        guard read(policy, &bytes, bytes.count) == 40 else { throw BoundaryError.invalid("fixed client hash preregistration unreadable") }
        clientCodeHash = String(decoding: bytes.prefix(40), as: UTF8.self)
        guard XPCFixtureExpectation.validHash(clientCodeHash) else { throw BoundaryError.invalid("fixed client hash preregistration malformed") }
        fd = openat(parent, "server.jsonl", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BoundaryError.io("service record already exists or cannot be created") }
    }
    func awaitObserver(runID: String) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        let parent = open(controlDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw BoundaryError.invalid("fixture observer directory unavailable") }
        defer { close(parent) }
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let marker = openat(parent, "observer-ready", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if marker >= 0 {
                defer { close(marker) }
                var info = stat(), bytes = [UInt8](repeating: 0, count: 37)
                guard fstat(marker, &info) == 0, info.st_uid == geteuid(), (1...2).contains(info.st_nlink),
                      info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == 0o400, info.st_size == 36,
                      read(marker, &bytes, bytes.count) == 36,
                      String(decoding: bytes.prefix(36), as: UTF8.self) == runID,
                      DispatchTime.now().uptimeNanoseconds < deadline
                else { throw BoundaryError.invalid("fixture observer readiness invalid") }
                append("observerReady"); return
            }
            guard errno == ENOENT else { throw BoundaryError.invalid("fixture observer readiness unavailable") }
            usleep(5_000)
        }
        throw BoundaryError.invalid("fixture observer readiness deadline exceeded")
    }
    deinit { close(fd) }
    func append(_ event: String, fields: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        guard sequence < 64 else { _exit(71) }
        sequence += 1
        var object = fields
        object["event"] = event; object["sequence"] = String(sequence)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), data.count <= 2048
        else { _exit(72) }
        let line = data + Data([10])
        line.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { _exit(73) } // No operation after an incomplete record.
                offset += count
            }
        }
    }
}

final class FixtureService: NSObject, FixtureExchange, @unchecked Sendable {
    let policy: XPCOperationPolicy
    let record: FixtureServerRecord
    weak var connection: NSXPCConnection?
    init(policy: XPCOperationPolicy, record: FixtureServerRecord, connection: NSXPCConnection) {
        self.policy = policy; self.record = record; self.connection = connection
    }
    private func authenticated() -> Bool {
        guard let current = NSXPCConnection.current(), current === connection,
              policy.accepts(XPCPeerCredentials(current)) else {
            record.append("messageCredentialsDenied"); return false
        }
        // XPC enforces the exact cdhash requirement before dispatching each exported invocation.
        // No SecCodeCopyGuestWithAttributes(PID), private audit-token selector, or client identity claim.
        record.append("messageAuthenticated", fields: ["signature": "OS-enforced-exact-cdhash", "peerAuditUID": "unavailable"])
        return true
    }
    func exchange(_ request: Data, reply: @escaping (Data) -> Void) {
        guard authenticated() else { reply(Data("denied".utf8)); return }
        if request == Data("wait:\(policy.runID)".utf8) {
            record.append("replyWithheld"); return // Fixed deadline/cancellation fixture, no canary operation.
        }
        guard policy.permits(request) else {
            record.append("operationDenied", fields: ["requestBytes": String(request.count)])
            reply(Data("denied".utf8)); return
        }
        record.append("operation", fields: ["operation": "read-canary", "runID": policy.runID])
        reply(Data("SANJBOX-A4-\(policy.runID)".utf8))
    }
    func finish(_ reply: @escaping () -> Void) {
        guard authenticated() else { reply(); return }
        record.append("finish"); reply()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [record] in
            record.append("serviceExit", fields: ["reason": "authenticated-finish"]); _exit(0)
        }
    }
}

final class FixtureServiceListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let policy: XPCOperationPolicy
    let requirement: String
    let record: FixtureServerRecord
    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []
    init(policy: XPCOperationPolicy, requirement: String, record: FixtureServerRecord) {
        self.policy = policy; self.requirement = requirement; self.record = record
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let peer = XPCPeerCredentials(connection)
        record.append("connectionObserved", fields: ["euid": String(peer.effectiveUID), "egid": String(peer.effectiveGID),
                                                     "asid": String(peer.auditSessionID), "pid": String(connection.processIdentifier)])
        guard connections.count < 8, policy.accepts(peer) else {
            record.append("connectionCredentialsDenied"); return false
        }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: FixtureExchange.self)
        connection.exportedObject = FixtureService(policy: policy, record: record, connection: connection)
        connection.invalidationHandler = { [record] in record.append("connectionInvalidated") }
        connections.append(connection)
        record.append("connectionCredentialsAccepted", fields: ["signature": "pending-per-message-OS-check"])
        connection.activate()
        return true
    }
}

public enum XPCFixtureServiceMain {
    public static func main() -> Never {
        do {
            guard CommandLine.arguments.count == 1, Bundle.main.bundleIdentifier == XPCFixture.serviceName,
                  let input = Bundle.main.object(forInfoDictionaryKey: "SanjboxFixtureExpectation") as? String,
                  let runID = Bundle.main.object(forInfoDictionaryKey: "SanjboxFixtureRunID") as? String,
                  UUID(uuidString: runID)?.uuidString == runID
            else { throw BoundaryError.invalid("service requires its own sealed fixture bundle policy") }
            let ownHash = try FixtureCodeIdentity.ownHash()
            try FixtureCodeIdentity.verifyService(at: Bundle.main.bundleURL, hash: ownHash)
            let expected = try BoundaryExpectation.parse(input)
            let record = try FixtureServerRecord()
            let mismatches = expected.mismatches(try ContextCollector.capture(groups: expected.groupsOfInterest))
            guard expected.xpc == nil, mismatches.isEmpty else {
                record.append("serviceIdentityRejected", fields: ["mismatches": mismatches.joined(separator: ",")])
                throw BoundaryError.invalid("service self context differs from preregistration")
            }
            record.append("serviceStart", fields: ["pid": String(getpid()), "runID": runID, "codeHash": ownHash,
                                                    "lookup": "bundled service activation; no global lookup oracle"])
            var peer = XPCPeerCredentials(effectiveUID: expected.effectiveUID, effectiveGID: expected.effectiveGID,
                                          auditSessionID: expected.auditSessionID)
            if let override = Bundle.main.object(forInfoDictionaryKey: "SanjboxFixturePeerASID") as? NSNumber {
                guard override.int64Value > 0, override.int64Value <= Int32.max else {
                    throw BoundaryError.invalid("invalid sealed peer ASID fixture policy")
                }
                peer = XPCPeerCredentials(effectiveUID: expected.effectiveUID, effectiveGID: expected.effectiveGID,
                                          auditSessionID: override.int32Value)
            }
            let policy = XPCOperationPolicy(peer: peer, runID: runID)
            let delegate = FixtureServiceListener(policy: policy,
                requirement: try XPCFixtureExpectation.requirement(record.clientCodeHash), record: record)
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                record.append("serviceExit", fields: ["reason": "fixed-watchdog"]); _exit(0)
            }
            try record.awaitObserver(runID: runID)
            let listener = NSXPCListener.service()
            listener.delegate = delegate
            withExtendedLifetime(delegate) { listener.resume(); dispatchMain() }
            _exit(74)
        } catch {
            // Only diagnostic literals. No protected data or dump of client requests.
            fputs("owned XPC service refused incomplete policy, identity or seal\n", stderr)
            exit(70)
        }
    }
}
