import Foundation

// This is a design document, never a deployment instruction or measured filesystem state.
struct Manifest: Codable {
    var schema: String
    var intent: String
    var phase: String
    var zone: Zone
    var containers: [ContainerPlan]
    var volumes: [VolumePlan]
    var roots: [RootPlan]
    var runtimePolicy: String
    var rollback: RollbackPlan
    var hostControl: HostControlPlan
    var readOnlyInputs: [ReadOnlyInput]
    var outsideWrites: String
    var hostAccess: String
}

struct Zone: Codable {
    var id: String
    var uid: UInt32
    var gid: UInt32
}

struct ContainerPlan: Codable {
    var id: String
    /// Optional declared binding; never looked up or accepted as an observed UUID.
    var declaredUUID: String?
    /// Planning budget for these volumes, not measured capacity/free space of a real container.
    var planningBudgetBytes: UInt64?
}

struct QuotaPlan: Codable {
    /// limited (positive limitBytes), unbounded (no limitBytes), or unresolved (no limitBytes).
    var mode: String
    var limitBytes: UInt64?
    /// Zero explicitly means no reservation, never an unknown measurement.
    var reserveBytes: UInt64
}

struct VolumePlan: Codable {
    var id: String
    var containerID: String
    var declaredUUID: String?
    var mountPoint: String
    var filesystem: String
    var caseSensitive: Bool
    var ownership: String
    var quota: QuotaPlan
}

struct RootPlan: Codable {
    var id: String
    var role: String
    var volumeID: String
    var relativePath: String
    var ownerUID: UInt32
    var rollback: String
    var purpose: String
}

struct RollbackPlan: Codable {
    var unitID: String
    var volumeIDs: [String]
    var strategy: String
    var quiescence: String
    var recoveryRequired: Bool
    var startPolicy: String
}

struct HostControlPlan: Codable {
    var directoryPath: String
    var ownerUID: UInt32
    var directoryMode: String
    var policyFile: String
    var recoveryFile: String
    var rollback: String
}

struct ReadOnlyInput: Codable {
    var id: String
    var path: String
    var purpose: String
}

struct Finding: Codable, Equatable {
    var severity: String
    var code: String
    var location: String
    var explanation: String
}

struct ResolvedRoot: Codable, Equatable {
    var id: String
    var role: String
    var volumeID: String
    var plannedPath: String
    var rollbackUnit: String
}

struct ContainerBudget: Codable {
    var containerID: String
    var planningBudgetBytes: UInt64?
    var declaredReserveSum: UInt64?
    var declaredFiniteQuotaSum: UInt64?
    var hasUnboundedOrUnresolvedVolume: Bool
}

struct ValidationReport: Encodable {
    let schema = "sanjbox.state-manifest.validation.v1"
    var consistentDesign: Bool
    var requiredRolesDeclared: Bool
    let observedTopology = "not-inspected"
    let observedWriteCoverage = "unverified"
    let deploymentReady = false
    let acceptanceStatus = "Neověřeno"
    var findings: [Finding]
    var plannedRoots: [ResolvedRoot]
    var plannedVolumes: [VolumePlan]
    var containerBudgets: [ContainerBudget]
    let verificationRequired = [
        "RB-01: discover and enforce every writable location, including service-mediated and per-UID state outside declared paths; manifest membership is not coverage proof.",
        "RB-02/05: quiesce the entire UID and close file descriptors/mappings before snapshot or restore; application consistency requires separate tests.",
        "RB-03/04: prove home/startup, project, prefix, cache and TMP restoration on synthetic canaries; filesystem snapshot is not a writable restore tree.",
        "RB-06/07/08: implement writable-state reconstruction, host-owned recovery and deny-start after any incomplete switch; do not restore host policy from zone state.",
        "FS-10/11: verify mount identity, ownership, ancestor and symlink/alias boundaries, new mounts and continuous protection; lexical path checks do not inspect these.",
        "S4/S6: observe actual APFS container/volume UUIDs, mountpoints, quota/reserve configuration and available capacity; validate prefix/tool compatibility.",
        "F4/S7: runtime is deferred in MVP; any later runtime storage and external writable state require their own topology and isolation evidence."
    ]
}
