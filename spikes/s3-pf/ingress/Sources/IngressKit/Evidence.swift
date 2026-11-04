import Foundation

public enum IPFamily: String, Codable, CaseIterable, Sendable { case ipv4, ipv6 }
public enum BindMode: String, Codable, CaseIterable, Sendable { case loopback, wildcard }
public enum Route: String, Codable, Sendable { case hostToZone, lanToZone, otherZoneToZone, sameZone, zoneToHost, zoneToOtherZone, squatHostPort }
public struct Scenario: Codable, Equatable, Sendable {
    public var id: String
    public var caseID: String
    public var family: IPFamily
    public var bind: BindMode
    public var route: Route
    public var expected: String
    public var status: String = "planned"
    public var executableHere: Bool = false
    public static let all: [Scenario] = IPFamily.allCases.flatMap { family in
        BindMode.allCases.flatMap { bind in
            [("NET-10", Route.hostToZone), ("NET-10", .lanToZone), ("NET-10", .otherZoneToZone),
             ("NET-11", .squatHostPort), ("NET-12", .sameZone), ("NET-12", .zoneToHost), ("NET-12", .zoneToOtherZone)].map { caseID, route in
                Scenario(id: "\(caseID).\(family.rawValue).\(bind.rawValue).\(route.rawValue)", caseID: caseID,
                    family: family, bind: bind, route: route,
                    expected: route == .sameZone ? "authenticatedRoundtrip" : route == .squatHostPort ? "reservedHostPortCannotBeAcquired" : "zeroForbiddenContacts")
            }
        }
    }
}
public enum EvidenceOrigin: String, Codable, Sendable { case planned, mock, measured }
public enum Actor: String, Codable, Sendable { case initiator, listener, oracle }
public struct Participant: Codable, Sendable {
    public var actor: Actor
    public var instanceID: UUID
    public var pid: Int32
    public var machine: String // only "target" or "lan"
    public var expected: Identity?
    public var observed: Identity?
    public var signature: SignatureReport?
    static let shape: Shape = .object(["actor": .scalar, "instanceID": .scalar, "pid": .scalar, "machine": .scalar,
        "expected": Identity.shape, "observed": Identity.shape, "signature": SignatureReport.shape])
}
public enum EventKind: String, Codable, Sendable {
    case listenerStarted, listenerStopped, attempt, connected, accepted, payload, handshake, closed
    case captureStarted, captureStopped, packetContact
    case bindDenied, bindAcquired, hostReservationHeld, hostReclaimed
}
public enum Stage: String, Codable, Sendable { case before, test, drain, after }
public struct EvidenceEvent: Codable, Sendable {
    public var timeMs: Int
    public var stage: Stage
    public var actor: Actor
    public var instanceID: UUID
    public var kind: EventKind
    public var runID: UUID
    public var flowID: UUID
    public var value: Int
    static let shape: Shape = .object(["timeMs": .scalar, "stage": .scalar, "actor": .scalar, "instanceID": .scalar,
        "kind": .scalar, "runID": .scalar, "flowID": .scalar, "value": .scalar])
}
public struct ObservationWindow: Codable, Sendable {
    public var testStartMs: Int
    public var testEndMs: Int
    public var drainEndMs: Int
    public var retryUpperBoundMs: Int?
    public var roundTripUpperBoundMs: Int?
    public var captureDrops: Int?
    public var captureGapsMs: Int?
    public var clockUncertaintyMs: Int?
    static let shape: Shape = .object(["testStartMs": .scalar, "testEndMs": .scalar, "drainEndMs": .scalar,
        "retryUpperBoundMs": .scalar, "roundTripUpperBoundMs": .scalar, "captureDrops": .scalar,
        "captureGapsMs": .scalar, "clockUncertaintyMs": .scalar])
}
public struct CellEvidence: Codable, Sendable {
    public var scenarioID: String
    public var origin: EvidenceOrigin
    public var portBasis: String // fixedHostReservation or ephemeralFixture
    public var participants: [Participant]
    public var window: ObservationWindow?
    public var events: [EvidenceEvent]
    static let shape: Shape = .object(["scenarioID": .scalar, "origin": .scalar, "portBasis": .scalar,
        "participants": .array(Participant.shape), "window": ObservationWindow.shape, "events": .array(EvidenceEvent.shape)])
}
public struct RoleMap: Codable, Sendable {
    public var host: Identity
    public var zone: Identity
    public var otherZone: Identity
    public var lan: Identity?
    static let shape: Shape = .object(["host": Identity.shape, "zone": Identity.shape, "otherZone": Identity.shape, "lan": Identity.shape])
}
public struct EvidenceInput: Codable, Sendable {
    public var schemaVersion: Int
    public var runID: UUID
    public var cells: [CellEvidence]
    public var roles: RoleMap?
    static let shape: Shape = .object(["schemaVersion": .scalar, "runID": .scalar, "cells": .array(CellEvidence.shape), "roles": RoleMap.shape])
    public static func decode(_ data: Data) throws -> EvidenceInput {
        let value = try strictDecode(Self.self, data: data, shape: shape)
        try value.validate(); return value
    }
    public func validate() throws {
        guard schemaVersion == 1, cells.count <= Scenario.all.count,
              Set(cells.map(\.scenarioID)).count == cells.count else { throw IngressError("invalid evidence schema/duplicate cells") }
        if let roles {
            for identity in [roles.host, roles.zone, roles.otherZone] + [roles.lan].compactMap({ $0 }) { try identity.validate() }
            guard Set([roles.host.effectiveUID, roles.zone.effectiveUID, roles.otherZone.effectiveUID]).count == 3,
                  Set([roles.host.auditSessionID, roles.zone.auditSessionID, roles.otherZone.auditSessionID]).count == 3 else { throw IngressError("host/zone role identities overlap") }
        }
        for cell in cells {
            guard Scenario.all.contains(where: { $0.id == cell.scenarioID }),
                  ["fixedHostReservation", "ephemeralFixture"].contains(cell.portBasis), cell.participants.count <= 3,
                  Set(cell.participants.map(\.actor)).count == cell.participants.count,
                  Set(cell.participants.map(\.instanceID)).count == cell.participants.count,
                  cell.events.count <= 256 else { throw IngressError("invalid cell/participants/bounds") }
            for participant in cell.participants {
                guard participant.pid > 0, ["target", "lan"].contains(participant.machine) else { throw IngressError("invalid participant") }
                try participant.expected?.validate(); try participant.observed?.validate()
            }
            if let w = cell.window {
                guard w.testStartMs > 0, w.testStartMs < w.testEndMs, w.testEndMs < w.drainEndMs, w.drainEndMs <= 3_600_000 else { throw IngressError("invalid observation window") }
                for n in [w.retryUpperBoundMs, w.roundTripUpperBoundMs, w.captureDrops, w.captureGapsMs, w.clockUncertaintyMs].compactMap({ $0 }) {
                    guard (0...3_600_000).contains(n) else { throw IngressError("invalid observation count") }
                }
            }
            var previous = -1
            var flowStages: [UUID: Stage] = [:]
            let actorKinds: [Actor: Set<EventKind>] = [
                .initiator: [.attempt, .connected, .handshake, .closed, .bindDenied, .bindAcquired],
                .listener: [.listenerStarted, .listenerStopped, .accepted, .payload, .handshake, .closed, .hostReservationHeld, .hostReclaimed],
                .oracle: [.captureStarted, .captureStopped, .packetContact]]
            for event in cell.events {
                guard event.timeMs >= previous, (0...3_600_000).contains(event.timeMs), (0...1_048_576).contains(event.value),
                      event.runID == runID, cell.participants.contains(where: { $0.actor == event.actor && $0.instanceID == event.instanceID })
                else { throw IngressError("invalid event ordering/run/actor/value") }
                guard actorKinds[event.actor]!.contains(event.kind) else { throw IngressError("event kind belongs to another actor") }
                if let previousStage = flowStages[event.flowID], previousStage != event.stage,
                   !(previousStage == .test && event.stage == .drain) { throw IngressError("flow ID reused across unrelated stages") }
                flowStages[event.flowID] = event.stage
                previous = event.timeMs
                if let w = cell.window {
                    let correctStage: Bool = switch event.stage {
                    case .before: event.timeMs < w.testStartMs
                    case .test: event.timeMs >= w.testStartMs && event.timeMs <= w.testEndMs
                    case .drain: event.timeMs > w.testEndMs && event.timeMs <= w.drainEndMs
                    case .after: event.timeMs > w.drainEndMs
                    }
                    guard correctStage else { throw IngressError("event outside declared stage") }
                }
            }
        }
    }
}
public struct CellResult: Codable, Sendable {
    public var scenario: Scenario
    public var origin: EvidenceOrigin
    public var classification: String
    public var problems: [String]
    public var forbiddenContactsObserved: Int
    public var payloadBytesObserved: Int
}
public struct MatrixReport: Codable, Sendable {
    public var schemaVersion = 1
    public var scope = "WP1.C3 independent preparation; no gate adjudication"
    public var gate = "S3b unverified"
    public var provenanceWarning = "Input records are claims, not cryptographic attestation. Independent review must authenticate raw evidence, identities, clocks, capture topology and policy mechanism. No result here is a gate pass."
    public var cells: [CellResult]
}

public enum Adjudicator {
    public static func evaluate(_ input: EvidenceInput) throws -> MatrixReport {
        try input.validate()
        return MatrixReport(cells: Scenario.all.map { scenario in
            guard let cell = input.cells.first(where: { $0.scenarioID == scenario.id }) else {
                return .init(scenario: scenario, origin: .planned, classification: "notMeasured", problems: ["missing cell evidence"], forbiddenContactsObserved: 0, payloadBytesObserved: 0)
            }
            return evaluate(cell, scenario: scenario, roles: input.roles)
        })
    }
    private static func evaluate(_ cell: CellEvidence, scenario: Scenario, roles: RoleMap?) -> CellResult {
        var problems: [String] = []
        var result = CellResult(scenario: scenario, origin: cell.origin, classification: "incomplete", problems: [], forbiddenContactsObserved: 0, payloadBytesObserved: 0)
        if cell.origin == .planned { result.classification = "notMeasured"; result.problems = ["planned input is not an observation"]; return result }
        if cell.origin == .mock { problems.append("mock does not prove real ingress isolation") }
        let byActor = Dictionary(uniqueKeysWithValues: cell.participants.map { ($0.actor, $0) })
        var identityValid = true
        for actor in [Actor.initiator, .listener, .oracle] {
            guard let p = byActor[actor], let expected = p.expected, let observed = p.observed else {
                problems.append("missing credentials/session for \(actor.rawValue)"); identityValid = false; continue
            }
            if expected != observed { problems.append("wrong credentials/session for \(actor.rawValue)"); identityValid = false }
            if p.signature?.permitsLive != true { problems.append("missing/invalid signing prerequisite for \(actor.rawValue)"); identityValid = false }
        }
        if let roles {
            let pair: (Identity?, Identity) = switch scenario.route {
            case .hostToZone: (roles.host, roles.zone)
            case .lanToZone: (roles.lan, roles.zone)
            case .otherZoneToZone: (roles.otherZone, roles.zone)
            case .sameZone: (roles.zone, roles.zone)
            case .zoneToHost, .squatHostPort: (roles.zone, roles.host)
            case .zoneToOtherZone: (roles.zone, roles.otherZone)
            }
            if pair.0 == nil || byActor[.initiator]?.expected != pair.0 || byActor[.listener]?.expected != pair.1 || byActor[.oracle]?.expected != roles.host {
                problems.append("participants do not match preregistered route roles"); identityValid = false
            }
        } else { problems.append("missing preregistered host/zone identity role map"); identityValid = false }
        // Standalone matrix declarations do not carry raw endpoint bindings. The offline link report
        // checks available producer facts separately and never upgrades this classifier to a gate pass.
        problems.append("endpoint tuple and packet-source association require the separate offline link report and external C1/L4 review; a scenario ID alone is insufficient")
        if let initiator = byActor[.initiator], let listener = byActor[.listener], let oracle = byActor[.oracle] {
            if oracle.machine != "target" || oracle.pid == listener.pid || oracle.pid == initiator.pid {
                problems.append("oracle is not a separate target-side process")
            }
            if initiator.pid == listener.pid && initiator.machine == listener.machine { problems.append("same-process transport is not a zone proof") }
            if let source = initiator.observed, let target = listener.observed {
                switch scenario.route {
                case .sameZone:
                    if source.effectiveUID != target.effectiveUID || source.auditSessionID != target.auditSessionID || initiator.machine != "target" || listener.machine != "target" {
                        problems.append("same-zone participants do not share expected UID/session on target")
                    }
                case .lanToZone:
                    if initiator.machine != "lan" || listener.machine != "target" { problems.append("LAN source is not on the independent LAN machine") }
                default:
                    if source.effectiveUID == target.effectiveUID || source.auditSessionID == target.auditSessionID || initiator.machine != "target" || listener.machine != "target" {
                        problems.append("cross-zone/host participants lack distinct UID and audit session")
                    }
                }
            }
        }
        let events = cell.events
        func matching(_ kind: EventKind, _ actor: Actor, _ stage: Stage? = nil) -> [EvidenceEvent] {
            events.filter { $0.kind == kind && $0.actor == actor && (stage == nil || $0.stage == stage) }
        }
        func roundtrip(_ stage: Stage) -> Bool {
            let attempts = matching(.attempt, .initiator, stage)
            return attempts.contains { attempt in
                let flow = events.filter { $0.flowID == attempt.flowID && $0.stage == stage }
                let sequence: [(EventKind, Actor)] = [(.attempt, .initiator), (.connected, .initiator), (.accepted, .listener), (.handshake, .listener), (.handshake, .initiator), (.closed, .listener)]
                var previous = -1
                for (kind, actor) in sequence {
                    let found = flow.filter { $0.kind == kind && $0.actor == actor }
                    guard found.count == 1, let event = found.first, event.timeMs >= previous else { return false }
                    previous = event.timeMs
                }
                let packet = flow.filter { $0.kind == .packetContact && $0.actor == .oracle }
                return !packet.isEmpty && packet.allSatisfy { $0.timeMs >= attempt.timeMs && $0.timeMs <= previous }
            }
        }
        for stage in [Stage.before, .after] where !roundtrip(stage) { problems.append("missing expected counterpart/nonce handshake positive control \(stage.rawValue)") }
        if matching(.attempt, .initiator, .test).isEmpty { problems.append("no test attempt") }
        if matching(.listenerStarted, .listener, .before).count != 1 || matching(.listenerStopped, .listener, .after).count != 1 {
            problems.append("listener lifecycle does not span controls/test/drain")
        }
        if let w = cell.window {
            let starts = matching(.captureStarted, .oracle, .before)
            let ends = matching(.captureStopped, .oracle, .after)
            if starts.count != 1 || ends.count != 1 || starts.first!.timeMs > (events.first?.timeMs ?? 0) || ends.first!.timeMs < (events.last?.timeMs ?? 0) {
                problems.append("independent capture does not span all controls/test/drain")
            }
            if w.captureDrops != 0 || w.captureGapsMs != 0 { problems.append("capture loss/gaps unknown or nonzero") }
            if let retry = w.retryUpperBoundMs, let rtt = w.roundTripUpperBoundMs, let uncertainty = w.clockUncertaintyMs {
                if w.drainEndMs - w.testEndMs <= retry + 2 * rtt + 2 * uncertainty { problems.append("drain/time coverage too short") }
            } else { problems.append("missing retry/RTT/clock bounds") }
        } else { problems.append("missing observation/time coverage") }
        // A complete TCP accept, a packet contact or a connect is a contact even with zero payload.
        let during = events.filter { $0.stage == .test || $0.stage == .drain }
        let contactKinds: Set<EventKind> = [.connected, .accepted, .handshake, .packetContact, .payload]
        let contacts = during.filter { contactKinds.contains($0.kind) }
        result.forbiddenContactsObserved = scenario.route == .sameZone || scenario.route == .squatHostPort ? 0 : Set(contacts.map(\.flowID)).count
        result.payloadBytesObserved = during.filter { $0.kind == .payload && $0.actor == .listener }.reduce(0) { $0 + $1.value }
        var violation = result.forbiddenContactsObserved > 0
        if scenario.route == .sameZone && !roundtrip(.test) { problems.append("same-zone counterpart/handshake missing") }
        if scenario.route == .squatHostPort {
            if cell.portBasis != "fixedHostReservation" { problems.append("ephemeral collision fixture does not test fixed host-port squatting") }
            if matching(.hostReservationHeld, .listener, .before).isEmpty || matching(.hostReclaimed, .listener, .after).isEmpty {
                problems.append("host port reservation/reclaim evidence missing")
            }
            if during.contains(where: { $0.kind == .bindAcquired && $0.actor == .initiator }) { violation = true }
            if matching(.bindDenied, .initiator, .test).isEmpty { problems.append("no explicit denied bind observation") }
        }
        // Preserve observed findings even if capture is partial. Wrong credentials invalidate attribution.
        if !identityValid { result.classification = "invalidMeasurement" }
        else if cell.origin == .mock { result.classification = violation ? "mockFinding" : "mockOnly" }
        else if violation { result.classification = "observedViolationNeedsReview" }
        else if problems.isEmpty { result.classification = "consistentEvidenceNeedsReview" }
        result.problems = problems
        return result
    }
}
