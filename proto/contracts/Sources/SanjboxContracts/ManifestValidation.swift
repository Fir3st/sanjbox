import Foundation

// Mirrored from B3 Validation.swift. tools/test_manifest_parity.py compiles the CURRENT B3
// source independently and compares every report field; update both only through reviewed scope.

struct B3ManifestValidator {
    func validate(_ manifest: StateManifestDocument) -> ManifestValidationReport {
        var report = ManifestValidationReport(consistentDesign: false, requiredRolesDeclared: false, findings: [],
                                      plannedRoots: [], plannedVolumes: [], containerBudgets: [])
        func add(_ code: String, _ location: String, _ explanation: String, warning: Bool = false) {
            report.findings.append(.init(severity: warning ? "warning" : "error", code: code, location: location, explanation: explanation))
        }
        guard (1...8).contains(manifest.containers.count), (1...16).contains(manifest.volumes.count),
              (1...64).contains(manifest.roots.count), manifest.readOnlyInputs.count <= 32,
              manifest.rollback.volumeIDs.count <= 16 else {
            add("collection-limit", "$", "Require 1...8 containers, 1...16 volumes, 1...64 roots, at most 32 read-only inputs and 16 restore references.")
            return report
        }
        if manifest.schema != "sanjbox.state-manifest.v1" || manifest.intent != "design-only" {
            add("design-only", "$", "Only sanjbox.state-manifest.v1 design-only documents are supported; observations and deployment are not supported.")
        }
        if !["mvp", "f4-design"].contains(manifest.phase) { add("phase", "phase", "Supported phases are mvp and f4-design.") }
        if manifest.zone.id.utf8.count != 4 || !manifest.zone.id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) {
            add("zone-id", "zone.id", "The candidate short-prefix layout requires exactly four lowercase ASCII letters/digits.")
        }
        if manifest.zone.uid == 0 || manifest.zone.gid == 0 { add("zone-identity", "zone", "A zone must declare non-root UID and GID; existence and uniqueness on a host remain unverified.") }
        if manifest.hostAccess != "controlled-export-only" { add("host-access", "hostAccess", "C-001/F0.3 requires controlled export; no inherited host project ACL is provided.") }
        if manifest.outsideWrites != "forbidden-unverified" { add("outside-writes", "outsideWrites", "Writes outside the declaration must be forbidden-unverified; a manifest cannot assert enforcement.") }

        for (label, ids) in [("containers", manifest.containers.map(\.id)), ("volumes", manifest.volumes.map(\.id)),
                             ("roots", manifest.roots.map(\.id)), ("readOnlyInputs", manifest.readOnlyInputs.map(\.id))] {
            if ids.contains(where: { !Identifier.isValidPlanID($0) }) { add("identifier", label, "IDs must be 1...32 lowercase ASCII letters, digits or hyphens.") }
            if Set(ids).count != ids.count { add("duplicate-id", label, "IDs must be unique within their collection.") }
        }
        let containers = Dictionary(manifest.containers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let volumes = Dictionary(manifest.volumes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seenUUIDs = Set<UUID>()
        for (label, value) in manifest.containers.map({ ("container:" + $0.id, $0.declaredUUID) }) + manifest.volumes.map({ ("volume:" + $0.id, $0.declaredUUID) }) {
            if let value {
                guard value.utf8.count == 36, let uuid = UUID(uuidString: value), uuid.uuidString != "00000000-0000-0000-0000-000000000000" else {
                    add("invalid-declared-uuid", label, "A declared UUID must be a nonzero canonical UUID, or omitted while unassigned.")
                    continue
                }
                if !seenUUIDs.insert(uuid).inserted { add("uuid-alias", label, "One declared physical UUID cannot represent multiple logical containers/volumes, even with different letter case.") }
            }
        }
        for container in manifest.containers {
            if container.planningBudgetBytes == 0 { add("zero-container-budget", container.id, "An unknown budget is omitted; zero cannot budget a state container.") }
            if !manifest.volumes.contains(where: { $0.containerID == container.id }) { add("unused-container", container.id, "Every declared container needs at least one volume.") }
        }
        for volume in manifest.volumes {
            if containers[volume.containerID] == nil { add("container-reference", volume.id, "Volume references an undeclared container.") }
            if !StateManifestSchema.isNormalizedPath(volume.mountPoint, absolute: true) || ["/users", "/volumes", "/opt", "/opt/snj", "/applications", "/library", "/system", "/private", "/usr"].contains(StateManifestSchema.foldedPath(volume.mountPoint)) {
                add("mount-path", volume.id, "Mountpoint must be a normalized, non-root, non-alias absolute design path, not a shared system parent.")
            }
            if volume.filesystem != "apfs" || volume.ownership != "required" { add("filesystem-policy", volume.id, "This candidate requires APFS with ownership enabled; neither is measured here.") }
            switch volume.quota.mode {
            case "limited":
                if volume.quota.limitBytes == nil || volume.quota.limitBytes == 0 {
                    add("quota-limit", volume.id, "limited requires a positive byte limit; zero is never shorthand for unlimited.")
                }
                if let limit = volume.quota.limitBytes, volume.quota.reserveBytes > limit { add("reserve-exceeds-quota", volume.id, "Declared reserve must not exceed the finite quota.") }
            case "unbounded", "unresolved":
                if volume.quota.limitBytes != nil { add("quota-mode", volume.id, "unbounded/unresolved must omit limitBytes, not use zero or a hidden finite limit.") }
                add("quota-unverified", volume.id, "No finite quota is planned for this volume; no per-zone storage limit can be inferred.", warning: true)
            default: add("quota-mode", volume.id, "Quota mode must be limited, unbounded or unresolved.")
            }
            if !manifest.roots.contains(where: { $0.volumeID == volume.id }) { add("unused-volume", volume.id, "Every zone volume must have a declared write root.") }
        }
        for i in manifest.volumes.indices {
            for j in manifest.volumes.indices where j > i {
                if StateManifestSchema.overlaps(manifest.volumes[i].mountPoint, manifest.volumes[j].mountPoint) {
                    add("mount-overlap", "volumes", "Equal, aliased-by-case/normalization or nested mountpoints are unsupported; declare independent restore volumes.")
                }
            }
        }

        let required = ["home", "project", "prefix", "cache", "tmp"]
        let roleCounts = Dictionary(manifest.roots.map { ($0.role, 1) }, uniquingKeysWith: +)
        report.requiredRolesDeclared = required.allSatisfy { roleCounts[$0] == 1 }
        if !report.requiredRolesDeclared { add("required-roles", "roots", "Declare exactly one home, project, prefix, cache and tmp root.") }
        let runtimeCount = roleCounts["runtime", default: 0]
        report.requiredRolesDeclared = report.requiredRolesDeclared && ((manifest.phase == "mvp" && runtimeCount == 0)
            || (manifest.phase == "f4-design" && runtimeCount == 1))
        if manifest.phase == "mvp" {
            if manifest.runtimePolicy != "deferred-f4" || runtimeCount != 0 { add("runtime-mvp", "runtimePolicy", "MVP explicitly defers runtime to F4 (C-002); no runtime root may be active in this design.") }
        } else if manifest.phase == "f4-design" {
            if manifest.runtimePolicy != "declared-unverified" || runtimeCount != 1 { add("runtime-f4", "runtimePolicy", "F4 design requires one runtime root and declared-unverified policy; this does not enable Docker.") }
        }
        for root in manifest.roots {
            if !required.contains(root.role) && !["runtime", "additional"].contains(root.role) { add("root-role", root.id, "Unknown write-root role.") }
            if root.ownerUID != manifest.zone.uid { add("root-owner", root.id, "Every zone write root must declare the zone UID; actual ownership is not measured.") }
            if root.rollback != "whole-volume" { add("partial-rollback", root.id, "Every write root participates in whole-volume restore; per-directory exclusions cannot model an APFS volume snapshot.") }
            if root.purpose.isEmpty || root.purpose.utf8.count > 256 { add("root-purpose", root.id, "A bounded purpose is required for every root.") }
            guard let volume = volumes[root.volumeID] else { add("volume-reference", root.id, "Root references an undeclared volume."); continue }
            guard StateManifestSchema.isNormalizedPath(root.relativePath, absolute: false), StateManifestSchema.isNormalizedPath(volume.mountPoint, absolute: true) else {
                add("root-path", root.id, "Root path must be a normalized relative path (or . for the volume root), never absolute or containing traversal.")
                continue
            }
            let path = volume.mountPoint + (root.relativePath == "." ? "" : "/" + root.relativePath)
            guard path.utf8.count <= 1024 else { add("resolved-path-limit", root.id, "Combined mountpoint and relative path exceed 1024 bytes."); continue }
            report.plannedRoots.append(.init(id: root.id, role: root.role, volumeID: root.volumeID, plannedPath: path, rollbackUnit: manifest.rollback.unitID))
            if root.role == "prefix" && path != "/opt/snj/" + manifest.zone.id {
                add("prefix-layout", root.id, "This candidate requires /opt/snj/<four-character-zone>; bottle compatibility remains S6 work.")
            }
        }
        for i in report.plannedRoots.indices {
            for j in report.plannedRoots.indices where j > i {
                if StateManifestSchema.overlaps(report.plannedRoots[i].plannedPath, report.plannedRoots[j].plannedPath) {
                    add("root-overlap", "roots", "Write-root roles must be disjoint; nested home/cache/project or case/normalization aliases double-count scope.")
                }
            }
        }
        let restoreIDs = manifest.rollback.volumeIDs
        if !Identifier.isValidPlanID(manifest.rollback.unitID) || Set(restoreIDs).count != restoreIDs.count || Set(restoreIDs) != Set(volumes.keys) {
            add("restore-membership", "rollback", "One restore unit must include every declared zone volume exactly once, and no unknown volume.")
        }
        if manifest.rollback.strategy != "rebuild-writable-state-then-switch" || manifest.rollback.quiescence != "whole-uid-required"
            || !manifest.rollback.recoveryRequired || manifest.rollback.startPolicy != "deny-until-verified" {
            add("restore-contract", "rollback", "Require writable reconstruction, whole-UID quiescence, host recovery and deny-start until verification; no rename/snapshot-mount shortcut is supported.")
        }
        if manifest.volumes.count > 1 { add("multi-volume-recovery", "rollback", "Several volumes are not an atomic rollback. B4 must implement and test a durable recovery protocol before start is possible.", warning: true) }
        validateControlAndInputs(manifest, report: &report)
        budget(manifest, report: &report)
        report.plannedVolumes = manifest.volumes
        report.plannedRoots.sort { $0.id < $1.id }
        report.findings.sort { ($0.severity, $0.code, $0.location) < ($1.severity, $1.code, $1.location) }
        report.consistentDesign = !report.findings.contains { $0.severity == "error" }
        return report
    }

    private func validateControlAndInputs(_ m: StateManifestDocument, report: inout ManifestValidationReport) {
        func add(_ code: String, _ location: String, _ why: String) {
            report.findings.append(.init(severity: "error", code: code, location: location, explanation: why))
        }
        let control = m.hostControl
        if !StateManifestSchema.isNormalizedPath(control.directoryPath, absolute: true) || control.ownerUID != 0 || control.ownerUID == m.zone.uid
            || control.directoryMode != "0700" || control.rollback != "excluded" {
            add("host-control", "hostControl", "Require a normalized host-root-owned 0700 control directory explicitly excluded from zone rollback; these are desired properties only.")
        }
        for filename in [control.policyFile, control.recoveryFile] {
            if !StateManifestSchema.isNormalizedPath(filename, absolute: false) || filename == "." || filename.contains("/") || filename.utf8.count > 128 {
                add("control-file", "hostControl", "Policy and recovery names must be distinct bounded single filenames within the control directory.")
            }
        }
        if StateManifestSchema.foldedPath(control.policyFile) == StateManifestSchema.foldedPath(control.recoveryFile) { add("control-alias", "hostControl", "Policy and recovery cannot alias each other.") }
        if m.volumes.contains(where: { StateManifestSchema.overlaps(control.directoryPath, $0.mountPoint) }) {
            add("control-in-restore", "hostControl", "Host policy/recovery must be lexically outside and not above every zone mountpoint; actual volume separation still requires measurement.")
        }
        for input in m.readOnlyInputs {
            if !StateManifestSchema.isNormalizedPath(input.path, absolute: true) || input.purpose.isEmpty || input.purpose.utf8.count > 256 {
                add("read-only-input", input.id, "Declare a normalized path and bounded purpose for public read-only inputs.")
            }
            if m.volumes.contains(where: { StateManifestSchema.overlaps(input.path, $0.mountPoint) }) || StateManifestSchema.overlaps(input.path, control.directoryPath) {
                add("input-state-overlap", input.id, "A public read-only input must not overlap any zone volume or host control directory.")
            }
        }
        for i in m.readOnlyInputs.indices {
            for j in m.readOnlyInputs.indices where j > i && StateManifestSchema.overlaps(m.readOnlyInputs[i].path, m.readOnlyInputs[j].path) {
                add("input-overlap", "readOnlyInputs", "Read-only input declarations must not overlap or alias lexically.")
            }
        }
    }

    private func budget(_ m: StateManifestDocument, report: inout ManifestValidationReport) {
        for container in m.containers {
            var reserves: UInt64? = 0, quotas: UInt64? = 0
            let volumes = m.volumes.filter { $0.containerID == container.id }
            for volume in volumes {
                if let value = reserves {
                    let sum = value.addingReportingOverflow(volume.quota.reserveBytes)
                    reserves = sum.overflow ? nil : sum.partialValue
                }
                if let limit = volume.quota.limitBytes, let value = quotas {
                    let sum = value.addingReportingOverflow(limit)
                    quotas = sum.overflow ? nil : sum.partialValue
                }
            }
            func add(_ severity: String, _ code: String, _ text: String) {
                report.findings.append(.init(severity: severity, code: code, location: container.id, explanation: text))
            }
            if reserves == nil || quotas == nil { add("error", "budget-overflow", "Reserve/quota sum exceeds UInt64; no truncated total is used.") }
            if let cap = container.planningBudgetBytes {
                if let reserves, reserves > cap { add("error", "reserves-exceed-budget", "Declared reservations exceed this container's planning budget.") }
                if let quotas, quotas > cap { add("warning", "quotas-oversubscribed", "Finite quota limits exceed the planning budget. APFS quotas are ceilings, not reserved capacity or guaranteed available bytes.") }
            } else { add("warning", "container-budget-unresolved", "Container planning budget is unknown; actual capacity, existing volumes, snapshots and reserve admission are unobserved.") }
            report.containerBudgets.append(.init(containerID: container.id, planningBudgetBytes: container.planningBudgetBytes,
                declaredReserveSum: reserves, declaredFiniteQuotaSum: quotas,
                hasUnboundedOrUnresolvedVolume: volumes.contains { $0.quota.mode != "limited" }))
        }
    }
}
