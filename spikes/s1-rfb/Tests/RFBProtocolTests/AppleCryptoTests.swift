import Foundation
import XCTest
import CArdCryptoTestSupport
@testable import RFBProtocol

struct AuthVector: Decodable {
    let name: String
    let generator: UInt16
    let width: Int
    let modulus, privateValue, publicValue, peerValue, peerPrivate, sharedValue: String
    let padding, username, password, plaintext, md5, response: String
    var challenge: AppleDHChallenge { AppleDHChallenge(generator: generator, modulus: unhex(modulus), serverPublicKey: unhex(peerValue)) }
}

func unhex(_ value: String) -> [UInt8] {
    let ascii = Array(value.filter { !$0.isWhitespace }.utf8)
    precondition(ascii.count % 2 == 0)
    return stride(from: 0, to: ascii.count, by: 2).map {
        UInt8(String(bytes: ascii[$0..<$0+2], encoding: .utf8)!, radix: 16)!
    }
}

enum AuthVectors {
    static func all() throws -> [AuthVector] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "type30-vectors", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([AuthVector].self, from: Data(contentsOf: url))
    }
    static func small() throws -> AuthVector { try XCTUnwrap(all().first { $0.name == "non-named-rfc2409-leading-zero" }) }
    static func execute(_ v: AuthVector, modulus: [UInt8]? = nil, peer: [UInt8]? = nil,
                        generator: UInt16? = nil, failStage: Int32 = 0,
                        privateValue: [UInt8]? = nil, publicValue: [UInt8]? = nil) -> (Int32, [UInt8], [UInt8]) {
        let user = Array(v.username.utf8.prefix(63)), password = Array(v.password.utf8.prefix(63))
        var output = [UInt8](repeating: 0xA5, count: 128 + v.width)
        var shared = [UInt8](repeating: 0, count: v.width)
        let result = ard_test_response(generator ?? v.generator, modulus ?? unhex(v.modulus),
            peer ?? unhex(v.peerValue), v.width, user, user.count, password, password.count,
            privateValue ?? unhex(v.privateValue), publicValue ?? unhex(v.publicValue),
            unhex(v.padding), &output, &shared, failStage)
        return (result, output, shared)
    }
}

final class AppleCryptoTests: XCTestCase {
    func testIndependentWholeResponseAndDHKnownAnswers() throws {
        for vector in try AuthVectors.all() {
            let (result, output, shared) = AuthVectors.execute(vector)
            XCTAssertEqual(result, 0, vector.name)
            XCTAssertEqual(output, unhex(vector.response), vector.name)
            XCTAssertEqual(shared, unhex(vector.sharedValue), vector.name)
            XCTAssertEqual(Array(output.dropFirst(128)), unhex(vector.publicValue), vector.name)
            var digest = [UInt8](repeating: 0, count: 16)
            XCTAssertEqual(ard_test_digest(shared, shared.count, &digest), 1)
            XCTAssertEqual(digest, unhex(vector.md5), vector.name)
        }
    }

    func testPublishedDigestKnownAnswers() {
        for (input, expected) in [("", "d41d8cd98f00b204e9800998ecf8427e"),
                                  ("a", "0cc175b9c0f1b6a831c399e269772661"),
                                  ("abc", "900150983cd24fb0d6963f7d28e17f72"),
                                  ("message digest", "f96b697d7cb7938d525a2f31aaf161d0")] {
            var digest = [UInt8](repeating: 0, count: 16)
            XCTAssertEqual(ard_test_digest(Array(input.utf8), input.utf8.count, &digest), 1)
            XCTAssertEqual(digest, unhex(expected))
        }
    }

    func testExplicitNullPointersForEmptyCredentialFields() throws {
        let v = try XCTUnwrap(AuthVectors.all().first { $0.username.isEmpty && $0.password.isEmpty })
        var output = [UInt8](repeating: 0xA5, count: 128 + v.width)
        var shared = [UInt8](repeating: 0, count: v.width)
        let code = ard_test_response(v.generator, unhex(v.modulus), unhex(v.peerValue), v.width,
            nil, 0, nil, 0, unhex(v.privateValue), unhex(v.publicValue), unhex(v.padding),
            &output, &shared, 0)
        XCTAssertEqual(code, 0)
        XCTAssertEqual(output, unhex(v.response))
        XCTAssertEqual(shared, unhex(v.sharedValue))
    }

    func testPublishedAES128ECBNoPaddingKnownAnswer() {
        let key = unhex("2b7e151628aed2a6abf7158809cf4f3c")
        let block = unhex("6bc1bee22e409f96e93d7e117393172a ae2d8a571e03ac9c9eb76fac45af8e51 30c81c46a35ce411e5fbc1191a0a52ef f69f2445df4f9b17ad2b417be66c3710")
        let expected = unhex("3ad77bb40d7a3660a89ecaf32466ef97 f5d3d58503b9699de785895a96fdbaaf 43b1cd7f598ece23881b00e3ed030688 7b0c785e27e8ad3f8223207104725dd4")
        var output = [UInt8](repeating: 0, count: 128)
        XCTAssertEqual(ard_test_encrypt(key, block + block, &output), 1)
        XCTAssertEqual(output, expected + expected)
    }

    func testSuppliedNonNamedParametersReallyUseNonNamedPath() throws {
        for vector in try AuthVectors.all() {
            XCTAssertEqual(ard_test_has_named_group(unhex(vector.modulus), vector.width, vector.generator),
                           vector.name.hasPrefix("non-named") ? 0 : 1, vector.name)
        }
    }

    func testOriginalWireWidthControlsLeadingZeroHashing() throws {
        let vectors = try AuthVectors.all()
        let a = try AuthVectors.small()
        let b = try XCTUnwrap(vectors.first { $0.width == 129 })
        XCTAssertEqual(unhex(b.modulus), [0] + unhex(a.modulus))
        XCTAssertEqual(unhex(b.sharedValue), [0] + unhex(a.sharedValue))
        XCTAssertNotEqual(a.md5, b.md5)
        XCTAssertEqual(unhex(a.publicValue).dropLast().filter { $0 != 0 }.count, 0)
        XCTAssertEqual(unhex(a.publicValue).last, 4)
    }

    func testCredentialBytesIncludingEmbeddedNULMatchIndependentVectors() throws {
        for v in try AuthVectors.all() {
            let (_, response, shared) = AuthVectors.execute(v)
            var plaintext = [UInt8](repeating: 0, count: 128)
            XCTAssertEqual(ard_oracle_decrypt(shared, v.width, response, &plaintext), 1)
            XCTAssertEqual(plaintext, unhex(v.plaintext), v.name)
        }
        let utf8 = try XCTUnwrap(AuthVectors.all().first { $0.name.contains("utf8") })
        XCTAssertEqual(unhex(utf8.plaintext)[62], 0xC3) // deliberate split of é's UTF-8
        XCTAssertEqual(Array(unhex(utf8.plaintext)[64..<71]), Array("a\0after".utf8))
    }

    func testCompositeAndNonSafePrimeParametersFailClosed() throws {
        let v = try AuthVectors.small()
        var even = unhex(v.modulus); even[even.count - 1] = 0xFE
        var small = unhex(v.modulus); small[0] = 0
        // RFC 5114 §2.1 prime, with a 160-bit subgroup: not a safe prime.
        let nonSafe = unhex("B10B8F96 A080E01D DE92DE5E AE5D54EC 52C99FBC FB06A3C6 9A6A9DCA 52D23B61 6073E286 75A23D18 9838EF1E 2EE652C0 13ECB4AE A9061123 24975C3C D49B83BF ACCBDD7D 90C4BD70 98488E9C 219A7372 4EFFD6FA E5644738 FAA31A4F F55BCCC0 A151AF5F 0DC8B4BD 45BF37DF 365C1A65 E68CFDA7 6D4DA708 DF1FB2BC 2E4A4371")
        for modulus in [even, small, nonSafe, [UInt8](repeating: 0xFF, count: 128)] {
            let (result, response, shared) = AuthVectors.execute(v, modulus: modulus)
            XCTAssertEqual(result, 2)
            XCTAssertTrue(response.allSatisfy { $0 == 0 })
            XCTAssertTrue(shared.allSatisfy { $0 == 0 })
        }
    }

    func testPeerRangeAndGeneratorBoundsFailClosed() throws {
        let v = try AuthVectors.small()
        let p = unhex(v.modulus)
        var one = [UInt8](repeating: 0, count: v.width); one[v.width - 1] = 1
        var pMinusOne = p; pMinusOne[pMinusOne.count - 1] -= 1
        for peer in [[UInt8](repeating: 0, count: v.width), one, pMinusOne, p] {
            let (result, response, _) = AuthVectors.execute(v, peer: peer)
            XCTAssertEqual(result, 3)
            XCTAssertTrue(response.allSatisfy { $0 == 0 })
        }
        for generator: UInt16 in [0, 1] {
            let (result, response, _) = AuthVectors.execute(v, generator: generator)
            XCTAssertEqual(result, 1)
            XCTAssertTrue(response.allSatisfy { $0 == 0 })
        }
    }

    func testBackendFailuresNeverReleasePartialOutput() throws {
        let v = try AuthVectors.small()
        for stage: Int32 in 1...4 {
            let (result, response, shared) = AuthVectors.execute(v, failStage: stage)
            XCTAssertEqual(result, 4)
            XCTAssertTrue(response.allSatisfy { $0 == 0 })
            XCTAssertTrue(shared.allSatisfy { $0 == 0 })
        }
    }
}
