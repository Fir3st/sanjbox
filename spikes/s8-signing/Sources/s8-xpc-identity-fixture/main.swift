import Darwin
import Foundation
import S8Preparation
import XPC

// This is a non-service, owned synthetic test executable. It has no production
// policy loader and is never embedded in, or launched by, the service app.
private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(2)
}

private struct Result: Codable { let name: String; let passed: Bool; let detail: String }
private final class State: @unchecked Sendable {
    let lock = NSLock()
    var result: Result?
    var deliveries = 0
    var identityVerified = false
    var peers: [xpc_connection_t] = []
    let done = DispatchSemaphore(value: 0)
    func set(_ result: Result) {
        lock.lock(); defer { lock.unlock() }
        guard self.result == nil else { return }
        self.result = result; done.signal()
    }
    func accepted(_ peer: xpc_connection_t) { lock.lock(); peers.append(peer); lock.unlock() }
    func delivered() { lock.lock(); deliveries += 1; lock.unlock() }
    func verified() { lock.lock(); identityVerified = true; lock.unlock() }
    func hadVerifiedDelivery() -> Bool {
        lock.lock(); defer { lock.unlock() }; return identityVerified && deliveries == 1
    }
    func close() {
        lock.lock(); let copy = peers; peers.removeAll(); lock.unlock()
        for peer in copy { xpc_connection_cancel(peer) }
    }
}

private func exercise(name: String, policy: NativeXPCPeerPolicy, expected: String?,
                      transportRequirement: String? = nil, replyRequirement: String? = nil,
                      expectReplyRejection: Bool = false) throws -> Result {
    let verifier = try NativeXPCMessageVerifier(policy: policy)
    let queue = DispatchQueue(label: "org.sanjbox.s8.owned-xpc.\(name)")
    let state = State()
    let listener = xpc_connection_create(nil, queue)
    xpc_connection_set_event_handler(listener) { peer in
        guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
        state.accepted(peer)
        if let transportRequirement {
            guard xpc_connection_set_peer_code_signing_requirement(peer, transportRequirement) == 0 else {
                state.set(.init(name: name, passed: false, detail: "transport requirement setup failed"))
                xpc_connection_cancel(peer); return
            }
        }
        xpc_connection_set_event_handler(peer) { message in
            guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
            state.delivered()
            do {
                let identity = try verifier.inspect(received: message)
                let correct = identity.codeDirectoryHash == policy.codeDirectoryHash &&
                    identity.connectionEffectiveUID == policy.effectiveUID &&
                    identity.connectionEffectiveGID == policy.effectiveGID &&
                    identity.connectionAuditSessionID == policy.auditSessionID &&
                    identity.adHoc && !identity.mutationAuthorized
                if replyRequirement != nil {
                    guard expected == nil, correct, let reply = xpc_dictionary_create_reply(message),
                          let replyConnection = xpc_dictionary_get_remote_connection(message) else {
                        state.set(.init(name: name, passed: false, detail: "verified native reply unavailable")); return
                    }
                    state.verified()
                    xpc_dictionary_set_bool(reply, "ownedSyntheticReply", true)
                    xpc_connection_send_message(replyConnection, reply)
                } else {
                    state.set(.init(name: name, passed: expected == nil && correct, detail: "message-bound ad-hoc identity"))
                }
            } catch {
                let diagnostic = String(describing: error)
                state.set(.init(name: name, passed: expected == diagnostic, detail: diagnostic))
            }
        }
        xpc_connection_activate(peer)
    }
    xpc_connection_activate(listener)
    let endpoint = xpc_endpoint_create(listener)
    let client = xpc_connection_create_from_endpoint(endpoint)
    xpc_connection_set_event_handler(client) { _ in }
    if let replyRequirement {
        guard xpc_connection_set_peer_code_signing_requirement(client, replyRequirement) == 0 else {
            xpc_connection_cancel(client); state.close(); xpc_connection_cancel(listener)
            return .init(name: name, passed: false, detail: "reply requirement setup failed")
        }
    }
    xpc_connection_activate(client)
    defer {
        xpc_connection_cancel(client); state.close(); xpc_connection_cancel(listener)
        // Drain our serial receiver queue before releasing its state. No process,
        // service registration, filesystem endpoint or global name was created.
        queue.sync {}
    }
    let message = xpc_dictionary_create(nil, nil, 0)
    // These contradictory sender-controlled values must have no effect. In the
    // negative cases, the supplied values instead claim the rejected policy.
    xpc_dictionary_set_uint64(message, "claimedUID", UInt64(expected == nil ? 0 : policy.effectiveUID))
    xpc_dictionary_set_uint64(message, "claimedSession", UInt64(expected == nil ? 0 : policy.auditSessionID))
    xpc_dictionary_set_string(message, "claimedCodeRequirement", policy.codeSigningRequirement)
    xpc_dictionary_set_string(message, "auditToken", "synthetic-untrusted-not-an-OS-token")
    if replyRequirement != nil {
        xpc_connection_send_message_with_reply(client, message, queue) { reply in
            let valid: Bool
            if expectReplyRejection {
                valid = reply === XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT
            } else {
                valid = xpc_get_type(reply) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_bool(reply, "ownedSyntheticReply")
            }
            let verified = state.hadVerifiedDelivery()
            let detail = !verified ? "reply arrived without a verified request" :
                !valid ? "unexpected native reply or error" :
                expectReplyRejection ? "OS rejected reply code requirement" : "OS accepted pinned reply"
            state.set(.init(name: name, passed: valid && verified, detail: detail))
        }
    } else { xpc_connection_send_message(client, message) }
    guard state.done.wait(timeout: .now() + 3) == .success else {
        return .init(name: name, passed: false, detail: "native XPC deadline expired")
    }
    state.lock.lock(); defer { state.lock.unlock() }
    return state.result!
}

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args == ["plan"] {
    print("DRY-RUN: owned anonymous XPC identity controls only. --apply-fixture CDHASH UID GID ASID requires an externally pinned fixture hash and identity. No service, admin, registration or attach API.")
    exit(0)
}
guard args.count == 5, args[0] == "--apply-fixture", args[1].count == 40,
      args[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      let uid = UInt32(args[2]), let gid = UInt32(args[3]), let session = Int32(args[4]) else {
    fail("Only plan or --apply-fixture CDHASH UID GID ASID is accepted")
}
// Arm before identity/signing preflight: its first synchronous Security call
// must share the deadline with all later XPC/Security work and queue cleanup.
// No child processes are created here; an alarm ends only this owned fixture.
signal(SIGALRM, SIG_DFL); alarm(20)
defer { alarm(0) }
var audit = auditinfo_addr()
guard getuid() == uid, geteuid() == uid, getgid() == gid, getegid() == gid,
      getaudit_addr(&audit, Int32(MemoryLayout<auditinfo_addr>.size)) == 0,
      audit.ai_auid == uid, audit.ai_asid == session, selfSignatureIssues().isEmpty else {
    fail("fixture identity/session or ad-hoc hardened empty-entitlement preflight refused")
}
do {
    let hex = Array(args[1].utf8)
    let hash = Data(stride(from: 0, to: hex.count, by: 2).map {
        UInt8(String(bytes: hex[$0..<$0 + 2], encoding: .utf8)!, radix: 16)!
    })
    func policy(_ digest: Data = hash, _ user: UInt32 = uid,
                _ group: UInt32 = gid, _ sid: Int32 = session) throws -> NativeXPCPeerPolicy {
        try .init(codeDirectoryHash: digest, effectiveUID: user, effectiveGID: group, auditSessionID: sid)
    }
    let pinned = try policy()
    var wrong = hash; wrong[0] ^= 1
    let other = try policy(wrong)
    var results = [Result]()
    results.append(try exercise(name: "positive-with-forged-wire-claims", policy: pinned, expected: nil))
    results.append(try exercise(name: "positive-os-transport-requirement", policy: pinned, expected: nil,
                                transportRequirement: pinned.codeSigningRequirement, replyRequirement: pinned.codeSigningRequirement))
    results.append(try exercise(name: "wrong-os-reply-code-requirement", policy: pinned, expected: nil,
                                replyRequirement: other.codeSigningRequirement, expectReplyRejection: true))
    results.append(try exercise(name: "wrong-live-code-pin", policy: other,
                                expected: "message sender does not satisfy live code pin"))
    results.append(try exercise(name: "wrong-os-uid", policy: policy(hash, uid + 1),
                                expected: "OS connection credentials differ from verifier policy"))
    results.append(try exercise(name: "wrong-os-gid", policy: policy(hash, uid, gid + 1),
                                expected: "OS connection credentials differ from verifier policy"))
    results.append(try exercise(name: "wrong-os-session", policy: policy(hash, uid, gid, session + 1),
                                expected: "OS connection credentials differ from verifier policy"))
    let verifier = try NativeXPCMessageVerifier(policy: pinned)
    let forged = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_string(forged, "auditToken", "synthetic-untrusted-not-an-OS-token")
    do {
        _ = try verifier.inspect(received: forged)
        results.append(.init(name: "locally-forged-message", passed: false, detail: "unexpected admission"))
    } catch {
        results.append(.init(name: "locally-forged-message",
            passed: String(describing: error) == "received XPC message provenance required", detail: String(describing: error)))
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(results), as: UTF8.self))
    exit(results.allSatisfy(\.passed) ? 0 : 1)
} catch { fail("native fixture refused: \(error)") }
