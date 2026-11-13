import Foundation

public struct ManifestFinding: Codable, Equatable, Sendable {
    public var severity: String
    public var code: String
    public var location: String
    public var explanation: String
}

public struct ManifestPlannedRoot: Codable, Equatable, Sendable {
    public var id: String
    public var role: String
    public var volumeID: String
    public var plannedPath: String
    public var rollbackUnit: String
}

public struct ManifestContainerBudget: Codable, Equatable, Sendable {
    public var containerID: String
    public var planningBudgetBytes: UInt64?
    public var declaredReserveSum: UInt64?
    public var declaredFiniteQuotaSum: UInt64?
    public var hasUnboundedOrUnresolvedVolume: Bool
}

public struct ManifestValidationReport: Encodable, Equatable, Sendable {
    public let schema = "sanjbox.state-manifest.validation.v1"
    public var consistentDesign: Bool
    public var requiredRolesDeclared: Bool
    public let observedTopology = "not-inspected"
    public let observedWriteCoverage = "unverified"
    public let deploymentReady = false
    public let acceptanceStatus = "Neověřeno"
    public var findings: [ManifestFinding]
    public var plannedRoots: [ManifestPlannedRoot]
    public var plannedVolumes: [ManifestVolume]
    public var containerBudgets: [ManifestContainerBudget]
    public let verificationRequired = [
        "RB-01: discover and enforce every writable location, including service-mediated and per-UID state outside declared paths; manifest membership is not coverage proof.",
        "RB-02/05: quiesce the entire UID and close file descriptors/mappings before snapshot or restore; application consistency requires separate tests.",
        "RB-03/04: prove home/startup, project, prefix, cache and TMP restoration on synthetic canaries; filesystem snapshot is not a writable restore tree.",
        "RB-06/07/08: implement writable-state reconstruction, host-owned recovery and deny-start after any incomplete switch; do not restore host policy from zone state.",
        "FS-10/11: verify mount identity, ownership, ancestor and symlink/alias boundaries, new mounts and continuous protection; lexical path checks do not inspect these.",
        "S4/S6: observe actual APFS container/volume UUIDs, mountpoints, quota/reserve configuration and available capacity; validate prefix/tool compatibility.",
        "F4/S7: runtime is deferred in MVP; any later runtime storage and external writable state require their own topology and isolation evidence."
    ]
}
