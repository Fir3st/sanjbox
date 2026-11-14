import Foundation
import Darwin
import CArdWorkerRunner

/// Cancellation of a synthetic authentication operation; never reset/reused after cancel.
public final class AppleAuthenticationCancellation: @unchecked Sendable {
    fileprivate let handle: OpaquePointer
    public init() throws {
        guard let handle = ard_cancel_create() else { throw SyntheticAppleCredentialProvider.Failure.backend }
        self.handle = handle
    }
    public func cancel() { ard_cancel_set(handle) }
    deinit { ard_cancel_destroy(handle) }
}

/// Opt-in, offline-only type-30 experiment. No credential loading or live transport.
/// Uses a repository-owned worker with a pinned public libcrypto adapter. The worker
/// must be in this user's trusted build tree; it is not attested against same-UID code.
/// Swift strings/arrays may leave copies. Wiping the request is best-effort hygiene,
/// not a blanket secret-erasure guarantee; accept only explicitly synthetic inputs.
/// Caller must retain SIGCHLD default disposition without SA_NOCLDWAIT and must
/// not use competing child reapers throughout a call. This is not a general-purpose
/// process library; the initial disposition check cannot prevent later caller changes.
public struct SyntheticAppleCredentialProvider: AppleCredentialProvider {
    public enum Failure: String, Error, Equatable, Sendable {
        case invalidChallenge, invalidWorker, backend, deadlineExceeded, cancelled
        case malformedResponse, workerFailed, cleanupFailed
        case unsupportedProcessEnvironment
    }
    private let workerPath: String
    private let username: [UInt8]
    private let password: [UInt8]
    private let cancellation: AppleAuthenticationCancellation?
    private let timeoutMilliseconds: UInt32

    public init(workerExecutable: URL, syntheticUsername: String, syntheticPassword: String,
                cancellation: AppleAuthenticationCancellation? = nil) throws {
        try self.init(workerExecutable: workerExecutable, syntheticUsername: syntheticUsername,
                      syntheticPassword: syntheticPassword, cancellation: cancellation, timeoutMilliseconds: 10_000)
    }

    // Short deadlines are available only to @testable tests, not a wire input.
    init(workerExecutable: URL, syntheticUsername: String, syntheticPassword: String,
         cancellation: AppleAuthenticationCancellation?, timeoutMilliseconds: UInt32) throws {
        guard workerExecutable.isFileURL, workerExecutable.lastPathComponent == "sanjbox-ard-worker",
              timeoutMilliseconds > 0, timeoutMilliseconds <= 10_000 else { throw Failure.invalidWorker }
        // Foundation may abbreviate /private/tmp back to the /tmp symlink. POSIX
        // realpath preserves the actual ancestor names that the runner checks.
        guard let canonical = workerExecutable.path.withCString({ realpath($0, nil) }) else { throw Failure.invalidWorker }
        defer { free(canonical) }
        let path = String(cString: canonical)
        guard URL(fileURLWithPath: path).lastPathComponent == "sanjbox-ard-worker" else { throw Failure.invalidWorker }
        workerPath = path
        username = Array(syntheticUsername.utf8.prefix(63))
        password = Array(syntheticPassword.utf8.prefix(63))
        self.cancellation = cancellation
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    public func credentialResponse(for challenge: AppleDHChallenge) throws -> [UInt8] {
        let width = challenge.modulus.count
        guard (128...512).contains(width), challenge.serverPublicKey.count == width,
              challenge.generator > 1 else { throw Failure.invalidChallenge }
        guard let first = challenge.modulus.firstIndex(where: { $0 != 0 }) else { throw Failure.invalidChallenge }
        let bits = (width - first - 1) * 8 + (8 - challenge.modulus[first].leadingZeroBitCount)
        guard (1024...4096).contains(bits) else { throw Failure.invalidChallenge }
        func u16(_ n: Int) -> [UInt8] { [UInt8(n >> 8), UInt8(n & 255)] }
        var request = Array("A3D1".utf8) + u16(Int(challenge.generator)) + u16(width)
            + u16(username.count) + u16(password.count)
            + challenge.modulus + challenge.serverPublicKey + username + password
        defer { _ = request.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var output = [UInt8](repeating: 0, count: 648)
        var outputCount = 0
        let code = workerPath.withCString { path in
            ard_run_worker(path, request, request.count, &output, &outputCount,
                           timeoutMilliseconds, cancellation?.handle)
        }
        switch Int(code) {
        case ARD_RUN_OK: break
        case ARD_RUN_EXECUTABLE: throw Failure.invalidWorker
        case ARD_RUN_TIMEOUT: throw Failure.deadlineExceeded
        case ARD_RUN_CANCELLED: throw Failure.cancelled
        case ARD_RUN_OUTPUT: throw Failure.malformedResponse
        case ARD_RUN_EXIT: throw Failure.workerFailed
        case ARD_RUN_CLEANUP: throw Failure.cleanupFailed
        case ARD_RUN_CALLER: throw Failure.unsupportedProcessEnvironment
        default: throw Failure.backend
        }
        guard outputCount >= 8, Array(output[0..<4]) == Array("A3R1".utf8), output[4] == 0 else {
            throw Failure.malformedResponse
        }
        let length = Int(output[6]) << 8 | Int(output[7])
        if output[5] != 0 {
            guard (1...4).contains(output[5]), length == 0, outputCount == 8 else { throw Failure.malformedResponse }
            throw Failure.backend
        }
        guard length == 128 + width, outputCount == 8 + length else { throw Failure.malformedResponse }
        return Array(output[8..<outputCount])
    }
}
