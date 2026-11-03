import Foundation

func compare(_ current: [RootReport], configuration: Configuration, baseline: Snapshot?) -> Drift {
    guard let baseline else { return .init(compared: false, events: []) }
    var events: [DriftEvent] = []
    let oldRoots = Dictionary(uniqueKeysWithValues: baseline.roots.map { ($0.root.id, $0) })
    let newRoots = Dictionary(uniqueKeysWithValues: current.map { ($0.root.id, $0) })
    if baseline.configuration.limits != configuration.limits {
        events.append(.init(rootID: "*", kind: "limits-changed"))
    }
    for id in Set(oldRoots.keys).union(newRoots.keys).sorted() {
        guard let old = oldRoots[id] else { events.append(.init(rootID: id, kind: "root-added-to-scope")); continue }
        guard let new = newRoots[id] else { events.append(.init(rootID: id, kind: "root-removed-from-scope")); continue }
        guard old.root.path == new.root.path else { events.append(.init(rootID: id, kind: "root-path-changed")); continue }
        if old.root.purpose != new.root.purpose { events.append(.init(rootID: id, kind: "root-purpose-changed")) }
        if old.gaps != new.gaps || old.enumerationComplete != new.enumerationComplete || old.metadataComplete != new.metadataComplete {
            events.append(.init(rootID: id, kind: "coverage-changed"))
        }
        let oldEntries = Dictionary(uniqueKeysWithValues: old.entries.map { ($0.path, $0) })
        let newEntries = Dictionary(uniqueKeysWithValues: new.entries.map { ($0.path, $0) })
        for path in Set(oldEntries.keys).union(newEntries.keys).sorted() {
            let a = oldEntries[path], b = newEntries[path]
            if a?.stat == nil, b?.stat != nil {
                events.append(.init(rootID: id, path: path, kind: observedAbsent(path, in: oldEntries) ? "added-observation" : "newly-observed-unknown-before"))
            } else if a?.stat != nil, b?.stat == nil {
                events.append(.init(rootID: id, path: path, kind: observedAbsent(path, in: newEntries) ? "absent-observation" : "unobserved-now"))
            } else if let a, let b, a.stat != nil, b.stat != nil {
                var fields: [String] = []
                if a.stat != b.stat { fields.append("stat") }
                if let aa = a.acl, let ba = b.acl, aa.comparable && ba.comparable && aa != ba { fields.append("acl") }
                if let am = a.mount, let bm = b.mount, am != bm { fields.append("mount") }
                if !fields.isEmpty { events.append(.init(rootID: id, path: path, kind: "metadata-changed", fields: fields)) }
                if a.status != b.status || a.acl?.status != b.acl?.status || (a.mount == nil) != (b.mount == nil) {
                    events.append(.init(rootID: id, path: path, kind: "observation-status-changed"))
                }
            }
        }
    }
    return .init(compared: true, events: events)
}

private func observedAbsent(_ path: String, in entries: [String: Entry]) -> Bool {
    // A raced subtree never supports a conclusion of absence, including an apparently missing child.
    var ancestors: [String] = [path]
    var cursor = path
    while cursor != "." {
        cursor = cursor.contains("/") ? String(cursor.prefix(upTo: cursor.lastIndex(of: "/")!)) : "."
        ancestors.append(cursor)
    }
    if ancestors.contains(where: { entries[$0]?.status == "changed" }) { return false }
    if ancestors.contains(where: { entries[$0]?.status == "missing" }) { return true }
    for child in ancestors where child != "." {
        let parent = child.contains("/") ? String(child.prefix(upTo: child.lastIndex(of: "/")!)) : "."
        if entries[child] == nil, entries[parent]?.listing == "complete" { return true }
    }
    return false
}
