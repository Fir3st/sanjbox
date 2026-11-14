import Foundation

public enum CaseMode: String, Codable, Sendable { case synthetic, manual, unsupported }
public enum Probe: String, CaseIterable, Codable, Sendable {
    case foreignRead, hardlinkRead, symlinkRead, startDuringStop, identityReuse
    case deniedLoopback, allowedLoopback, invalidMessage
}
public struct AcceptanceCase: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var requirements: String
    public var gate: String
    public var mode: CaseMode
    public var step: String
    public var oracle: String
    public var reference: String
    public var limitation: String
    public var probe: Probe?
}
public enum HarnessError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let text): text } }
}
public enum Catalog {
    public static func load() throws -> [AcceptanceCase] {
        let url = Bundle.module.url(forResource: "catalog", withExtension: "json")!
        let cases = try JSONDecoder().decode([AcceptanceCase].self, from: Data(contentsOf: url))
        try validate(cases)
        return cases
    }
    public static func validate(_ cases: [AcceptanceCase]) throws {
        guard cases.count == 155, Set(cases.map(\.id)).count == cases.count else {
            throw HarnessError.invalid("catalog must contain 155 unique cases")
        }
        for item in cases {
            guard item.id.range(of: "^[A-Z]+-[0-9]{2}$", options: .regularExpression) != nil,
                  [item.title, item.requirements, item.gate, item.step, item.oracle,
                   item.reference, item.limitation].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  (item.mode == .synthetic) == (item.probe != nil) else {
                throw HarnessError.invalid("invalid catalog entry: \(item.id)")
            }
        }
        guard Set(cases.compactMap(\.probe)) == Set(Probe.allCases),
              cases.compactMap(\.probe).count == Probe.allCases.count else {
            throw HarnessError.invalid("each implemented probe must be mapped exactly once")
        }
    }
}
