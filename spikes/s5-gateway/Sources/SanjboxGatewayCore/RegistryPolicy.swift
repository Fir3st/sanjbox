import CoreFoundation
import CryptoKit
import Foundation

public enum RegistryFailure: Error, Sendable { case configuration, target, metadata, denied, changed, tooLarge, busy }

/// Trusted budgets. D1 transport/listener limits still apply independently.
public struct RegistryLimits: Sendable {
    public let metadataBytes: Int
    public let artifactBytes: Int
    public let files: Int
    public let operations: Int
    public let auditRecords: Int
    public let lifetime: Duration
    public init(metadataBytes: Int = 4_194_304, artifactBytes: Int = 4_194_304,
                files: Int = 10_000, operations: Int = 4, auditRecords: Int = 1024,
                lifetime: Duration = .seconds(90)) throws {
        guard (1...4_194_304).contains(metadataBytes), (1...4_194_304).contains(artifactBytes),
              (1...10_000).contains(files), (1...16).contains(operations),
              (1...10_000).contains(auditRecords), lifetime > .zero, lifetime <= .seconds(120) else {
            throw RegistryFailure.configuration
        }
        self.metadataBytes = metadataBytes; self.artifactBytes = artifactBytes
        self.files = files; self.operations = operations; self.auditRecords = auditRecords; self.lifetime = lifetime
    }
}

func registryMount(_ mount: String) throws -> String {
    guard mount.first == "/", (2...64).contains(mount.utf8.count),
          mount.dropFirst().utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
        throw RegistryFailure.configuration
    }
    return mount
}
func registryOrigin(_ origin: String) throws -> String {
    guard let url = URLComponents(string: origin), let port = url.port, (1...65535).contains(port),
          origin == "http://127.0.0.1:\(port)" else { throw RegistryFailure.configuration }
    return origin
}
func registryHeadersAllowed(_ request: HTTPRequest) -> Bool {
    let forbidden: Set<String> = ["authorization", "proxy-authorization", "cookie", "x-api-key", "api-key",
                                  "range", "if-range", "if-none-match", "if-modified-since", "content-encoding", "expect"]
    return request.headers.keys.allSatisfy { !forbidden.contains($0.lowercased()) }
}
func registryError(_ error: Error) -> HTTPResponse {
    switch error {
    case RegistryFailure.target: return .error(400)
    case RegistryFailure.tooLarge: return .error(413)
    case RegistryFailure.busy: return .error(503, rejection: .capacity)
    case RegistryFailure.denied, RegistryFailure.changed: return .error(403)
    default: return .error(502)
    }
}
func registryJSON(_ data: Data, maximum: Int) throws -> [String: Any] {
    guard data.count <= maximum else { throw RegistryFailure.tooLarge }
    do {
        var scan = StrictJSONScan(data)
        try scan.validate()
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RegistryFailure.metadata }
        return root
    } catch is CancellationError { throw CancellationError() }
    catch NPMFailure.tooLarge { throw RegistryFailure.tooLarge }
    catch { throw RegistryFailure.metadata }
}
func registryMediaType(_ head: UpstreamResponseHead) -> String? {
    head.headers["content-type"]?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
}
func registryDate(_ text: String) -> Date? {
    guard text.utf8.count <= 32,
          text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?Z$"#, options: .regularExpression) != nil else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
    guard let date = formatter.date(from: text), ISO8601DateFormatter().string(from: date).prefix(19) == text.prefix(19) else { return nil }
    // Foundation's formatter may truncate sub-millisecond precision. Parse that
    // portion separately so cooldown never permits an artifact fractionally early.
    let wholeText = String(text.prefix(19)) + "Z"
    guard let whole = ISO8601DateFormatter().date(from: wholeText) else { return nil }
    let fraction = text.contains(".") ? Double("0" + text.dropFirst(19).dropLast()) : 0
    guard let fraction else { return nil }
    return whole.addingTimeInterval(fraction)
}
func registrySHA256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func registryValidDigest(_ text: String) -> Bool {
    text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
func registrySize(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
          number.doubleValue > 0, number.doubleValue <= 4_194_304 else { return nil }
    return number.intValue
}

/// Records a prepared download, never an installation. Owner must export only
/// completed records; pending records deliberately consume bounded capacity.
public struct RegistryDownloadRecord: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case prepared, transportAccepted, sendFailed }
    public let id: UUID
    public let project: String
    public let filename: String
    public let version: String
    public let sha256: String
    public let source: String
    public let uploadedAt: Date
    public let bytes: Int
    public let preparedAt: Date
    public var state: State
}
