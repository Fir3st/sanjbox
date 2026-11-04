import Darwin
import Foundation

/// Fixed callers only. A pipe with nonblocking draining bounds output without filling a pipe
/// before waitUntilExit. Signals use only the PID returned by this tool's own child Process.
/// Internal fixed call sites; there is no user-provided executable or argument passthrough.
enum BoundedTool {
    static func run(_ executable: String, _ arguments: [String], seconds: Double = 5) throws -> Data {
        guard ["/bin/launchctl", "/usr/bin/xcrun", "/usr/bin/codesign"].contains(executable),
              seconds > 0, seconds <= 10 else { throw S8Error.refused("tool is outside allowlist") }
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = pipe
        // Do not inherit DYLD/compiler injection or shell environment from the caller.
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "TMPDIR": "/private/tmp"]
        try process.run()
        try pipe.fileHandleForWriting.close()
        let fd = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
            throw S8Error.refused("cannot bound tool output")
        }
        defer { try? pipe.fileHandleForReading.close() }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var output = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { output.append(contentsOf: buffer.prefix(count)) }
            if output.count > 65_536 || ProcessInfo.processInfo.systemUptime >= deadline {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw S8Error.refused("tool timeout or output limit: \(executable)")
            }
            if !process.isRunning && count <= 0 { break }
            if count < 0 && errno != EAGAIN && errno != EINTR {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit(); throw S8Error.refused("tool output read failed")
            }
            usleep(2_000)
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw S8Error.refused("tool failed: \(executable), status \(process.terminationStatus)")
        }
        return output
    }
}
