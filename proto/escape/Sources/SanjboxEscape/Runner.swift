import Darwin
import Foundation
import SanjboxContracts
import SanjboxProbeKit

// Test-only fault injection stays internal; no CLI switch enables a permissive boundary.
enum Fault: Hashable { case foreignReadAllowed, networkBypass, missingStopped, wrongIdentity }

struct IdentityGuard {
    let baseline: ProbeContext
    let expected: ProbeExpectation
    init() {
        let uid = getuid(), euid = geteuid(), gid = getgid(), egid = getegid()
        baseline = ProbeContext.capture()
        expected = ProbeExpectation(effectiveUID: euid, realUID: uid, effectiveGID: egid, realGID: gid,
                                    requiredGroups: baseline.kernelGroups)
    }
    func valid(_ actual: ProbeContext) -> Bool {
        // Require the original non-root, same-user context and resolved audit/bootstrap measurements.
        baseline.realUID > 0 && baseline.realUID == baseline.effectiveUID &&
        baseline.realGID == baseline.effectiveGID && baseline.audit != nil && baseline.launchdManager != nil &&
        expected.mismatches(in: actual).isEmpty && actual.kernelGroups.sorted() == baseline.kernelGroups.sorted() &&
        actual.audit == baseline.audit && actual.launchdManager == baseline.launchdManager &&
        actual.windowSession == baseline.windowSession
    }
    func check() -> Bool { valid(ProbeContext.capture(groupsOfInterest: expected.groupsOfInterest)) }
}

public enum SyntheticRunner {
    public static func run(counterpart: URL) throws -> HarnessReport {
        try run(counterpart: counterpart, faults: [])
    }
    static func run(counterpart: URL, faults: Set<Fault>) throws -> HarnessReport {
        let catalog = try Catalog.load()
        let identity = IdentityGuard() // Before fixtures, child processes or sockets.
        var observations: [String: Observation] = [:]
        guard identity.check(), !faults.contains(.wrongIdentity) else {
            for item in catalog where item.mode == .synthetic {
                observations[item.id] = Observation(identityValid: false, attempted: false, controlValid: false,
                    complete: false, oracleSatisfied: false, detail: "same-user identity/session preflight failed; no probe ran")
            }
            return try HarnessReport(results: catalog.map { Evaluation.evaluate($0, observation: observations[$0.id]) },
                                     counterpart: [], audit: [], cleanupVerified: true)
        }
        let fixture = try OwnedFixture()
        defer { try? fixture.cleanup() }
        var audit: [AuditRecord] = []
        func record(_ action: AuditAction, _ outcome: AuditOutcome, subject: String? = nil) {
            audit.append(AuditRecord(sequence: UInt64(audit.count + 1),
                timestampUTC: Date().formatted(JSONLines.timestampStyle), zoneID: "h6zz", actorUID: geteuid(),
                action: action, outcome: outcome, subjectID: subject,
                detail: "H6 same-user synthetic fixture; no real zone or acceptance evidence"))
        }
        record(.zoneCreated, .allowed)
        var network: [CounterpartEvidence] = []
        for item in catalog where item.mode == .synthetic {
            guard identity.check() else {
                observations[item.id] = Observation(identityValid: false, attempted: false, controlValid: false,
                    complete: false, oracleSatisfied: false, detail: "probe identity/session drift; measurement invalid")
                continue
            }
            do {
                switch item.probe! {
                case .foreignRead, .hardlinkRead, .symlinkRead:
                    observations[item.id] = try treeProbe(item.probe!, fixture: fixture, faults: faults)
                case .startDuringStop: observations[item.id] = try startProbe()
                case .identityReuse: observations[item.id] = try reuseProbe()
                case .invalidMessage: observations[item.id] = try messageProbe()
                case .deniedLoopback:
                    let receiver = try LoopbackCounterpart(executable: counterpart)
                    let canary = try Canary.make(label: "network-deny")
                    let before = try receiver.run(in: fixture.directory("net-before"), role: "NET-02 positive-before", canary: canary, send: true)
                    network.append(before)
                    // Mock gate records a denial and performs no send. Fault injection models a lying gate.
                    record(.gateRequestDenied, .denied, subject: "net-02")
                    let denied = try receiver.run(in: fixture.directory("net-denied"), role: "NET-02 attempted-denied", canary: canary,
                        send: faults.contains(.networkBypass), omitStopped: faults.contains(.missingStopped))
                    network.append(denied)
                    let after = try receiver.run(in: fixture.directory("net-after"), role: "NET-02 positive-after", canary: canary, send: true)
                    network.append(after)
                    observations[item.id] = Observation(controlValid: before.received(canary) && after.received(canary),
                        complete: denied.complete, oracleSatisfied: denied.empty,
                        detail: "mock gate denied; isolated counterpart run checked for all contact, with positive controls before/after")
                case .allowedLoopback:
                    let receiver = try LoopbackCounterpart(executable: counterpart)
                    let canary = try Canary.make(label: "network-allow")
                    let received = try receiver.run(in: fixture.directory("net-allowed"), role: "NET-12 allowed fixture", canary: canary, send: true)
                    network.append(received)
                    observations[item.id] = Observation(controlValid: received.complete, complete: received.complete,
                        oracleSatisfied: received.received(canary), detail: "registered canary and exact bytes observed by separate loopback counterpart")
                }
            } catch {
                // Exceptions never turn missing observations into successful denials.
                observations[item.id] = Observation(attempted: true, controlValid: false, complete: false,
                    oracleSatisfied: false, detail: "probe could not finish: \(error)")
            }
        }
        let cleaned: Bool
        do { try fixture.cleanup(); cleaned = true; record(.zoneCleaned, .allowed) }
        catch { cleaned = false; record(.zoneCleaned, .failed) }
        return try HarnessReport(results: catalog.map { Evaluation.evaluate($0, observation: observations[$0.id]) },
                                 counterpart: network, audit: audit, cleanupVerified: cleaned)
    }
}

private func treeProbe(_ probe: Probe, fixture: OwnedFixture, faults: Set<Fault>) throws -> Observation {
    let directory = try fixture.directory(probe.rawValue)
    let zone = directory.appendingPathComponent("zone")
    let foreign = directory.appendingPathComponent("host-home")
    guard mkdir(zone.path, 0o700) == 0, mkdir(foreign.path, 0o700) == 0 else {
        throw HarnessError.invalid("cannot create tree fixture")
    }
    let own = try Canary.make(label: "zone").written(to: zone)
    let host = try Canary.make(label: "host").written(to: foreign)
    let boundary = TreeBoundary(zone: zone)
    let ownName = URL(fileURLWithPath: own.path!).lastPathComponent
    let positive = try boundary.read(root: "zone", name: ownName) == Data(own.token.utf8)
    let hostControl = try Data(contentsOf: URL(fileURLWithPath: host.path!)) == Data(host.token.utf8)
    let denied: Bool
    switch probe {
    case .foreignRead:
        let result = faults.contains(.foreignReadAllowed) ? try Data(contentsOf: URL(fileURLWithPath: host.path!))
            : try boundary.read(root: "host-home", name: URL(fileURLWithPath: host.path!).lastPathComponent)
        denied = result == nil
    case .hardlinkRead:
        let alias = zone.appendingPathComponent("hardlink")
        guard link(host.path!, alias.path) == 0 else { throw HarnessError.invalid("cannot create owned hardlink control") }
        let linkControl = try Data(contentsOf: alias) == Data(host.token.utf8)
        denied = try linkControl && (boundary.read(root: "zone", name: "hardlink")) == nil
    case .symlinkRead:
        let alias = zone.appendingPathComponent("symlink")
        guard symlink(host.path!, alias.path) == 0 else { throw HarnessError.invalid("cannot create owned symlink control") }
        let linkControl = try Data(contentsOf: alias) == Data(host.token.utf8)
        denied = try linkControl && (boundary.read(root: "zone", name: "symlink")) == nil
    default: throw HarnessError.invalid("not a tree probe")
    }
    return Observation(controlValid: positive && hostControl, oracleSatisfied: denied,
        detail: "own-file and bypass controls read generated canaries; mock boundary must deny the selected foreign/link operation")
}

private func runningModel() throws -> ZoneStateMachine {
    var state = try ZoneStateMachine(zoneID: "h6zz")
    // Design-only numbers, never passed to an OS identity or process operation.
    try state.assignIdentity(uid: 9001, gid: 9001)
    try state.apply(.start); try state.apply(.launched)
    return state
}
private func startProbe() throws -> Observation {
    var state = try runningModel()
    let control = state.state == .running
    try state.apply(.stop)
    var rejected = true
    for _ in 0..<2 {
        let before = state
        do { try state.apply(.start); rejected = false }
        catch let error as ContractError { rejected = rejected && error.code == "forbidden-transition" && state == before }
        if state.state == .stopping { try state.apply(.quiesced) }
    }
    return Observation(controlValid: control, oracleSatisfied: rejected,
                       detail: "H1 rejects start in stopping and stopped without mutating state/identity")
}
private func reuseProbe() throws -> Observation {
    var state = try runningModel()
    let control = state.uid == 9001
    try state.apply(.stop)
    var retained = !state.uidAvailableForReuse && state.uid == 9001
    try state.apply(.quiesced)
    for _ in 0..<2 {
        let before = state
        do { try state.assignIdentity(uid: 9002, gid: 9002); retained = false }
        catch let error as ContractError { retained = retained && error.code == "uid-reuse-before-cleanup" && state == before }
        retained = retained && !state.uidAvailableForReuse && state.uid == 9001
        if state.state == .stopped { try state.apply(.cleanup) }
    }
    try state.apply(.cleaned)
    return Observation(controlValid: control, oracleSatisfied: retained && state.uidAvailableForReuse && state.uid == nil,
                       detail: "H1 reserves design UID until cleaned; no global allocator or OS users tested")
}
private func messageProbe() throws -> Observation {
    let valid = try HelperMessage.startZone(.init(zoneID: "h6zz")).encoded()
    let control = try HelperMessage.decode(valid) == .startZone(.init(zoneID: "h6zz"))
    func envelope(_ kind: String, _ body: String) -> Data {
        Data("{\"version\":1,\"kind\":\"\(kind)\",\"body\":\"\(Data(body.utf8).base64EncodedString())\"}".utf8)
    }
    let helperCases = [Data("not json".utf8), Data(repeating: 32, count: XPCEnvelope.maxBytes + 1),
                       envelope("zone.start", "{\"zoneID\":\"h6zz\",\"force\":true}"),
                       envelope("zone.unknown", "{}"), envelope("zone.start", "{\"zoneID\":\"../x\"}")]
    var rejected = true
    for bytes in helperCases {
        do { _ = try HelperMessage.decode(bytes); rejected = false }
        catch is ContractError {} // A different error is incomplete, not a correct rejection.
    }
    let broker = BrokerMessage.frame(.init(zoneID: "h6zz", streamID: "fixture", sequence: 1, width: 1, height: 1, surfaceAttachmentIndex: 0))
    let brokerControl = try BrokerMessage.decode(broker.encoded()) == broker
    for bytes in [Data("not json".utf8), Data(repeating: 32, count: 4097), envelope("broker.unknown", "{}") ] {
        do { _ = try BrokerMessage.decode(bytes); rejected = false }
        catch is ContractError {}
    }
    return Observation(controlValid: control && brokerControl, oracleSatisfied: rejected,
                       detail: "H1 helper/broker valid controls and 8 invalid wire fixtures; no XPC or Mach rights")
}
