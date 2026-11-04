import Darwin
import Foundation

/// Hooks exist for deterministic synthetic failure tests; the CLI always uses Native defaults.
struct ScanHooks {
    var beforeOpen: ((String) -> Void)?
    var beforeList: ((String) -> Void)?
    var mount: (Int32) -> MountMetadata? = readMount
    var listingError: ((String) -> Int32?)?
}

final class Scanner {
    private let configuration: Configuration
    private let hooks: ScanHooks
    private var remaining: Int

    init(configuration: Configuration, hooks: ScanHooks = .init()) {
        self.configuration = configuration
        self.hooks = hooks
        remaining = configuration.limits.maxEntries
    }

    func scan() -> [RootReport] {
        configuration.roots.map { root in
            var report = RootReport(root: root, entries: [], gaps: [], enumerationComplete: true, metadataComplete: true)
            visit(parent: AT_FDCWD, name: root.path, path: ".", depth: 0, rootDevice: nil, rootMount: nil, report: &report)
            report.entries.sort { $0.path < $1.path }
            report.gaps.sort { ($0.path, $0.scope, $0.reason) < ($1.path, $1.scope, $1.reason) }
            report.enumerationComplete = !report.gaps.contains { $0.scope == "subtree" }
            report.metadataComplete = report.gaps.isEmpty
            return report
        }
    }

    private func gap(_ path: String, _ scope: String, _ reason: String, _ report: inout RootReport) {
        report.gaps.append(.init(path: path, scope: scope, reason: reason))
    }

    private func visit(parent: Int32, name: String, path: String, depth: Int, rootDevice: Int32?,
                       rootMount: MountMetadata?, report: inout RootReport) {
        guard remaining > 0 else { gap(path, "subtree", "entry-limit", &report); return }
        remaining -= 1
        let index = report.entries.count
        report.entries.append(.init(path: path, status: "observed", listing: "not-directory"))
        if restrictedPath(name) {
            report.entries[index].status = "skipped"
            gap(path, "subtree", "restricted-name-no-inspection", &report)
            return
        }
        var before = stat()
        let statFlags = AT_SYMLINK_NOFOLLOW | (parent == AT_FDCWD ? AT_SYMLINK_NOFOLLOW_ANY : 0)
        guard fstatat(parent, name, &before, statFlags) == 0 else {
            let code = errno
            report.entries[index].status = code == ENOENT ? "missing" : "inaccessible"
            report.entries[index].errorNumber = code
            gap(path, "subtree", code == ELOOP ? "symlink-in-root-path" : report.entries[index].status, &report)
            return
        }
        let value = metadata(before)
        report.entries[index].stat = value
        if value.kind != "regular" && value.kind != "directory" {
            let reason = value.kind == "symlink" ? "skipped-symlink" : "skipped-special-node"
            report.entries[index].acl = .init(status: reason)
            gap(path, "metadata", reason + "-acl-and-mount", &report)
            return
        }
        hooks.beforeOpen?(path)
        let fd = openat(parent, name, O_EVTONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            report.entries[index].errorNumber = errno
            report.entries[index].status = "inaccessible"
            report.entries[index].listing = value.kind == "directory" ? "inaccessible" : "not-directory"
            gap(path, value.kind == "directory" ? "subtree" : "metadata", "metadata-open-failed", &report)
            return
        }
        defer { close(fd) }
        var pinned = stat()
        guard fstat(fd, &pinned) == 0, sameObject(before, pinned), metadata(before) == metadata(pinned) else {
            report.entries[index].status = "changed"
            report.entries[index].listing = value.kind == "directory" ? "changed" : "not-directory"
            gap(path, "subtree", "changed-before-open", &report)
            return
        }
        report.entries[index].mount = hooks.mount(fd)
        guard let mount = report.entries[index].mount else {
            gap(path, "metadata", "mount-unavailable", &report)
            if value.kind == "directory" {
                report.entries[index].listing = "inaccessible"
                gap(path, "subtree", "mount-unavailable", &report)
            }
            return
        }
        if !mount.local {
            report.entries[index].listing = value.kind == "directory" ? "nonlocal-mount" : "not-directory"
            gap(path, value.kind == "directory" ? "subtree" : "metadata", "nonlocal-mount-no-acl-or-traversal", &report)
            return
        }
        report.entries[index].acl = readACL(fd)
        if report.entries[index].acl?.comparable != true { gap(path, "metadata", "acl-unavailable", &report) }
        if value.kind == "directory" {
            if let rootDevice, let rootMount,
               rootDevice != before.st_dev || rootMount.filesystemID != mount.filesystemID {
                report.entries[index].listing = "mount-boundary"
                gap(path, "subtree", "mount-boundary", &report)
            } else if depth >= configuration.limits.maxDepth {
                report.entries[index].listing = "depth-limit"
                gap(path, "subtree", "depth-limit", &report)
            } else {
                enumerate(fd: fd, path: path, depth: depth, index: index,
                          rootDevice: rootDevice ?? before.st_dev, rootMount: rootMount ?? mount, report: &report)
            }
        }
        var after = stat()
        var linked = stat()
        // Recheck both the pinned object and its directory entry. Ancestors are checked on unwind.
        if fstat(fd, &after) != 0 || metadata(before) != metadata(after)
            || fstatat(parent, name, &linked, statFlags) != 0 || metadata(after) != metadata(linked) {
            report.entries[index].status = "changed"
            if value.kind == "directory" { report.entries[index].listing = "changed" }
            gap(path, value.kind == "directory" ? "subtree" : "metadata", "changed-during-scan", &report)
        }
    }

    private func enumerate(fd: Int32, path: String, depth: Int, index: Int, rootDevice: Int32,
                           rootMount: MountMetadata, report: inout RootReport) {
        hooks.beforeList?(path)
        if let code = hooks.listingError?(path) {
            report.entries[index].listing = "inaccessible"
            report.entries[index].errorNumber = code
            gap(path, "subtree", "directory-listing-failed", &report)
            return
        }
        let listingFD = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard listingFD >= 0 else {
            report.entries[index].listing = "inaccessible"
            report.entries[index].errorNumber = errno
            gap(path, "subtree", "directory-listing-failed", &report)
            return
        }
        guard let directory = fdopendir(listingFD) else {
            close(listingFD)
            report.entries[index].listing = "inaccessible"
            gap(path, "subtree", "fdopendir-failed", &report)
            return
        }
        defer { closedir(directory) }
        while true {
            errno = 0
            guard let item = readdir(directory) else {
                if errno == 0 { report.entries[index].listing = "complete" }
                else {
                    report.entries[index].listing = "inaccessible"
                    report.entries[index].errorNumber = errno
                    gap(path, "subtree", "readdir-failed", &report)
                }
                return
            }
            let nameBytes = withUnsafeBytes(of: &item.pointee.d_name) { Array($0.prefix(Int(item.pointee.d_namlen))) }
            if nameBytes == [46] || nameBytes == [46, 46] { continue }
            guard let name = String(bytes: nameBytes, encoding: .utf8), !name.contains("/"), !name.utf8.contains(0) else {
                report.entries[index].listing = "unreadable-name"
                gap(path, "subtree", "non-utf8-or-invalid-entry-name", &report)
                return
            }
            guard remaining > 0 else {
                report.entries[index].listing = "entry-limit"
                gap(path, "subtree", "entry-limit", &report)
                return
            }
            let child = path == "." ? name : path + "/" + name
            guard child.utf8.count <= maximumPathBytes else {
                report.entries[index].listing = "entry-limit"
                gap(path, "subtree", "path-length-limit", &report)
                return
            }
            visit(parent: fd, name: name, path: child, depth: depth + 1, rootDevice: rootDevice,
                  rootMount: rootMount, report: &report)
        }
    }
}
