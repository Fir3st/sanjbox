import Darwin
import Foundation

/// No pipes that can deadlock on unread output; only fresh owned files. Every wait has a deadline.
final class ChildProcess {
    let process = Process()
    let outputURL: URL
    let errorURL: URL
    private let output: FileHandle
    private let error: FileHandle
    init(executable: URL, arguments: [String], directory: URL, label: String) throws {
        outputURL = directory.appendingPathComponent(label + ".stdout")
        errorURL = directory.appendingPathComponent(label + ".stderr")
        func fresh(_ url: URL) throws -> FileHandle {
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw HarnessError.invalid("cannot create child output") }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        output = try fresh(outputURL); error = try fresh(errorURL)
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = error
        try process.run()
    }
    func wait(seconds: Double) throws -> Int32 {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        guard !process.isRunning else {
            terminate()
            throw HarnessError.invalid("child process deadline exceeded")
        }
        return process.terminationStatus
    }
    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        let killDeadline = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning, ProcessInfo.processInfo.systemUptime < killDeadline { usleep(10_000) }
    }
    func outputData() throws -> Data {
        let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1 << 20 else { throw HarnessError.invalid("child output exceeded 1 MiB") }
        return try Data(contentsOf: outputURL)
    }
    deinit { terminate() }
}
