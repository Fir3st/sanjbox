import Foundation
import Testing
import XPC
@testable import S8Preparation

private let syntheticPin = Data(repeating: 0x52, count: 20)

@Test func nativeXPCPolicyRequiresCompleteVerifierOwnedInputs() throws {
    for digest in [Data(), Data(repeating: 1, count: 19), Data(repeating: 1, count: 21), Data(repeating: 0, count: 20)] {
        #expect(throws: (any Error).self) {
            try NativeXPCPeerPolicy(codeDirectoryHash: digest, effectiveUID: 501, effectiveGID: 20, auditSessionID: 42)
        }
    }
    for uid: UInt32 in [0, UInt32.max] {
        #expect(throws: (any Error).self) {
            try NativeXPCPeerPolicy(codeDirectoryHash: syntheticPin, effectiveUID: uid, effectiveGID: 20, auditSessionID: 42)
        }
    }
    #expect(throws: (any Error).self) {
        try NativeXPCPeerPolicy(codeDirectoryHash: syntheticPin, effectiveUID: 501, effectiveGID: UInt32.max, auditSessionID: 42)
    }
    for asid: Int32 in [0, -1] {
        #expect(throws: (any Error).self) {
            try NativeXPCPeerPolicy(codeDirectoryHash: syntheticPin, effectiveUID: 501, effectiveGID: 20, auditSessionID: asid)
        }
    }
}

@Test func nativeXPCPolicyCompilesOnlyAnExactCodeHashRequirement() throws {
    let policy = try NativeXPCPeerPolicy(codeDirectoryHash: syntheticPin, effectiveUID: 501, effectiveGID: 20, auditSessionID: 42)
    #expect(policy.codeSigningRequirement == "cdhash H\"5252525252525252525252525252525252525252\"")
    _ = try NativeXPCMessageVerifier(policy: policy)
}

@Test func nativeXPCRejectsLocallyConstructedIdentityClaimsWithoutTransport() throws {
    let policy = try NativeXPCPeerPolicy(codeDirectoryHash: syntheticPin, effectiveUID: 501, effectiveGID: 20, auditSessionID: 42)
    let verifier = try NativeXPCMessageVerifier(policy: policy)
    let forged = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_uint64(forged, "pid", UInt64(ProcessInfo.processInfo.processIdentifier))
    xpc_dictionary_set_uint64(forged, "uid", UInt64(policy.effectiveUID))
    xpc_dictionary_set_uint64(forged, "auditSessionID", UInt64(policy.auditSessionID))
    xpc_dictionary_set_string(forged, "codeSigningRequirement", policy.codeSigningRequirement)
    xpc_dictionary_set_string(forged, "auditToken", "synthetic-claim-not-a-transport-token")
    do {
        _ = try verifier.inspect(received: forged)
        Issue.record("locally constructed dictionary acquired transport provenance")
    } catch {
        #expect(String(describing: error) == "received XPC message provenance required")
    }
}

@Test func nativeXPCRejectsNonDictionaryObjectsWithoutCallingSecurity() throws {
    let policy = try NativeXPCPeerPolicy(codeDirectoryHash: syntheticPin, effectiveUID: 501, effectiveGID: 20, auditSessionID: 42)
    let verifier = try NativeXPCMessageVerifier(policy: policy)
    for message in [xpc_string_create("synthetic"), xpc_array_create(nil, 0), xpc_uint64_create(501)] {
        do {
            _ = try verifier.inspect(received: message)
            Issue.record("non-dictionary XPC object admitted")
        } catch {
            #expect(String(describing: error) == "received XPC message provenance required")
        }
    }
}
