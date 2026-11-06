import CryptoKit
import Foundation
import SanjboxProbeKit
import SanjboxNetworkProvenance

public struct ImportedFinding: Codable, Sendable {
    public var sourceID: String
    public var line: Int
    public var origin: ImportOrigin
    public var kind: String
    public var counterpartFlowID: Int?
    public var packetFlowID: UUID?
    public var bytes: Int?
    public var claimedBindings: [UUID]
    public var hasInvalidOrIncompleteSource: Bool
    public var networkFlowID: UUID? = nil
    public var networkContactID: Int? = nil
    public var payloadDisposition: String? = nil
    public var disposition = "retained raw observation claim; attribution and forbidden-operation decision require external review"
}
public struct TimeProjection: Codable, Sendable {
    public var sourceID: String
    public var line: Int
    public var rawTimestamp: String
    public var clockID: String?
    public var relativeMs: Int?
    public var uncertaintyMs: Int?
    public var basis = "supplied UTC offset/calibration claim, not an independently verified clock"
}
public struct LinkedFlow: Codable, Sendable {
    public var binding: FlowBinding
    public var endpoint: EndpointRegistration?
    public var status: String
    public var origins: [ImportOrigin]
    public var sourceRecords: [RecordReference]
    public var times: [TimeProjection]
    public var checks: [String]
    public var problems: [String]
    public var missingBindings: [String]
}
public struct AdapterReport: Codable, Sendable {
    public var schemaVersion = 1
    public var runID: UUID
    public var runStartUTC: String
    public var inputSHA256: String
    public var matrixDeclaration: EvidenceInput?
    public var gate = "S3b unverified; no gate or COVERAGE status is changed"
    public var externalReviewRequired = true
    public var packetAbsenceProven = false
    public var provenanceWarning = "Sources, bindings, matrix identities/signing flags and imported capture metadata are unauthenticated claims. Computed hashes only fingerprint supplied bytes. A common accept/bytes log cannot prove zero packets. Findings survive invalid or missing sibling evidence."
    public var matrix: MatrixReport
    public var matrixProblems: [String]
    public var sources: [SourceReport]
    public var links: [LinkedFlow]
    public var findings: [ImportedFinding]
}

public enum EvidenceAdapter {
    public static func link(_ data: Data) throws -> AdapterReport {
        let input = try AdapterInput.decode(data)
        var sources = input.sources.map(parseSource).sorted { $0.id < $1.id }
        let instances = sources.compactMap { $0.network?.records.first?.record.instanceID }
        for index in sources.indices {
            if let instance = sources[index].network?.records.first?.record.instanceID,
               instances.filter({ $0 == instance }).count > 1 {
                sources[index].problems.append("network producer instance reused across source IDs; alias/replay ambiguity")
            }
        }
        var matrixInput: EvidenceInput?
        var matrixProblems: [String] = []
        if let raw = input.matrixJSON {
            do {
                let value = try EvidenceInput.decode(Data(raw.utf8))
                if value.runID == input.runID { matrixInput = value }
                else { matrixProblems.append("matrix runID differs from adapter runID; matrix not associated") }
            } catch { matrixProblems.append("matrix strict JSON/schema invalid; raw findings retained") }
        } else { matrixProblems.append("missing matrix evidence") }
        let matrix = try Adjudicator.evaluate(matrixInput ?? EvidenceInput(schemaVersion: 1, runID: input.runID, cells: [], roles: nil))
        if let matrixInput {
            for cell in matrixInput.cells {
                for event in cell.events where [.accepted, .payload, .packetContact, .connected, .bindAcquired].contains(event.kind) {
                    if !input.bindings.contains(where: { $0.scenarioID == cell.scenarioID && $0.flowID == event.flowID }) {
                        matrixProblems.append("\(cell.scenarioID): observed matrix flow \(event.flowID.uuidString.lowercased()) has no raw binding")
                    }
                }
            }
        }
        let links = input.bindings.map { binding in
            linkFlow(binding, input: input, sources: sources, matrix: matrixInput, matrixReport: matrix)
        }.sorted { ($0.binding.scenarioID, $0.binding.flowID.uuidString, $0.binding.stage.rawValue) < ($1.binding.scenarioID, $1.binding.flowID.uuidString, $1.binding.stage.rawValue) }
        var findings: [ImportedFinding] = []
        for source in sources {
            for row in source.counterpart where [.accepted, .closed, .datagram].contains(row.record.kind) {
                let ids = input.bindings.filter { $0.counterpart?.sourceID == source.id && $0.counterpart?.flowID == row.record.flowID }.map(\.flowID)
                findings.append(.init(sourceID: source.id, line: row.line, origin: source.origin, kind: row.record.kind.rawValue,
                    counterpartFlowID: row.record.flowID, packetFlowID: nil, bytes: row.record.bytes,
                    claimedBindings: Array(Set(ids)).sorted { $0.uuidString < $1.uuidString },
                    hasInvalidOrIncompleteSource: !source.problems.isEmpty || source.recordProblems))
            }
            for row in source.network?.records ?? [] where ["accepted", "closed", "datagramContact", "datagram"].contains(row.record.kind) {
                let e = row.record
                let ids = input.bindings.filter { $0.network?.receiverSourceID == source.id && $0.network?.contactID == e.contactID }.map(\.flowID)
                let disposition: String
                if e.repeatedRegisteredPayload == true { disposition = "claimed repeated registered payload; retained contact, not a fresh authenticated peer" }
                else if e.bytes == 0 { disposition = "explicit zero-byte contact" }
                else if ["accepted", "datagramContact"].contains(e.kind) { disposition = "contact before terminal/raw validation; absent ending is unknown, not zero" }
                else if e.rawTruncated == true || e.operationFinished != true { disposition = "partial/truncated/interrupted contact" }
                else if e.payloadClaims == nil { disposition = "malformed/partial payload claim; exact raw checked separately" }
                else if e.matchesRegisteredPayload != true { disposition = "foreign run/flow/challenge payload claim" }
                else { disposition = "claimed registered payload; exact raw checked separately, not peer authentication" }
                findings.append(.init(sourceID: source.id, line: row.line, origin: source.origin, kind: e.kind,
                    counterpartFlowID: nil, packetFlowID: nil, bytes: e.bytes,
                    claimedBindings: Array(Set(ids)).sorted { $0.uuidString < $1.uuidString },
                    hasInvalidOrIncompleteSource: !source.problems.isEmpty || source.recordProblems,
                    networkFlowID: e.flowID, networkContactID: e.contactID, payloadDisposition: disposition))
            }
            for row in source.packets where row.record.kind == .packetContact {
                let ids = input.bindings.filter { $0.capture?.sourceID == source.id && $0.capture?.captureID == row.record.captureID && $0.flowID == row.record.flowID }.map(\.flowID)
                findings.append(.init(sourceID: source.id, line: row.line, origin: source.origin, kind: "packetContact",
                    counterpartFlowID: nil, packetFlowID: row.record.flowID, bytes: nil,
                    claimedBindings: Array(Set(ids)).sorted { $0.uuidString < $1.uuidString },
                    hasInvalidOrIncompleteSource: !source.problems.isEmpty || source.recordProblems))
            }
        }
        return AdapterReport(runID: input.runID, runStartUTC: input.runStartUTC,
            inputSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            matrixDeclaration: matrixInput, matrix: matrix, matrixProblems: Array(Set(matrixProblems)).sorted(),
            sources: sources, links: links, findings: findings.sorted { ($0.sourceID, $0.line) < ($1.sourceID, $1.line) })
    }

    private static func linkFlow(_ binding: FlowBinding, input: AdapterInput, sources: [SourceReport], matrix: EvidenceInput?, matrixReport: MatrixReport) -> LinkedFlow {
        var result = LinkedFlow(binding: binding, endpoint: nil, status: "partialLinkNeedsReview", origins: [], sourceRecords: [], times: [], checks: [], problems: [], missingBindings: binding.network == nil ? [
            "C1 send wire has no runID, flowID, canary, target/local tuple, family, start/end interval or monotonic clock ID",
            "common counterpart wire has no runID, caseID, ingress flow nonce, process/peer identity, signature or clock ID",
            "common bytes/accepts are application observations, not packet capture or zero-packet proof",
            "C1 is one-way; common counterpart does not echo or authenticate an expected peer handshake",
            "raw origins, preregistration, identities/signatures, calibration, capture topology and L4 duration/repetitions require independent review"
        ] : [
            "application bytes/contacts are not packet capture or zero-packet proof",
            "challenge is correlation, not peer authentication or global replay prevention; no authenticated same-zone roundtrip",
            "raw origins, prior registration, recorded own identity/signature, external clock calibration, capture topology and L4 require independent review"
        ])
        let scenario = Scenario.all.first { $0.id == binding.scenarioID }
        let cell = matrix?.cells.first { $0.scenarioID == binding.scenarioID }
        let endpoint = input.endpoints.first { $0.id == binding.endpointID }
        result.endpoint = endpoint
        if scenario == nil { result.problems.append("unknown matrix scenario") }
        if let endpoint {
            result.problems += endpoint.problems
            if endpoint.scenarioID != binding.scenarioID { result.problems.append("endpoint allowlist entry belongs to another scenario") }
        } else { result.problems.append("endpoint not on exact preregistered allowlist") }
        if let canary = binding.canary, !validCanary(canary) { result.problems.append("invalid synthetic canary") }
        if input.bindings.filter({ $0.flowID == binding.flowID }).count != 1 { result.problems.append("duplicate/reused ingress flow binding") }
        if let ref = binding.sender, input.bindings.filter({ $0.sender == ref }).count != 1 { result.problems.append("sender record reused for multiple flows") }
        if let ref = binding.counterpart, input.bindings.filter({ $0.counterpart == ref }).count != 1 { result.problems.append("counterpart flow reused for multiple bindings") }
        if let matrix {
            let cells = matrix.cells.filter { $0.events.contains { $0.flowID == binding.flowID } }
            if cells.count != 1 || cells.first?.scenarioID != binding.scenarioID { result.problems.append("matrix flow absent or reused across cells") }
        }
        if let cell {
            if cell.origin == .planned { result.problems.append("planned matrix cell is not observation evidence") }
            if matrixReport.cells.first(where: { $0.scenario.id == cell.scenarioID })?.classification == "invalidMeasurement" { result.problems.append("matrix identities/signing/route prerequisites invalid or missing") }
            if !cell.events.contains(where: { $0.flowID == binding.flowID && $0.stage == binding.stage }) { result.problems.append("requested flow/stage absent from matrix") }
        } else { result.problems.append("missing/invalid matrix cell for binding") }
        if scenario?.route == .squatHostPort { result.missingBindings.append("C1/common wire does not measure bind acquisition, fixed host-port owner/reservation or reclaim") }

        func useSource(_ id: String, format: String) -> SourceReport? {
            guard let source = sources.first(where: { $0.id == id && $0.format == format }) else {
                result.problems.append("missing/wrong-format source \(id)"); return nil
            }
            result.origins.append(source.origin)
            result.problems += source.problems.map { "\(id): \($0)" }
            if source.recordProblems { result.problems.append("\(id): invalid record metadata; consult source records") }
            return source
        }
        func project(_ timestamp: String, source: SourceReport, line: Int) -> TimeProjection {
            let clock = source.clock
            var relative: Int?
            if clock?.usable == true, let date = utcDate(timestamp), let start = utcDate(input.runStartUTC) {
                let value = (date.timeIntervalSince(start) * 1000).rounded() + Double(clock!.offsetMs!)
                if (-3_600_000...7_200_000).contains(value) { relative = Int(value) }
            }
            let projection = TimeProjection(sourceID: source.id, line: line, rawTimestamp: timestamp, clockID: clock?.id,
                relativeMs: relative, uncertaintyMs: clock?.usable == true ? clock?.uncertaintyMs : nil)
            result.times.append(projection)
            if relative == nil { result.problems.append("\(source.id) line \(line): time cannot be mapped to bounded run window") }
            return projection
        }
        func reference(_ source: SourceReport, _ line: Int) { result.sourceRecords.append(.init(sourceID: source.id, line: line)) }
        func withinStage(_ t: TimeProjection, allowDrain: Bool) {
            guard let time = t.relativeMs, let u = t.uncertaintyMs, let window = cell?.window else {
                result.missingBindings.append("finite observation window and calibrated source times"); return
            }
            let lower: Int, upper: Int
            switch binding.stage {
            case .before: lower = 0; upper = window.testStartMs - 1
            case .test: lower = window.testStartMs; upper = allowDrain ? window.drainEndMs : window.testEndMs
            case .drain: lower = window.testEndMs + 1; upper = window.drainEndMs
            case .after: lower = window.drainEndMs + 1; upper = 3_600_000
            }
            if time - u < lower || time + u > upper { result.problems.append("\(t.sourceID) line \(t.line): time/uncertainty crosses requested stage window") }
        }
        var observations: [MatrixObservation] = []
        func reconcileObservations() {
            guard let cell else { return }
            for kind in [EventKind.accepted, .closed, .payload, .packetContact] + (binding.network == nil ? [] : [.attempt, .connected]) {
                let raw = observations.filter { $0.kind == kind }
                // Keep all claims for this flow, including wrong-stage/actor claims, so
                // neither side can disappear merely because it has no eligible edge.
                let expected = cell.events.enumerated().filter { $0.element.flowID == binding.flowID && $0.element.kind == kind }
                let actor: Actor = kind == .packetContact ? .oracle : [.attempt, .connected].contains(kind) ? .initiator : .listener
                let edges = raw.map { observation -> [Int] in
                    guard observation.eligible, let t = observation.time.relativeMs,
                          let uncertainty = observation.time.uncertaintyMs else { return [] }
                    return expected.indices.filter { index in
                        let event = expected[index].element
                        return event.actor == actor &&
                            (event.stage == binding.stage || binding.stage == .test && event.stage == .drain) &&
                            abs(event.timeMs - t) <= uncertainty &&
                            (kind != .payload || observation.value == event.value)
                    }
                }
                let matches = maximumObservationMatching(edges, matrixCount: expected.count)
                for index in raw.indices {
                    if matches[index] == nil {
                        if raw[index].requiresMatrixEvent {
                            let time = raw[index].time
                            result.problems.append("\(time.sourceID) line \(time.line): raw \(kind.rawValue) time/value lacks matching matrix event in one-to-one reconciliation")
                        }
                    } else {
                        result.checks.append("raw \(kind.rawValue) time/value matches a distinct matrix event under supplied clock bound")
                    }
                }
                let consumed = Set(matches.compactMap { $0 })
                for index in expected.indices where !consumed.contains(index) {
                    let (position, event) = expected[index]
                    result.problems.append("matrix \(kind.rawValue) event \(position + 1) (timeMs \(event.timeMs), value \(event.value)) lacks matching raw observation in one-to-one reconciliation")
                }
            }
        }
        func lifecycleCoverage(_ start: TimeProjection?, _ end: TimeProjection?, label: String) {
            guard let cell, let window = cell.window, let a = start?.relativeMs, let au = start?.uncertaintyMs,
                  let b = end?.relativeMs, let bu = end?.uncertaintyMs else { result.missingBindings.append("\(label) lifecycle/time coverage"); return }
            let activity = cell.events.filter { ![.captureStarted, .captureStopped, .listenerStarted, .listenerStopped].contains($0.kind) }
            let first = min(activity.first?.timeMs ?? window.testStartMs, window.testStartMs)
            let last = max(activity.last?.timeMs ?? window.drainEndMs, window.drainEndMs)
            if a + au > first || b - bu < last || a >= b { result.problems.append("\(label) does not cover controls/test/drain with clock uncertainty") }
        }

        if binding.network == nil {
        var sender: SenderWire?
        if let ref = binding.sender, let source = useSource(ref.sourceID, format: "c1RunRecordStream") {
            if let row = source.sender.first(where: { $0.line == ref.line && $0.record.probe == "sanjbox-s3-probe.send" }) {
                reference(source, row.line); sender = row.record
                let r = row.record
                let time = project(r.timestamp, source: source, line: row.line)
                withinStage(time, allowDrain: true) // This is send completion, never an invented attempt timestamp.
                if r.caseID != scenario?.caseID { result.problems.append("C1 caseID differs from matrix case") }
                else { result.checks.append("C1 caseID matches matrix") }
                if !r.mismatches.isEmpty { result.problems.append("C1 send contains identity mismatches") }
                if let p = cell?.participants.first(where: { $0.actor == .initiator }), let expected = p.expected {
                    let decoded = try? Identity(context: r.context, required: expected.requiredGroups, forbidden: expected.forbiddenGroups)
                    if r.context.pid != p.pid || decoded != expected || decoded != p.observed || !expected.commonExpectation.mismatches(in: r.context).isEmpty {
                        result.problems.append("C1 sender context differs from exact matrix initiator identity/session/PID")
                    } else { result.checks.append("C1 context matches exact matrix initiator using shared identity/membership validator") }
                } else { result.missingBindings.append("expected matrix initiator identity") }
                if r.details["clientError"] != nil { result.missingBindings.append("C1 client error is not delivery or isolation proof") }
                if let identityRef = binding.senderIdentity, identityRef.sourceID == source.id,
                   let row = source.sender.first(where: { $0.line == identityRef.line && $0.record.probe == "sanjbox-s3-probe.identity" }) {
                    reference(source, row.line)
                    let identityTime = project(row.record.timestamp, source: source, line: row.line)
                    let ir = row.record
                    if row.line >= ref.line || ir.context != r.context || ir.outcome != .passed || !ir.mismatches.isEmpty ||
                        ir.details["expectedAuditSessionID"] != r.context.audit.map({ String($0.sessionID) }) ||
                        ir.details["actualAuditSessionID"] != r.context.audit.map({ String($0.sessionID) }) ||
                        identityTime.relativeMs == nil || time.relativeMs == nil || identityTime.relativeMs! > time.relativeMs! {
                        result.problems.append("C1 preceding identity record does not substantiate send context")
                    } else { result.checks.append("C1 preceding identity and send share context and audit session") }
                    // C1 emits exactly identity then send per invocation; concatenated invocations must stay adjacent.
                    if ref.line != row.endLine + 1 { result.problems.append("C1 identity/send records are not adjacent") }
                } else { result.missingBindings.append("explicit same-source preceding C1 identity record") }
            } else { result.problems.append("C1 send reference absent/not a send record") }
        } else { result.missingBindings.append("C1 sender raw record binding") }

        if let ref = binding.counterpart, let source = useSource(ref.sourceID, format: "commonCounterpartJSONL") {
            let rows = source.counterpart.filter { $0.record.flowID == ref.flowID }
            if rows.isEmpty { result.problems.append("counterpart raw flow absent") }
            if let endpoint {
                let starts = source.counterpart.filter { $0.record.kind == .started }
                if starts.count == 1, starts[0].record.listeners?.contains(where: { $0.transport == endpoint.transport && $0.endpoint.matches(endpoint.bind) }) == true {
                    result.checks.append("common started listener matches exact allowlisted family/bind/port/transport")
                } else { result.problems.append("common started listener does not match endpoint allowlist") }
            }
            for row in rows {
                reference(source, row.line)
                let r = row.record
                let t = project(r.timestamp, source: source, line: row.line)
                withinStage(t, allowDrain: true)
                if let endpoint, r.transport != endpoint.transport || r.local?.matches(endpoint.local) != true || r.remote?.matches(endpoint.remote) != true {
                    result.problems.append("common flow local/remote tuple or transport differs from exact allowlist")
                } else if endpoint != nil { result.checks.append("common flow tuple matches exact allowlisted endpoints") }
                let eligible = row.problems.isEmpty && endpoint.map {
                    r.transport == $0.transport && r.local?.matches($0.local) == true && r.remote?.matches($0.remote) == true
                } == true
                switch r.kind {
                case .accepted:
                    observations.append(.init(kind: .accepted, time: t, value: nil, eligible: eligible))
                case .closed, .datagram:
                    if r.kind == .closed { observations.append(.init(kind: .closed, time: t, value: nil, eligible: eligible)) }
                    // Missing bytes are not zero and can never match a payload claim.
                    // Explicit zero can support an optional zero-valued matrix event;
                    // absence of a payload event for a zero-byte contact is also valid.
                    if let bytes = r.bytes, bytes >= 0 {
                        observations.append(.init(kind: .payload, time: t, value: bytes,
                            eligible: eligible, requiresMatrixEvent: bytes > 0))
                    }
                default: result.problems.append("non-flow event has counterpart flow ID")
                }
            }
            let terminals = rows.filter { $0.record.kind == .closed || $0.record.kind == .datagram }
            if let canary = binding.canary, validCanary(canary) {
                if terminals.contains(where: { $0.record.findings?.contains(where: { $0.token == canary && $0.encoding == "raw" }) == true }) {
                    result.checks.append("common raw canary finding exactly matches registered synthetic canary (not a sender nonce binding)")
                    if terminals.contains(where: { ($0.record.bytes ?? 0) < canary.utf8.count && $0.record.findings?.contains(where: { $0.token == canary && $0.encoding == "raw" }) == true }) {
                        result.problems.append("raw canary finding exceeds reported byte count")
                    }
                } else { result.missingBindings.append("exact registered canary absent from common raw findings; prefix/zero bytes are not a nonce") }
                if terminals.flatMap({ $0.record.findings ?? [] }).contains(where: { $0.token != Canary.tokenPrefix && $0.token != canary }) { result.problems.append("common flow contains a different registered canary") }
            } else { result.missingBindings.append("registered synthetic canary") }
            if let bytes = sender?.details["localKernelAcceptedBytes"].flatMap(Int.init), terminals.count == 1,
               let received = terminals.first?.record.bytes, received > bytes { result.problems.append("receiver bytes exceed referenced C1 local-kernel total; association conflicts") }
            var start: TimeProjection?, end: TimeProjection?
            for row in source.counterpart where row.record.kind == .started || row.record.kind == .stopped {
                reference(source, row.line)
                let p = project(row.record.timestamp, source: source, line: row.line)
                if row.record.kind == .started { start = p } else { end = p }
            }
            lifecycleCoverage(start, end, label: "common listener")
        } else { result.missingBindings.append("common counterpart raw flow binding") }

        } else if let network = binding.network {
            if binding.sender != nil || binding.senderIdentity != nil || binding.counterpart != nil || binding.canary != nil {
                result.problems.append("network binding cannot mix legacy sender/counterpart/canary references")
            }
            if network.senderSourceID == network.receiverSourceID { result.problems.append("network sender and receiver must be distinct sources/instances") }
            if input.bindings.filter({ $0.network?.senderSourceID == network.senderSourceID }).count != 1 ||
                input.bindings.filter({ $0.network?.receiverSourceID == network.receiverSourceID && $0.network?.contactID == network.contactID }).count != 1 {
                result.problems.append("network sender or receiver contact reused across bindings")
            }
            let sendSource = useSource(network.senderSourceID, format: "sanjboxNetworkProvenanceV1")
            let recvSource = useSource(network.receiverSourceID, format: "sanjboxNetworkProvenanceV1")
            let send = sendSource?.network?.records ?? [], recv = recvSource?.network?.records ?? []
            let sr = send.first?.record, rr = recv.first?.record
            if sr?.kind != "registered" || rr?.kind != "registered" || sr?.role != "sender" || rr?.role != "receiver" || sr?.instanceID == rr?.instanceID {
                result.problems.append("network binding missing distinct registered sender/receiver instances")
            }
            if sr?.runID != input.runID || rr?.runID != input.runID || sr?.flowID != binding.flowID || rr?.flowID != binding.flowID ||
                sr?.registration?.flow != rr?.registration?.flow || sr?.scope != rr?.scope || sr?.transport != rr?.transport {
                result.problems.append("network registered run/flow/challenge/scope/transport binding mismatch")
            } else { result.checks.append("sender and receiver registered run/flow/challenge agree (correlation only)") }
            if sr?.scope != .testArea || rr?.scope != .testArea { result.missingBindings.append("hostDiagnostic provenance is not a testArea/L4 identity or isolation measurement") }
            for (source, registered, actor) in [(sendSource, sr, Actor.initiator), (recvSource, rr, Actor.listener)] {
                guard let source, let registered else { continue }
                if let p = cell?.participants.first(where: { $0.actor == actor }), let identity = registered.identity,
                   let adapted = try? JSONDecoder().decode(Identity.self, from: encodeJSON(identity)),
                   p.expected == adapted, p.observed == adapted, p.pid == registered.pid, p.instanceID == registered.instanceID,
                   p.signature?.valid == registered.signature?.valid,
                   p.signature?.hardenedRuntime == registered.signature?.hardenedRuntime,
                   p.signature?.getTaskAllowAbsent == registered.signature?.getTaskAllowAbsent {
                    result.checks.append("network recorded own identity/PID/instance/signature flags match matrix \(actor.rawValue) claims")
                } else { result.problems.append("network recorded own identity/PID/instance/signature differs from matrix \(actor.rawValue)") }
                result.checks += source.network?.checks ?? []
            }
            let terminal = recv.filter { $0.record.contactID == network.contactID && ["closed", "datagram"].contains($0.record.kind) }
            let connected = send.first { $0.record.kind == "connected" }?.record
            let ended = send.first { $0.record.kind == "attemptEnded" }?.record
            let started = recv.first { $0.record.kind == "receiverStarted" }?.record
            if let endpoint, let connected, let started,
               networkEndpoint(connected.local)?.matches(endpoint.remote) == true,
               networkEndpoint(connected.remote)?.matches(endpoint.local) == true,
               networkEndpoint(sr?.registration?.endpoint)?.matches(endpoint.local) == true,
               networkEndpoint(started.local)?.matches(endpoint.bind) == true,
               sr?.transport.rawValue == endpoint.transport.rawValue {
                result.checks.append("actual sender tuple reverses exact receiver endpoint allowlist; receiver bound endpoint checked")
            } else { result.problems.append("network sender actual/target or receiver bound tuple differs from exact allowlist; exact-bind diagnostics do not cover wildcard scenarios") }
            if terminal.count != 1 { result.problems.append("network selected contact terminal missing/duplicate; raw byte count unknown") }
            if let terminal = terminal.first?.record, let source = input.sources.first(where: { $0.id == network.receiverSourceID }),
               let raw = networkRaw(source, name: "received-\(network.contactID).bin"), let registration = sr?.registration {
                if raw != registration.flow.bytes || terminal.matchesRegisteredPayload != true || terminal.repeatedRegisteredPayload != false || terminal.rawTruncated != false {
                    result.problems.append("network selected raw is zero/partial/foreign/replayed payload; no fresh exact frame correlation")
                } else { result.checks.append("exact independently supplied receiver bytes equal sender registered frame; no bytes reconstructed from hashes") }
                if let accepted = ended?.localKernelAcceptedBytes {
                    if raw.count > accepted { result.problems.append("network received bytes exceed sender kernel accepted count") }
                } else { result.missingBindings.append("sender terminal kernel accepted count (unknown, never zero)") }
            } else { result.missingBindings.append("selected exact receiver raw and sender registration; hash/payload claims cannot supply bytes") }
            if let source = sendSource {
                for row in send {
                    reference(source, row.line)
                    let t = project(row.record.timestamp.utc, source: source, line: row.line)
                    if row.record.kind != "registered" { withinStage(t, allowDrain: true) }
                    if row.record.kind == "attemptStarted" {
                        observations.append(.init(kind: .attempt, time: t, value: nil,
                            eligible: row.problems.isEmpty && source.problems.isEmpty && endpoint.map {
                                networkEndpoint(row.record.target)?.matches($0.local) == true
                            } == true))
                    }
                    if row.record.kind == "connected" {
                        observations.append(.init(kind: .connected, time: t, value: nil,
                            eligible: row.problems.isEmpty && source.problems.isEmpty && endpoint.map {
                                networkEndpoint(row.record.local)?.matches($0.remote) == true && networkEndpoint(row.record.remote)?.matches($0.local) == true
                            } == true))
                    }
                }
            }
            if let source = recvSource {
                var start: TimeProjection?, end: TimeProjection?
                for row in recv where row.record.contactID == network.contactID || ["registered", "receiverStarted", "receiverStopped"].contains(row.record.kind) {
                    reference(source, row.line)
                    let e = row.record, t = project(e.timestamp.utc, source: source, line: row.line)
                    if e.kind == "receiverStarted" { start = t }
                    else if e.kind == "receiverStopped" { end = t }
                    else if e.kind != "registered" {
                        withinStage(t, allowDrain: true)
                        let tuple = endpoint.map { networkEndpoint(e.local)?.matches($0.local) == true && networkEndpoint(e.remote)?.matches($0.remote) == true && e.transport.rawValue == $0.transport.rawValue } == true
                        if !tuple { result.problems.append("network selected receiver contact tuple differs from allowlist/sender") }
                        let eligible = row.problems.isEmpty && source.problems.isEmpty && tuple
                        if e.kind == "accepted" { observations.append(.init(kind: .accepted, time: t, value: nil, eligible: eligible)) }
                        if e.kind == "closed" { observations.append(.init(kind: .closed, time: t, value: nil, eligible: eligible)) }
                        if ["closed", "datagram"].contains(e.kind), let bytes = e.bytes {
                            observations.append(.init(kind: .payload, time: t, value: bytes, eligible: eligible, requiresMatrixEvent: bytes > 0))
                        }
                    }
                }
                lifecycleCoverage(start, end, label: "network receiver")
            }
        }

        if let ref = binding.capture, let source = useSource(ref.sourceID, format: "packetImportV1JSONL") {
            let rows = source.packets.filter { $0.record.captureID == ref.captureID }
            let starts = rows.filter { $0.record.kind == .captureStarted }
            let stops = rows.filter { $0.record.kind == .captureStopped }
            if starts.count != 1 || stops.count != 1 || rows.first?.record.kind != .captureStarted || rows.last?.record.kind != .captureStopped {
                result.problems.append("imported capture lifecycle missing/duplicate/reversed")
            }
            var start: TimeProjection?, end: TimeProjection?
            let oracle = cell?.participants.first { $0.actor == .oracle }
            for row in rows {
                let r = row.record
                // All capture metadata are checked, including other flows: a swapped capture is not a match.
                let provenanceMatches = r.runID == input.runID && r.scenarioID == binding.scenarioID && r.family == scenario?.family &&
                    r.clockID == source.clock?.id && r.oracleInstanceID == oracle?.instanceID && r.interface == starts.first?.record.interface
                if !provenanceMatches { result.problems.append("capture run/case/family/clock/interface/oracle provenance mismatch") }
                if r.kind == .packetContact && r.flowID != binding.flowID { continue }
                reference(source, row.line)
                let p = project(r.timestamp, source: source, line: row.line)
                if r.kind == .captureStarted { start = p }
                else if r.kind == .captureStopped {
                    end = p
                    if r.droppedPackets != 0 || r.gapsMs != 0 { result.problems.append("imported packet capture losses/gaps unknown or nonzero") }
                    if r.droppedPackets != cell?.window?.captureDrops || r.gapsMs != cell?.window?.captureGapsMs { result.problems.append("imported capture loss/gap counts differ from matrix claims") }
                } else {
                    withinStage(p, allowDrain: true)
                    if let endpoint, r.transport != endpoint.transport || r.local?.matches(endpoint.local) != true || r.remote?.matches(endpoint.remote) != true {
                        result.problems.append("packet tuple/transport differs from exact allowlist")
                    }
                    let tupleMatches = endpoint.map {
                        r.transport == $0.transport && r.local?.matches($0.local) == true && r.remote?.matches($0.remote) == true
                    } == true
                    observations.append(.init(kind: .packetContact, time: p, value: nil,
                        eligible: row.problems.isEmpty && provenanceMatches && tupleMatches))
                }
            }
            lifecycleCoverage(start, end, label: "imported packet capture")
            if rows.isEmpty { result.problems.append("referenced imported capture absent") }
            result.missingBindings.append("packetImportV1 is a separate supplied transcript; original capture and recorder identity/topology are not authenticated here")
        } else { result.missingBindings.append("independent packet capture import; common accept/bytes cannot fill it") }

        reconcileObservations()
        if let w = cell?.window, let retry = w.retryUpperBoundMs, let rtt = w.roundTripUpperBoundMs,
           let uncertainty = w.clockUncertaintyMs {
            let rawMax = result.times.compactMap(\.uncertaintyMs).max() ?? 0
            if uncertainty < rawMax { result.problems.append("matrix clock uncertainty understates an imported source bound") }
            if w.drainEndMs - w.testEndMs <= retry + 2 * rtt + 2 * max(uncertainty, rawMax) { result.problems.append("drain does not exceed retry + 2*RTT + 2*clock uncertainty") }
            if w.captureDrops != 0 || w.captureGapsMs != 0 { result.problems.append("matrix capture loss/gaps unknown or nonzero") }
        } else { result.missingBindings.append("observation retry/RTT/clock/drain bounds") }
        if result.origins.contains(.importedMeasured), cell?.origin == .mock { result.problems.append("imported measured source associated with mock matrix; origin conflict") }
        if Set(result.origins).count > 1 { result.problems.append("mixed source origins; fixture/unknown cannot substantiate measured evidence") }
        result.origins = Array(Set(result.origins)).sorted { $0.rawValue < $1.rawValue }
        result.problems = Array(Set(result.problems)).sorted()
        result.missingBindings = Array(Set(result.missingBindings)).sorted()
        result.checks = Array(Set(result.checks)).sorted()
        result.sourceRecords = Array(Set(result.sourceRecords)).sorted { ($0.sourceID, $0.line) < ($1.sourceID, $1.line) }
        result.times.sort { ($0.sourceID, $0.line) < ($1.sourceID, $1.line) }
        if !result.problems.isEmpty { result.status = "conflictingOrIncompleteLink" }
        return result
    }
}

private struct MatrixObservation {
    var kind: EventKind
    var time: TimeProjection
    var value: Int?
    var eligible: Bool
    var requiresMatrixEvent = true
}

/// Deterministic maximum-cardinality bipartite matching via augmenting paths. A matrix
/// occurrence has at most one owner; a later raw observation can reassign earlier matches
/// rather than fail because a greedy first choice consumed its only candidate. Parser bounds
/// limit each side to 256 occurrences per kind/flow (O(V*E), <=256 recursion depth). Duplicate
/// equal-time occurrences remain separate vertices. Only explicit compatibility edges match.
func maximumObservationMatching(_ edges: [[Int]], matrixCount: Int) -> [Int?] {
    var owners = [Int?](repeating: nil, count: matrixCount)
    func augment(_ raw: Int, visited: inout [Bool]) -> Bool {
        for matrix in edges[raw] where !visited[matrix] {
            visited[matrix] = true
            if owners[matrix] == nil || augment(owners[matrix]!, visited: &visited) {
                owners[matrix] = raw
                return true
            }
        }
        return false
    }
    for raw in edges.indices {
        var visited = [Bool](repeating: false, count: matrixCount)
        _ = augment(raw, visited: &visited)
    }
    var matches = [Int?](repeating: nil, count: edges.count)
    for matrix in owners.indices {
        if let raw = owners[matrix] { matches[raw] = matrix }
    }
    return matches
}
