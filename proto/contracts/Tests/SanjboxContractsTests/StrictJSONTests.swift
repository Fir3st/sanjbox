import Foundation
import Testing
@testable import SanjboxContracts

@Suite("Přesná celočíselná JSON pole")
struct StrictJSONTests {
    private struct Number: Decodable { let value: UInt64 }

    private func decode(_ token: String) throws -> UInt64 {
        try StrictJSON.decode(Data("{\"value\":\(token)}".utf8),
                              shape: .object(["value": .integer(minimum: 0, maximum: UInt64.max)]),
                              limit: 1024, as: Number.self).value
    }

    @Test func acceptsEveryRelevantUnsignedBoundaryExactly() throws {
        for number: UInt64 in [0, 1, UInt64(UInt32.max), 9_007_199_254_740_991,
                               9_007_199_254_740_992, 9_007_199_254_740_993, UInt64.max - 1, UInt64.max] {
            #expect(try decode(String(number)) == number)
        }
    }

    @Test func rejectsNonIntegerNotationOverflowAndOtherScalarTypes() {
        for token in ["-1", "-0", "0.0", "1e0", "1E+0", "1e-9999", "0.00000000000000000001",
                      "18446744073709551616", "18446744073709551615.0000001",
                      "true", "false", "null", "\"1\""] {
            rejection("invalid-range") { _ = try decode(token) }
        }
    }

    @Test func malformedNumbersStillFailJSONGrammar() {
        for token in ["01", "1.", "1e", "--1"] {
            rejection("invalid-json") { _ = try decode(token) }
        }
    }
}
