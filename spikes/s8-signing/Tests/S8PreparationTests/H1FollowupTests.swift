import Foundation
import SanjboxContracts
import Testing
@testable import S8Preparation

@Test func h1FuzzerCoversEveryPublicMessageAndBothBrokerAdmissions() throws {
    let report = try H1Fuzzer.run(iterations: 1)
    #expect(report.succeeded)
    #expect(report.positiveControls == 84)
    #expect(report.coveredControls.count == 42)
    for kind in HelperMessageKind.allCases {
        #expect(report.coveredControls.contains(kind.rawValue))
        #expect(report.coveredControls.contains("reply-success:" + kind.rawValue))
        #expect(report.coveredControls.contains("reply-failure:" + kind.rawValue))
    }
    for kind in BrokerMessageKind.allCases {
        #expect(report.coveredControls.contains(kind.rawValue))
        #expect(report.coveredControls.contains("envelope:" + kind.rawValue))
    }
    #expect(report.negativeCases == report.rejectionCodes.values.reduce(0, +))
    #expect(Set(H1Fuzzer.mutationNames).isSubset(of: Set(report.coveredMutations)))
    #expect(report.coveredMutations.contains("reply-zone-correlation"))
    #expect(report.coveredMutations.contains("delivery-dimensions"))
}

@Test func h1FuzzerIsDeterministicAndBoundedAtTenThousand() throws {
    let a = try H1Fuzzer.run(iterations: 10_000, seed: 21304)
    let b = try H1Fuzzer.run(iterations: 10_000, seed: 21304)
    #expect(a.succeeded && b.succeeded)
    #expect(a.corpusSHA256 == b.corpusSHA256)
    #expect(a.rejectionCodes == b.rejectionCodes)
    #expect(a.negativeCases > 10_500)
    let changed = try H1Fuzzer.run(iterations: 1, seed: 21305)
    #expect(changed.corpusSHA256 != a.corpusSHA256)
    for count in [0, -1, 10_001] {
        #expect(throws: (any Error).self) { try H1Fuzzer.run(iterations: count) }
    }
    #expect(throws: (any Error).self) { try H1Fuzzer.run(iterations: 1, seed: 0) }
}

@Test func h1FuzzerOracleDetectsAcceptAllRejectAllAndNonContractErrors() throws {
    let accepts = try H1Fuzzer.run(iterations: 1, seed: 21304, evaluate: { _ in })
    #expect(!accepts.succeeded && accepts.unexpectedAccepts == accepts.negativeCases)
    #expect(accepts.failures.count == 16)
    let rejects = try H1Fuzzer.run(iterations: 1, seed: 21304, evaluate: { _ in throw ContractError("invalid-value", "injected") })
    #expect(!rejects.succeeded && rejects.positiveControls == 0)
    let broken = try H1Fuzzer.run(iterations: 1, seed: 21304, evaluate: { _ in throw S8Error.refused("injected") })
    #expect(!broken.succeeded && broken.rejectionCodes.isEmpty)
}

private func host() -> SyntheticServicePeer {
    .init(role: .hostController, uid: 501, auditUID: 501, auditSession: 31, processID: 123,
          processVersion: 7, codeHash: String(repeating: "a", count: 64), signatureMatches: true)
}

@Test func daemonSeamOnlyAdmitsExactHostAndOneUseApprovedOperation() throws {
    let h = host(); var boundary = try SyntheticDaemonBoundary(trustedHost: h)
    let id = try boundary.approveForSimulation(.register, host: h)
    try boundary.simulateDaemonMutation(.register, peer: h, approvalID: id)
    #expect(boundary.simulatedEffects == 1)
    #expect(throws: (any Error).self) { try boundary.simulateDaemonMutation(.register, peer: h, approvalID: id) }
    let wrongAction = try boundary.approveForSimulation(.register, host: h)
    #expect(throws: (any Error).self) { try boundary.simulateDaemonMutation(.unregister, peer: h, approvalID: wrongAction) }
    #expect(throws: (any Error).self) { try boundary.simulateDaemonMutation(.register, peer: h, approvalID: wrongAction) }
    #expect(boundary.simulatedEffects == 1)
    let revoke = try boundary.approveForSimulation(.unregister, host: h)
    boundary.revoke()
    #expect(throws: (any Error).self) { try boundary.simulateDaemonMutation(.unregister, peer: h, approvalID: revoke) }
}

@Test func daemonSeamRejectsEachIdentityDimensionBeforeAnyEffect() throws {
    let h = host()
    for variant in 0..<9 {
        var peer = h
        switch variant {
        case 0: peer.role = .area
        case 1: peer.uid = 601
        case 2: peer.auditUID = 601
        case 3: peer.auditSession = 41
        case 4: peer.processID = 124
        case 5: peer.processVersion = 8
        case 6: peer.codeHash = String(repeating: "b", count: 64)
        case 7: peer.signatureMatches = false
        default: peer.uid = 0
        }
        var b = try SyntheticDaemonBoundary(trustedHost: h)
        let id = try b.approveForSimulation(.register, host: h)
        #expect(throws: (any Error).self) { try b.approveForSimulation(.register, host: peer) }
        #expect(throws: (any Error).self) { try b.simulateDaemonMutation(.register, peer: peer, approvalID: id) }
        #expect(throws: (any Error).self) { try b.inspectHelperRequest(HelperMessage.capabilities.encoded(), peer: peer) }
        #expect(b.simulatedEffects == 0)
    }
    let b = try SyntheticDaemonBoundary(trustedHost: h)
    for input in try H1Fuzzer.controls() where input.receiver == .helper {
        #expect(try b.inspectHelperRequest(input.wire, peer: h).rawValue == input.control)
    }
    #expect(throws: (any Error).self) { try b.inspectHelperRequest(Data("{}".utf8), peer: h) }
}

@Test func daemonSeamRequiresValidBaselineAndBoundsApprovals() throws {
    var h = host(); h.signatureMatches = false
    #expect(throws: (any Error).self) { try SyntheticDaemonBoundary(trustedHost: h) }
    h = host(); h.role = .area
    #expect(throws: (any Error).self) { try SyntheticDaemonBoundary(trustedHost: h) }
    h = host(); var b = try SyntheticDaemonBoundary(trustedHost: h)
    for _ in 0..<32 { _ = try b.approveForSimulation(.register, host: h) }
    #expect(throws: (any Error).self) { try b.approveForSimulation(.register, host: h) }
    #expect(throws: (any Error).self) { try b.approveForSimulation(.status, host: h) }
}

private func binding(_ service: FixtureService = .agent) -> SyntheticRegistrationBinding {
    .init(runID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, service: service,
          ownerUID: 501, signedInventorySHA256: String(repeating: "a", count: 64))
}

private func registered(_ service: FixtureService = .agent) throws -> SyntheticRegistrationWorkflow {
    var w = try SyntheticRegistrationWorkflow(binding: binding(service))
    try w.beginRegistration(status: 0, boot: "boot-1", session: 31)
    try w.registrationResult(succeeded: true, status: 1)
    return w
}

@Test func restartRecoveryDryRunCompletesOnlyAfterManualReviewAndCleanupOracle() throws {
    for service in FixtureService.allCases {
        var w = try registered(service)
        w.restart(); #expect(w.phase == .recoveryReview)
        try w.reviewRecovery(current: binding(service), status: 1, boot: "boot-2", session: 41, userConfirmedExclusiveSlot: true)
        try w.beginUnregister(current: binding(service), status: 1, boot: "boot-2", session: 41)
        try w.unregisterResult(succeeded: true, status: 0)
        #expect(w.phase == .verifyStopped)
        try w.confirmStopped(ownHelpersRemaining: 0, relaunchObserved: false, lifecycleCheckComplete: true)
        #expect(w.phase == .cleaned)
        w.restart(); #expect(w.phase == .cleaned)
    }
}

@Test func restartDoesNotAdoptReceiptsStatusOrUncertainEffects() throws {
    var w = try registered(); w.restart()
    #expect(throws: (any Error).self) { try w.beginUnregister(current: binding(), status: 1, boot: "boot-1", session: 31) }
    #expect(w.phase == .conflict)
    for variant in 0..<6 {
        w = try registered(); w.restart(); var current = binding()
        if variant == 0 { current.runID = UUID() }
        if variant == 1 { current.ownerUID = 601 }
        if variant == 2 { current.service = .daemon }
        if variant == 3 { current.signedInventorySHA256 = String(repeating: "b", count: 64) }
        #expect(throws: (any Error).self) {
            try w.reviewRecovery(current: current, status: variant == 4 ? 2 : 1, boot: "boot-2", session: 41,
                                 userConfirmedExclusiveSlot: variant != 5)
        }
        #expect(w.phase == .conflict)
    }
    w = try SyntheticRegistrationWorkflow(binding: binding())
    try w.beginRegistration(status: 0, boot: "boot-1", session: 31)
    w.restart(); #expect(w.phase == .conflict)
}

@Test func cleanupDryRunFailsClosedOnContextStatusAndProcessEvidence() throws {
    for variant in 0..<7 {
        var w = try registered()
        if variant == 0 {
            #expect(throws: (any Error).self) { try w.beginUnregister(current: binding(), status: 1, boot: "boot-2", session: 31) }
        } else if variant == 1 {
            #expect(throws: (any Error).self) { try w.beginUnregister(current: binding(), status: 1, boot: "boot-1", session: 32) }
        } else {
            try w.beginUnregister(current: binding(), status: 1, boot: "boot-1", session: 31)
            if variant == 2 {
                #expect(throws: (any Error).self) { try w.unregisterResult(succeeded: false, status: 0) }
            } else {
                try w.unregisterResult(succeeded: true, status: 0)
                #expect(throws: (any Error).self) {
                    try w.confirmStopped(ownHelpersRemaining: variant == 3 ? 1 : 0,
                        relaunchObserved: variant == 4 ? true : variant == 5 ? nil : false,
                        lifecycleCheckComplete: variant != 6)
                }
            }
        }
        #expect(w.phase == .conflict)
    }
}

@Test func serviceWorkflowPlansAllSixCasesWithoutNativeAuthorization() throws {
    let plans = try SyntheticServiceWorkflows.plans()
    #expect(plans.count == 6)
    for plan in plans {
        #expect(!plan.nativeRegistrationAllowed && !plan.nativeArtifactCleanupAllowed)
        #expect(plan.phases == ["pristine", "registerIntent", "registered", "recoveryReview", "registered",
                               "unregisterIntent", "verifyStopped", "cleaned"])
    }
}

@Test func h1AdmissionAPIsAcceptExactLimitsAndRejectOneByteOver() throws {
    let controls = try H1Fuzzer.controls()
    for name in ["helper.capabilities", "reply-success:helper.capabilities", "broker.frame", "envelope:broker.frame"] {
        let original = controls.first { $0.control == name }!
        let isBroker = original.receiver == .broker || original.receiver == .brokerEnvelope
        let maxWire = isBroker ? BrokerContract.maxBytes : XPCEnvelope.maxBytes
        let maxBody = isBroker ? BrokerContract.maxBodyBytes : XPCEnvelope.maxBodyBytes
        var input = original
        input.wire.append(Data(repeating: 0x20, count: maxWire - input.wire.count))
        try input.validate()
        input.wire.append(0x20)
        #expect(throws: (any Error).self) { try input.validate() }
        var header = try JSONSerialization.jsonObject(with: original.wire) as! [String: Any]
        var body = Data(base64Encoded: header["body"] as! String)!
        body.append(Data(repeating: 0x20, count: maxBody - body.count))
        header["body"] = body.base64EncodedString()
        input.wire = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys, .withoutEscapingSlashes])
        try input.validate()
        body.append(0x20); header["body"] = body.base64EncodedString()
        input.wire = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys, .withoutEscapingSlashes])
        #expect(throws: (any Error).self) { try input.validate() }
    }
}
