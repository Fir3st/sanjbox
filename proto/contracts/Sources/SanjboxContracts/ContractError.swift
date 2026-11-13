import Foundation

/// Stable, machine-readable rejection reason. Codes are part of the v0 contract: callers and the
/// future H6 fuzzer/escape harness branch on `code`, never on the free-form `detail`.
public struct ContractError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: String
    public let detail: String

    public init(_ code: String, _ detail: String) {
        self.code = code
        self.detail = detail
    }

    public var description: String { "\(code): \(detail)" }
}

extension ContractError {
    /// Every code this prototype can emit. Kept in one place so a reviewer can diff the list
    /// against the negative tests.
    public static let codes: Set<String> = [
        "input-too-large", "invalid-json", "trailing-input", "duplicate-key", "nesting-limit",
        "collection-limit", "string-limit", "unknown-field", "missing-field", "invalid-value",
        "invalid-range", "invalid-version", "unknown-message-kind", "invalid-identifier",
        "invalid-policy", "forbidden-transition", "state-invariant", "uid-reuse-before-cleanup",
        "uid-already-assigned", "sequence-violation",
    ]

    static func inputTooLarge(_ detail: String) -> ContractError { .init("input-too-large", detail) }
    static func invalidJSON(_ detail: String) -> ContractError { .init("invalid-json", detail) }
    static func invalidValue(_ path: String) -> ContractError { .init("invalid-value", path) }
    static func invalidRange(_ path: String) -> ContractError { .init("invalid-range", path) }
    static func unknownField(_ path: String) -> ContractError { .init("unknown-field", path) }
    static func missingField(_ path: String) -> ContractError { .init("missing-field", path) }
    static func invalidIdentifier(_ path: String) -> ContractError { .init("invalid-identifier", path) }
}
