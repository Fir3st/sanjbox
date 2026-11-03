import CryptoKit
import Foundation
import SanjboxGatewayCore
import SanjboxGatewayFixtures
import XCTest

func decodedRequest(_ target: String, method: String = "GET", headers: String = "", body: String = "") throws -> HTTPRequest {
    var parser = HTTPRequestDecoder(maximumBodyBytes: 4096)
    let wire = "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1:12345\r\n\(headers)Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
    return try XCTUnwrap(parser.append(Data(wire.utf8)))
}

@MainActor final class RegistryFixtureTests: XCTestCase {
    func testStableCatalogBytesAndIntegrity() throws {
        let first = try RegistryFixtures.standard(), second = try RegistryFixtures.standard()
        XCTAssertEqual(first.artifacts.count, 8)
        for (a, b) in zip(first.artifacts, second.artifacts) {
            XCTAssertEqual(a.archive, b.archive)
            XCTAssertEqual(a.integrity, "sha512-" + Data(SHA512.hash(data: a.archive)).base64EncodedString())
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: a.manifest) as? [String: String])
            XCTAssertEqual(Set(manifest.keys), ["name", "version"])
            XCTAssertEqual(manifest["name"], a.key.name)
            XCTAssertEqual(manifest["version"], a.key.version)
        }
    }

    func testArchiveMatchesIndependentPythonUstarGzipVector() throws {
        // Python stdlib tarfile USTAR, canonical JSON, first 3072 bytes (two files +
        // two end blocks), RFC 1951 stored block and zlib.crc32. See SOURCES.md.
        let artifact = try RegistryFixtures.standard().artifact(PackageKey(name: "fixture-bead", version: "1.0.0"))
        XCTAssertEqual(artifact.archive.count, 3095)
        XCTAssertEqual(SHA256.hash(data: artifact.archive).map { String(format: "%02x", $0) }.joined(),
                       "dce3d65c3651022ed0e18156a097796099d5b5b88eeecb86f60271b21e2e1621")
    }

    func testPackumentTimeBoundaryAndUnknownDate() throws {
        let fixtures = try RegistryFixtures.standard()
        for name in ["fixture-bead", "@fixture/bead"] {
            let data = try fixtures.packument(name: name)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let time = try XCTUnwrap(value["time"] as? [String: String])
            XCTAssertEqual(time["1.0.0"], "2025-12-24T23:59:59Z")
            XCTAssertEqual(time["1.1.0"], "2025-12-25T00:00:00Z")
            XCTAssertEqual(time["1.2.0"], "2025-12-25T00:00:01Z")
            XCTAssertNil(time["1.3.0"])
            let versions = try XCTUnwrap(value["versions"] as? [String: [String: Any]])
            XCTAssertEqual(versions.count, 4, "upstream mock must NOT implement cooldown filtering")
            for artifact in fixtures.artifacts.filter({ $0.key.name == name }) {
                let dist = try XCTUnwrap(versions[artifact.key.version]?["dist"] as? [String: String])
                XCTAssertEqual(dist["tarball"], FixtureOrigin.upstream.value + artifact.key.upstreamTarballTarget)
                XCTAssertEqual(dist["integrity"], artifact.integrity)
            }
        }
    }

    func testScopedTargetsRetainEncodedPackumentAndSeparateTarballNamespace() throws {
        let key = try PackageKey(name: "@fixture/bead", version: "1.2.0")
        XCTAssertEqual(key.upstreamPackumentTarget, "/@fixture%2fbead")
        XCTAssertEqual(key.packumentTarget, "/npm/@fixture%2fbead")
        XCTAssertEqual(key.upstreamTarballTarget, "/@fixture/bead/-/bead-1.2.0.tgz")
        XCTAssertEqual(key.tarballTarget, "/npm/@fixture/bead/-/bead-1.2.0.tgz")
        XCTAssertEqual(try decodedRequest(key.packumentTarget).target, key.packumentTarget)
    }

    func testCustomCatalogLatestUsesNumericVersionTriple() throws {
        let fixtures = try RegistryFixtures(artifacts: ["1.10.0", "1.9.0"].map {
            try SyntheticArtifact(key: PackageKey(name: "bead", version: $0), publishedAt: nil)
        })
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtures.packument(name: "bead")) as? [String: Any])
        XCTAssertEqual((metadata["dist-tags"] as? [String: String])?["latest"], "1.10.0")
    }

    func testLockfilesPinArtifactIdentityURLAndDigest() throws {
        let fixtures = try RegistryFixtures.standard(), origin = try FixtureOrigin.loopback(port: 12345)
        for artifact in fixtures.artifacts {
            let project = try fixtures.project(key: artifact.key, origin: origin)
            let lock = try XCTUnwrap(JSONSerialization.jsonObject(with: project.lockfile) as? [String: Any])
            XCTAssertEqual(lock["lockfileVersion"] as? Int, 3)
            let packages = try XCTUnwrap(lock["packages"] as? [String: [String: Any]])
            XCTAssertEqual(packages.count, 2)
            let entry = try XCTUnwrap(packages["node_modules/" + artifact.key.name])
            XCTAssertEqual(entry["resolved"] as? String, origin.value + artifact.key.tarballTarget)
            XCTAssertEqual(entry["integrity"] as? String, artifact.integrity)
            XCTAssertEqual(entry["version"] as? String, artifact.key.version)
        }
    }

    func testInvalidNamesVersionsDatesAndDuplicateKeysRejected() throws {
        for name in ["", "../bead", "@fixture/../bead", "bead?x", "BEAD", "@/bead", "@fixture/", "a/b", String(repeating: "a", count: 81)] {
            XCTAssertThrowsError(try PackageKey(name: name, version: "1.0.0"), name)
        }
        for version in ["01.0.0", "1.0", "1.0.0-beta", "1.0.0/../../x", "10000.0.0"] {
            XCTAssertThrowsError(try PackageKey(name: "bead", version: version))
        }
        let key = try PackageKey(name: "bead", version: "1.0.0")
        XCTAssertThrowsError(try SyntheticArtifact(key: key, publishedAt: -1))
        let artifact = try SyntheticArtifact(key: key, publishedAt: nil)
        XCTAssertThrowsError(try RegistryFixtures(artifacts: [artifact, artifact]))
        XCTAssertThrowsError(try RegistryFixtures(artifacts: []))
        XCTAssertThrowsError(try RegistryFixtures(artifacts: Array(repeating: artifact, count: 33)))
        XCTAssertThrowsError(try FixtureOrigin.loopback(port: 0))
    }

    func testMockServesUnfilteredArtifactsAndExactPaths() async throws {
        let fixtures = try RegistryFixtures.standard(), mock = try RegistryMock(fixtures: fixtures)
        try await mock.configure(origin: .loopback(port: 12345))
        let router = try TypedRouter(routes: [mock.route])
        for artifact in fixtures.artifacts {
            guard case .response(let reply) = try await router.reply(to: decodedRequest(artifact.key.tarballTarget)) else {
                return XCTFail("not a response")
            }
            XCTAssertEqual(reply.body, artifact.archive)
            XCTAssertEqual(reply.status, 200)
        }
        for target in ["/npm/fixture-bead?redirect=x", "/npm/@fixture%252fbead", "/npm/unknown", "/npm/fixture-bead/-/missing.tgz"] {
            let response = try await mock.reply(to: decodedRequest(target))
            XCTAssertEqual(response.status, 404)
        }
        let transcript = try await mock.transcript()
        XCTAssertEqual(transcript.count, 12)
    }

    func testMockTranscriptOverflowFailsRatherThanDroppingEvidence() async throws {
        let mock = try RegistryMock(fixtures: .standard(), requestLimit: 1)
        try await mock.configure(origin: .loopback(port: 12345))
        _ = try await mock.reply(to: decodedRequest("/npm/fixture-bead"))
        let response = try await mock.reply(to: decodedRequest("/npm/fixture-bead"))
        XCTAssertEqual(response.status, 503)
        do { _ = try await mock.transcript(); XCTFail("truncated transcript accepted") }
        catch { XCTAssertEqual(error as? FixtureFailure, .limit) }
    }

    func testD1AuthAndMethodsRejectBeforeMockHandler() async throws {
        let mock = try RegistryMock(fixtures: .standard())
        try await mock.configure(origin: .loopback(port: 12345))
        let router = try TypedRouter(routes: [mock.route])
        for header in ["Authorization", "Proxy-Authorization", "Cookie", "X-API-Key", "Api-Key"] {
            guard case .response(let response) = try await router.reply(to: decodedRequest("/npm/fixture-bead", headers: "\(header): synthetic\r\n")) else {
                return XCTFail("not response")
            }
            XCTAssertEqual(response.status, 403)
        }
        for method in ["PUT", "DELETE", "POST", "CONNECT"] {
            guard case .response(let response) = try await router.reply(to: decodedRequest("/npm/fixture-bead", method: method)) else {
                return XCTFail("not response")
            }
            XCTAssertEqual(response.status, 403)
        }
        let requests = try await mock.transcript()
        XCTAssertTrue(requests.isEmpty)
    }
}
