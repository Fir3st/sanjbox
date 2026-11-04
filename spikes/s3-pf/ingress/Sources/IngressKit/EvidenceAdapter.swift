import CryptoKit
import Foundation
import SanjboxProbeKit

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
        let sources = input.sources.map(parseSource).sorted { $0.id < $1.id }
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
        var result = LinkedFlow(binding: binding, endpoint: nil, status: "partialLinkNeedsReview", origins: [], sourceRecords: [], times: [], checks: [], problems: [], missingBindings: [
            "C1 send wire has no runID, flowID, canary, target/local tuple, family, start/end interval or monotonic clock ID",
            "common counterpart wire has no runID, caseID, ingress flow nonce, process/peer identity, signature or clock ID",
            "common bytes/accepts are application observations, not packet capture or zero-packet proof",
            "C1 is one-way; common counterpart does not echo or authenticate an expected peer handshake",
            "raw origins, preregistration, identities/signatures, calibration, capture topology and L4 duration/repetitions require independent review"
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
        func matrixEvent(_ kind: EventKind, time: TimeProjection, value: Int? = nil) {
            guard let cell, let t = time.relativeMs, let uncertainty = time.uncertaintyMs else { return }
            let expected = cell.events.filter { $0.flowID == binding.flowID && $0.kind == kind &&
                ($0.stage == binding.stage || binding.stage == .test && $0.stage == .drain) }
            if !expected.contains(where: { abs($0.timeMs - t) <= uncertainty && (value == nil || $0.value == value) }) {
                result.problems.append("\(time.sourceID) line \(time.line): raw \(kind.rawValue) time/value lacks matching matrix event")
            } else { result.checks.append("raw \(kind.rawValue) time/value matches matrix event under supplied clock bound") }
        }
        func lifecycleCoverage(_ start: TimeProjection?, _ end: TimeProjection?, label: String) {
            guard let cell, let window = cell.window, let a = start?.relativeMs, let au = start?.uncertaintyMs,
                  let b = end?.relativeMs, let bu = end?.uncertaintyMs else { result.missingBindings.append("\(label) lifecycle/time coverage"); return }
            let activity = cell.events.filter { ![.captureStarted, .captureStopped, .listenerStarted, .listenerStopped].contains($0.kind) }
            let first = min(activity.first?.timeMs ?? window.testStartMs, window.testStartMs)
            let last = max(activity.last?.timeMs ?? window.drainEndMs, window.drainEndMs)
            if a + au > first || b - bu < last || a >= b { result.problems.append("\(label) does not cover controls/test/drain with clock uncertainty") }
        }

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
                switch r.kind {
                case .accepted: matrixEvent(.accepted, time: t)
                case .closed:
                    matrixEvent(.closed, time: t)
                    if let bytes = r.bytes, bytes > 0 { matrixEvent(.payload, time: t, value: bytes) }
                case .datagram: matrixEvent(.payload, time: t, value: r.bytes)
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
                if r.runID != input.runID || r.scenarioID != binding.scenarioID || r.family != scenario?.family ||
                    r.clockID != source.clock?.id || r.oracleInstanceID != oracle?.instanceID || r.interface != starts.first?.record.interface {
                    result.problems.append("capture run/case/family/clock/interface/oracle provenance mismatch")
                }
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
                    matrixEvent(.packetContact, time: p)
                }
            }
            let packets = rows.filter { $0.record.kind == .packetContact && $0.record.flowID == binding.flowID }
            let expectedPackets = cell?.events.filter { $0.kind == .packetContact && $0.flowID == binding.flowID } ?? []
            if packets.count != expectedPackets.count { result.problems.append("matrix packet observations and imported flow packet records differ in count") }
            lifecycleCoverage(start, end, label: "imported packet capture")
            if rows.isEmpty { result.problems.append("referenced imported capture absent") }
            result.missingBindings.append("packetImportV1 is a separate supplied transcript; original capture and recorder identity/topology are not authenticated here")
        } else { result.missingBindings.append("independent packet capture import; common accept/bytes cannot fill it") }

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
