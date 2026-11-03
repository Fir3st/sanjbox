import Darwin
import Darwin.membership
import Foundation
import XCTest
@testable import BoundaryKit

final class FixtureTests: XCTestCase {
    private let bytes = Data("synthetic-owned-file-canary".utf8)
    private func fixture() throws -> OwnedFixture {
        let value = try OwnedFixture()
        try value.create(.control, bytes: bytes, mode: 0o600)
        try value.create(.denied, bytes: bytes, mode: 0)
        return value
    }
    private func exists(_ fixture: OwnedFixture, _ name: String) -> Bool {
        var value = stat()
        return fstatat(fixture.directoryFD, name, &value, AT_SYMLINK_NOFOLLOW) == 0
    }
    func testFreshPermissionDenialWithPositiveControlsAndIdempotentCleanup() throws {
        let value = try fixture()
        XCTAssertEqual(try value.read(.control), bytes)
        XCTAssertThrowsError(try value.read(.denied)) { error in
            XCTAssertTrue([EACCES, EPERM].contains((error as? OwnedFixture.OpenFailure)?.errno ?? 0))
        }
        XCTAssertEqual(try value.read(.control), bytes)
        try value.cleanup(); try value.cleanup(); XCTAssertTrue(value.removed)
    }
    func testModeChangeConflictsBeforeAnyUnlink() throws {
        let value = try fixture()
        let fd = value.receipts.first { $0.name == .denied }!.fd
        XCTAssertEqual(fchmod(fd, 0o600), 0)
        XCTAssertThrowsError(try value.cleanup()); XCTAssertTrue(exists(value, "control"))
        XCTAssertEqual(fchmod(fd, 0), 0); try value.cleanup()
    }
    func testImmutableFlagChangeConflictsBeforeAnyUnlink() throws {
        let value = try fixture()
        let fd = value.receipts.first { $0.name == .denied }!.fd
        XCTAssertEqual(fchflags(fd, UInt32(UF_IMMUTABLE)), 0)
        defer { XCTAssertEqual(fchflags(fd, 0), 0); XCTAssertNoThrow(try value.cleanup()) }
        XCTAssertThrowsError(try value.cleanup()); XCTAssertTrue(exists(value, "control")); XCTAssertTrue(exists(value, "denied"))
        XCTAssertEqual(fchflags(fd, 0), 0); try value.cleanup()
    }
    func testContentChangeConflictsBeforeAnyUnlink() throws {
        let value = try fixture()
        let fd = value.receipts.first { $0.name == .denied }!.fd
        var changed: UInt8 = 88
        XCTAssertEqual(pwrite(fd, &changed, 1, 0), 1)
        XCTAssertThrowsError(try value.cleanup()); XCTAssertTrue(exists(value, "control"))
        XCTAssertEqual(bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }, bytes.count)
        try value.cleanup()
    }
    func testHardlinkRejectedAndCleanupPreservesBothFiles() throws {
        let value = try fixture()
        XCTAssertEqual(linkat(value.directoryFD, "control", value.directoryFD, "extra", 0), 0)
        XCTAssertThrowsError(try value.read(.control)); XCTAssertThrowsError(try value.cleanup())
        XCTAssertTrue(exists(value, "control")); XCTAssertTrue(exists(value, "denied"))
        XCTAssertEqual(unlinkat(value.directoryFD, "extra", 0), 0); try value.cleanup()
    }
    func testSymlinkReplacementNeverFollowsTarget() throws {
        let value = try fixture()
        XCTAssertEqual(unlinkat(value.directoryFD, "control", 0), 0)
        XCTAssertEqual(symlinkat("denied", value.directoryFD, "control"), 0)
        XCTAssertThrowsError(try value.read(.control)); XCTAssertThrowsError(try value.cleanup())
        XCTAssertTrue(exists(value, "denied"))
        XCTAssertEqual(unlinkat(value.directoryFD, "control", 0), 0); try value.cleanup()
    }
    func testFIFOReplacementDoesNotBlockReadOrCleanup() throws {
        let value = try fixture()
        XCTAssertEqual(unlinkat(value.directoryFD, "control", 0), 0)
        let path = "/private/tmp/" + value.name + "/control"
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        XCTAssertThrowsError(try value.read(.control)); XCTAssertThrowsError(try value.cleanup())
        XCTAssertEqual(unlinkat(value.directoryFD, "control", 0), 0); try value.cleanup()
    }
    func testRenameOutIsConflictAndDoesNotSearchOrDeleteElsewhere() throws {
        let value = try fixture(), destination = try OwnedFixture()
        XCTAssertEqual(renameat(value.directoryFD, "control", destination.directoryFD, "control"), 0)
        XCTAssertThrowsError(try value.cleanup())
        XCTAssertTrue(exists(value, "denied")); XCTAssertTrue(exists(destination, "control"))
        XCTAssertEqual(renameat(destination.directoryFD, "control", value.directoryFD, "control"), 0)
        try value.cleanup(); try destination.cleanup()
    }
    func testAlreadyUnlinkedFileIsAnIdempotentCleanupCase() throws {
        let value = try fixture()
        XCTAssertEqual(unlinkat(value.directoryFD, "control", 0), 0)
        try value.cleanup(); try value.cleanup()
    }
    func testDirectoryModeChangeConflictsWithoutDeletingEntries() throws {
        let value = try fixture()
        XCTAssertEqual(fchmod(value.directoryFD, 0o750), 0)
        XCTAssertThrowsError(try value.cleanup()); XCTAssertTrue(exists(value, "control"))
        XCTAssertEqual(fchmod(value.directoryFD, 0o700), 0); try value.cleanup()
    }
    func testExtendedACLChangeConflictsBeforeAnyUnlink() throws {
        let value = try fixture()
        let fd = value.receipts.first { $0.name == .denied }!.fd
        var acl = acl_init(1)
        guard acl != nil else { throw BoundaryError.io("test ACL allocation") }
        defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
        var entry: acl_entry_t?
        guard acl_create_entry(&acl, &entry) == 0, let entry,
              acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0 else { throw BoundaryError.io("test ACL entry") }
        var uuid = UUID().uuid
        let qualifier = withUnsafeMutableBytes(of: &uuid) { buffer -> Int32 in
            guard mbr_uid_to_uuid(getuid(), buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)) == 0 else { return -1 }
            return acl_set_qualifier(entry, buffer.baseAddress!)
        }
        XCTAssertEqual(qualifier, 0)
        var permissions: acl_permset_t?
        guard acl_get_permset(entry, &permissions) == 0, let permissions,
              acl_add_perm(permissions, ACL_READ_DATA) == 0 else { throw BoundaryError.io("test ACL permissions") }
        XCTAssertEqual(acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED), 0)
        defer {
            if let empty = acl_init(0) {
                XCTAssertEqual(acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED), 0)
                acl_free(UnsafeMutableRawPointer(empty))
            } else { XCTFail("test ACL reset allocation") }
            XCTAssertNoThrow(try value.cleanup())
        }
        XCTAssertThrowsError(try value.cleanup()); XCTAssertTrue(exists(value, "control"))
    }
    func testGroupChangeConflictsBeforeAnyUnlink() throws {
        let value = try fixture()
        let receipt = value.receipts.first { $0.name == .denied }!
        let count = getgroups(0, nil)
        var groups = [gid_t](repeating: 0, count: max(0, Int(count)))
        guard count > 0, getgroups(count, &groups) == count,
              let other = groups.first(where: { $0 != receipt.group }) else {
            try value.cleanup(); throw XCTSkip("current user has no second supplementary group for owned fixture chown")
        }
        XCTAssertEqual(fchown(receipt.fd, uid_t.max, other), 0)
        defer { XCTAssertEqual(fchown(receipt.fd, uid_t.max, receipt.group), 0); XCTAssertNoThrow(try value.cleanup()) }
        XCTAssertThrowsError(try value.cleanup()); XCTAssertTrue(exists(value, "control"))
    }
}
