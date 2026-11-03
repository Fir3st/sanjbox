import Darwin
import Foundation

/// Only owned schema inputs are opened. Declared mountpoints/roots are never passed to a filesystem API.
func ownedSchemaData(at path: String, suffix: String, maximumBytes: Int) throws -> Data {
    guard designPath(path, absolute: true), path.hasSuffix(suffix), !restrictedInputPath(path) else {
        throw ManifestError("require an absolute, normalized, non-restricted owned schema path with suffix \(suffix)")
    }
    var named = stat()
    let statResult = fstatat(AT_FDCWD, path, &named, AT_SYMLINK_NOFOLLOW_ANY | AT_SYMLINK_NOFOLLOW)
    guard statResult == 0, eligibleInput(named, limit: maximumBytes) else { throw ManifestError("schema metadata preflight refused") }
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw ManifestError("schema open refused (errno \(errno))") }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0, eligibleInput(opened, limit: maximumBytes), unchanged(named, opened) else {
        throw ManifestError("schema path changed before read")
    }
    // One bounded request; a short read is an error rather than a reason for unbounded retries.
    let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
    var finished = stat()
    guard fstat(descriptor, &finished) == 0, unchanged(opened, finished),
          data.count == opened.st_size, data.count <= maximumBytes else { throw ManifestError("schema input changed, was short, or exceeded its limit") }
    return data
}

private func eligibleInput(_ info: stat, limit: Int) -> Bool {
    info.st_mode & S_IFMT == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1
        && info.st_mode & 0o022 == 0 && info.st_size > 0 && info.st_size <= limit
}

private func unchanged(_ a: stat, _ b: stat) -> Bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid
        && a.st_nlink == b.st_nlink && a.st_size == b.st_size && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
        && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
}

private func restrictedInputPath(_ value: String) -> Bool {
    value.split(separator: "/").contains { part in
        let name = part.lowercased()
        return name.hasPrefix(".env") || ["secret", "token", "credential", "keychain"].contains(where: name.contains)
            || [".ssh", ".gnupg"].contains(name) || [".db", ".sqlite", ".pem", ".key", ".p12"].contains(where: name.hasSuffix)
    }
}
