import Foundation
import Testing
@testable import SanjboxGatewayCore

private func brewMetadata(extraDates: Bool = false) throws -> Data {
    let digest = String(repeating: "a", count: 64)
    var file: [String: Any] = ["url": "https://ghcr.io/v2/homebrew/core/fixture/blobs/sha256:" + digest, "sha256": digest]
    var root: [String: Any] = ["name": "fixture", "tap": "homebrew/core", "versions": ["stable": "1.0.0"],
        "generated_date": "2000-01-01", "tap_git_head": String(repeating: "b", count: 40)]
    if extraDates {
        file["upload-time"] = "2000-01-01T00:00:00Z"
        file["created"] = "2000-01-01T00:00:00Z"
        root["published_at"] = "2000-01-01T00:00:00Z"
    }
    root["bottle"] = ["stable": ["files": ["arm64_tahoe": file]]]
    return try JSONSerialization.data(withJSONObject: root)
}

@Test func homebrewKnownDigestNeverSubstitutesForArtifactPublicationTime() throws {
    for extraDates in [false, true] {
        let report = try HomebrewMetadataAssessment.inspect(brewMetadata(extraDates: extraDates), formula: "fixture")
        #expect(report.bottles == 1 && report.reason == .missingArtifactPublicationTime && !report.artifactCooldownSupported)
    }
    var root = try JSONSerialization.jsonObject(with: brewMetadata()) as! [String: Any]
    root["bottle"] = ["stable": ["files": ["arm64_tahoe": ["url": "https://evil.example/bottle.tar.gz", "sha256": String(repeating: "a", count: 64)]]]]
    let report = try HomebrewMetadataAssessment.inspect(JSONSerialization.data(withJSONObject: root), formula: "fixture")
    #expect(report.reason == .unsupportedBottleIdentity && !report.artifactCooldownSupported)
    root["tap"] = "other/tap"
    #expect(throws: Error.self) { try HomebrewMetadataAssessment.inspect(JSONSerialization.data(withJSONObject: root), formula: "fixture") }
}

@Test func homebrewDiagnosticAndAllBottleCatalogCaskPathsStayClosed() async throws {
    let metadata = try brewMetadata(extraDates: true)
    let backend = D5Backend { _, request, _ in
        #expect(request.target == "/api/formula/fixture.json")
        return D5Wire(type: "application/json", body: metadata)
    }
    let handler = try HomebrewGateway(registryHostname: "brew.example", upstream: d5Client(backend))
    let response = try await handler.response(to: d5Request("/brew/api/formula/fixture.json"))
    #expect(response.status == 403)
    #expect(String(decoding: response.body, as: UTF8.self).contains("artifact_publication_time_unverified"))
    #expect(!String(decoding: response.body, as: UTF8.self).contains("https://"))
    for target in ["/brew/bottles/fixture/blobs/sha256:aaa", "/brew/bottles/fixture/manifests/1.0.0", "/brew/api/formula.jws.json",
                   "/brew/api/formula.json", "/brew/api/cask/fixture.json", "/brew/api/formula/../x.json",
                   "/brew/api/formula/%66ixture.json", "/brew/https://evil.example/source.tar.gz"] {
        #expect(try await handler.response(to: d5Request(target)).status != 200)
    }
    #expect(try await handler.response(to: d5Request("/brew/api/formula/fixture.json", headers: ["Authorization": "synthetic"])).status == 403)
    #expect(backend.calls.count == 1)
}

@Test func homebrewMalformedMissingOrRedirectedMetadataCannotEnableDownload() async throws {
    for wire in [D5Wire(type: "application/json", body: Data("{}".utf8)),
                 D5Wire(status: 302, type: "application/json", headers: ["Location": "https://brew.example/other"], body: Data()),
                 D5Wire(type: "text/html", body: try brewMetadata())] {
        let backend = D5Backend { _, _, _ in wire }
        let handler = try HomebrewGateway(registryHostname: "brew.example", upstream: d5Client(backend))
        #expect(try await handler.response(to: d5Request("/brew/api/formula/fixture.json")).status == 502)
        #expect(backend.calls.count == 1)
    }
}

private func gitHandler(_ backend: D5Backend, push: Bool = true, bytes: Int = 1_048_576,
                        limits: RegistryLimits = try! RegistryLimits()) throws -> GitGateway {
    GitGateway(configuration: try GitConfiguration(hostname: "git.example", repositoryPath: "/owner/fixture.git", allowPush: push,
        maximumRequestBytes: bytes, limits: limits), upstream: d5Client(backend))
}
private let gitDiscovery = "/git/project.git/info/refs?service=git-upload-pack"
private let gitPush = "/git/project.git/git-receive-pack"

@Test func gitOnlyExactProjectServicesReachFixedUpstreamWithoutClientHeaders() async throws {
    let backend = D5Backend { host, request, _ in
        #expect(host == "git.example")
        #expect(request.target.hasPrefix("/owner/fixture.git/"))
        #expect(request.headers["x-client-canary"] == nil && request.headers["authorization"] == nil && request.headers["git-protocol"] == nil)
        let service = request.target.contains("git-receive-pack") ? "git-receive-pack" : "git-upload-pack"
        return D5Wire(type: "application/x-\(service)-" + (request.method == "GET" ? "advertisement" : "result"), body: Data("0000".utf8))
    }
    let handler = try gitHandler(backend)
    for service in ["git-upload-pack", "git-receive-pack"] {
        #expect(try await handler.response(to: d5Request("/git/project.git/info/refs?service=" + service)).status == 200)
        #expect(try await handler.response(to: d5Request("/git/project.git/" + service, method: "POST",
            headers: ["content-type": "application/x-\(service)-request", "x-client-canary": "synthetic"], body: Data("0000".utf8))).status == 200)
    }
    #expect(backend.calls.count == 4)
}

@Test func gitOtherRepositoryTraversalEncodingQueryAndProtocolV2NeverDial() async throws {
    let backend = D5Backend { _, _, _ in Issue.record("Denied request reached upstream"); return D5Wire(body: Data()) }
    let handler = try gitHandler(backend)
    for target in ["/git/other.git/info/refs?service=git-upload-pack", "/git/project.git/../other.git/git-receive-pack",
                   "/git/project.git/%2e%2e/other.git/git-receive-pack", "/git/%70roject.git/git-receive-pack",
                   "/git/project.git%2fgit-receive-pack", "/git//project.git/git-receive-pack", gitDiscovery + "&x=1",
                   gitDiscovery + "&service=git-receive-pack", "/git/project.git/info/refs?service=git-upload-archive",
                   "/git/project.git/objects/info/alternates", "/git/project.git/info/lfs/objects/batch",
                   "/git/project.git/modules/other.git/info/refs?service=git-upload-pack", "https://evil.example/repo.git"] {
        #expect(try await handler.response(to: d5Request(target)).status == 400)
    }
    for header in ["authorization", "Proxy-Authorization", "cookie", "range", "content-encoding", "Git-Protocol"] {
        #expect(try await handler.response(to: d5Request(gitDiscovery, headers: [header: "synthetic"])).status == 403)
    }
    #expect(backend.calls.isEmpty)
}

@Test func gitReadOnlyWrongMethodContentTypeBodyAndSizeFailBeforeNetwork() async throws {
    let backend = D5Backend { _, _, _ in Issue.record("Denied request reached upstream"); return D5Wire(body: Data()) }
    let handler = try gitHandler(backend, bytes: 4)
    #expect(try await handler.response(to: d5Request(gitDiscovery, method: "POST")).status == 403)
    #expect(try await handler.response(to: d5Request(gitDiscovery, body: Data([0]))).status == 403)
    #expect(try await handler.response(to: d5Request(gitPush)).status == 403)
    for headers in [[:], ["content-type": "text/plain"], ["content-type": "application/x-git-receive-pack-request; charset=utf8"],
                    ["content-type": "application/x-git-receive-pack-request", "Content-Type": "application/x-git-receive-pack-request"]] {
        #expect(try await handler.response(to: d5Request(gitPush, method: "POST", headers: headers, body: Data("0000".utf8))).status == 403)
    }
    #expect(try await handler.response(to: d5Request(gitPush, method: "POST", headers: ["content-type": "application/x-git-receive-pack-request"], body: Data(repeating: 0, count: 5))).status == 413)
    let readOnly = try gitHandler(backend, push: false)
    #expect(try await readOnly.response(to: d5Request("/git/project.git/info/refs?service=git-receive-pack")).status == 403)
    #expect(try await readOnly.response(to: d5Request(gitPush, method: "POST", headers: ["content-type": "application/x-git-receive-pack-request"], body: Data("0000".utf8))).status == 403)
    #expect(backend.calls.isEmpty)
}

@Test func gitRedirectAuthDumbHTTPAndOversizedResponseNeverEscape() async throws {
    for status in [301, 302, 303, 307, 308, 401, 403] {
        let backend = D5Backend { _, _, _ in D5Wire(status: status, type: "application/x-git-upload-pack-advertisement",
            headers: ["Location": "https://git.example/other.git", "WWW-Authenticate": "Basic realm=synthetic"], body: Data("0000".utf8)) }
        let response = try await gitHandler(backend).response(to: d5Request(gitDiscovery))
        #expect(response.status == 403 && !String(decoding: response.body, as: UTF8.self).contains("synthetic"))
        #expect(backend.calls.count == 1)
    }
    let dumb = D5Backend { _, _, _ in D5Wire(type: "text/plain", body: Data("refs/heads/main".utf8)) }
    #expect(try await gitHandler(dumb).response(to: d5Request(gitDiscovery)).status == 403)
    let large = D5Backend { _, _, _ in D5Wire(type: "application/x-git-upload-pack-advertisement", body: Data("0000".utf8)) }
    #expect(try await gitHandler(large, limits: RegistryLimits(artifactBytes: 3)).response(to: d5Request(gitDiscovery)).status == 413)
    for path in ["/owner/../other.git", "/owner/%66ixture.git", "https://evil.example/fixture.git", "/owner//fixture.git", "/owner/fixture.git?x=1"] {
        #expect(throws: Error.self) { try GitConfiguration(hostname: "git.example", repositoryPath: path) }
    }
}
