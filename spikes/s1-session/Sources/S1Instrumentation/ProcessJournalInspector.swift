import CryptoKit
import Darwin
import Foundation

public struct JournalByteRange: Codable, Equatable, Sendable {
    /// Zero-based offsets, exclusive end; line numbers are one-based.
    public var start: Int
    public var end: Int
}
public struct InspectedProcessRow: Codable, Sendable {
    public var line: Int
    public var bytes: JournalByteRange
    public var sequence: Int
    public var point: ProcessSeriesPoint
}
public struct ProcessJournalDiagnostic: Codable, Sendable {
    public var line: Int
    public var bytes: JournalByteRange
    public var code: String
}
public struct ProcessJournalTail: Codable, Sendable {
    public var line: Int
    public var bytes: JournalByteRange
    public var kind: String
}
public struct ProcessJournalInspection: Encodable, Sendable {
    public let schemaVersion = 1
    public let status = "incomplete-unverified"
    public let acquisitionComplete = false
    public let identityAuthenticated = false
    public let provenanceArtifactsVerified = false
    public let acceptanceVerdict = "not-evaluated"
    public let scope = "offline retained claims only; no complete recording, S1/P4 verdict, system or cross-process memory total"
    public var inputSHA256: String
    public var inputBytes: Int
    public var suppliedPlanSHA256: String?
    public var runID: String?
    public var window: Window?
    public var structuralError = false
    public var contiguousPrefixBytes = 0
    public var rows: [InspectedProcessRow] = []
    public var diagnostics: [ProcessJournalDiagnostic] = []
    public var tail: ProcessJournalTail?
    /// Bytes after the rejected LF-terminated row are deliberately not interpreted/resynchronized.
    public var unexaminedBytes: JournalByteRange?
}

/// No acquisition, process lookup, sidecar loading, filesystem writes, or inferred provenance.
public enum ProcessJournalInspector {
    public static let maximumBytes = 32 * 1024 * 1024
    public static let maximumRows = 32 * 602
    public static let maximumLineBytes = 4096 // Includes producer's terminating LF.

    public static func suppliedPlan(_ data: Data) throws -> ProcessSeriesPlan {
        try require(data.count <= 16_384, "supplied plan exceeds 16 KiB")
        var syntax = JournalJSONSyntax(data)
        try syntax.validate()
        let plan = try StrictJSON.decodeExact(ProcessSeriesPlan.self, from: data)
        try plan.validate()
        try require(Set(plan.registrations.map { $0.identity.uid }).count == 1, "supplied plan must use one target UID")
        return plan
    }

    /// Byte/count bounded; library callers supervise execution time. CLI supplies a 30-second watchdog.
    public static func inspect(_ data: Data, suppliedPlanJSON: Data? = nil) throws -> ProcessJournalInspection {
        try require(data.count <= maximumBytes, "journal exceeds 32 MiB; input not inspected")
        let plan = try suppliedPlanJSON.map(suppliedPlan)
        var report = ProcessJournalInspection(inputSHA256: sha256(data), inputBytes: data.count,
            suppliedPlanSHA256: suppliedPlanJSON.map(sha256))
        let bytes = Array(data)
        var state = PrefixState(plan: plan)
        var start = 0, line = 1
        while start < bytes.count {
            let newline = bytes[start...].firstIndex(of: 10)
            let end = newline.map { $0 + 1 } ?? bytes.count
            let range = JournalByteRange(start: start, end: end)
            if newline == nil {
                var kind = "unterminated-final-bytes"
                do {
                    try require(end - start < maximumLineBytes, "final bytes exceed row bound")
                    let entry = try decodeRow(Data(bytes[start..<end]))
                    var trial = state
                    _ = try trial.accept(entry, sequence: report.rows.count)
                    kind = "complete-row-without-LF"
                } catch JournalSyntaxError.incomplete {
                    // EOF inside a syntactically possible JSON prefix is distinct from a bad complete row.
                } catch {
                    report.structuralError = true
                    kind = "invalid-final-bytes"
                    report.diagnostics.append(.init(line: line, bytes: range, code: reason(error)))
                }
                report.tail = .init(line: line, bytes: range, kind: kind)
                break
            }
            do {
                try require(end - start <= maximumLineBytes, "row exceeds 4096 bytes including LF")
                try require(report.rows.count < maximumRows, "journal exceeds row count bound")
                let entry = try decodeRow(Data(bytes[start..<(end - 1)]))
                let issues = try state.accept(entry, sequence: report.rows.count)
                report.runID = entry.runID; report.window = entry.window
                report.rows.append(.init(line: line, bytes: range, sequence: entry.sequence, point: entry.point))
                report.contiguousPrefixBytes = end
                report.diagnostics += issues.map { .init(line: line, bytes: range, code: $0) }
            } catch {
                report.structuralError = true
                report.diagnostics.append(.init(line: line, bytes: range, code: reason(error)))
                if end < bytes.count { report.unexaminedBytes = .init(start: end, end: bytes.count) }
                break
            }
            start = end; line += 1
        }
        if bytes.isEmpty { report.diagnostics.append(.init(line: 1, bytes: .init(start: 0, end: 0), code: "empty journal; no retained rows")) }
        return report
    }

    /// Only a deliberately staged file, never an old dataset, arbitrary path, FIFO, or symlink.
    public static func readStaged(name: String) throws -> Data {
        try require(identifier(name), "invalid staged journal name")
        let parent = open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try require(parent >= 0, "cannot open staging parent")
        defer { close(parent) }
        let fd = openat(parent, "sanjbox-a2-journal-\(geteuid())-\(name).jsonl", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        try require(fd >= 0, "cannot open explicitly staged journal")
        defer { close(fd) }
        func permitted(_ info: stat) -> Bool {
            (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1 &&
            info.st_mode & 0o777 == 0o600 && info.st_size >= 0 && info.st_size <= maximumBytes
        }
        var before = stat()
        try require(fstat(fd, &before) == 0 && permitted(before), "journal type/owner/mode/size/link conflict")
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            try require(count >= 0, "journal read failed")
            if count == 0 { break }
            try require(data.count + count <= maximumBytes, "journal grew beyond byte bound")
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        try require(fstat(fd, &after) == 0 && permitted(after) && before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
            before.st_size == after.st_size && data.count == before.st_size &&
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
            "staged journal changed while read")
        return data
    }

    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func reason(_ error: Error) -> String {
        if let error = error as? InstrumentError { return error.description }
        if let error = error as? JournalSyntaxError { return error == .incomplete ? "incomplete JSON in LF-terminated row" : "invalid JSON syntax, duplicate key, number, or depth" }
        return "invalid row schema, type, unknown key, or null"
    }
    private static func decodeRow(_ data: Data) throws -> ProcessSeriesJournalEntry {
        var syntax = JournalJSONSyntax(data)
        try syntax.validate()
        return try StrictJSON.decodeExact(ProcessSeriesJournalEntry.self, from: data)
    }

    private struct PrefixState {
        var plan: ProcessSeriesPlan?
        var runID: String?
        var window: Window?
        var previous: [Int: Double] = [:]
        var counts: [Int: Int] = [:]
        var targets: [Int: TestProcessIdentity] = [:]
        var observedPIDs: [Int: Int32] = [:]
        var registeredSlots = Set<Int>()
        var priorMismatches: [Int: Set<TestProcessIdentity>] = [:]
        var previousGlobal: Double?
        mutating func accept(_ entry: ProcessSeriesJournalEntry, sequence: Int) throws -> [String] {
            try require(entry.schemaVersion == 1 && identifier(entry.runID), "invalid journal schema or run ID")
            try require(sequence < maximumRows && entry.sequence == sequence, "noncontiguous sequence or row count bound")
            let w = entry.window, p = entry.point
            try require(boundedTime(w.start) && boundedTime(w.end) && (1...600).contains(w.duration), "invalid journal window")
            try require(runID == nil || runID == entry.runID, "journal run ID changed")
            try require(window == nil || window == w, "journal window changed")
            try require((1...32).contains(p.slot) && (counts[p.slot] ?? 0) < 602, "invalid slot or per-slot row count")
            try require(boundedTime(p.readStarted) && boundedTime(p.time) && p.time >= p.readStarted && p.readStarted >= w.start, "invalid point time or pre-window read")
            try require(previous[p.slot].map { p.readStarted > $0 } ?? true, "unordered or overlapping per-slot reads")
            try require(previousGlobal.map { p.readStarted >= $0 } ?? true, "reversed serial journal chronology")
            let binding = plan?.registrations.first { $0.slot == p.slot }
            if let plan {
                try require(plan.runID == entry.runID && abs(plan.seconds - w.duration) <= 0.000001, "supplied plan run or window mismatch")
                try require(binding != nil, "slot absent from supplied plan")
            }
            for identity in [p.before, p.after].compactMap({ $0 }) {
                // Mismatch observations may truthfully show root, foreign UID or real/effective drift.
                try require(identity.pid > 0 && identity.startSeconds > 0 && identity.startMicroseconds < 1_000_000, "invalid observed numeric identity")
                if let pid = binding?.identity.pid ?? observedPIDs[p.slot] {
                    try require(identity.pid == pid, "observed PID differs from selected target")
                }
                try require(!observedPIDs.contains { $0.key != p.slot && $0.value == identity.pid }, "observed target PID reused across slots")
                observedPIDs[p.slot] = identity.pid
            }
            if let code = p.errorCode { try require(code >= 0, "negative errno") }
            if p.state != .sampled { try require(p.physicalFootprintBytes == nil && p.residentBytes == nil, "failure point contains memory metrics") }
            var matchedBefore = false
            switch p.state {
            case .sampled:
                try require(p.before != nil && p.before == p.after && p.errorCode == nil && p.physicalFootprintBytes != nil && p.residentBytes != nil, "inconsistent sampled point")
                try require(p.physicalFootprintBytes! <= 1 << 60 && p.residentBytes! <= 1 << 60, "memory metric exceeds bound")
                matchedBefore = true
            case .notRegistered:
                try require(p.before == nil && p.after == nil && p.errorCode == nil && p.time == p.readStarted && !registeredSlots.contains(p.slot), "inconsistent notRegistered point")
                try require(plan == nil, "notRegistered contradicts supplied fixed plan")
            case .unreadableBefore:
                try require(p.before == nil && p.after == nil && p.errorCode != nil, "inconsistent unreadableBefore point")
            case .identityChangedBefore:
                try require(p.before != nil && p.after == nil && p.errorCode == nil, "inconsistent identityChangedBefore point")
                if let expected = binding?.identity ?? targets[p.slot] { try require(p.before != expected, "identityChangedBefore equals expected identity") }
            case .readFailed:
                try require(p.before != nil && p.before == p.after && p.errorCode != nil, "inconsistent readFailed point")
                matchedBefore = true
            case .unreadableAfter:
                try require(p.before != nil && p.after == nil && p.errorCode != nil, "inconsistent unreadableAfter point")
                matchedBefore = true
            case .identityChangedAfter:
                try require(p.before != nil && p.after != nil && p.before != p.after && p.before!.pid == p.after!.pid, "inconsistent identityChangedAfter point")
                matchedBefore = true // errorCode can retain an earlier rusage failure.
            }
            if matchedBefore, let identity = p.before {
                try identity.validate()
                try require(priorMismatches[p.slot]?.contains(identity) != true, "matched identity contradicts earlier mismatch claim")
                if let expected = binding?.identity ?? targets[p.slot] { try require(identity == expected, "matched-before claim changes selected instance") }
                try require(!targets.contains { $0.key != p.slot && $0.value.pid == identity.pid }, "target PID reused across slots")
                try require(targets.values.allSatisfy { $0.uid == identity.uid }, "matched targets use different UIDs")
                targets[p.slot] = identity
            }
            if p.state != .notRegistered { registeredSlots.insert(p.slot) }
            if p.state == .identityChangedBefore, let identity = p.before { priorMismatches[p.slot, default: []].insert(identity) }
            var issues: [String] = []
            if p.state != .sampled { issues.append("retained failure state: " + p.state.rawValue) }
            if p.time - p.readStarted > 1 { issues.append("process read exceeds one second") }
            if p.time > w.end + 1 { issues.append("sample exceeds acquisition end tolerance") }
            if let last = previous[p.slot], p.readStarted - last > 2 { issues.append("process sampling gap exceeds two seconds") }
            if previous[p.slot] == nil && p.readStarted - w.start > 0.1 { issues.append("missing initial endpoint for slot") }
            previous[p.slot] = p.time; counts[p.slot, default: 0] += 1
            previousGlobal = p.time; runID = entry.runID; window = w
            return issues
        }
    }
}

private enum JournalSyntaxError: Error { case incomplete, invalid }
/// Syntax/prefix recognizer: distinguishes EOF in a possible JSON value from malformed input.
/// Integer fields require integer tokens; no null, nonfinite values, ambiguous keys or deep trees.
private struct JournalJSONSyntax {
    let bytes: [UInt8]
    var index = 0
    init(_ data: Data) { bytes = Array(data) }
    mutating func validate() throws {
        try value(depth: 0, key: nil); space()
        guard index == bytes.count else { throw JournalSyntaxError.invalid }
    }
    mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func peek() throws -> UInt8 { space(); guard index < bytes.count else { throw JournalSyntaxError.incomplete }; return bytes[index] }
    mutating func consume(_ byte: UInt8) throws { guard try peek() == byte else { throw JournalSyntaxError.invalid }; index += 1 }
    mutating func string() throws -> String {
        space(); let start = index; try consume(34)
        while index < bytes.count {
            let b = bytes[index]; index += 1
            if b == 34 {
                guard let text = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else { throw JournalSyntaxError.invalid }
                return text
            }
            if b < 32 { throw JournalSyntaxError.invalid }
            if b == 92 {
                guard index < bytes.count else { throw JournalSyntaxError.incomplete }
                let escaped = bytes[index]; index += 1
                if escaped == 117 {
                    let unit = try unicodeQuad(lowSurrogate: false)
                    if (0xD800...0xDBFF).contains(unit) {
                        try stringByte(92); try stringByte(117)
                        _ = try unicodeQuad(lowSurrogate: true)
                    }
                } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(escaped) { throw JournalSyntaxError.invalid }
            } else if b >= 128 {
                // Validate each available byte now: an absent closing quote must not hide
                // impossible UTF-8 (including overlong scalars, surrogates or > U+10FFFF).
                switch b {
                case 0xC2...0xDF: try continuation()
                case 0xE0: try continuation(0xA0, 0xBF); try continuation()
                case 0xE1...0xEC, 0xEE...0xEF: try continuation(); try continuation()
                case 0xED: try continuation(0x80, 0x9F); try continuation()
                case 0xF0: try continuation(0x90, 0xBF); try continuation(); try continuation()
                case 0xF1...0xF3: try continuation(); try continuation(); try continuation()
                case 0xF4: try continuation(0x80, 0x8F); try continuation(); try continuation()
                default: throw JournalSyntaxError.invalid
                }
            }
        }
        throw JournalSyntaxError.incomplete
    }
    mutating func stringByte(_ expected: UInt8) throws {
        guard index < bytes.count else { throw JournalSyntaxError.incomplete }
        guard bytes[index] == expected else { throw JournalSyntaxError.invalid }
        index += 1
    }
    mutating func continuation(_ lower: UInt8 = 0x80, _ upper: UInt8 = 0xBF) throws {
        guard index < bytes.count else { throw JournalSyntaxError.incomplete }
        guard (lower...upper).contains(bytes[index]) else { throw JournalSyntaxError.invalid }
        index += 1
    }
    mutating func unicodeQuad(lowSurrogate: Bool) throws -> UInt32 {
        var value: UInt32 = 0
        for remaining in (0...3).reversed() {
            guard index < bytes.count else { throw JournalSyntaxError.incomplete }
            let byte = bytes[index], digit: UInt32
            switch byte {
            case 48...57: digit = UInt32(byte - 48)
            case 65...70: digit = UInt32(byte - 65 + 10)
            case 97...102: digit = UInt32(byte - 97 + 10)
            default: throw JournalSyntaxError.invalid
            }
            index += 1; value = value * 16 + digit
            let minimum = value << (4 * remaining)
            let maximum = minimum + (UInt32(1) << (4 * remaining)) - 1
            // Reject an impossible partial escape too, e.g. a standalone \uDC prefix.
            let possible = lowSurrogate ? maximum >= 0xDC00 && minimum <= 0xDFFF : minimum < 0xDC00 || maximum > 0xDFFF
            guard possible else { throw JournalSyntaxError.invalid }
        }
        return value
    }
    mutating func value(depth: Int, key: String?) throws {
        guard depth <= 24 else { throw JournalSyntaxError.invalid }
        switch try peek() {
        case 123:
            index += 1
            if try peek() == 125 { index += 1; return }
            var keys = Set<String>()
            while true {
                let name = try string()
                guard keys.insert(name).inserted else { throw JournalSyntaxError.invalid }
                try consume(58); try value(depth: depth + 1, key: name)
                if try peek() == 125 { index += 1; return }
                try consume(44)
            }
        case 91:
            index += 1
            if try peek() == 93 { index += 1; return }
            while true {
                try value(depth: depth + 1, key: nil)
                if try peek() == 93 { index += 1; return }
                try consume(44)
            }
        case 34: _ = try string()
        case 116: try literal("true")
        case 102: try literal("false")
        case 45, 48...57: try number(key: key)
        default: throw JournalSyntaxError.invalid // Null is not a producer value in either input schema.
        }
    }
    mutating func literal(_ text: String) throws {
        for b in text.utf8 {
            guard index < bytes.count else { throw JournalSyntaxError.incomplete }
            guard bytes[index] == b else { throw JournalSyntaxError.invalid }; index += 1
        }
    }
    mutating func number(key: String?) throws {
        let start = index
        func digit(_ b: UInt8) -> Bool { (48...57).contains(b) }
        if bytes[index] == 45 { index += 1 }
        guard index < bytes.count else { throw JournalSyntaxError.incomplete }
        guard digit(bytes[index]) else { throw JournalSyntaxError.invalid }
        if bytes[index] == 48 { index += 1 }
        else { while index < bytes.count && digit(bytes[index]) { index += 1 } }
        if index < bytes.count && bytes[index] == 46 {
            index += 1
            guard index < bytes.count else { throw JournalSyntaxError.incomplete }
            guard digit(bytes[index]) else { throw JournalSyntaxError.invalid }
            while index < bytes.count && digit(bytes[index]) { index += 1 }
        }
        if index < bytes.count && [101, 69].contains(bytes[index]) {
            index += 1
            if index < bytes.count && [43, 45].contains(bytes[index]) { index += 1 }
            guard index < bytes.count else { throw JournalSyntaxError.incomplete }
            guard digit(bytes[index]) else { throw JournalSyntaxError.invalid }
            while index < bytes.count && digit(bytes[index]) { index += 1 }
        }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let value = Double(token), value.isFinite else { throw JournalSyntaxError.invalid }
        let significand = token.split(whereSeparator: { $0 == "e" || $0 == "E" }).first ?? ""
        guard value != 0 || !significand.utf8.contains(where: { (49...57).contains($0) }) else { throw JournalSyntaxError.invalid }
        if let key, !["start", "end", "readStarted", "time", "seconds"].contains(key) {
            guard token.utf8.allSatisfy({ (48...57).contains($0) }) else { throw JournalSyntaxError.invalid }
        }
    }
}
