import Darwin
import Darwin.membership
import Foundation
import XCTest
@testable import HostAudit

final class HostACLHardeningTests: XCTestCase {
    private func callerUUID() throws -> String {
        var uuid = UUID().uuid
        guard mbr_uid_to_uuid(geteuid(), &uuid) == 0 else { throw AuditFailure("fixture caller UUID unavailable") }
        return UUID(uuid: uuid).uuidString
    }
    private func deny() throws -> ACLDeny { .init(principalUUID: try callerUUID(), permissions: ["add_file"]) }
    private func fixture(roots: [String] = ["target"], prepare: (HardenFixture) throws -> Void = { _ in }) throws -> HardenFixture {
        let f = try HardenFixture()
        addTeardownBlock { try f.cleanup() }
        try f.setup(roots: roots, plan: .init(schema: "sanjbox.host-harden.plan.v2",
                    roots: roots.indices.map { "root-\($0)" }, mode: nil, deny: [try deny()]), prepare: prepare)
        // Tests which deliberately leave a deny installed must clear only these exact owned fixtures.
        // This teardown runs before the fixture identity-checked recursive removal (LIFO).
        for root in roots {
            let p = try HardenPath(f.at(root), allowTargetACL: true)
            let original = try p.requireTarget()
            let pinned = dup(p.fd)
            guard pinned >= 0 else { throw AuditFailure("fixture cleanup pin failed") }
            addTeardownBlock {
                defer { close(pinned) }
                var named = stat(), current = stat()
                guard lstat(f.at(root), &named) == 0, fstat(pinned, &current) == 0,
                      sameObject(named, current), current.st_uid == geteuid(),
                      current.st_ino == original.stat.inode, current.st_dev == original.stat.device else {
                    throw AuditFailure("fixture ACL cleanup identity mismatch")
                }
                try HostACLHardeningTests.nativeSet(pinned, entries: [])
            }
        }
        return f
    }
    private func check(_ result: CommandResult, _ code: Int32, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.exitCode, code, String(decoding: result.output, as: UTF8.self), file: file, line: line)
    }
    private func stamp(_ f: HardenFixture, _ name: String = "target") throws -> HardenStamp {
        try HardenPath(f.at(name), allowTargetACL: true).requireTarget()
    }
    /// Independent fixture builder: direct SDK operations rather than the production serializer.
    private static func nativeSet(_ fd: Int32, entries: [ACLEntry], global: [UInt32] = []) throws {
        var acl = try XCTUnwrap(acl_init(Int32(entries.count))) as acl_t?
        defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
        var flags: acl_flagset_t?
        XCTAssertEqual(acl_get_flagset_np(UnsafeMutableRawPointer(acl!), &flags), 0)
        for flag in global { XCTAssertEqual(acl_add_flag_np(try XCTUnwrap(flags), acl_flag_t(rawValue: flag)), 0) }
        for value in entries {
            var entry: acl_entry_t?
            XCTAssertEqual(acl_create_entry(&acl, &entry), 0)
            let ace = try XCTUnwrap(entry)
            XCTAssertEqual(acl_set_tag_type(ace, acl_tag_t(rawValue: value.tag)), 0)
            var uuid = try XCTUnwrap(UUID(uuidString: value.principalUUID)).uuid
            XCTAssertEqual(withUnsafePointer(to: &uuid) { acl_set_qualifier(ace, $0) }, 0)
            XCTAssertEqual(acl_set_permset_mask_np(ace, value.permissions), 0)
            XCTAssertEqual(acl_get_flagset_np(UnsafeMutableRawPointer(ace), &flags), 0)
            for flag in value.flags { XCTAssertEqual(acl_add_flag_np(try XCTUnwrap(flags), acl_flag_t(rawValue: flag)), 0) }
        }
        XCTAssertEqual(acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED), 0)
    }
    private func set(_ f: HardenFixture, _ entries: [ACLEntry], name: String = "target", global: [UInt32] = []) throws {
        let path = try HardenPath(f.at(name), allowTargetACL: true)
        _ = try path.requireTarget()
        try Self.nativeSet(path.fd, entries: entries, global: global)
    }
    private func allow(flags: [UInt32] = []) throws -> ACLEntry {
        .init(principalUUID: try callerUUID(), tag: ACL_EXTENDED_ALLOW.rawValue,
              permissions: UInt64(ACL_ADD_FILE.rawValue | ACL_ADD_SUBDIRECTORY.rawValue), flags: flags)
    }
    private func canWrite(_ f: HardenFixture, _ name: String = "target") -> Bool {
        // Native authorization oracle; no directory entries or file contents are read/written.
        if access(f.at(name), W_OK) == 0 { return true }
        XCTAssertEqual(errno, EACCES)
        return false
    }

    func testACLPreviewExactNoWriteAndAbsentRoundTrip() throws {
        let f = try fixture()
        let before = try stamp(f)
        XCTAssertEqual(before.acl.status, "absent")
        let output = try f.run("harden")
        check(output, 0)
        let preview = try JSONDecoder().decode(HardenResult.self, from: output.output)
        XCTAssertEqual(preview.changes[0].before, before)
        XCTAssertEqual(preview.changes[0].mode, 0o755)
        XCTAssertEqual(preview.changes[0].acl?.entries, [try deny().entry])
        XCTAssertEqual(try stamp(f), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.state))
        XCTAssertTrue(canWrite(f))
        check(try f.run("harden", apply: true), 0)
        XCTAssertFalse(canWrite(f))
        XCTAssertEqual(try f.mode(), 0o755)
        let applied = try stamp(f)
        check(try f.run("uninstall"), 0)
        XCTAssertEqual(try stamp(f), applied)
        check(try f.run("uninstall", apply: true), 0)
        XCTAssertEqual(try stamp(f).acl, before.acl, "absence must not become an empty-but-present ACL")
        XCTAssertTrue(canWrite(f))
        check(try f.run("uninstall", apply: true), 0)
    }

    func testNativeAllowBeforeDenyOrderAndOriginalOrderRestored() throws {
        let f = try fixture { f in try self.set(f, [self.allow(), self.deny().entry]) }
        let before = try stamp(f)
        XCTAssertTrue(canWrite(f), "an earlier allow can satisfy the requested right before a later deny")
        // Exact existing deny is deliberately refused, even when shadowed by an earlier allow.
        check(try f.run("harden", apply: true), 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.state))
        let g = try fixture { g in
            var later = try self.deny().entry
            later.permissions |= UInt64(ACL_ADD_SUBDIRECTORY.rawValue)
            try self.set(g, [self.allow(), later])
        }
        let original = try stamp(g).acl
        XCTAssertTrue(canWrite(g))
        check(try g.run("harden", apply: true), 0)
        XCTAssertEqual(try stamp(g).acl.entries, [try deny().entry] + original.entries)
        XCTAssertFalse(canWrite(g), "new deny is first, not appended after the matching allow")
        check(try g.run("uninstall", apply: true), 0)
        XCTAssertEqual(try stamp(g).acl, original)
        XCTAssertTrue(canWrite(g))
        XCTAssertEqual(try stamp(f), before)
    }

    func testNativeInheritedEntriesAndFlagsRoundTrip() throws {
        let f = try fixture { f in
            // Create true inherited ACEs in a fresh synthetic parent; then clear that parent.
            try f.directory("seed")
            let inherited = try self.allow(flags: [ACL_ENTRY_FILE_INHERIT.rawValue, ACL_ENTRY_DIRECTORY_INHERIT.rawValue])
            try self.set(f, [inherited], name: "seed")
            try f.directory("seed/child", mode: 0o755)
            let target = try HardenPath(f.at("target"))
            _ = try target.requireTarget()
            XCTAssertEqual(rmdir(f.at("target")), 0)
            XCTAssertEqual(rename(f.at("seed/child"), f.at("target")), 0)
            try self.set(f, [], name: "seed")
        }
        let original = try stamp(f).acl
        XCTAssertEqual(original.entries.count, 1)
        XCTAssertTrue(original.entries[0].flags.contains(ACL_ENTRY_INHERITED.rawValue))
        check(try f.run("harden", apply: true), 0)
        XCTAssertEqual(try stamp(f).acl.entries.dropFirst(), original.entries[...])
        check(try f.run("uninstall", apply: true), 0)
        XCTAssertEqual(try stamp(f).acl, original)
    }

    func testNewDenyDoesNotInheritOrOwnDescendants() throws {
        let f = try fixture { f in
            try self.set(f, [self.allow(flags: [ACL_ENTRY_FILE_INHERIT.rawValue, ACL_ENTRY_DIRECTORY_INHERIT.rawValue,
                                               ACL_ENTRY_LIMIT_INHERIT.rawValue, ACL_ENTRY_ONLY_INHERIT.rawValue])])
            try f.directory("target/existing")
        }
        let childFD = open(f.at("target/existing"), O_EVTONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(childFD, 0)
        defer { close(childFD) }
        let childBefore = readACL(childFD)
        check(try f.run("harden", apply: true), 0)
        XCTAssertEqual(readACL(childFD), childBefore)
        try f.directory("target/new")
        let newFD = open(f.at("target/new"), O_EVTONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(newFD, 0)
        defer { close(newFD) }
        XCTAssertEqual(readACL(newFD), childBefore, "only the pre-existing inheritable allow propagates")
        XCTAssertFalse(readACL(newFD).entries.contains { $0.tag == ACL_EXTENDED_DENY.rawValue })
        check(try f.run("uninstall", apply: true), 4) // Child creation changed parent ctime.
        XCTAssertEqual(readACL(newFD), childBefore)
    }

    func testGlobalNoInheritAndKernelEmptyACLNormalization() throws {
        for withEntry in [false, true] {
            let f = try fixture { f in try self.set(f, withEntry ? [self.allow()] : [], global: [ACL_FLAG_NO_INHERIT.rawValue]) }
            let original = try stamp(f).acl
            XCTAssertEqual(original.status, withEntry ? "observed" : "absent")
            XCTAssertEqual(original.flags, withEntry ? [ACL_FLAG_NO_INHERIT.rawValue] : [])
            check(try f.run("harden", apply: true), 0)
            check(try f.run("uninstall", apply: true), 0)
            XCTAssertEqual(try stamp(f).acl, original)
        }
    }

    func testLaterACLModeAndACLChangeAwayBackAreConflicts() throws {
        for kind in ["acl", "mode", "aba"] {
            let f = try fixture()
            check(try f.run("harden", apply: true), 0)
            let installed = try stamp(f).acl
            if kind == "mode" { XCTAssertEqual(chmod(f.at("target"), 0o750), 0) }
            else {
                try set(f, [allow()])
                if kind == "aba" { try set(f, installed.entries) }
            }
            let changed = try stamp(f)
            check(try f.run("uninstall", apply: true), 4)
            XCTAssertEqual(try stamp(f), changed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.state + "/00-restore-intent.json"))
        }
    }

    func testACLFinalCheckAndPostMutationRacesRefuseWithoutRollback() throws {
        for phase in ["before-apply", "after-apply", "before-restore", "after-restore"] {
            let f = try fixture()
            if phase.hasSuffix("restore") { check(try f.run("harden", apply: true), 0) }
            var changed: HardenStamp?
            let mutation: (Int, String) throws -> Void = { _, _ in
                try self.set(f, [self.allow()]); changed = try self.stamp(f)
            }
            let hooks = phase.hasPrefix("before") ? HardenHooks(beforeFinalCheck: mutation) : HardenHooks(afterMutation: mutation)
            check(try f.run(phase.hasSuffix("restore") ? "uninstall" : "harden", apply: true, hooks: hooks), 4)
            XCTAssertEqual(try stamp(f), changed)
            check(try f.run("uninstall", apply: true), 4)
            XCTAssertEqual(try stamp(f), changed)
        }
    }

    func testPartialMultiRootApplyAndRestoreRetainAmbiguousIntent() throws {
        for operation in ["harden", "uninstall"] {
            let f = try fixture(roots: ["target", "second"])
            if operation == "uninstall" { check(try f.run("harden", apply: true), 0) }
            let stop = HardenHooks(beforeFinalCheck: { index, _ in
                if index == 1 { throw HardenConflict("synthetic interruption before second mutation") }
            })
            check(try f.run(operation, apply: true, hooks: stop), 4)
            XCTAssertEqual(canWrite(f), operation == "uninstall")
            XCTAssertEqual(canWrite(f, "second"), operation == "harden")
            let first = try stamp(f), second = try stamp(f, "second")
            check(try f.run("uninstall", apply: true), 4)
            XCTAssertEqual(try stamp(f), first)
            XCTAssertEqual(try stamp(f, "second"), second)
        }
    }

    func testACLPreflightConflictPreventsAllRestores() throws {
        let f = try fixture(roots: ["target", "second"])
        check(try f.run("harden", apply: true), 0)
        try set(f, [allow()], name: "second")
        let first = try stamp(f), second = try stamp(f, "second")
        check(try f.run("uninstall", apply: true), 4)
        XCTAssertEqual(try stamp(f), first)
        XCTAssertEqual(try stamp(f, "second"), second)
    }

    func testACLProcessCrashAfterApplyAndRestoreIsAmbiguous() throws {
        for operation in ["harden", "uninstall"] {
            let f = try fixture()
            if operation == "uninstall" { check(try f.run("harden", apply: true), 0) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest", "HostAuditTests.HostHardeningTests/testCrashHarnessChild",
                                 Bundle(for: HostACLHardeningTests.self).bundleURL.path]
            process.environment = ["PATH": "/usr/bin:/bin", "SANJBOX_B2_TEST_PATH": f.path, "SANJBOX_B2_TEST_OPERATION": operation]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(15)
            while process.isRunning && Date() < deadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 77)
            XCTAssertEqual(canWrite(f), operation == "uninstall")
            let current = try stamp(f)
            check(try f.run("uninstall", apply: true), 4)
            XCTAssertEqual(try stamp(f), current)
        }
    }

    func testBoundedACLPlanAndJournalRejectUnsupportedMetadata() throws {
        let valid = try deny()
        for bad in [ACLDeny(principalUUID: "not-a-uuid", permissions: ["list"]),
                    ACLDeny(principalUUID: valid.principalUUID.lowercased(), permissions: ["list"]),
                    ACLDeny(principalUUID: valid.principalUUID, permissions: ["list", "list"]),
                    ACLDeny(principalUUID: valid.principalUUID, permissions: ["writesecurity"]),
                    ACLDeny(principalUUID: valid.principalUUID, permissions: ["directory_inherit"])] {
            XCTAssertThrowsError(try validateDenies([bad]))
        }
        XCTAssertThrowsError(try validateDenies([valid, valid]))
        XCTAssertThrowsError(try HardeningPlan(schema: "sanjbox.host-harden.plan.v2", roots: ["a"], deny: [valid]).validate())
        let unknown = "{\"principalUUID\":\"\(valid.principalUUID)\",\"permissions\":[\"list\"],\"flags\":[64]}"
        XCTAssertThrowsError(try JSONDecoder().decode(ACLDeny.self, from: Data(unknown.utf8)))
        for kind in ["mask", "flag", "tag", "uuid", "reorder", "version"] {
            let f = try fixture { f in try self.set(f, [self.allow()]) }
            check(try f.run("harden", apply: true), 0)
            let path = f.state + "/manifest.json"
            var manifest = try JSONDecoder().decode(HardenManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            switch kind {
            case "mask": manifest.changes[0].acl!.entries[0].permissions |= 1 << 63
            case "flag": manifest.changes[0].acl!.entries[0].flags = [ACL_ENTRY_FILE_INHERIT.rawValue]
            case "tag": manifest.changes[0].acl!.entries[0].tag = ACL_EXTENDED_ALLOW.rawValue
            case "uuid": manifest.changes[0].acl!.entries[0].principalUUID = "bad"
            case "reorder": manifest.changes[0].acl!.entries.reverse()
            default: manifest.schema = "sanjbox.host-harden.journal.v1"
            }
            try encode(manifest).write(to: URL(fileURLWithPath: path))
            let before = try stamp(f)
            check(try f.run("uninstall", apply: true), 4)
            XCTAssertEqual(try stamp(f), before)
        }
    }

    func testACLBoundsAndInheritedAncestorRefusal() throws {
        let f = try fixture { f in try self.set(f, Array(repeating: self.allow(), count: 128)) }
        check(try f.run("harden", apply: true), 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.state))
        let g = try fixture()
        let ancestor = try HardenPath(g.path)
        try Self.nativeSet(ancestor.fd, entries: [allow()])
        defer { try? Self.nativeSet(ancestor.fd, entries: []) }
        check(try g.run("harden", apply: true), 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: g.state))
    }

    func testCallerGroupEveryoneAndUnresolvedReopenDeniesRefused() throws {
        var group = UUID().uuid
        XCTAssertEqual(mbr_gid_to_uuid(getegid(), &group), 0)
        let principals = [try callerUUID(), UUID(uuid: group).uuidString,
                          "ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C", "13600F21-0F7B-4FD2-9D59-FF33C10A9BA7"]
        for principal in principals {
            let f = try HardenFixture()
            addTeardownBlock { try f.cleanup() }
            try f.setup(plan: .init(schema: "sanjbox.host-harden.plan.v2", roots: ["root-0"], mode: nil,
                deny: [.init(principalUUID: principal, permissions: ["list", "search"])]))
            let before = try stamp(f)
            check(try f.run("harden", apply: true), 4)
            XCTAssertEqual(try stamp(f), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.state))
        }
    }

    func testNonCallerReadAndSearchDenyCanBeRestored() throws {
        let f = try HardenFixture()
        addTeardownBlock { try f.cleanup() }
        var nobody = UUID().uuid
        XCTAssertEqual(mbr_uid_to_uuid(UInt32.max - 1, &nobody), 0)
        try f.setup(plan: .init(schema: "sanjbox.host-harden.plan.v2", roots: ["root-0"], mode: nil,
            deny: [.init(principalUUID: UUID(uuid: nobody).uuidString, permissions: ["list", "search", "readattr"])]))
        let original = try stamp(f)
        check(try f.run("harden", apply: true), 0)
        XCTAssertEqual(try stamp(f).acl.entries.count, 1)
        check(try f.run("uninstall", apply: true), 0)
        XCTAssertEqual(try stamp(f).acl, original.acl)
    }

    func testV2CLIWrappersDefaultPreviewApplyAndUninstall() throws {
        let f = try fixture()
        let binary = Bundle(for: HostACLHardeningTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("sanjbox-host-harden")
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (operation, apply) in [("harden", false), ("harden", true), ("uninstall", false), ("uninstall", true), ("uninstall", true)] {
            let process = Process()
            process.executableURL = sourceRoot.appendingPathComponent(operation == "harden" ? "harden-host.sh" : "uninstall.sh")
            process.arguments = Array(f.args(operation, apply: apply).dropFirst())
            process.environment = ["PATH": "/usr/bin:/bin", "SANJBOX_HOST_HARDEN_BIN": binary.path]
            let output = Pipe()
            process.standardOutput = output; process.standardError = FileHandle.standardError
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
            let result = try JSONDecoder().decode(HardenResult.self, from: data)
            XCTAssertEqual(result.dryRun, !apply)
            XCTAssertNotNil(result.changes.first?.acl)
            if operation == "harden" && !apply { XCTAssertFalse(FileManager.default.fileExists(atPath: f.state)) }
        }
        XCTAssertTrue(canWrite(f))
        XCTAssertEqual(try stamp(f).acl.status, "absent")
    }
}
