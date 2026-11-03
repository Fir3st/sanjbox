import Darwin
import Darwin.membership
import Foundation
import XCTest
import SanjboxProbeKit
@testable import HostAudit

/// All filesystem mutations are confined to this freshly created, owned synthetic tree.
// XCTest runs each fixture's teardown after its test; immutable identity is shared with that closure only.
private final class Fixture: @unchecked Sendable {
    let path: String
    private let identity: StatMetadata
    init() throws {
        var template = Array("/private/tmp/sanjbox-s4-tests.XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw AuditFailure("mkdtemp failed") }
        path = String(cString: created)
        var value = stat()
        guard lstat(path, &value) == 0 else { throw AuditFailure("fixture stat failed") }
        identity = metadata(value)
    }
    func at(_ name: String) -> String { path + "/" + name }
    func directory(_ name: String) throws {
        XCTAssertEqual(mkdir(at(name), 0o700), 0)
    }
    func file(_ name: String, mode: mode_t = 0o600) throws {
        let fd = open(at(name), O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw AuditFailure("fixture creation failed") }
        defer { close(fd) }
        let bytes = Array("SYNTHETIC FILE CONTENT MUST NOT APPEAR IN REPORT".utf8)
        XCTAssertEqual(write(fd, bytes, bytes.count), bytes.count)
    }
    func json<T: Encodable>(_ name: String, _ object: T) throws {
        let fd = open(at(name), O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AuditFailure("fixture JSON creation failed") }
        defer { close(fd) }
        let data = try encode(object)
        try data.withUnsafeBytes { bytes in
            guard write(fd, bytes.baseAddress, bytes.count) == bytes.count else { throw AuditFailure("fixture write failed") }
        }
    }
    func cleanup() throws {
        var current = stat()
        guard path.hasPrefix("/private/tmp/sanjbox-s4-tests."), lstat(path, &current) == 0,
              current.st_uid == geteuid(), current.st_mode & S_IFMT == S_IFDIR,
              current.st_mode & 0o777 == 0o700, current.st_dev == identity.device, current.st_ino == identity.inode
        else { throw AuditFailure("refusing cleanup of changed fixture root") }
        try FileManager.default.removeItem(atPath: path)
    }
}

final class HostAuditTests: XCTestCase {
    private func fixture() throws -> Fixture {
        let f = try Fixture()
        addTeardownBlock { try f.cleanup() }
        return f
    }
    private func config(_ path: String, depth: Int = 8, entries: Int = 100) -> Configuration {
        .init(roots: [.init(id: "synthetic", path: path, purpose: "synthetic test only")], limits: .init(maxDepth: depth, maxEntries: entries))
    }
    private func expectation(_ context: ProbeContext) throws -> IdentityInput {
        let manager = try XCTUnwrap(context.launchdManager)
        return .init(expectation: .init(effectiveUID: context.effectiveUID, realUID: context.realUID,
            effectiveGID: context.effectiveGID, realGID: context.realGID, requiredGroups: [], forbiddenGroups: [],
            launchdManagerName: manager.name, launchdManagerUID: manager.uid), auditSessionID: try XCTUnwrap(context.audit?.sessionID))
    }
    private func snapshot(_ roots: [RootReport], _ configuration: Configuration) -> Snapshot {
        let context = ProbeContext.capture()
        return .init(generatedAt: "synthetic", identity: .init(context: context, mismatches: [], valid: true),
                     configuration: configuration, roots: roots, drift: .init(compared: false, events: []))
    }

    func testRegularMetadataEmptyACLAndUnreadableFileGap() throws {
        let f = try fixture()
        try f.directory("root")
        try f.file("root/unreadable", mode: 0)
        try f.file("root/regular")
        let report = Scanner(configuration: config(f.at("root"))).scan()[0]
        let entry = try XCTUnwrap(report.entries.first { $0.path == "unreadable" })
        XCTAssertEqual(entry.stat?.kind, "regular")
        XCTAssertEqual(entry.stat?.mode, 0)
        XCTAssertEqual(entry.status, "inaccessible")
        XCTAssertNil(entry.acl)
        XCTAssertEqual(entry.errorNumber, EACCES)
        let regular = try XCTUnwrap(report.entries.first { $0.path == "regular" })
        XCTAssertTrue(regular.acl?.comparable == true)
        XCTAssertTrue(regular.acl?.entries.isEmpty == true)
        XCTAssertTrue(report.enumerationComplete)
        XCTAssertFalse(report.metadataComplete)
        XCTAssertFalse(String(decoding: try encode(report), as: UTF8.self).contains("SYNTHETIC FILE CONTENT"))
    }

    func testSymlinkEscapeAndAncestorSymlinkNeverFollowed() throws {
        let f = try fixture()
        try f.directory("root")
        try f.directory("outside")
        try f.file("outside/marker")
        XCTAssertEqual(symlink(f.at("outside"), f.at("root/link")), 0)
        let report = Scanner(configuration: config(f.at("root"))).scan()[0]
        XCTAssertEqual(report.entries.map(\.path), [".", "link"])
        XCTAssertEqual(report.entries.last?.stat?.kind, "symlink")
        XCTAssertEqual(report.entries.last?.acl?.status, "skipped-symlink")
        XCTAssertTrue(report.enumerationComplete)
        XCTAssertFalse(report.metadataComplete)
        let ancestor = Scanner(configuration: config(f.at("root/link/marker"))).scan()[0]
        XCTAssertNil(ancestor.entries.first?.stat)
        XCTAssertFalse(ancestor.metadataComplete)
        XCTAssertEqual(ancestor.entries.first?.errorNumber, ELOOP)
    }

    func testSocketAndFIFOMetadataDoNotOpenOrConnect() throws {
        let f = try fixture()
        try f.directory("root")
        XCTAssertEqual(mkfifo(f.at("root/pipe"), 0o600), 0)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(f.at("root/socket").utf8CString)
        XCTAssertLessThan(bytes.count, MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { out in out.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0, "Unix socket bind errno \(errno)")
        let report = Scanner(configuration: config(f.at("root"))).scan()[0]
        XCTAssertEqual(report.entries.first { $0.path == "socket" }?.stat?.kind, "socket")
        XCTAssertEqual(report.entries.first { $0.path == "pipe" }?.stat?.kind, "fifo")
        XCTAssertTrue(report.entries.filter { $0.path != "." }.allSatisfy { $0.acl?.status == "skipped-special-node" && $0.mount == nil })
        XCTAssertFalse(report.metadataComplete)
    }

    func testNativeACLIncludingDarwinEndOfListAndDrift() throws {
        let f = try fixture()
        try f.directory("root")
        try f.file("root/file")
        let c = config(f.at("root"))
        let before = snapshot(Scanner(configuration: c).scan(), c)
        let acl = try XCTUnwrap(acl_init(1))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var mutable: acl_t? = acl
        var entry: acl_entry_t?
        XCTAssertEqual(acl_create_entry(&mutable, &entry), 0)
        let ace = try XCTUnwrap(entry)
        XCTAssertEqual(acl_set_tag_type(ace, ACL_EXTENDED_DENY), 0)
        var uuid = UUID().uuid
        XCTAssertEqual(mbr_uid_to_uuid(geteuid(), &uuid), 0)
        XCTAssertEqual(withUnsafePointer(to: &uuid) { acl_set_qualifier(ace, $0) }, 0)
        var permissions: acl_permset_t?
        XCTAssertEqual(acl_get_permset(ace, &permissions), 0)
        XCTAssertEqual(acl_add_perm(try XCTUnwrap(permissions), ACL_WRITE_DATA), 0)
        XCTAssertEqual(acl_set_file(f.at("root/file"), ACL_TYPE_EXTENDED, acl), 0)
        let roots = Scanner(configuration: c).scan()
        let read = try XCTUnwrap(roots[0].entries.first { $0.path == "file" }?.acl)
        XCTAssertEqual(read.status, "observed")
        XCTAssertEqual(read.entries.count, 1)
        XCTAssertEqual(read.entries.first?.principalUUID, UUID(uuid: uuid).uuidString)
        XCTAssertEqual(read.entries.first?.permissions, UInt64(ACL_WRITE_DATA.rawValue))
        XCTAssertTrue(compare(roots, configuration: c, baseline: before).events.contains { $0.fields.contains("acl") })
        let empty = try XCTUnwrap(acl_init(0))
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        XCTAssertEqual(acl_set_file(f.at("root/file"), ACL_TYPE_EXTENDED, empty), 0)
    }

    func testEntryDepthAndGlobalRootBounds() throws {
        let f = try fixture()
        try f.directory("root")
        for n in 0..<20 { try f.file("root/f\(n)") }
        let bounded = Scanner(configuration: config(f.at("root"), entries: 4)).scan()[0]
        XCTAssertEqual(bounded.entries.count, 4)
        XCTAssertTrue(bounded.gaps.contains { $0.reason == "entry-limit" })
        XCTAssertFalse(bounded.enumerationComplete)
        XCTAssertLessThan(try encode(bounded).count, 12_000)
        let depth = Scanner(configuration: config(f.at("root"), depth: 0)).scan()[0]
        XCTAssertEqual(depth.entries.count, 1)
        XCTAssertTrue(depth.gaps.contains { $0.reason == "depth-limit" })
        var c = config(f.at("root"), entries: 1)
        c.roots.append(.init(id: "second", path: f.at("missing"), purpose: "synthetic missing"))
        let roots = Scanner(configuration: c).scan()
        XCTAssertTrue(roots[1].entries.isEmpty)
        XCTAssertFalse(roots[1].metadataComplete)
        XCTAssertTrue(roots[1].gaps.contains { $0.reason == "entry-limit" })
    }

    func testMissingAndRealDeniedDirectory() throws {
        let f = try fixture()
        let missing = Scanner(configuration: config(f.at("missing"))).scan()[0]
        XCTAssertEqual(missing.entries.first?.status, "missing")
        XCTAssertFalse(missing.metadataComplete)
        try f.directory("root")
        try f.file("root/hidden")
        XCTAssertEqual(chmod(f.at("root"), 0), 0)
        defer { XCTAssertEqual(chmod(f.at("root"), 0o700), 0) }
        let denied = Scanner(configuration: config(f.at("root"))).scan()[0]
        XCTAssertFalse(denied.enumerationComplete)
        XCTAssertFalse(denied.entries.contains { $0.path == "hidden" })
        XCTAssertTrue(denied.gaps.contains { $0.reason == "directory-listing-failed" || $0.reason == "metadata-open-failed" })
    }

    func testReplacementWithSymlinkBetweenStatAndOpen() throws {
        let f = try fixture()
        try f.directory("root")
        try f.directory("root/child")
        try f.directory("outside")
        try f.file("outside/marker")
        let hooks = ScanHooks(beforeOpen: { path in
            if path == "child" {
                XCTAssertEqual(rmdir(f.at("root/child")), 0)
                XCTAssertEqual(symlink(f.at("outside"), f.at("root/child")), 0)
            }
        })
        let report = Scanner(configuration: config(f.at("root")), hooks: hooks).scan()[0]
        XCTAssertFalse(report.entries.contains { $0.path.contains("marker") })
        XCTAssertFalse(report.enumerationComplete)
        XCTAssertEqual(report.entries.first?.status, "changed")
    }

    func testRegularReplacedByFIFOIsRejectedWithoutReading() throws {
        let f = try fixture()
        try f.directory("root")
        try f.file("root/candidate")
        let hooks = ScanHooks(beforeOpen: { path in
            if path == "candidate" {
                XCTAssertEqual(unlink(f.at("root/candidate")), 0)
                XCTAssertEqual(mkfifo(f.at("root/candidate"), 0o600), 0)
            }
        })
        let report = Scanner(configuration: config(f.at("root")), hooks: hooks).scan()[0]
        let entry = try XCTUnwrap(report.entries.first { $0.path == "candidate" })
        XCTAssertTrue(["changed", "inaccessible"].contains(entry.status))
        XCTAssertNil(entry.acl)
        XCTAssertNil(entry.mount)
        XCTAssertFalse(report.metadataComplete)
        XCTAssertEqual(report.entries.first?.status, "changed")
    }

    func testAncestorMutationDetectedOnUnwind() throws {
        let f = try fixture()
        try f.directory("root")
        try f.directory("root/child")
        var changed = false
        let hooks = ScanHooks(beforeList: { path in
            if path == "child", !changed {
                changed = true
                XCTAssertEqual(rename(f.at("root"), f.at("moved")), 0)
                XCTAssertEqual(mkdir(f.at("root"), 0o700), 0)
            }
        })
        let report = Scanner(configuration: config(f.at("root")), hooks: hooks).scan()[0]
        XCTAssertEqual(report.entries.first?.status, "changed")
        XCTAssertEqual(report.entries.first?.listing, "changed")
        XCTAssertFalse(report.enumerationComplete)
    }

    func testMockMountBoundaryNonlocalAndUnavailableMetadata() throws {
        let f = try fixture()
        try f.directory("root")
        try f.directory("root/child")
        try f.file("root/child/unreached")
        var calls = 0
        let boundary = ScanHooks(mount: { fd in
            calls += 1
            var mount = readMount(fd)
            if calls > 1 { mount?.filesystemID = [123, 456] }
            return mount
        })
        let report = Scanner(configuration: config(f.at("root")), hooks: boundary).scan()[0]
        XCTAssertEqual(report.entries.first { $0.path == "child" }?.listing, "mount-boundary")
        XCTAssertFalse(report.entries.contains { $0.path.contains("unreached") })
        XCTAssertFalse(report.enumerationComplete)
        let remote = ScanHooks(mount: { fd in var mount = readMount(fd); mount?.local = false; return mount })
        let remoteReport = Scanner(configuration: config(f.at("root")), hooks: remote).scan()[0]
        XCTAssertEqual(remoteReport.entries.count, 1)
        XCTAssertNil(remoteReport.entries.first?.acl)
        XCTAssertFalse(remoteReport.metadataComplete)
        let unavailable = Scanner(configuration: config(f.at("root")), hooks: .init(mount: { _ in nil })).scan()[0]
        XCTAssertFalse(unavailable.metadataComplete)
        XCTAssertTrue(unavailable.gaps.contains { $0.reason == "mount-unavailable" })
    }

    func testDriftMissingAddedUnobservedRootsAndCoverage() throws {
        let f = try fixture()
        try f.directory("root")
        try f.file("root/removed")
        let c = config(f.at("root"))
        let before = snapshot(Scanner(configuration: c).scan(), c)
        XCTAssertEqual(unlink(f.at("root/removed")), 0)
        try f.file("root/added")
        let after = Scanner(configuration: c).scan()
        let drift = compare(after, configuration: c, baseline: before)
        XCTAssertTrue(drift.events.contains { $0.path == "removed" && $0.kind == "absent-observation" })
        XCTAssertTrue(drift.events.contains { $0.path == "added" && $0.kind == "added-observation" })
        let partial = config(f.at("root"), depth: 0)
        let partialRoots = Scanner(configuration: partial).scan()
        let uncertain = compare(partialRoots, configuration: partial, baseline: before)
        XCTAssertTrue(uncertain.events.contains { $0.path == "removed" && $0.kind == "unobserved-now" })
        XCTAssertTrue(uncertain.events.contains { $0.kind == "coverage-changed" })
        let reverse = compare(after, configuration: c, baseline: snapshot(partialRoots, partial))
        XCTAssertTrue(reverse.events.contains { $0.path == "added" && $0.kind == "newly-observed-unknown-before" })
        let other = config(f.at("missing"))
        let movedRoot = compare(Scanner(configuration: other).scan(), configuration: other, baseline: before)
        XCTAssertTrue(movedRoot.events.contains { $0.kind == "root-path-changed" })
        var changedScope = c
        changedScope.roots[0].id = "new-root"
        let scope = compare(Scanner(configuration: changedScope).scan(), configuration: changedScope, baseline: before)
        XCTAssertEqual(Set(scope.events.map(\.kind)), ["root-added-to-scope", "root-removed-from-scope"])
        XCTAssertEqual(rmdir(f.at("root")), -1) // still contains synthetic added file
        XCTAssertEqual(unlink(f.at("root/added")), 0)
        XCTAssertEqual(rmdir(f.at("root")), 0)
        let missingRoot = compare(Scanner(configuration: c).scan(), configuration: c, baseline: before)
        XCTAssertTrue(missingRoot.events.contains { $0.path == "removed" && $0.kind == "absent-observation" })
    }

    func testUnknownACLNeverBecomesAbsenceAndRacedTreeNeverProvesAbsence() throws {
        let f = try fixture()
        try f.directory("root")
        try f.file("root/file")
        let c = config(f.at("root"))
        var roots = Scanner(configuration: c).scan()
        let before = snapshot(roots, c)
        let fileIndex = try XCTUnwrap(roots[0].entries.firstIndex { $0.path == "file" })
        roots[0].entries[fileIndex].acl = .init(status: "unsupported", errorNumber: ENOTSUP)
        let drift = compare(roots, configuration: c, baseline: before)
        XCTAssertFalse(drift.events.contains { $0.fields.contains("acl") })
        XCTAssertTrue(drift.events.contains { $0.kind == "observation-status-changed" })
        roots[0].entries.removeLast()
        roots[0].entries[0].status = "changed"
        let race = compare(roots, configuration: c, baseline: before)
        XCTAssertTrue(race.events.contains { $0.path == "file" && $0.kind == "unobserved-now" })
        XCTAssertFalse(race.events.contains { $0.kind == "absent-observation" })
    }

    func testOwnedInputRejectsSymlinkHardlinkPermissionsAndOversize() throws {
        let f = try fixture()
        let c = config(f.at("root"))
        try f.json("safe.s4-config.json", c)
        XCTAssertNoThrow(try readOwnedInput(f.at("safe.s4-config.json"), suffix: ".s4-config.json", limit: 65536))
        XCTAssertEqual(symlink(f.at("safe.s4-config.json"), f.at("link.s4-config.json")), 0)
        XCTAssertThrowsError(try readOwnedInput(f.at("link.s4-config.json"), suffix: ".s4-config.json", limit: 65536))
        XCTAssertEqual(link(f.at("safe.s4-config.json"), f.at("hard.s4-config.json")), 0)
        XCTAssertThrowsError(try readOwnedInput(f.at("safe.s4-config.json"), suffix: ".s4-config.json", limit: 65536))
        XCTAssertEqual(unlink(f.at("hard.s4-config.json")), 0)
        XCTAssertEqual(chmod(f.at("safe.s4-config.json"), 0o666), 0)
        XCTAssertThrowsError(try readOwnedInput(f.at("safe.s4-config.json"), suffix: ".s4-config.json", limit: 65536))
        XCTAssertEqual(chmod(f.at("safe.s4-config.json"), 0o600), 0)
        XCTAssertThrowsError(try readOwnedInput(f.at("safe.s4-config.json"), suffix: ".s4-config.json", limit: 1))
        XCTAssertThrowsError(try readOwnedInput(f.at("safe.s4-config.json"), suffix: ".s4-expect.json", limit: 65536))
    }

    func testInvalidIdentityStopsBeforeConfigAndBaselineRead() throws {
        let f = try fixture()
        let context = ProbeContext.capture()
        var expected = try expectation(context)
        expected.expectation.effectiveUID = context.effectiveUID + 1
        try f.json("wrong.s4-expect.json", expected)
        let result = try HostAuditCommand.run(["--expect", f.at("wrong.s4-expect.json"), "--config", f.at("never-opened.s4-config.json"),
                                               "--baseline", f.at("never-opened.s4-report.json")], capture: { _ in context })
        XCTAssertEqual(result.exitCode, 3)
        let identity = try JSONDecoder().decode(IdentityReport.self, from: result.output)
        XCTAssertFalse(identity.valid)
        XCTAssertTrue(identity.mismatches.contains { $0.field == "effectiveUID" })
    }

    func testCommandAndActualCLIBaselineRoundTrip() throws {
        let f = try fixture()
        try f.directory("root")
        try f.file("root/file")
        let context = ProbeContext.capture()
        try f.json("run.s4-expect.json", expectation(context))
        let c = config(f.at("root"))
        try f.json("run.s4-config.json", c)
        let args = ["--expect", f.at("run.s4-expect.json"), "--config", f.at("run.s4-config.json")]
        let first = try HostAuditCommand.run(args)
        XCTAssertEqual(first.exitCode, 0)
        let report = try JSONDecoder().decode(Snapshot.self, from: first.output)
        try report.validateBaseline()
        try f.json("baseline.s4-report.json", report)
        let second = try HostAuditCommand.run(args + ["--baseline", f.at("baseline.s4-report.json")])
        let again = try JSONDecoder().decode(Snapshot.self, from: second.output)
        XCTAssertEqual(again.drift.events, [])
        // Test the executable from this exact test product directory (including Release/custom scratch builds).
        let binary = Bundle(for: HostAuditTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("sanjbox-host-audit")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
        let process = Process()
        process.executableURL = binary
        process.arguments = args + ["--baseline", f.at("baseline.s4-report.json")]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let cli = try JSONDecoder().decode(Snapshot.self, from: data)
        XCTAssertTrue(cli.identity.valid)
        XCTAssertTrue(cli.drift.compared)
        XCTAssertEqual(cli.drift.events, [])
    }

    func testRestrictedNamesAreExplicitGapsWithoutMetadataOpen() throws {
        let f = try fixture()
        try f.directory("root")
        try f.directory("root/Keychains")
        try f.file("root/Keychains/hidden")
        try f.file("root/synthetic-token.txt")
        try f.file("root/.env.example")
        try f.file("root/database.sqlite")
        var opened: [String] = []
        let report = Scanner(configuration: config(f.at("root")), hooks: .init(beforeOpen: { opened.append($0) })).scan()[0]
        XCTAssertEqual(opened, ["."])
        XCTAssertEqual(report.entries.count, 5)
        XCTAssertTrue(report.entries.filter { $0.path != "." }.allSatisfy { $0.status == "skipped" && $0.stat == nil })
        XCTAssertFalse(report.metadataComplete)
        XCTAssertEqual(report.gaps.count, 4)
    }

    func testInvalidConfigurationAndBaselineRejected() throws {
        let f = try fixture()
        var c = config(f.path)
        c.roots[0].path = "/"
        XCTAssertThrowsError(try c.validate())
        c.roots[0].path = f.path + "/../other"
        XCTAssertThrowsError(try c.validate())
        c = config(f.path, entries: 1025)
        XCTAssertThrowsError(try c.validate())
        c = config(f.path)
        c.roots.append(c.roots[0])
        XCTAssertThrowsError(try c.validate())
        let good = config(f.path)
        var baseline = snapshot(Scanner(configuration: good).scan(), good)
        baseline.schema = "foreign"
        XCTAssertThrowsError(try baseline.validateBaseline())
        baseline.schema = "sanjbox.host-audit.report.v1"
        baseline.roots[0].entries.append(baseline.roots[0].entries[0])
        XCTAssertThrowsError(try baseline.validateBaseline())
    }
}
