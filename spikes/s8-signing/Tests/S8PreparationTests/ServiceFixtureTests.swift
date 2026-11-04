import Darwin
import Foundation
import Testing
import SanjboxProbeKit
@testable import S8Preparation

@Test func threeServicesHaveDistinctFixedExecutablesAndIdentifiers() {
    #expect(Set(FixtureService.allCases.map(\.executable)).count == 3)
    #expect(Set(FixtureService.allCases.map(\.identifier)).count == 3)
    for service in [FixtureService.agent, .daemon] {
        #expect(service.launchPlist["BundleProgram"] as? String == "Contents/MacOS/" + service.executable)
        #expect(Set(service.launchPlist.keys) == ["Label", "BundleProgram", "RunAtLoad", "ProcessType"])
    }
}

@Test func dryRunCannotAuthorizeAnActualDaemonMutation() {
    for action in [FixtureAction.register, .unregister] {
        #expect(FixtureActionPolicy.refusal(service: .daemon, action: action, apply: false, identityIssues: [], adHoc: true) == nil)
        #expect(FixtureActionPolicy.refusal(service: .daemon, action: action, apply: true, identityIssues: [], adHoc: false) != nil)
    }
}

@Test func adHocMutationAndWrongSessionAreRefused() {
    for service in FixtureService.allCases {
        #expect(FixtureActionPolicy.refusal(service: service, action: .register, apply: true, identityIssues: [], adHoc: true) != nil)
        #expect(FixtureActionPolicy.refusal(service: service, action: .status, apply: false, identityIssues: ["auditSessionID"], adHoc: false) != nil)
    }
    #expect(FixtureActionPolicy.refusal(service: .agent, action: .register, apply: true, identityIssues: [], adHoc: false) == nil)
}

@Test func unknownAndPreviousUISessionCannotUnregister() {
    for status in 0...3 {
        let lifecycle = UserFixtureLifecycle()
        #expect(throws: (any Error).self) { try lifecycle.authorize(.agent, .unregister, status: status) }
    }
}

@Test func successfulOwnRegistrationAllowsOnlyUnchangedServiceCleanup() throws {
    var lifecycle = UserFixtureLifecycle()
    try lifecycle.begin(.agent, .register, status: 0)
    lifecycle.finish(.agent, .register, status: 1, succeeded: true)
    #expect(throws: (any Error).self) { try lifecycle.authorize(.loginItem, .unregister, status: 1) }
    #expect(throws: (any Error).self) { try lifecycle.authorize(.agent, .unregister, status: 2) }
    try lifecycle.begin(.agent, .unregister, status: 1)
    lifecycle.finish(.agent, .unregister, status: 0, succeeded: true)
    #expect(throws: (any Error).self) { try lifecycle.authorize(.agent, .unregister, status: 1) }
}

@Test func pendingOrFailedActionsCannotClaimOwnership() throws {
    var lifecycle = UserFixtureLifecycle()
    try lifecycle.begin(.agent, .register, status: 0)
    #expect(throws: (any Error).self) { try lifecycle.authorize(.agent, .unregister, status: 1) }
    lifecycle.finish(.agent, .register, status: 1, succeeded: false)
    #expect(throws: (any Error).self) { try lifecycle.authorize(.agent, .unregister, status: 1) }
    lifecycle.finish(.agent, .register, status: 3, succeeded: true)
    #expect(throws: (any Error).self) { try lifecycle.authorize(.agent, .unregister, status: 3) }
}

@Test func existingRegistrationsAndDaemonNeverReachInjectedMutation() throws {
    var calls = 0
    for service in FixtureService.allCases {
        for status in 0...3 {
            var lifecycle = UserFixtureLifecycle()
            do {
                try lifecycle.begin(service, .register, status: status)
                calls += 1 // Synthetic injected adapter; no ServiceManagement import or calls.
                lifecycle.finish(service, .register, status: 1, succeeded: true)
            } catch {}
        }
    }
    #expect(calls == 2) // Only notRegistered LoginItem and LaunchAgent.
}

private func syntheticContext(uid: UInt32 = 600) -> ProbeContext {
    .init(pid: 12, parentPID: 1, realUID: uid, effectiveUID: uid, realGID: 600, effectiveGID: 600,
          userName: "synthetic", kernelGroups: [600], groupMembership: [], audit: nil,
          launchdManager: nil, windowSession: nil)
}

@Test func startupMarkersNeverInferLaunchCauseOrMeasurementValidity() throws {
    let event = try ServiceEvent(runID: UUID().uuidString, service: .daemon, phase: "startup", context: syntheticContext(uid: 0))
    #expect(!event.validMeasurement)
    #expect(event.launchCause.hasPrefix("unknown"))
    let roundtrip = try JSONDecoder().decode(ServiceEvent.self, from: JSONEncoder().encode(event))
    #expect(roundtrip.context == event.context && roundtrip.runID == event.runID)
    #expect(roundtrip.eventID != roundtrip.runID)
}

@Test func malformedRunAndPhaseFailBeforePersistence() {
    #expect(throws: (any Error).self) { try ServiceEvent(runID: "../../outside", service: .agent, phase: "startup", context: syntheticContext()) }
    #expect(throws: (any Error).self) { try ServiceEvent(runID: UUID().uuidString, service: .agent, phase: "reboot-proved", context: syntheticContext()) }
}

@Test func writerRejectsRootForeignAndMissingSessionBeforeCreatingFiles() throws {
    for uid: UInt32 in [0, UInt32.max, geteuid()] {
        let event = try ServiceEvent(runID: UUID().uuidString, service: .agent, phase: "startup", context: syntheticContext(uid: uid))
        #expect(throws: (any Error).self) { try ServiceEventStore.write(event) }
    }
}

private func ownSyntheticContext() throws -> ProbeContext {
    var audit = auditinfo_addr()
    guard getaudit_addr(&audit, Int32(MemoryLayout<auditinfo_addr>.size)) == 0 else { throw S8Error.refused("audit metadata unavailable") }
    var context = syntheticContext(uid: geteuid())
    context.realUID = getuid(); context.realGID = getgid(); context.effectiveGID = getegid()
    context.audit = try JSONDecoder().decode(ProbeContext.AuditSession.self, from: JSONSerialization.data(withJSONObject:
        ["sessionID": audit.ai_asid, "auditUID": audit.ai_auid, "flags": audit.ai_flags]))
    return context
}

@Test func ownEventWriterCreatesUniqueBoundedPrivateRecords() throws {
    let event = try ServiceEvent(runID: UUID().uuidString, service: .agent, phase: "status", context: ownSyntheticContext())
    let first = try ServiceEventStore.write(event)
    let second = try ServiceEventStore.write(event)
    defer {
        for root in [first, second] {
            let fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if fd >= 0 {
                unlinkat(fd, "event.json", 0); unlinkat(fd, "manifest.json", 0); close(fd); rmdir(root)
            }
        }
    }
    #expect(first != second)
    for root in [first, second] {
        var rs = stat(); #expect(lstat(root, &rs) == 0)
        #expect(rs.st_uid == geteuid() && rs.st_mode & 0o7777 == 0o700)
        let data = try readOwnedFile(root + "/event.json", maximum: 16_384)
        let manifest = try #require(JSONSerialization.jsonObject(with: readOwnedFile(root + "/manifest.json", maximum: 4096)) as? [String: Any])
        #expect(manifest["eventSHA256"] as? String == sha256(data))
        #expect(manifest["runID"] as? String == event.runID)
        #expect((manifest["rootInode"] as? NSNumber)?.uint64Value == rs.st_ino)
        #expect((manifest["session"] as? NSNumber)?.int32Value == event.context.audit?.sessionID)
    }
}

@Test func ownCredentialsWithWrongAuditSessionCannotWriteEvent() throws {
    var context = try ownSyntheticContext()
    context.audit?.sessionID += 1
    let event = try ServiceEvent(runID: UUID().uuidString, service: .agent, phase: "status", context: context)
    #expect(throws: (any Error).self) { try ServiceEventStore.write(event) }
}

@Test func unpairedOrFailedCompletionCannotCreateCleanupOwnership() {
    var lifecycle = UserFixtureLifecycle()
    lifecycle.finish(.agent, .register, status: 1, succeeded: true)
    #expect(throws: (any Error).self) { try lifecycle.authorize(.agent, .unregister, status: 1) }
}

@Test func mutatedRunIDCannotReachEventPersistence() throws {
    var event = try ServiceEvent(runID: UUID().uuidString, service: .agent, phase: "status", context: ownSyntheticContext())
    event.runID = "../outside"
    #expect(throws: (any Error).self) { try ServiceEventStore.write(event) }
}
