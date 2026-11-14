import Foundation
import XCTest
import Darwin
import CArdWorkerRunner
import CArdCryptoTestSupport
@testable import RFBProtocol

final class AppleProviderTests: XCTestCase {
    private var products: URL {
        var directory = Bundle(for: Self.self).bundleURL
        // SwiftPM's current Xcode build layout nests test bundles below Products.
        for _ in 0..<5 {
            directory.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("sanjbox-ard-worker").path) {
                guard let canonical = realpath(directory.path, nil) else { XCTFail("products realpath"); return directory }
                defer { free(canonical) }
                return URL(fileURLWithPath: String(cString: canonical))
            }
        }
        XCTFail("worker missing near test bundle: \(Bundle(for: Self.self).bundleURL.path)")
        return directory
    }
    private var worker: URL { products.appendingPathComponent("sanjbox-ard-worker") }
    private var fixture: URL { products.appendingPathComponent("ard-worker-test-fixture") }
    private var temporaryDirectory: URL {
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            XCTFail("temporary directory realpath"); return FileManager.default.temporaryDirectory
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }

    private func provider(_ vector: AuthVector, cancellation: AppleAuthenticationCancellation? = nil,
                          timeout: UInt32 = 10_000) throws -> SyntheticAppleCredentialProvider {
        try .init(workerExecutable: worker, syntheticUsername: vector.username,
                  syntheticPassword: vector.password, cancellation: cancellation, timeoutMilliseconds: timeout)
    }

    private func run(_ mode: UInt8, timeout: UInt32 = 1_000, path: URL? = nil) -> (Int32, [UInt8]) {
        var output = [UInt8](repeating: 0xA5, count: 648), count = 0
        let code = (path ?? fixture).path.withCString {
            ard_run_worker($0, [mode], 1, &output, &count, timeout, nil)
        }
        if code != ARD_RUN_OK { XCTAssertEqual(count, 0); XCTAssertTrue(output.allSatisfy { $0 == 0 }) }
        if code == ARD_RUN_EXECUTABLE && path == nil { XCTFail("built fixture refused: \(fixture.path)") }
        return (code, Array(output.prefix(count)))
    }

    func testProductionWorkerUsesFreshKeysAndDecryptableCredentialFields() throws {
        let v = try AuthVectors.small(), p = try provider(v)
        var responses: [[UInt8]] = []
        for _ in 0..<2 {
            let response = try p.credentialResponse(for: v.challenge)
            XCTAssertEqual(response.count, 128 + v.width)
            let publicValue = Array(response.dropFirst(128))
            // Independently assume the synthetic server's role with its literal keypair.
            let (result, _, shared) = AuthVectors.execute(v, peer: publicValue,
                privateValue: unhex(v.peerPrivate), publicValue: unhex(v.peerValue))
            XCTAssertEqual(result, 0)
            var plaintext = [UInt8](repeating: 0, count: 128)
            XCTAssertEqual(ard_oracle_decrypt(shared, v.width, response, &plaintext), 1)
            XCTAssertEqual(Array(plaintext[0...v.username.utf8.count]), Array(v.username.utf8) + [0])
            XCTAssertEqual(Array(plaintext[64...64 + v.password.utf8.count]), Array(v.password.utf8) + [0])
            responses.append(response)
        }
        XCTAssertNotEqual(responses[0], responses[1])
        XCTAssertNotEqual(Array(responses[0].dropFirst(128)), Array(responses[1].dropFirst(128)))
    }

    func testDirectChallengeCannotBypassProviderBounds() throws {
        let v = try AuthVectors.small(), p = try provider(v)
        let bad = [AppleDHChallenge(generator: 0, modulus: unhex(v.modulus), serverPublicKey: unhex(v.peerValue)),
                   AppleDHChallenge(generator: 1, modulus: unhex(v.modulus), serverPublicKey: unhex(v.peerValue)),
                   AppleDHChallenge(generator: 2, modulus: [], serverPublicKey: []),
                   AppleDHChallenge(generator: 2, modulus: [UInt8](repeating: 0xFF, count: 127), serverPublicKey: [UInt8](repeating: 3, count: 127)),
                   AppleDHChallenge(generator: 2, modulus: [UInt8](repeating: 0xFF, count: 513), serverPublicKey: [UInt8](repeating: 3, count: 513)),
                   AppleDHChallenge(generator: 2, modulus: [UInt8](repeating: 0, count: 128), serverPublicKey: unhex(v.peerValue)),
                   AppleDHChallenge(generator: 2, modulus: unhex(v.modulus), serverPublicKey: [3])]
        for challenge in bad {
            XCTAssertThrowsError(try p.credentialResponse(for: challenge)) {
                XCTAssertEqual($0 as? SyntheticAppleCredentialProvider.Failure, .invalidChallenge)
            }
        }
    }

    func testProductionWorkerRejectsUnsafeGroupAndPeer() throws {
        let v = try AuthVectors.small(), p = try provider(v)
        var modulus = unhex(v.modulus); modulus[modulus.count - 1] = 0xFE
        for challenge in [AppleDHChallenge(generator: 2, modulus: modulus, serverPublicKey: unhex(v.peerValue)),
                          AppleDHChallenge(generator: 2, modulus: unhex(v.modulus), serverPublicKey: [UInt8](repeating: 0, count: 128))] {
            XCTAssertThrowsError(try p.credentialResponse(for: challenge)) {
                XCTAssertEqual($0 as? SyntheticAppleCredentialProvider.Failure, .backend)
            }
        }
    }

    func testRealWorkerRejectsMalformedRequestFrames() throws {
        let v = try AuthVectors.small()
        let valid = Array("A3D1".utf8) + [0, 2, 0, 128, 0, 0, 0, 0]
            + unhex(v.modulus) + unhex(v.peerValue)
        var badWidth = valid; badWidth[7] = 127
        var badUser = valid; badUser[9] = 64
        var badGenerator = valid; badGenerator[5] = 1
        for request in [Array(valid.prefix(11)), Array(valid.dropLast()), valid + [0],
                        [0] + Array(valid.dropFirst()), badWidth, badUser, badGenerator,
                        [UInt8](repeating: 0, count: 1162)] {
            var output = [UInt8](repeating: 0xA5, count: 648), count = 0
            let code = worker.path.withCString { ard_run_worker($0, request, request.count, &output, &count, 1_000, nil) }
            XCTAssertEqual(code, Int32(ARD_RUN_OK))
            XCTAssertEqual(Array(output.prefix(count)), Array("A3R1".utf8) + [0, 1, 0, 0])
        }
        var output = [UInt8](repeating: 0xA5, count: 648), count = 0
        let tooLarge = [UInt8](repeating: 0, count: 1163)
        XCTAssertEqual(worker.path.withCString { ard_run_worker($0, tooLarge, tooLarge.count, &output, &count, 1_000, nil) }, Int32(ARD_RUN_IO))
        XCTAssertEqual(count, 0); XCTAssertTrue(output.allSatisfy { $0 == 0 })
    }

    func testMaximumAndPaddedWidthWorkThroughRealWorker() throws {
        for v in try AuthVectors.all().filter({ $0.width == 512 || $0.width == 129 }) {
            let response = try provider(v).credentialResponse(for: v.challenge)
            XCTAssertEqual(response.count, 128 + v.width)
            if v.width == 129 { XCTAssertEqual(response[128], 0) }
        }
    }

    func testCancellationBeforeLaunchAndDuringWorker() throws {
        let v = try AuthVectors.small()
        let token = try AppleAuthenticationCancellation(); token.cancel()
        XCTAssertThrowsError(try provider(v, cancellation: token).credentialResponse(for: v.challenge)) {
            XCTAssertEqual($0 as? SyntheticAppleCredentialProvider.Failure, .cancelled)
        }
        let handle = try XCTUnwrap(ard_cancel_create())
        defer { ard_cancel_destroy(handle) }
        // Own the cancellation storage until the operation and concurrent signal finish.
        let address = UInt(bitPattern: handle)
        let cancelled = expectation(description: "signal delivered")
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(30)) {
            ard_cancel_set(OpaquePointer(bitPattern: address)); cancelled.fulfill()
        }
        var output = [UInt8](repeating: 0xA5, count: 648), count = 0
        let code = fixture.path.withCString { ard_run_worker($0, [UInt8(ascii: "h")], 1, &output, &count, 1_000, handle) }
        XCTAssertEqual(code, Int32(ARD_RUN_CANCELLED))
        XCTAssertEqual(count, 0)
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
        wait(for: [cancelled], timeout: 1)
    }

    func testHardDeadlineIncludesSilentPartialAndClosedOutputWorkers() {
        for mode in "hpr".utf8 {
            let start = ContinuousClock.now
            let (code, _) = run(mode, timeout: 60)
            XCTAssertEqual(code, Int32(ARD_RUN_TIMEOUT))
            XCTAssertLessThan(start.duration(to: .now), .seconds(1.5))
        }
    }

    func testIgnoredSIGCHLDAndNoChildWaitRefuseBeforeSpawn() {
        for mode in "in".utf8 {
            let (code, bytes) = run(mode)
            XCTAssertEqual(code, Int32(ARD_RUN_OK))
            XCTAssertEqual(bytes, [UInt8(ARD_RUN_CALLER)])
        }
    }

    func testACLOnLeafAndAncestorRefusesExecution() throws {
        let root = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent("sanjbox-ard-worker")
        try FileManager.default.copyItem(at: fixture, to: copy)
        XCTAssertEqual(run(UInt8(ascii: "s"), path: copy).0, Int32(ARD_RUN_OK))
        for path in [copy, root] {
            let fd = open(path.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(fd, 0)
            defer { close(fd) }
            var acl = acl_init(1)
            guard acl != nil else { return XCTFail("ACL allocation") }
            defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
            var entry: acl_entry_t?
            XCTAssertEqual(acl_create_entry(&acl, &entry), 0)
            let ace = try XCTUnwrap(entry)
            XCTAssertEqual(acl_set_tag_type(ace, ACL_EXTENDED_ALLOW), 0)
            var uuid = UUID().uuid
            XCTAssertEqual(withUnsafeMutableBytes(of: &uuid) { buffer in
                mbr_uid_to_uuid(getuid(), buffer.baseAddress!.assumingMemoryBound(to: UInt8.self))
            }, 0)
            XCTAssertEqual(withUnsafePointer(to: &uuid) { acl_set_qualifier(ace, $0) }, 0)
            var permissions: acl_permset_t?
            XCTAssertEqual(acl_get_permset(ace, &permissions), 0)
            XCTAssertEqual(acl_add_perm(try XCTUnwrap(permissions), ACL_WRITE_DATA), 0)
            XCTAssertEqual(acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED), 0)
            XCTAssertEqual(run(UInt8(ascii: "s"), path: copy).0, Int32(ARD_RUN_EXECUTABLE))
            let empty = try XCTUnwrap(acl_init(0))
            XCTAssertEqual(acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED), 0)
            acl_free(UnsafeMutableRawPointer(empty))
            XCTAssertEqual(run(UInt8(ascii: "s"), path: copy).0, Int32(ARD_RUN_OK))
        }
    }

    func testRealCryptoDeadlineFailsClosed() throws {
        let v = try AuthVectors.small()
        XCTAssertThrowsError(try provider(v, timeout: 1).credentialResponse(for: v.challenge)) {
            XCTAssertEqual($0 as? SyntheticAppleCredentialProvider.Failure, .deadlineExceeded)
        }
    }

    func testOutputOverflowExitAndEmptyResponse() {
        XCTAssertEqual(run(UInt8(ascii: "o")).0, Int32(ARD_RUN_OUTPUT))
        XCTAssertEqual(run(UInt8(ascii: "e")).0, Int32(ARD_RUN_EXIT))
        // The transport permits EOF+exit 0 with empty output; the provider rejects its shape.
        XCTAssertEqual(run(UInt8(ascii: "c")).0, Int32(ARD_RUN_OK))
        XCTAssertEqual(run(UInt8(ascii: "s")).1, Array("ok".utf8))
    }

    func testNoInheritedOrLeakedDescriptors() throws {
        let descriptor = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        let before = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        for _ in 0..<20 {
            let (code, bytes) = run(UInt8(ascii: "f"))
            XCTAssertEqual(code, Int32(ARD_RUN_OK))
            XCTAssertEqual(bytes, [0])
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        XCTAssertEqual(after, before)
    }

    func testOwnedProcessGroupIsCleanedAfterSuccessfulParentExit() {
        let (code, bytes) = run(UInt8(ascii: "d"))
        XCTAssertEqual(code, Int32(ARD_RUN_OK))
        XCTAssertEqual(bytes.count, MemoryLayout<pid_t>.size)
        guard bytes.count == MemoryLayout<pid_t>.size else { return }
        let pid = bytes.withUnsafeBytes { $0.loadUnaligned(as: pid_t.self) }
        XCTAssertGreaterThan(pid, 0)
        let until = ContinuousClock.now.advanced(by: .seconds(1))
        while kill(pid, 0) == 0 && ContinuousClock.now < until { usleep(1_000) }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testWorkerPathRefusesMissingSymlinkAndWritableExecutable() throws {
        let root = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing")
        XCTAssertEqual(run(UInt8(ascii: "s"), path: missing).0, Int32(ARD_RUN_EXECUTABLE))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture)
        XCTAssertEqual(run(UInt8(ascii: "s"), path: link).0, Int32(ARD_RUN_EXECUTABLE))
        let copy = root.appendingPathComponent("copy")
        try FileManager.default.copyItem(at: fixture, to: copy)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: copy.path)
        XCTAssertEqual(run(UInt8(ascii: "s"), path: copy).0, Int32(ARD_RUN_EXECUTABLE))
    }

    func testFIFOExecutableFailsPromptlyWithoutOpeningItForRead() throws {
        let root = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("sanjbox-ard-worker")
        XCTAssertEqual(mkfifo(fifo.path, 0o700), 0)
        // Rescue an accidentally blocking implementation after 500 ms; a regression
        // fails the time assertion instead of hanging the entire test process.
        let rescue = expectation(description: "FIFO rescue finished")
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(500)) {
            let fd = open(fifo.path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { close(fd) }
            rescue.fulfill()
        }
        let start = ContinuousClock.now
        XCTAssertEqual(run(UInt8(ascii: "s"), timeout: 60, path: fifo).0, Int32(ARD_RUN_EXECUTABLE))
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(200))
        wait(for: [rescue], timeout: 1)
    }

    func testMalformedWorkerStatusAndLengthAreTerminal() throws {
        let v = try AuthVectors.small()
        let root = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("sanjbox-ard-worker")
        try FileManager.default.copyItem(at: fixture, to: fake)
        for mode in ["m", "l", "t", "z", "b", "o", "c"] {
            let p = try SyntheticAppleCredentialProvider(workerExecutable: fake, syntheticUsername: "synthetic", syntheticPassword: mode)
            XCTAssertThrowsError(try p.credentialResponse(for: v.challenge)) {
                XCTAssertEqual($0 as? SyntheticAppleCredentialProvider.Failure, .malformedResponse, mode)
            }
        }
        let p = try SyntheticAppleCredentialProvider(workerExecutable: fake, syntheticUsername: "synthetic", syntheticPassword: "q")
        XCTAssertThrowsError(try p.credentialResponse(for: v.challenge)) {
            XCTAssertEqual($0 as? SyntheticAppleCredentialProvider.Failure, .backend)
        }
    }

    func testRealProviderFragmentedParserAlwaysStopsAtIdentity() throws {
        let v = try AuthVectors.small()
        let prefix = AppleFixtures.banner + [1,30] + AppleFixtures.u16(Int(v.generator))
            + AppleFixtures.u16(v.width) + unhex(v.modulus) + unhex(v.peerValue)
        let after = AppleFixtures.u32(0) + AppleFixtures.serverInit()
            + AppleFixtures.sessionInfo(mask: 4) + AppleFixtures.sessionResult(2) + AppleFixtures.sessionResult(4)
        for chunkSize in [1, 7, 127, prefix.count] {
            var client = RFBClient(authenticationPolicy: .syntheticAppleSubset,
                appleCredentialProvider: try provider(v), appleSelectionPolicy: .syntheticVirtualOnly)
            var events: [RFBClient.Event] = []
            for offset in stride(from: 0, to: prefix.count, by: chunkSize) {
                events += try client.receive(Array(prefix[offset..<min(offset + chunkSize, prefix.count)]))
            }
            XCTAssertEqual(events.count, 3)
            guard case .send(let response) = events.last else { return XCTFail("missing real response") }
            XCTAssertEqual(response.count, 128 + v.width)
            XCTAssertThrowsError(try client.receive(after)) {
                XCTAssertEqual($0 as? RFBClient.Failure, .unverifiedSessionIdentity)
            }
            XCTAssertEqual(client.phase, .failed)
            XCTAssertEqual(client.session, .grantedUnverified)
            XCTAssertNil(client.framebuffer)
            XCTAssertEqual(client.bufferedByteCount, 0)
        }
    }
}
