import Darwin
import Foundation
import SanjboxProbeKit

public enum HostHardeningCommand {
    public static let usage = """
    usage: sanjbox-host-harden harden --expect ABS.s4-expect.json --baseline ABS.s4-report.json --plan ABS.s4-harden.json --state ABS/state [--dry-run | --apply --acknowledge-quiescent]
           sanjbox-host-harden uninstall --expect ABS.s4-expect.json --state ABS/state [--dry-run | --apply --acknowledge-quiescent]
    Default: dry-run, no filesystem writes. Only explicit owned directories, empty ACL, local APFS, mode 0700.
    Real protected host roots: user-only reviewed invocation in a quiescent namespace. No sudo or recursive changes.
    Exit 0: completed preview/operation; 3: identity mismatch; 4: conflict/refusal; 2: usage/schema/I/O error.
    Preserve state on every error. Pending intent is ambiguous and never automatically restored.
    """

    public static func run(_ arguments: [String]) throws -> CommandResult {
        try run(arguments, capture: { ProbeContext.capture(groupsOfInterest: $0) })
    }

    static func run(_ arguments: [String], capture: (Set<UInt32>) -> ProbeContext,
                    hooks: HardenHooks = .init()) throws -> CommandResult {
        if arguments == ["--help"] { return .init(output: Data((usage + "\n").utf8), exitCode: 0) }
        var pending = arguments[...]
        guard let operation = pending.popFirst(), ["harden", "uninstall"].contains(operation) else { throw AuditFailure(usage) }
        var options: [String: String] = [:], switches = Set<String>()
        while let flag = pending.popFirst() {
            if ["--apply", "--dry-run", "--acknowledge-quiescent"].contains(flag) {
                guard switches.insert(flag).inserted else { throw AuditFailure(usage) }
            } else {
                guard ["--expect", "--baseline", "--plan", "--state"].contains(flag), options[flag] == nil,
                      let value = pending.popFirst() else { throw AuditFailure(usage) }
                options[flag] = value
            }
        }
        let apply = switches.contains("--apply")
        guard !(apply && switches.contains("--dry-run")), apply == switches.contains("--acknowledge-quiescent"),
              let expectPath = options["--expect"], let statePath = options["--state"],
              operation == "harden" ? options.count == 4 : options.count == 2
        else { throw AuditFailure(usage) }
        let input = try JSONDecoder().decode(IdentityInput.self, from: readOwnedInput(expectPath, suffix: ".s4-expect.json", limit: 65536))
        try input.validate()
        let context = capture(input.expectation.groupsOfInterest)
        var mismatches = input.expectation.mismatches(in: context).map { IdentityMismatch(field: $0.field, expected: $0.expected, actual: $0.actual) }
        if context.audit?.sessionID != input.auditSessionID {
            mismatches.append(.init(field: "auditSessionID", expected: String(input.auditSessionID), actual: context.audit.map { String($0.sessionID) } ?? "none"))
        }
        let identity = IdentityReport(context: context, mismatches: mismatches, valid: mismatches.isEmpty)
        guard identity.valid else { return .init(output: try encode(identity), exitCode: 3) }
        var result = HardenResult(operation: operation, dryRun: !apply, statePath: statePath, changes: [], status: "refused", detail: "")
        do {
            guard getuid() == geteuid(), geteuid() != 0, context.realUID == getuid(), context.effectiveUID == geteuid()
            else { throw HardenConflict("non-root real/effective caller identity must match; setuid execution is unsupported") }
            if operation == "harden" {
                let plan = try JSONDecoder().decode(HardeningPlan.self, from: readOwnedInput(options["--plan"]!, suffix: ".s4-harden.json", limit: 65536))
                try plan.validate()
                let baseline = try JSONDecoder().decode(Snapshot.self, from: readOwnedInput(options["--baseline"]!, suffix: ".s4-report.json", limit: maximumReportBytes))
                try baseline.validateBaseline()
                guard baseline.identity.context.realUID == context.realUID, baseline.identity.context.effectiveUID == context.effectiveUID,
                      baseline.identity.context.audit?.sessionID == context.audit?.sessionID
                else { throw HardenConflict("baseline identity/session differs from current verified caller") }
                var handles: [HardenPath] = []
                for id in plan.roots {
                    guard let root = baseline.roots.first(where: { $0.root.id == id }),
                          let entry = root.entries.first(where: { $0.path == "." }), entry.status == "observed",
                          let expected = entry.stat, let acl = entry.acl, let mount = entry.mount,
                          emptyACL(acl), expected.kind == "directory"
                    else { throw HardenConflict("selected audit root lacks supported directory metadata") }
                    guard !result.changes.contains(where: { overlap($0.path, root.root.path) }) else { throw HardenConflict("overlapping roots are unsupported") }
                    let handle = try HardenPath(root.root.path)
                    let current = try handle.requireTarget()
                    guard current.stat == expected, current.acl == acl, current.mount == mount,
                          current.stat.mode != 0o700 else { throw HardenConflict("audit metadata is stale or root already has mode 0700; no change to claim") }
                    result.changes.append(.init(rootID: id, path: root.root.path, before: current, ancestors: handle.ancestors))
                    handles.append(handle)
                }
                try HardenJournal.checkDestination(statePath, targets: result.changes.map(\.path), creating: true)
                if apply { try install(result.changes, handles: handles, statePath: statePath, hooks: hooks) }
                result.status = apply ? "applied" : "would-apply"
                result.detail = apply ? "All selected mode changes have durable before/after records. Retain state for uninstall." : "No writes. Each listed before.stat.mode would become mode 448 (0700); state would be exclusively created."
            } else {
                // Existing private journal is locked during preview too, but is never created/modified.
                let journal = try HardenJournal(statePath, create: false)
                let manifest: HardenManifest = try journal.read("manifest.json")
                result.changes = manifest.changes
                try validate(manifest, journal: journal)
                let states = try loadEvents(manifest, journal: journal)
                var handles: [Int: HardenPath] = [:]
                for (index, state) in states.enumerated() {
                    guard state.restored == nil else { continue }
                    guard let applied = state.applied else {
                        if state.intent != nil { throw HardenConflict("operation \(index): interrupted apply intent is ambiguous; manual review required") }
                        continue // No intent => this invocation did not mutate this root.
                    }
                    guard state.restoreIntent == nil else { throw HardenConflict("operation \(index): interrupted restore intent is ambiguous; manual review required") }
                    let handle = try HardenPath(manifest.changes[index].path)
                    try handle.verify(ancestors: manifest.changes[index].ancestors)
                    _ = try handle.requireTarget(applied.after!)
                    handles[index] = handle
                }
                if apply {
                    for index in handles.keys.sorted() {
                        let handle = handles[index]!, change = manifest.changes[index], expected = states[index].applied!.after!
                        try journal.write(HardenEvent(transaction: manifest.transaction, index: index, phase: "restore-intent", before: expected), name: eventName(index, "restore-intent"))
                        try hooks.beforeFinalCheck(index, "restore")
                        try journal.verify()
                        try handle.verify(ancestors: change.ancestors)
                        _ = try handle.requireTarget(expected)
                        guard fchmod(handle.fd, change.before.stat.mode) == 0 else { throw HardenConflict("restore chmod failed; intent retained") }
                        try hooks.afterMutation(index, "restore")
                        let after = try handle.requireTarget()
                        guard after == expected.replacingMode(change.before.stat.mode, change: after.stat)
                        else { throw HardenConflict("metadata changed after restore; intent retained") }
                        try handle.verify(ancestors: change.ancestors)
                        guard fsync(handle.fd) == 0 else { throw HardenConflict("restore metadata flush failed; intent retained") }
                        try journal.write(HardenEvent(transaction: manifest.transaction, index: index, phase: "restored", before: expected, after: after), name: eventName(index, "restored"))
                    }
                }
                result.status = handles.isEmpty ? "already-restored-or-unmodified" : (apply ? "restored" : "would-restore")
                result.detail = "Only \(handles.count) completed, unchanged own changes \(apply ? "restored" : "would be restored"); before.stat.mode lists the exact original modes. Journal retained; no files, users, volumes or settings removed."
            }
            return .init(output: try encode(result), exitCode: 0)
        } catch let conflict as HardenConflict {
            result.status = "conflict"
            result.detail = conflict.description + " No automatic rollback. Preserve the journal, including incomplete records."
            return .init(output: try encode(result), exitCode: 4)
        }
    }
}

private func install(_ changes: [HardenChange], handles: [HardenPath], statePath: String, hooks: HardenHooks) throws {
    let journal = try HardenJournal(statePath, create: true)
    let manifest = HardenManifest(transaction: UUID().uuidString, bootSession: try bootSession(), ownerUID: geteuid(),
                                  statePath: statePath, stateIdentity: try journal.directory.requireTarget(),
                                  stateAncestors: journal.directory.ancestors, changes: changes)
    try journal.write(manifest, name: "manifest.json")
    // All records are immutable and exclusive. A pending intent is deliberately never inferred complete.
    for (index, change) in changes.enumerated() {
        let handle = handles[index]
        try handle.verify(ancestors: change.ancestors)
        _ = try handle.requireTarget(change.before)
        try journal.write(HardenEvent(transaction: manifest.transaction, index: index, phase: "intent", before: change.before), name: eventName(index, "intent"))
        try hooks.beforeFinalCheck(index, "apply")
        try journal.verify()
        try handle.verify(ancestors: change.ancestors)
        _ = try handle.requireTarget(change.before)
        guard fchmod(handle.fd, change.mode) == 0 else { throw HardenConflict("hardening chmod failed; intent retained") }
        try hooks.afterMutation(index, "apply")
        let after = try handle.requireTarget()
        guard after == change.before.replacingMode(change.mode, change: after.stat)
        else { throw HardenConflict("metadata changed after apply; intent retained") }
        try handle.verify(ancestors: change.ancestors)
        guard fsync(handle.fd) == 0 else { throw HardenConflict("hardening metadata flush failed; intent retained") }
        try journal.write(HardenEvent(transaction: manifest.transaction, index: index, phase: "applied", before: change.before, after: after), name: eventName(index, "applied"))
    }
}

private func validate(_ manifest: HardenManifest, journal: HardenJournal) throws {
    guard manifest.schema == "sanjbox.host-harden.journal.v1", UUID(uuidString: manifest.transaction) != nil,
          manifest.ownerUID == geteuid(), manifest.bootSession == (try bootSession()), manifest.statePath == journal.path,
          (1...16).contains(manifest.changes.count),
          Set(manifest.changes.map(\.rootID)).count == manifest.changes.count,
          manifest.stateIdentity.ancestorGuard == (try journal.directory.requireTarget()).ancestorGuard
    else { throw HardenConflict("journal identity/schema/boot differs; manual review required") }
    try journal.directory.verify(ancestors: manifest.stateAncestors)
    try HardenJournal.checkDestination(journal.path, targets: manifest.changes.map(\.path), creating: false)
    for (index, change) in manifest.changes.enumerated() {
        guard validAbsolutePath(change.path), !restrictedPath(change.path), change.mode == 0o700,
              change.before.stat.kind == "directory", change.before.stat.uid == geteuid(), change.before.stat.flags == 0,
              change.before.stat.mode & 0o7000 == 0, change.before.stat.mode & 0o700 == 0o700,
              change.before.stat.mode != 0o700, emptyACL(change.before.acl),
              !manifest.changes.prefix(index).contains(where: { overlap($0.path, change.path) })
        else { throw HardenConflict("unsupported or overlapping journal operation") }
    }
}

private struct EventState {
    var intent: HardenEvent?
    var applied: HardenEvent?
    var restoreIntent: HardenEvent?
    var restored: HardenEvent?
}
private func eventName(_ index: Int, _ phase: String) -> String { String(format: "%02d-%@.json", index, phase) }

private func loadEvents(_ manifest: HardenManifest, journal: HardenJournal) throws -> [EventState] {
    let names = try journal.names()
    var allowed: Set<String> = ["lock", "manifest.json"]
    var states: [EventState] = []
    for (index, change) in manifest.changes.enumerated() {
        var events: [String: HardenEvent] = [:]
        for phase in ["intent", "applied", "restore-intent", "restored"] {
            let name = eventName(index, phase)
            allowed.insert(name)
            guard names.contains(name) else { continue }
            let event: HardenEvent = try journal.read(name)
            guard event.schema == "sanjbox.host-harden.event.v1", event.transaction == manifest.transaction,
                  event.index == index, event.phase == phase else { throw HardenConflict("journal event identity/order mismatch") }
            events[phase] = event
        }
        let state = EventState(intent: events["intent"], applied: events["applied"], restoreIntent: events["restore-intent"], restored: events["restored"])
        guard state.intent == nil || (state.intent!.before == change.before && state.intent!.after == nil),
              state.applied == nil || (state.intent != nil && state.applied!.before == change.before && state.applied!.after != nil),
              state.restoreIntent == nil || (state.applied != nil && state.restoreIntent!.before == state.applied!.after && state.restoreIntent!.after == nil),
              state.restored == nil || (state.restoreIntent != nil && state.restored!.before == state.applied!.after && state.restored!.after != nil)
        else { throw HardenConflict("journal transition is incomplete or inconsistent") }
        if let after = state.applied?.after, after != change.before.replacingMode(change.mode, change: after.stat) {
            throw HardenConflict("applied journal contains changes outside the supported operation")
        }
        if let after = state.restored?.after, let applied = state.applied?.after,
           after != applied.replacingMode(change.before.stat.mode, change: after.stat) {
            throw HardenConflict("restored journal contains changes outside the supported operation")
        }
        states.append(state)
    }
    guard names.isSubset(of: allowed) else { throw HardenConflict("unexpected journal entries; preserve state for review") }
    return states
}
