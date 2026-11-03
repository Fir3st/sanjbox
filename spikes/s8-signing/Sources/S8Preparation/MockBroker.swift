import Foundation

/// An intentionally made-up fixed wire format for policy preparation. NOT XPC/Contracts.
/// No bytes in a request can provide identity, paths, signatures, or actual Mach rights.
public enum MockWire {
    public static let maximumBytes = 40
    public static func request(opcode: UInt8 = 1, zone: UInt32 = 3, window: UInt32 = 9, sequence: UInt64 = 1) -> Data {
        var bytes: [UInt8] = [0x53, 0x38, 0x4d, 0x31, 1, opcode, 0, 0]
        bytes += be(zone); bytes += be(window); bytes += be(sequence)
        bytes += be(UInt32(opcode == 2 ? 8 : 0)); bytes += be(UInt32(0)) // no global surface ID
        if opcode == 2 { bytes += [1, 0, 0, 0, 0, 20, 0, 30] } // bounded toy input payload
        return Data(bytes)
    }
    private static func be<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        (0..<MemoryLayout<T>.size).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
}

public struct MockPeer: Sendable {
    public enum Signature: Sendable { case approvedFixture, invalid, unknown, adHoc }
    public enum Role: Sendable { case sessionAgent, hostProxy }
    public var uid: UInt32 = 601
    public var auditSessionID: Int32? = 41
    public var signature: Signature = .approvedFixture
    public var role: Role = .sessionAgent
    public var generation: UInt32 = 1
    public init() {}
}

/// This value is a mock oracle input, NOT a Mach port or evidence of port ownership.
public struct MockRight: Sendable {
    public var zone: UInt32 = 3
    public var window: UInt32 = 9
    public var generation: UInt32 = 1
    public var isSendRight = true
    public init() {}
}

public enum MockDecision: String, Codable, Sendable { case accepted, malformed, identity, capability, replay, exhausted }

public struct MockBroker: Sendable {
    public var enabled = true
    public var generation: UInt32 = 1
    public private(set) var accepted = 0
    public private(set) var lastSequence: UInt64 = 0
    public init() {}

    public mutating func evaluate(_ data: Data, peer: MockPeer, right: MockRight?) -> MockDecision {
        guard data.count == 32 || data.count == 40 else { return .malformed }
        let b = Array(data) // allocation only after maximum bound
        func integer(_ offset: Int, _ count: Int) -> UInt64 {
            b[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        guard Array(b[0..<4]) == [0x53, 0x38, 0x4d, 0x31], b[4] == 1,
              b[6] == 0, b[7] == 0, integer(8, 4) == 3, integer(12, 4) == 9,
              integer(28, 4) == 0 else { return .malformed }
        let sequence = integer(16, 8)
        let opcode = b[5]
        guard (opcode == 1 && data.count == 32 && integer(24, 4) == 0) ||
              (opcode == 2 && data.count == 40 && integer(24, 4) == 8 && b[32] == 1 &&
               b[33] == 0 && b[34] == 0 && b[35] == 0 && integer(36, 2) < 4096 && integer(38, 2) < 4096)
        else { return .malformed }
        guard enabled, peer.signature == .approvedFixture, peer.generation == generation else { return .identity }
        if opcode == 1 {
            guard peer.uid == 601, peer.auditSessionID == 41, peer.role == .sessionAgent else { return .identity }
            guard let right, right.isSendRight, right.zone == 3, right.window == 9, right.generation == generation else { return .capability }
        } else {
            guard peer.uid == 501, peer.auditSessionID == 31, peer.role == .hostProxy else { return .identity }
            guard right == nil else { return .capability }
        }
        guard sequence > lastSequence, sequence != UInt64.max else { return .replay }
        guard accepted < 64 else { return .exhausted }
        lastSequence = sequence; accepted += 1
        return .accepted
    }
}

public struct FuzzReport: Encodable, Sendable {
    public let kind = "mock-only-not-XPC"
    public var iterations: Int
    public var seed: UInt64
    public var positiveControls: Int
    public var negativeCases: Int
    public var unexpectedAccepts: Int
    public var corpusSHA256: String
    public var failures: [String]
}

public enum MockFuzzer {
    public static func run(iterations: Int, seed: UInt64 = 0x5338) throws -> FuzzReport {
        guard (1...10_000).contains(iterations), seed != 0 else { throw S8Error.refused("fuzz bounds: 1...10000, nonzero seed") }
        var state = seed; var corpus = Data(); var failures: [String] = []
        var controls = 0; var negative = 0; var unexpected = 0
        func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
        func positiveControls() {
            var broker = MockBroker()
            if broker.evaluate(MockWire.request(), peer: MockPeer(), right: MockRight()) == .accepted { controls += 1 }
            else { failures.append("frame positive control") }
            var peer = MockPeer(); peer.uid = 501; peer.auditSessionID = 31; peer.role = .hostProxy
            if broker.evaluate(MockWire.request(opcode: 2, sequence: 2), peer: peer, right: nil) == .accepted { controls += 1 }
            else { failures.append("input positive control") }
        }
        positiveControls()
        for index in 0..<iterations {
            var request = MockWire.request()
            var peer = MockPeer(); var right: MockRight? = MockRight(); var broker = MockBroker()
            let variant = index % 16
            let random = next()
            switch variant {
            case 0: request[6] = UInt8(random % 255 + 1) // reserved field always invalid
            case 1: request = request.prefix(Int(random % 32))
            case 2: request.append(contentsOf: [UInt8](repeating: 0, count: 41))
            case 3: request[5] = UInt8(random % 253 + 3)
            case 4: request[31] = 1 // global IOSurface identifier never accepted
            case 5: peer.auditSessionID = nil
            case 6: peer.auditSessionID = 42
            case 7: peer.uid = 602
            case 8: peer.signature = random & 1 == 0 ? .unknown : .adHoc
            case 9: peer.signature = .invalid
            case 10: right = nil
            case 11: right?.zone = 4
            case 12: right?.isSendRight = false
            case 13: broker.generation = 2 // revocation/stale connection, no actual race exercised
            case 14: request = Data("../../outside\u{0}/absolute/path".utf8)
            default: broker.enabled = false
            }
            // Stream is at most 730 KiB (10000 * 73); records are length-prefixed for provenance.
            corpus.append(UInt8(request.count)); corpus.append(request); corpus.append(UInt8(variant))
            negative += 1
            if broker.evaluate(request, peer: peer, right: right) == .accepted {
                unexpected += 1
                if failures.count < 16 { failures.append("unexpected mock acceptance at \(index), variant \(variant)") }
            }
        }
        positiveControls()
        return .init(iterations: iterations, seed: seed, positiveControls: controls, negativeCases: negative,
                     unexpectedAccepts: unexpected, corpusSHA256: sha256(corpus), failures: failures)
    }
}
