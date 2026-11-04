import CryptoKit
import Foundation

// B4 is a protocol prototype. These types cannot authorize a real process or APFS operation.
struct RecoveryFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func recoveryEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(value)
    data.append(10)
    guard data.count <= 64 * 1024 else { throw RecoveryFailure("record exceeds 64 KiB") }
    return data
}

func recoveryDecode<T: Codable>(_ type: T.Type, _ data: Data) throws -> T {
    var preflight = try JSONPreflight(data)
    try preflight.check()
    let value = try JSONDecoder().decode(type, from: data)
    guard try recoveryEncode(value) == data else { throw RecoveryFailure("noncanonical or unknown-field record") }
    return value
}

func recoveryHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

struct RecoveryStamp: Codable, Equatable {
    var device: Int32
    var inode: UInt64
    var uid: UInt32
    var gid: UInt32
    var mode: UInt16
    var birthSeconds: Int64
    var birthNanos: Int64
    var generation: UInt32
    var size: Int64
    var changeSeconds: Int64
    var changeNanos: Int64
}

struct RecoveryReceipt: Codable, Equatable {
    var area: String
    var name: String
    var stamp: RecoveryStamp
    var digest: String
}

struct RecoveryIdentity: Codable {
    var schema = "sanjbox.mock-recovery.identity.v1"
    var transaction: String
    var ownerUID: UInt32
    var bootSession: String
    var rootPath: String
    var root: RecoveryStamp
    var control: RecoveryStamp
    var state: RecoveryStamp
    var manifest: RecoveryReceipt
    var policy: RecoveryReceipt
}

struct RecoveryEvent: Codable {
    var schema = "sanjbox.mock-recovery.event.v1"
    var sequence: Int
    var transaction: String
    var manifestDigest: String
    var previousDigest: String
    var phase: String
    var volume: String?
    var receipts: [RecoveryReceipt]
}

struct RecoveryStep: Equatable {
    var phase: String
    var volume: String?
}

/// The witness is issued and revalidated by the lifecycle adapter, never by a CLI acknowledgement.
/// A native adapter must hold an admission interlock throughout each operation and across helper death.
struct RecoveryQuiescence: Equatable {
    var zoneUID: UInt32
    var generation: UUID
    var wholeUID: Bool
    var admissionBlocked: Bool
    var networkBlocked: Bool
    var fullyOff: Bool
    var descriptorsClosed: Bool
    var mappingsClosed: Bool
}

protocol RecoveryBackend: AnyObject {
    var volumeIDs: [String] { get }
    func acquireQuiescence(restoring: Bool) throws -> RecoveryQuiescence
    func validateQuiescence(_ witness: RecoveryQuiescence, restoring: Bool) throws
    func currentBindings() throws -> [RecoveryReceipt]
    func validate(_ receipts: [RecoveryReceipt]) throws
    func snapshot(_ volume: String, source: RecoveryReceipt) throws -> RecoveryReceipt
    func prepare(_ volume: String, snapshot: RecoveryReceipt) throws -> [RecoveryReceipt]
    func switchBinding(_ volume: String, before: RecoveryReceipt, prepared: [RecoveryReceipt]) throws -> RecoveryReceipt
    func verifyRestored(_ volume: String, snapshot: RecoveryReceipt, prepared: [RecoveryReceipt], binding: RecoveryReceipt) throws
}

struct RecoveryInspection: Codable {
    var schema = "sanjbox.mock-recovery.inspection.v1"
    var phase: String
    var records: Int
    var mockStartAllowed: Bool
    var realStartAllowed = false
    var reason: String
    var evidence = "synthetic-file-backed-mock; no APFS or lifecycle enforcement"
}
