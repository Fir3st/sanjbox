import Darwin
import Foundation
import Security

/// This wire format deliberately contains NO claimed UID, PID, audit token or signing identity.
@objc protocol FixtureExchange {
    func exchange(_ request: Data, reply: @escaping (Data) -> Void)
    func finish(_ reply: @escaping () -> Void)
}

struct XPCFixtureExpectation: Codable, Equatable {
    let runID: String
    let clientCodeHash: String
    let serviceCodeHash: String
    func validate() throws {
        guard UUID(uuidString: runID)?.uuidString == runID,
              Self.validHash(clientCodeHash), Self.validHash(serviceCodeHash)
        else { throw BoundaryError.invalid("XPC requires canonical run UUID and exact 20-byte code hashes") }
    }
    static func validHash(_ text: String) -> Bool {
        text.count == 40 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func requirement(_ hash: String) throws -> String {
        guard validHash(hash) else { throw BoundaryError.invalid("invalid XPC code hash") }
        return "cdhash H\"\(hash)\""
    }
}

struct XPCPeerCredentials: Equatable {
    let effectiveUID: UInt32
    let effectiveGID: UInt32
    let auditSessionID: Int32
    init(effectiveUID: UInt32, effectiveGID: UInt32, auditSessionID: Int32) {
        self.effectiveUID = effectiveUID; self.effectiveGID = effectiveGID; self.auditSessionID = auditSessionID
    }
    init(_ connection: NSXPCConnection) {
        self.init(effectiveUID: connection.effectiveUserIdentifier,
                  effectiveGID: connection.effectiveGroupIdentifier,
                  auditSessionID: connection.auditSessionIdentifier)
    }
}

struct XPCOperationPolicy {
    let peer: XPCPeerCredentials
    let runID: String
    func accepts(_ observed: XPCPeerCredentials) -> Bool {
        peer.effectiveUID > 0 && peer.effectiveUID != UInt32.max && peer.effectiveGID != UInt32.max &&
        peer.auditSessionID > 0 && peer == observed
    }
    func permits(_ request: Data) -> Bool {
        // Fixed ASCII grammar: no decoder, user paths, service names or nested object graph.
        request.count == 48 && request == Data("read-canary:\(runID)".utf8)
    }
}

enum FixtureCodeIdentity {
    static func ownHash() throws -> String {
        var dynamic: SecCode?
        guard SecCodeCopySelf([], &dynamic) == errSecSuccess, let dynamic,
              SecCodeCheckValidity(dynamic, .noNetworkAccess, nil) == errSecSuccess
        else { throw BoundaryError.invalid("fixture running signature invalid") }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamic, [], &code) == errSecSuccess, let code
        else { throw BoundaryError.invalid("fixture static code unavailable") }
        return try hash(code)
    }
    static func hash(_ code: SecStaticCode) throws -> String {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              try SigningSelf.evaluateMetadata(dictionary).policyMatches,
              let bytes = dictionary[kSecCodeInfoUnique as String] as? Data, bytes.count == 20
        else { throw BoundaryError.invalid("fixture requires runtime signature without get-task-allow and exact cdhash") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func verifyService(at url: URL, hash expected: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | SecCSFlags.noNetworkAccess.rawValue), nil) == errSecSuccess,
              try hash(code) == expected
        else { throw BoundaryError.invalid("owned embedded service seal or code hash mismatch") }
    }
}

/// One terminal result wins. Deadline and cancellation close the latch; late replies cannot revive it.
final class XPCReplyLatch: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let deadline: DispatchTime
    private let now: @Sendable () -> UInt64
    private var value: Result<Data, BoundaryError>?
    init(deadline: DispatchTime = .now() + 2, now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.deadline = deadline; self.now = now
    }
    @discardableResult func finish(_ result: Result<Data, BoundaryError>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value == nil else { return false }
        value = now() < deadline.uptimeNanoseconds ? result : .failure(.invalid("owned XPC reply deadline exceeded"))
        semaphore.signal(); return true
    }
    func cancel() { finish(.failure(.invalid("owned XPC request cancelled"))) }
    func result() throws -> Data {
        if semaphore.wait(timeout: deadline) != .success {
            finish(.failure(.invalid("owned XPC reply deadline exceeded")))
        }
        lock.lock(); defer { lock.unlock() }
        guard let value else { throw BoundaryError.invalid("owned XPC reply missing") }
        // A reply may already be queued when the caller resumes after its absolute deadline.
        // Neither that reply nor a late callback is allowed to start another fixture operation.
        if case .success = value, now() >= deadline.uptimeNanoseconds {
            self.value = .failure(.invalid("owned XPC reply deadline exceeded"))
            throw BoundaryError.invalid("owned XPC reply deadline exceeded")
        }
        return try value.get()
    }
}

/// Observe only the authenticated fixture service; never signal or validate code by PID.
final class FixtureExitWatch {
    private let fd: Int32
    init(pid: pid_t) throws {
        guard pid > 0, pid != getpid() else { throw BoundaryError.invalid("XPC did not reach a separate service process") }
        fd = kqueue()
        guard fd >= 0 else { throw BoundaryError.io("fixture exit observer unavailable") }
        var event = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ENABLE),
                           fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        guard kevent(fd, &event, 1, nil, 0, nil) == 0 else {
            close(fd); throw BoundaryError.invalid("fixture exit observation could not be registered")
        }
    }
    deinit { close(fd) }
    func wait() throws {
        var event = kevent(), timeout = timespec(tv_sec: 10, tv_nsec: 0)
        let count = kevent(fd, nil, 0, &event, 1, &timeout)
        guard count == 1, event.flags & UInt16(EV_ERROR) == 0, event.fflags & UInt32(NOTE_EXIT) != 0
        else { throw BoundaryError.conflict("owned service exit not observed; preserve fixture for review") }
    }
}

enum XPCFixture {
    static let serviceName = "org.sanjbox.a4.fixture-service"
    static let clientName = "org.sanjbox.a4.fixture-client"
    static func run(expected: BoundaryExpectation) throws -> [String: String] {
        guard let plan = expected.xpc else { throw BoundaryError.invalid("XPC needs explicit runID and sealed client/service code hashes") }
        try plan.validate()
        guard Bundle.main.bundleIdentifier == clientName,
              try FixtureCodeIdentity.ownHash() == plan.clientCodeHash
        else { throw BoundaryError.invalid("XPC requires the owned bundled client with its exact preregistered code hash") }
        try FixtureCodeIdentity.verifyService(at: Bundle.main.bundleURL, hash: plan.clientCodeHash)
        let service = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/FixtureService.xpc", isDirectory: true)
        try FixtureCodeIdentity.verifyService(at: service, hash: plan.serviceCodeHash)
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: FixtureExchange.self)
        connection.setCodeSigningRequirement(try XPCFixtureExpectation.requirement(plan.serviceCodeHash))
        connection.activate()
        defer { connection.invalidate() }
        func request(_ bytes: Data) throws -> Data {
            let latch = XPCReplyLatch()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                let failure = error as NSError
                latch.finish(.failure(.invalid("owned XPC transport/signature rejected or unavailable (\(failure.domain):\(failure.code))")))
            }) as? FixtureExchange else { throw BoundaryError.invalid("owned XPC proxy unavailable") }
            proxy.exchange(bytes) { data in
                latch.finish(data.count <= 128 ? .success(data) : .failure(.invalid("owned XPC reply size limit")))
            }
            return try latch.result()
        }
        let canary = Data("SANJBOX-A4-\(plan.runID)".utf8)
        let valid = Data("read-canary:\(plan.runID)".utf8)
        // First request has no protected operation. Its reply proves a live, code-authenticated service.
        guard try request(Data("hello".utf8)) == Data("denied".utf8)
        else { throw BoundaryError.invalid("XPC readiness control failed") }
        let watch = try FixtureExitWatch(pid: connection.processIdentifier)
        var exitWaitAttempted = false
        do {
            let peer = XPCPeerCredentials(connection)
            guard peer == XPCPeerCredentials(effectiveUID: expected.effectiveUID, effectiveGID: expected.effectiveGID,
                                            auditSessionID: expected.auditSessionID)
            else { throw BoundaryError.invalid("owned service connection credentials mismatch") }
            let scenario = Bundle.main.object(forInfoDictionaryKey: "SanjboxFixtureScenario") as? String ?? "normal"
            guard ["normal", "wait"].contains(scenario) else { throw BoundaryError.invalid("unknown fixed fixture scenario") }
            if scenario == "wait" { _ = try request(Data("wait:\(plan.runID)".utf8)) }
            guard try request(valid) == canary else { throw BoundaryError.invalid("XPC positive control failed") }
            let denied = [Data("read-canary:\(UUID().uuidString)".utf8), Data("write-canary:\(plan.runID)".utf8),
                          Data("read-canary:\(plan.runID);uid=0;asid=1".utf8), Data(repeating: 65, count: 4097)]
            for bytes in denied {
                guard try request(bytes) == Data("denied".utf8) else { throw BoundaryError.invalid("XPC forbidden operation returned data") }
            }
            guard try request(valid) == canary else { throw BoundaryError.invalid("XPC post-denial positive control failed") }
            let finished = XPCReplyLatch()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                finished.finish(.failure(.invalid("XPC finish failed")))
            }) as? FixtureExchange else { throw BoundaryError.invalid("XPC finish proxy unavailable") }
            proxy.finish { finished.finish(.success(Data())) }
            _ = try finished.result()
            exitWaitAttempted = true
            try watch.wait()
            return ["transport": "embedded NSXPC service; separate process", "runID": plan.runID,
                    "positiveControls": "before and after four denials", "operationCountExpected": "2",
                    "authorization": "OS per-message exact cdhash plus connection EUID/EGID/ASID",
                    "peerAuditUID": "unsupported by public NSXPC API; no full audit-token authentication claim",
                    "record": "independent fixed sibling Control/server.jsonl; verify with fixture runner",
                    "serviceExitObserved": "true", "globalServices": "not enumerated or contacted"]
        } catch {
            connection.invalidate()
            if !exitWaitAttempted { try watch.wait() } // Fixed watchdog also covers cancelled clients.
            throw error
        }
    }
}
