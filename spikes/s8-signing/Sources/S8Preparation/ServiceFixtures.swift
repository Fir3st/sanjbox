import Darwin
import Dispatch
import Foundation
import OSLog
import SanjboxProbeKit
import Security

/// A closed fixture vocabulary. No caller-selected label, executable, plist or service URL.
public enum FixtureService: String, CaseIterable, Codable, Sendable {
    case loginItem, agent, daemon
    public var identifier: String { "org.sanjbox.s8.fixture." + rawValue }
    public var executable: String {
        switch self { case .loginItem: "S8LoginItem"; case .agent: "S8LaunchAgent"; case .daemon: "S8LaunchDaemon" }
    }
    public var plistName: String { identifier + ".plist" }
    public var permitsUserMutation: Bool { self != .daemon }
    public var launchPlist: [String: Any] {
        ["Label": identifier, "BundleProgram": "Contents/MacOS/" + executable,
         "RunAtLoad": true, "ProcessType": "Background"]
    }
}

public enum FixtureAction: String, CaseIterable, Codable, Sendable { case status, register, unregister }

/// Decisions are pure: denied requests cannot instantiate a mutating SMAppService adapter.
public enum FixtureActionPolicy {
    public static func refusal(service: FixtureService, action: FixtureAction, apply: Bool,
                               identityIssues: [String], adHoc: Bool) -> String? {
        if !identityIssues.isEmpty { return "identity mismatch: invalid observation" }
        if action == .status || !apply { return nil }
        if !service.permitsUserMutation { return "daemon mutation unavailable: trusted host-only approval is not implemented" }
        if adHoc { return "ad-hoc bundles are static preparation only; user signing experiment required" }
        return nil
    }
}

/// Conservative in-memory provenance. Never adopts a registration discovered on launch.
/// A failed/uncertain API result loses ownership; status drift requires manual L2 review.
public struct UserFixtureLifecycle {
    private var owned: [FixtureService: Int] = [:]
    private var pending: [FixtureService: FixtureAction] = [:]
    public init() {}
    public func authorize(_ service: FixtureService, _ action: FixtureAction, status: Int) throws {
        guard service.permitsUserMutation, action != .status, pending[service] == nil else { throw S8Error.refused("not a user mutation") }
        switch action {
        case .register:
            guard status == 0, owned[service] == nil else { throw S8Error.refused("existing/unknown registration; preserve conflict") }
        case .unregister:
            guard let prior = owned[service], prior == status, [1, 2].contains(status) else {
                throw S8Error.refused("no current-session ownership or status changed; manual L2 review required")
            }
        case .status: break
        }
    }
    public mutating func begin(_ service: FixtureService, _ action: FixtureAction, status: Int) throws {
        try authorize(service, action, status: status)
        owned.removeValue(forKey: service)
        pending[service] = action
    }
    public mutating func finish(_ service: FixtureService, _ action: FixtureAction, status: Int, succeeded: Bool) {
        owned.removeValue(forKey: service)
        let matches = pending.removeValue(forKey: service) == action
        if matches && succeeded && action == .register && [1, 2].contains(status) { owned[service] = status }
    }
}

public struct FixtureSigning: Sendable {
    public var issues: [String]
    public var adHoc: Bool
}

/// No identity discovery, certificate reads or trust-network calls. This is a profile check,
/// not proof of Personal Team/self-signed provenance or a broker authorization mechanism.
public func fixtureSelfSigning() -> FixtureSigning {
    var own: SecCode?
    guard SecCodeCopySelf([], &own) == errSecSuccess, let own else {
        return .init(issues: ["own signature unavailable"], adHoc: true)
    }
    let validity = SecCodeCheckValidity(own, .noNetworkAccess, nil)
    var code: SecStaticCode?
    guard SecCodeCopyStaticCode(own, [], &code) == errSecSuccess, let code else {
        return .init(issues: ["own static signature unavailable"], adHoc: true)
    }
    var raw: CFDictionary?
    let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw)
    let info = raw as? [String: Any]
    let flags = (info?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
    let entitlements = SignaturePolicy.entitlementState(dictionary: info?[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
                                                        rawBlobPresent: info?[kSecCodeInfoEntitlements as String] != nil)
    // Reuse the strict runtime/entitlement policy; signing class is reported separately.
    let issues = SignaturePolicy.issues(validity: validity, information: status,
        flags: flags,
        identifier: info?[kSecCodeInfoIdentifier as String] as? String,
        entitlementState: entitlements.0, otherEntitlements: entitlements.1, requireAdHoc: false)
    return .init(issues: issues, adHoc: flags.map { $0 & SecCodeSignatureFlags.adhoc.rawValue != 0 } ?? true)
}

public func fixtureCodeHash() -> String? {
    var own: SecCode?; var code: SecStaticCode?; var raw: CFDictionary?
    guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
          SecCodeCopyStaticCode(own, [], &code) == errSecSuccess, let code,
          SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
          let hash = (raw as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
    return hash.map { String(format: "%02x", $0) }.joined()
}

public func fixtureRunID(bundle: Bundle = .main) throws -> String {
    // A standalone agent/daemon signature does not itself seal the containing Info.plist.
    // Validate that own enclosing bundle before trusting its run ID as correlation metadata.
    var enclosing: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &enclosing) == errSecSuccess,
          let enclosing,
          SecStaticCodeCheckValidity(enclosing, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | SecCSFlags.noNetworkAccess.rawValue), nil) == errSecSuccess else {
        throw S8Error.refused("own containing bundle seal invalid")
    }
    guard let run = bundle.object(forInfoDictionaryKey: "S8FixtureRunID") as? String,
          let uuid = UUID(uuidString: run), uuid.uuidString == run,
          bundle.object(forInfoDictionaryKey: "S8FixtureSchema") as? Int == 1 else {
        throw S8Error.refused("missing canonical sealed fixture run ID/schema")
    }
    return run
}

public struct ServiceEvent: Codable, Sendable {
    public var schema = 1
    public var kind = "s8-service-observation"
    public var runID: String
    public var eventID = UUID().uuidString
    public var service: FixtureService
    public var phase: String
    public var action: FixtureAction?
    public var context: ProbeContext
    public var timestamp = Date()
    public var bootSeconds: Int64?
    public var bootMicroseconds: Int32?
    public var identityIssues: [String]
    public var signatureIssues: [String]
    public var status: Int?
    public var errorDomain: String?
    public var errorCode: Int?
    /// Startup is an observation: a new login/reboot identity must be checked independently
    /// against the preregistered lifecycle oracle. No self-observed expectation is accepted.
    public var validMeasurement = false
    public var codeHash = fixtureCodeHash()
    public var launchCause = "unknown; correlate boot time and audit session with user timeline"

    public init(runID: String, service: FixtureService, phase: String, context: ProbeContext,
                identityIssues: [String] = [], signatureIssues: [String] = []) throws {
        guard UUID(uuidString: runID)?.uuidString == runID,
              ["startup", "status", "intent", "result"].contains(phase) else {
            throw S8Error.refused("invalid event identity or phase")
        }
        self.runID = runID; self.service = service; self.phase = phase; self.context = context
        self.identityIssues = identityIssues; self.signatureIssues = signatureIssues
        var boot = timeval(); var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 {
            bootSeconds = Int64(boot.tv_sec); bootMicroseconds = Int32(boot.tv_usec)
        }
    }
}

/// A new 0700 directory for each bounded event. It never opens a caller-provided path.
/// Snapshot manifest enables conflict-refusing offline cleanup; no production TOCTOU claim.
public enum ServiceEventStore {
    public static let prefix = "/private/tmp/sanjbox-s8-event-"
    public static func write(_ event: ServiceEvent) throws -> String {
        guard UUID(uuidString: event.runID)?.uuidString == event.runID,
              UUID(uuidString: event.eventID)?.uuidString == event.eventID,
              geteuid() != 0, event.context.effectiveUID == geteuid(), event.context.realUID == getuid(),
              event.context.realGID == getgid(), event.context.effectiveGID == getegid(),
              let audit = event.context.audit, audit.sessionID > 0 else {
            throw S8Error.refused("event writer requires own non-root credentials and audit session")
        }
        var current = auditinfo_addr()
        guard getaudit_addr(&current, Int32(MemoryLayout<auditinfo_addr>.size)) == 0,
              current.ai_asid == audit.sessionID, current.ai_auid == audit.auditUID else {
            throw S8Error.refused("event audit session changed")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        guard data.count <= 16_384 else { throw S8Error.refused("event exceeds bound") }
        let path = prefix + UUID().uuidString
        guard mkdir(path, 0o700) == 0 else { throw S8Error.refused("cannot create unique event root") }
        // Print immediately: a partial write is retained, never recursively removed on error.
        FileHandle.standardError.write(Data(("S8 own event root: " + path + "\n").utf8))
        let root = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { throw S8Error.refused("cannot pin event root") }
        defer { close(root) }
        var rs = stat(); var linked = stat()
        guard fstat(root, &rs) == 0, lstat(path, &linked) == 0, rs.st_ino == linked.st_ino,
              rs.st_dev == linked.st_dev, rs.st_uid == geteuid(), rs.st_mode & 0o7777 == 0o700,
              rs.st_flags == 0 else { throw S8Error.refused("event root changed") }
        try requireNoExtendedACL(fd: root)
        func create(_ name: String, _ contents: Data) throws -> stat {
            var currentRoot = stat()
            guard lstat(path, &currentRoot) == 0, currentRoot.st_ino == rs.st_ino,
                  currentRoot.st_dev == rs.st_dev, currentRoot.st_uid == rs.st_uid,
                  currentRoot.st_mode == rs.st_mode, currentRoot.st_flags == 0 else {
                throw S8Error.refused("event root changed before write")
            }
            try requireNoExtendedACL(fd: root)
            let fd = openat(root, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw S8Error.refused("event name conflict") }
            defer { close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0, before.st_uid == geteuid(), before.st_nlink == 1,
                  before.st_mode & 0o7777 == 0o600, before.st_flags == 0 else { throw S8Error.refused("event file metadata") }
            try requireNoExtendedACL(fd: fd)
            try contents.withUnsafeBytes { raw in
                var offset = 0
                while offset < contents.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), contents.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw S8Error.refused("event write failed") }
                    offset += n
                }
            }
            var after = stat(); var nameAfter = stat()
            guard fsync(fd) == 0, fstat(fd, &after) == 0, fstatat(root, name, &nameAfter, AT_SYMLINK_NOFOLLOW) == 0,
                  after.st_dev == before.st_dev, after.st_ino == before.st_ino, after.st_ino == nameAfter.st_ino,
                  after.st_uid == before.st_uid, after.st_gid == before.st_gid, after.st_mode == before.st_mode, after.st_nlink == 1,
                  after.st_flags == 0, after.st_size == contents.count else { throw S8Error.refused("event changed during write") }
            try requireNoExtendedACL(fd: fd)
            return after
        }
        let file = try create("event.json", data)
        let fields: [String: Any] = ["schema": 1, "kind": "s8-event-cleanup", "runID": event.runID,
            "session": audit.sessionID, "ownerUID": rs.st_uid, "ownerGID": rs.st_gid,
            "rootDevice": rs.st_dev, "rootInode": rs.st_ino, "eventInode": file.st_ino,
            "eventSHA256": sha256(data)]
        _ = try create("manifest.json", JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
        guard fsync(root) == 0 else { throw S8Error.refused("event directory sync failed") }
        return path
    }
}

/// Every helper is a one-shot observer. No IPC, input arguments, root writes, registration,
/// shell dispatch, KeepAlive or child supervisor. Success exit also prevents login-item retry storms.
public func runServiceFixture(_ service: FixtureService) {
    DispatchQueue.global().asyncAfter(deadline: .now() + 12) { _exit(0) }
    do {
        let context = try captureIdentity() // First observation, before any fixture file operation.
        guard CommandLine.arguments.count == 1 else { throw S8Error.refused("helper accepts no arguments") }
        let signing = fixtureSelfSigning()
        guard signing.issues.isEmpty else { throw S8Error.refused("helper signing profile invalid") }
        let run = try fixtureRunID()
        let expectedBundle = service == .loginItem ? service.identifier : "org.sanjbox.s8.fixture.host"
        guard Bundle.main.bundleIdentifier == expectedBundle else { throw S8Error.refused("wrong containing bundle") }
        let event = try ServiceEvent(runID: run, service: service, phase: "startup", context: context,
            identityIssues: ["observation only: independently verify expected credentials/session for this lifecycle phase"])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(event)
        guard bytes.count <= 16_384 else { throw S8Error.refused("startup marker exceeds bound") }
        // OS logging owns persistence for the root observer; no caller-controlled path reaches root.
        Logger(subsystem: "org.sanjbox.s8.fixture", category: "startup").notice("\(String(decoding: bytes, as: UTF8.self), privacy: .public)")
        FileHandle.standardOutput.write(bytes + Data([10]))
        if service != .daemon { _ = try ServiceEventStore.write(event) }
    } catch {
        Logger(subsystem: "org.sanjbox.s8.fixture", category: "refusal").error("fixture refused; no valid measurement")
        FileHandle.standardError.write(Data("S8 fixture refused; no valid measurement\n".utf8))
    }
    // Exit zero even on refusal. A missing marker is incomplete evidence, never a successful test.
    exit(0)
}
