import Darwin
import Foundation
import SanjboxProbeKit
import XCTest
@testable import StateManifest

private final class Inputs: @unchecked Sendable {
    let directory: String
    private let inode: ino_t
    private let device: dev_t
    init() throws {
        var bytes = Array("/private/tmp/sanjbox-state-tests.XXXXXX".utf8CString)
        guard let created = mkdtemp(&bytes) else { throw ManifestError("temporary fixture creation failed") }
        directory = String(cString: created)
        var info = stat()
        guard lstat(directory, &info) == 0 else { throw ManifestError("fixture metadata unavailable") }
        inode = info.st_ino
        device = info.st_dev
    }
    func path(_ name: String) -> String { directory + "/" + name }
    func write(_ name: String, data: Data) throws {
        let fd = open(path(name), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ManifestError("fixture write refused") }
        defer { close(fd) }
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count == data.count else { throw ManifestError("fixture write failed") }
    }
    func json<T: Encodable>(_ name: String, _ value: T) throws { try write(name, data: JSONEncoder().encode(value)) }
    func clean() throws {
        var info = stat()
        guard directory.hasPrefix("/private/tmp/sanjbox-state-tests."), lstat(directory, &info) == 0,
              info.st_ino == inode, info.st_dev == device, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else {
            throw ManifestError("refusing cleanup of replaced fixture")
        }
        try FileManager.default.removeItem(atPath: directory)
    }
}

final class StateManifestTests: XCTestCase {
    private var package: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func example(_ name: String = "mvp") throws -> Manifest {
        try decodeManifest(Data(contentsOf: package.appendingPathComponent("examples/\(name).state-manifest.json")))
    }
    private func validate(_ mutation: (inout Manifest) -> Void) throws -> ValidationReport {
        var manifest = try example()
        mutation(&manifest)
        return Validator().validate(manifest)
    }
    private func has(_ report: ValidationReport, _ code: String, severity: String = "error", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(report.findings.contains { $0.code == code && $0.severity == severity }, "missing \(severity): \(code)", file: file, line: line)
    }
    private func inputs() throws -> Inputs {
        let inputs = try Inputs()
        addTeardownBlock { try inputs.clean() }
        return inputs
    }
    private func expected(_ context: ProbeContext) throws -> ExpectedContext {
        let manager = try XCTUnwrap(context.launchdManager)
        return .init(schema: "sanjbox.state-expect.v1", expectation: .init(
            effectiveUID: context.effectiveUID, realUID: context.realUID,
            effectiveGID: context.effectiveGID, realGID: context.realGID,
            requiredGroups: [], forbiddenGroups: [], launchdManagerName: manager.name, launchdManagerUID: manager.uid
        ), auditSessionID: try XCTUnwrap(context.audit?.sessionID))
    }

    func testExamplesProduceCompleteDeclarationsButNoObservedGuarantees() throws {
        for name in ["mvp", "f4"] {
            let report = Validator().validate(try example(name))
            XCTAssertTrue(report.consistentDesign)
            XCTAssertTrue(report.requiredRolesDeclared)
            XCTAssertFalse(report.deploymentReady)
            XCTAssertEqual(report.observedTopology, "not-inspected")
            XCTAssertEqual(report.observedWriteCoverage, "unverified")
            XCTAssertEqual(report.acceptanceStatus, "Neověřeno")
            XCTAssertEqual(report.plannedRoots.count, name == "mvp" ? 5 : 6)
            XCTAssertEqual(report.plannedRoots.first { $0.role == "prefix" }?.plannedPath, "/opt/snj/t001")
            has(report, "multi-volume-recovery", severity: "warning")
            has(report, "container-budget-unresolved", severity: "warning")
        }
    }

    func testMissingAndDuplicateRequiredRolesNeverPassAsComplete() throws {
        let missing = try validate { $0.roots.removeAll { $0.role == "tmp" } }
        has(missing, "required-roles")
        XCTAssertFalse(missing.requiredRolesDeclared)
        let duplicate = try validate { m in
            var duplicate = m.roots[0]
            duplicate.id = "other-home"
            duplicate.relativePath = "other-home"
            m.roots.append(duplicate)
        }
        has(duplicate, "required-roles")
        XCTAssertFalse(duplicate.consistentDesign)
    }

    func testNestedRootsCaseAndUnicodeAliasesAreRejected() throws {
        has(try validate { $0.roots[3].relativePath = "home/Library/Caches" }, "root-overlap")
        has(try validate { $0.roots[3].relativePath = "HOME" }, "root-overlap")
        let unicode = try validate { m in
            m.roots[0].relativePath = "caf\u{e9}"
            m.roots[3].relativePath = "cafe\u{301}"
        }
        has(unicode, "root-overlap")
        XCTAssertFalse(overlaps("/zone/home", "/zone/homework"))
    }

    func testMountAliasesAndNestedMountsAreRejected() throws {
        has(try validate { $0.volumes[1].mountPoint = "/Volumes/Sanjbox/t001/state/prefix" }, "mount-overlap")
        has(try validate { $0.volumes[1].mountPoint = "/VOLUMES/SANJBOX/t001/STATE" }, "mount-overlap")
        for path in ["/tmp/a", "/TMP/a", "/var/a", "/ETC/a", "/System/Volumes/DATA/a", "/", "/Users", "/VOLUMES"] {
            has(try validate { $0.volumes[0].mountPoint = path }, "mount-path")
        }
    }

    func testRelativePathsTraversalControlAndCombinedLength() throws {
        for path in ["../escape", "home/../escape", "/absolute", "a//b", "a/", "./a", "a\u{0}b", "a\nb", "a\\b"] {
            has(try validate { $0.roots[0].relativePath = path }, "root-path")
        }
        has(try validate {
            $0.volumes[0].mountPoint = "/" + String(repeating: "a", count: 800)
            $0.roots[0].relativePath = String(repeating: "b", count: 300)
        }, "resolved-path-limit")
    }

    func testUnknownAndDuplicateLogicalReferencesDoNotTrap() throws {
        has(try validate { $0.containers.append($0.containers[0]) }, "duplicate-id")
        has(try validate { $0.volumes[1].id = $0.volumes[0].id }, "duplicate-id")
        has(try validate { $0.roots[1].id = $0.roots[0].id }, "duplicate-id")
        has(try validate { $0.volumes[0].containerID = "missing" }, "container-reference")
        has(try validate { $0.roots[0].volumeID = "missing" }, "volume-reference")
    }

    func testDeclaredUUIDAliasesCannotCreateFalseSeparateVolumes() throws {
        let uuid = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        has(try validate { $0.volumes[0].declaredUUID = uuid; $0.volumes[1].declaredUUID = uuid.lowercased() }, "uuid-alias")
        has(try validate { $0.containers[0].declaredUUID = uuid; $0.volumes[0].declaredUUID = uuid }, "uuid-alias")
        for value in ["not-a-uuid", "00000000-0000-0000-0000-000000000000"] {
            has(try validate { $0.volumes[0].declaredUUID = value }, "invalid-declared-uuid")
        }
    }

    func testQuotaZeroAndExplicitUnlimitedAreUnambiguous() throws {
        has(try validate { $0.volumes[0].quota.limitBytes = 0 }, "quota-limit")
        has(try validate { $0.volumes[0].quota.limitBytes = nil }, "quota-limit")
        has(try validate { $0.volumes[0].quota.mode = "unbounded"; $0.volumes[0].quota.limitBytes = 0 }, "quota-mode")
        let unlimited = try validate { $0.volumes[0].quota.mode = "unbounded"; $0.volumes[0].quota.limitBytes = nil }
        XCTAssertTrue(unlimited.consistentDesign)
        XCTAssertTrue(unlimited.containerBudgets[0].hasUnboundedOrUnresolvedVolume)
        XCTAssertFalse(unlimited.deploymentReady)
        has(unlimited, "quota-unverified", severity: "warning")
        has(try validate { $0.volumes[0].quota.reserveBytes = $0.volumes[0].quota.limitBytes! + 1 }, "reserve-exceeds-quota")
    }

    func testContainerReservationBudgetAndCeilingOversubscriptionDiffer() throws {
        let reserveExcess = try validate {
            $0.containers[0].planningBudgetBytes = 100
            $0.volumes[0].quota.reserveBytes = 60
            $0.volumes[1].quota.reserveBytes = 60
        }
        has(reserveExcess, "reserves-exceed-budget")
        let ceilings = try validate { $0.containers[0].planningBudgetBytes = 1024 }
        XCTAssertTrue(ceilings.consistentDesign)
        has(ceilings, "quotas-oversubscribed", severity: "warning")
        XCTAssertEqual(ceilings.containerBudgets[0].declaredReserveSum, 0)
        has(try validate { $0.containers[0].planningBudgetBytes = 0 }, "zero-container-budget")
    }

    func testBudgetOverflowIsRejectedWithoutTruncatedTotals() throws {
        let report = try validate {
            $0.volumes[0].quota.limitBytes = UInt64.max
            $0.volumes[1].quota.limitBytes = UInt64.max
            $0.volumes[0].quota.reserveBytes = UInt64.max
            $0.volumes[1].quota.reserveBytes = UInt64.max
        }
        has(report, "budget-overflow")
        XCTAssertNil(report.containerBudgets[0].declaredReserveSum)
        XCTAssertNil(report.containerBudgets[0].declaredFiniteQuotaSum)
        // The JSON path must retain UInt64 exactly, not silently round through NSNumber/Double.
        var maximum = try example()
        maximum.volumes[0].quota.limitBytes = UInt64.max
        let decoded = try decodeManifest(JSONEncoder().encode(maximum))
        XCTAssertEqual(decoded.volumes[0].quota.limitBytes, UInt64.max)
    }

    func testEveryVolumeMustBeInOneRestoreUnitAndNoRenameShortcut() throws {
        has(try validate { $0.rollback.volumeIDs.removeLast() }, "restore-membership")
        has(try validate { $0.rollback.volumeIDs.append("tools") }, "restore-membership")
        has(try validate { $0.rollback.volumeIDs.append("unknown") }, "restore-membership")
        for strategy in ["rename-swap", "snapshot-mount-is-writable", "restore-only-project"] {
            has(try validate { $0.rollback.strategy = strategy }, "restore-contract")
        }
        has(try validate { $0.rollback.recoveryRequired = false }, "restore-contract")
        has(try validate { $0.rollback.startPolicy = "start-anyway" }, "restore-contract")
        has(try validate { $0.roots[0].rollback = "excluded" }, "partial-rollback")
    }

    func testHostPolicyRecoveryCannotBeInOrAboveRestoredState() throws {
        for path in ["/Volumes/Sanjbox/t001/state/control", "/Volumes/Sanjbox", "/opt/snj/t001"] {
            has(try validate { $0.hostControl.directoryPath = path }, "control-in-restore")
        }
        has(try validate { $0.hostControl.ownerUID = $0.zone.uid }, "host-control")
        has(try validate { $0.hostControl.directoryMode = "0777" }, "host-control")
        has(try validate { $0.hostControl.rollback = "included" }, "host-control")
        has(try validate { $0.hostControl.recoveryFile = "POLICY.json" }, "control-alias")
        has(try validate { $0.hostControl.policyFile = "../outside" }, "control-file")
    }

    func testReadOnlyInputsCannotIncludeWritesOrHostRecovery() throws {
        for path in ["/opt/snj/t001/bin", "/Volumes/Sanjbox", "/Library"] {
            has(try validate { $0.readOnlyInputs[0].path = path }, "input-state-overlap")
        }
        has(try validate { $0.readOnlyInputs[1].path = $0.readOnlyInputs[0].path + "/nested" }, "input-overlap")
        has(try validate { $0.hostAccess = "inherited-host-acl" }, "host-access")
    }

    func testRuntimeIsExplicitlyDeferredUntilF4Design() throws {
        has(try validate { $0.runtimePolicy = "enabled" }, "runtime-mvp")
        var f4 = try example("f4")
        f4.phase = "mvp"
        has(Validator().validate(f4), "runtime-mvp")
        f4.phase = "f4-design"
        f4.roots.removeAll { $0.role == "runtime" }
        has(Validator().validate(f4), "runtime-f4")
        XCTAssertFalse(Validator().validate(f4).requiredRolesDeclared)
        has(try validate { $0.phase = "production" }, "phase")
    }

    func testNoDeclaredPathLookupOrShellEvaluationOccurs() throws {
        let fixture = try inputs()
        let report = try validate {
            $0.volumes[0].mountPoint = "/uncreated-synthetic-topology/t001"
            $0.roots[0].relativePath = "literal$(touch " + fixture.path("should-not-exist") + ")"
        }
        XCTAssertTrue(report.consistentDesign)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.path("should-not-exist")))
        XCTAssertEqual(report.observedTopology, "not-inspected")
    }

    func testStrictSchemaRejectsUnknownMeasuredAndNestedFields() throws {
        let data = try JSONEncoder().encode(example())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["observedTopology"] = "verified"
        XCTAssertThrowsError(try decodeManifest(JSONSerialization.data(withJSONObject: object)))
        object.removeValue(forKey: "observedTopology")
        var volumes = try XCTUnwrap(object["volumes"] as? [[String: Any]])
        volumes[0]["quotaEnforced"] = true
        object["volumes"] = volumes
        XCTAssertThrowsError(try decodeManifest(JSONSerialization.data(withJSONObject: object)))
        has(try validate { $0.intent = "measured" }, "design-only")
    }

    func testDuplicateDecodedJSONKeysAndBoundsAreRejected() throws {
        for json in [
            #"{"schema":"a","schema":"b"}"#,
            #"{"schema":"a","\u0073chema":"b"}"#,
            #"{"nested":{"id":1,"\u0069d":2}}"#,
            #"{"caf\u00e9":1,"cafe\u0301":2}"#,
            #"{"nested":{"x":1,"x":2}}"#
        ] {
            XCTAssertThrowsError(try { var p = try JSONPreflight(Data(json.utf8)); try p.check() }())
        }
        for json in [String(repeating: "[", count: 20) + "0" + String(repeating: "]", count: 20),
                     "[" + Array(repeating: "0", count: 129).joined(separator: ",") + "]",
                     "\"" + String(repeating: "x", count: 4097) + "\"", "{\"a\":1} trailing"] {
            XCTAssertThrowsError(try { var p = try JSONPreflight(Data(json.utf8)); try p.check() }())
        }
        XCTAssertThrowsError(try JSONPreflight(Data(repeating: 32, count: 256 * 1024 + 1)))
    }

    func testBoundedCollectionsAndOutputSize() throws {
        let report = try validate { m in
            let root = m.roots[0]
            m.roots = Array(repeating: root, count: 65)
        }
        has(report, "collection-limit")
        XCTAssertTrue(report.plannedRoots.isEmpty)
        let data = try JSONEncoder().encode(Validator().validate(example()))
        XCTAssertLessThan(data.count, 20_000)
    }

    func testOwnedInputMetadataRejectsAliasesLinksModesAndOversize() throws {
        let fixture = try inputs()
        try fixture.json("safe.state-manifest.json", example())
        let safe = fixture.path("safe.state-manifest.json")
        XCTAssertNoThrow(try ownedSchemaData(at: safe, suffix: ".state-manifest.json", maximumBytes: 256 * 1024))
        XCTAssertEqual(symlink(safe, fixture.path("link.state-manifest.json")), 0)
        XCTAssertThrowsError(try ownedSchemaData(at: fixture.path("link.state-manifest.json"), suffix: ".state-manifest.json", maximumBytes: 256 * 1024))
        XCTAssertEqual(symlink(fixture.directory, fixture.path("ancestor-alias")), 0)
        XCTAssertThrowsError(try ownedSchemaData(at: fixture.path("ancestor-alias/safe.state-manifest.json"), suffix: ".state-manifest.json", maximumBytes: 256 * 1024))
        XCTAssertEqual(link(safe, fixture.path("hard.state-manifest.json")), 0)
        XCTAssertThrowsError(try ownedSchemaData(at: safe, suffix: ".state-manifest.json", maximumBytes: 256 * 1024))
        XCTAssertEqual(unlink(fixture.path("hard.state-manifest.json")), 0)
        XCTAssertEqual(chmod(safe, 0o666), 0)
        XCTAssertThrowsError(try ownedSchemaData(at: safe, suffix: ".state-manifest.json", maximumBytes: 256 * 1024))
        XCTAssertEqual(chmod(safe, 0o600), 0)
        XCTAssertThrowsError(try ownedSchemaData(at: safe, suffix: ".state-manifest.json", maximumBytes: 1))
        try fixture.json("synthetic-secret.state-manifest.json", example())
        XCTAssertThrowsError(try ownedSchemaData(at: fixture.path("synthetic-secret.state-manifest.json"), suffix: ".state-manifest.json", maximumBytes: 256 * 1024))
        XCTAssertEqual(mkfifo(fixture.path("fifo.state-manifest.json"), 0o600), 0)
        XCTAssertThrowsError(try ownedSchemaData(at: fixture.path("fifo.state-manifest.json"), suffix: ".state-manifest.json", maximumBytes: 256 * 1024))
    }

    func testIdentityMismatchPrecedesManifestReadAndIncompleteExpectationFails() throws {
        let fixture = try inputs()
        let context = ProbeContext.capture()
        var exp = try expected(context)
        exp.expectation.effectiveUID = context.effectiveUID + 1
        try fixture.json("wrong.state-expect.json", exp)
        let result = try StateManifestCommand.run(["--expect", fixture.path("wrong.state-expect.json"), "--manifest", fixture.path("nonexistent.state-manifest.json")], capture: { _ in context })
        XCTAssertEqual(result.exitCode, 3)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        XCTAssertNil(object["validation"])
        exp.expectation.requiredGroups = nil
        XCTAssertThrowsError(try exp.requireComplete())
    }

    func testActualCLIUsesCurrentBuildProductAndKeepsTopologyUnverified() throws {
        let fixture = try inputs()
        try fixture.json("run.state-expect.json", expected(ProbeContext.capture()))
        try fixture.json("run.state-manifest.json", example())
        let executable = Bundle(for: StateManifestTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("sanjbox-state-manifest")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--expect", fixture.path("run.state-expect.json"), "--manifest", fixture.path("run.state-manifest.json")]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let validation = try XCTUnwrap(json["validation"] as? [String: Any])
        XCTAssertEqual(validation["consistentDesign"] as? Bool, true)
        XCTAssertEqual(validation["deploymentReady"] as? Bool, false)
        XCTAssertEqual(validation["observedTopology"] as? String, "not-inspected")
        XCTAssertEqual(validation["acceptanceStatus"] as? String, "Neověřeno")
    }
}
