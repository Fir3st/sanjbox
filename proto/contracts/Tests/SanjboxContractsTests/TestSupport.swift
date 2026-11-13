import Foundation
import Testing
@testable import SanjboxContracts

// Mocks/fixtures only. Every value here is synthetic: no real user, UID, volume, policy or network
// destination is touched or looked up. Bytes are assembled in memory, nothing is written to disk.

/// Asserts that `body` is rejected with exactly `code`, and that it is rejected at all.
func rejection(_ code: String, sourceLocation: SourceLocation = #_sourceLocation,
               _ body: () throws -> Void) {
    do {
        try body()
        Issue.record("expected rejection '\(code)', but the call succeeded", sourceLocation: sourceLocation)
    } catch let error as ContractError {
        #expect(error.code == code, "expected '\(code)', got '\(error)'", sourceLocation: sourceLocation)
    } catch {
        Issue.record("unexpected error type: \(error)", sourceLocation: sourceLocation)
    }
}

func envelopeJSON(kind: String, body: String, version: Int = 1, extra: String = "") -> Data {
    let base64 = Data(body.utf8).base64EncodedString()
    let suffix = extra.isEmpty ? "" : ",\(extra)"
    return Data("{\"version\":\(version),\"kind\":\"\(kind)\",\"body\":\"\(base64)\"\(suffix)}".utf8)
}

func zoneRefJSON(_ zoneID: String) -> String { "{\"zoneID\":\"\(zoneID)\"}" }

func validPolicy(zoneID: String = "a1b2") -> NetworkPolicy {
    NetworkPolicy(zoneID: zoneID, gates: [
        TypedGate(id: "npm-edge", type: .npm, upstream: "registry.npmjs.org"),
        TypedGate(id: "models", type: .modelAPI, upstream: "api.example.com", methods: ["POST"],
                  requestBytesLimit: 262_144, responseBytesLimit: 1_048_576),
    ])
}

func auditRecord(sequence: UInt64, zoneID: String = "a1b2", action: AuditAction = .zoneCreated,
                 detail: String? = nil) -> AuditRecord {
    AuditRecord(sequence: sequence, timestampUTC: "2026-11-07T12:34:56.789Z", zoneID: zoneID,
                actorUID: 4501, action: action, outcome: .allowed, detail: detail)
}

func jsonObject(_ fields: [(String, String)]) -> String {
    "{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
}
