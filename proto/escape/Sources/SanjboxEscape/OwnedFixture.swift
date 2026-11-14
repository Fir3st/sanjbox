import Darwin
import Foundation

/// Only a fresh mkdtemp tree is writable. There is no caller-selected target or host-data path.
final class OwnedFixture {
    let url: URL
    private let device: dev_t
    private let inode: ino_t
    private var removed = false
    init() throws {
        var template = Array("/private/tmp/sanjbox-h6-XXXXXX".utf8CString)
        guard let path = mkdtemp(&template) else { throw HarnessError.invalid("mkdtemp failed") }
        url = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { throw HarnessError.invalid("fixture stat failed") }
        device = metadata.st_dev; inode = metadata.st_ino
    }
    func directory(_ name: String) throws -> URL {
        let child = url.appendingPathComponent(name, isDirectory: true)
        guard mkdir(child.path, 0o700) == 0 else { throw HarnessError.invalid("fixture mkdir failed") }
        return child
    }
    func cleanup() throws {
        if removed { return }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(), metadata.st_dev == device, metadata.st_ino == inode else {
            throw HarnessError.invalid("fixture ownership changed; cleanup refused")
        }
        try FileManager.default.removeItem(at: url)
        removed = true
    }
    deinit { try? cleanup() }
}

/// An in-process mock boundary, not macOS filesystem enforcement. Foreign root names are denied.
struct TreeBoundary {
    let zone: URL
    func read(root: String, name: String) throws -> Data? {
        guard root == "zone", !name.isEmpty, !name.contains("/"), name != ".", name != "..",
              !name.utf8.contains(0) else { return nil }
        let directory = open(zone.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw HarnessError.invalid("cannot open owned zone fixture") }
        defer { close(directory) }
        let file = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if file < 0 {
            if errno == ELOOP { return nil }
            throw HarnessError.invalid("fixture open failed: \(errno)")
        }
        defer { close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0 else { throw HarnessError.invalid("fixture fstat failed") }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(),
              metadata.st_nlink == 1, metadata.st_size <= 4096 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4097)
        let count = Darwin.read(file, &bytes, bytes.count)
        guard count >= 0, count <= 4096 else { throw HarnessError.invalid("fixture read failed") }
        return Data(bytes.prefix(count))
    }
}
