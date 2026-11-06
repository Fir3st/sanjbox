import Darwin
import Foundation

/// New wire family. Never feed to the legacy common/C1 C3 decoders.
public struct NetworkEvent: Codable, Sendable {
    public var format = "sanjboxNetworkProvenanceV1"
    public var schemaVersion = 1
    public var sequence = 0
    public var timestamp = Timestamp.now()
    public var kind: String
    public var runID: UUID
    public var flowID: UUID
    public var instanceID: UUID
    public var role: String
    public var scope: ProvenanceScope
    public var pid: Int32 = getpid()
    public var parentPID: Int32 = getppid()
    public var transport: NetworkTransport
    public var family: String
    public var identity: NetworkIdentity?
    public var signature: OwnSignature?
    public var registration: NetworkRegistration?
    public var expectationSHA256: String?
    public var registrationSHA256: String?
    public var target: NetworkEndpoint?
    public var local: NetworkEndpoint?
    public var remote: NetworkEndpoint?
    public var contactID: Int?
    public var bytes: Int?
    public var localKernelAcceptedBytes: Int?
    public var rawFile: String?
    public var rawSHA256: String?
    public var rawTruncated: Bool?
    public var payloadClaims: PayloadClaims?
    public var matchesRegisteredPayload: Bool?
    public var repeatedRegisteredPayload: Bool?
    public var reason: String?
    public var operationFinished: Bool?
    public init(kind: String, registration: NetworkRegistration, role: String, instanceID: UUID) {
        self.kind = kind; runID = registration.flow.runID; flowID = registration.flow.flowID
        self.role = role; self.instanceID = instanceID; scope = registration.scope
        transport = registration.transport; family = registration.endpoint.family
    }
}

/// Descriptor-held, exclusive output. No append/reuse and no cleanup of evidence.
public final class NetworkJournal {
    public let path: String
    public let instanceID = UUID()
    public let registration: NetworkRegistration
    public let role: String
    private var directory: Int32 = -1
    private var log: Int32 = -1
    private var sequence = 0
    public init(registration: NetworkRegistration, expectationData: Data, registrationData: Data, role: String) throws {
        guard ["sender", "receiver"].contains(role) else { throw ProvenanceError("invalid output role") }
        self.registration = registration; self.role = role
        let name = "sanjbox-network-\(registration.flow.runID.uuidString.lowercased())-\(registration.flow.flowID.uuidString.lowercased())-\(role)"
        path = "/private/tmp/" + name
        let parent = open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ProvenanceError("private tmp unavailable") }
        defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == 0, info.st_mode & S_ISVTX != 0,
              mkdirat(parent, name, 0o700) == 0 else { throw ProvenanceError("exclusive run output refused; existing evidence preserved") }
        directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ProvenanceError("new directory unavailable") }
        do {
            guard fstat(directory, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else { throw ProvenanceError("output directory metadata conflict") }
            try rejectACL(directory)
            try save(expectationData, name: "expect.json")
            try save(registrationData, name: "probe.json")
            log = try create("events.jsonl")
            guard fsync(directory) == 0 else { throw ProvenanceError("output directory sync failed") }
        } catch { if log >= 0 { close(log); log = -1 }; close(directory); directory = -1; throw error }
    }
    deinit { if log >= 0 { close(log) }; if directory >= 0 { close(directory) } }
    public func event(_ kind: String) -> NetworkEvent { .init(kind: kind, registration: registration, role: role, instanceID: instanceID) }
    public func append(_ original: NetworkEvent) throws {
        guard sequence < 512 else { throw ProvenanceError("event bound exceeded; incomplete journal") }
        var event = original; sequence += 1; event.sequence = sequence
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(event) + Data([10])
        try writeAll(data, fd: log)
    }
    public func beginRaw(name: String) throws -> NetworkRawWriter {
        guard name.range(of: "^received-[0-9]{1,2}\\.bin$", options: .regularExpression) != nil else { throw ProvenanceError("invalid raw name") }
        let fd = try create(name)
        guard fsync(directory) == 0 else { close(fd); throw ProvenanceError("raw directory sync failed") }
        return NetworkRawWriter(fd: fd)
    }
    public func raw(_ data: Data, name: String) throws -> String {
        guard data.count <= 4096, name.range(of: "^(sent|received-[0-9]{1,2})\\.bin$", options: .regularExpression) != nil else { throw ProvenanceError("raw bound/name invalid") }
        try save(data, name: name); return provenanceDigest(data)
    }
    private func create(_ name: String) throws -> Int32 {
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProvenanceError("exclusive file create failed") }
        do { try rejectACL(fd) } catch { close(fd); throw error }
        return fd
    }
    private func save(_ data: Data, name: String) throws {
        let fd = try create(name); defer { close(fd) }
        try writeAll(data, fd: fd)
        guard fsync(directory) == 0 else { throw ProvenanceError("output directory sync failed") }
    }
    private func writeAll(_ data: Data, fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ProvenanceError("output write failed; incomplete prefix preserved") }
            offset += count
        }
        guard fsync(fd) == 0 else { throw ProvenanceError("output fsync failed; incomplete prefix preserved") }
    }
    private func rejectACL(_ fd: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else { throw ProvenanceError("output ACL unavailable") }; return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_valid(acl) == 0, acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1,
              errno == EINVAL else { throw ProvenanceError("output ACL rejected") }
    }
}

/// Each observed TCP chunk is persisted before the next socket wait. A crash may still fall
/// between the kernel read and this write; a missing terminal always means incomplete evidence.
public final class NetworkRawWriter {
    private let fd: Int32
    private var count = 0
    public private(set) var failed = false
    fileprivate init(fd: Int32) { self.fd = fd }
    deinit { close(fd) }
    public func append(_ data: Data) throws {
        do {
        guard count + data.count <= 4096 else { throw ProvenanceError("raw limit") }
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw ProvenanceError("raw write failed; incomplete prefix preserved") }
            offset += n
        }
        count += data.count
        guard fsync(fd) == 0 else { throw ProvenanceError("raw sync failed; incomplete prefix preserved") }
        } catch { failed = true; throw error }
    }
}
