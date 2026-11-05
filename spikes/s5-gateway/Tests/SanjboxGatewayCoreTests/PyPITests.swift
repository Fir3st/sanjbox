import Foundation
import Testing
@testable import SanjboxGatewayCore

@Test func pypiFiltersPerFileUploadTimesAndReconstructsJSON() async throws {
    var old = d5File(); old["core-metadata"] = ["sha256": String(repeating: "a", count: 64)]
    old["provenance"] = "https://evil.example/metadata"
    var yanked = d5File(filename: "fixture-0.1.tar.gz"); yanked["yanked"] = "retracted"
    let metadata = try d5Index(files: [old, yanked,
        d5File(filename: "fixture-2.0.tar.gz", time: d5ISO(d5Now.addingTimeInterval(-3599))),
        d5File(filename: "fixture-3.0.tar.gz", time: nil)], extras: ["versions": ["1.0", "2.0", "3.0"], "_links": ["next": "https://evil.example/"]])
    let backend = try d5DefaultBackend(metadata)
    let response = try await d5PyPI(backend).response(to: d5Request("/pypi/simple/fixture/"))
    #expect(response.status == 200 && response.contentType == "application/vnd.pypi.simple.v1+json")
    let root = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
    let files = root["files"] as! [[String: Any]]
    #expect(files.count == 1)
    #expect(files[0]["url"] as? String == "http://127.0.0.1:8765" + d5FileTarget)
    #expect(Set(root.keys) == ["meta", "name", "files"])
    #expect(files[0]["core-metadata"] == nil && files[0]["provenance"] == nil)
    #expect(try PyPIName("Some__Package.Name").value == "some-package-name")
    #expect(backend.calls[0].1.headers["accept"] == "application/vnd.pypi.simple.v1+json")
}

@Test func pypiDirectFileRequiresFreshMetadataBeforeAndAfterEveryDownload() async throws {
    let backend = try d5DefaultBackend(); let handler = try d5PyPI(backend)
    for _ in 0..<2 {
        let response = try await handler.response(to: d5Request(d5FileTarget, headers: ["x-untrusted": "never-forward"]))
        #expect(response.status == 200 && response.body == d5Bytes)
        #expect(await handler.downloadRecords().map(\.state) == [.prepared])
        let record = try #require(await handler.downloadRecords().first)
        #expect(record.project == "fixture" && record.version == "1.0.0" && record.filename == d5Filename)
        #expect(record.source == "https://files.example/packages/" + d5Filename && record.sha256 == registrySHA256(d5Bytes))
        #expect(record.uploadedAt == d5Now.addingTimeInterval(-3600))
        #expect(await handler.takeCompletedDownloadRecords().isEmpty)
        await response.completion?(true)
        #expect(await handler.takeCompletedDownloadRecords().map(\.state) == [.transportAccepted])
    }
    #expect(backend.calls.map { $0.1.target } == Array(repeating: ["/simple/fixture/", "/packages/" + d5Filename, "/simple/fixture/"], count: 2).flatMap { $0 })
    #expect(backend.calls.allSatisfy { $0.1.headers["x-untrusted"] == nil && $0.1.headers["authorization"] == nil })
}

@Test func pypiTimeBoundaryMissingFutureImpossibleAndSubmillisecondPrecision() async throws {
    for time in [nil, "invalid", "2027-02-31T00:00:00Z", "2027-01-15T07:00:00+00:00",
                 d5ISO(d5Now.addingTimeInterval(1)), d5ISO(d5Now.addingTimeInterval(-3599))] {
        let backend = try d5DefaultBackend(d5Index(files: [d5File(time: time)]))
        #expect(try await d5PyPI(backend).response(to: d5Request(d5FileTarget)).status == 403)
        #expect(backend.calls.count == 1)
    }
    let fractional = String(d5ISO(d5Now.addingTimeInterval(-3600)).dropLast()) + ".000001Z"
    let backend = try d5DefaultBackend(d5Index(files: [d5File(time: fractional)]))
    #expect(try await d5PyPI(backend).response(to: d5Request(d5FileTarget)).status == 403)
    #expect(registryDate("2026-01-01T00:00:00.1234567Z") == nil)
}

@Test func pypiRejectsAmbiguousMetadataAndUnsupportedStatusVersions() async throws {
    let plain = String(decoding: try d5Index(), as: UTF8.self)
    let duplicate = plain.replacingOccurrences(of: "\"name\":\"fixture\"", with: "\"name\":\"fixture\",\"na\\u006de\":\"fixture\"")
    let cases = [Data(duplicate.utf8), try d5Index(files: [d5File(), d5File()]),
                 try d5Index(extras: ["name": "other"]), try d5Index(extras: ["meta": ["api-version": "2.0"]]),
                 try d5Index(extras: ["meta": ["api-version": "1.4", "project-status": "quarantined"]]),
                 try d5Index(extras: ["project-status": ["status": "quarantined"]]),
                 try d5Index(extras: ["project-status": ["reason": "missing status"]]),
                 try d5Index(extras: ["project-status": "active"]),
                 try d5Index(extras: ["project-status": ["status": "quarantined"], "meta": ["api-version": "1.4", "project-status": "active"]])]
    for data in cases {
        let backend = try d5DefaultBackend(data)
        #expect(try await d5PyPI(backend).response(to: d5Request(d5FileTarget)).status != 200)
        #expect(backend.calls.count == 1)
    }
}

@Test func pypiDoesNotAcceptUnknownIdentityWeakHashesBooleanSizesOrYankedFiles() async throws {
    let variants: [[String: Any]] = [ ["hashes": ["md5": "irrelevant"]], ["size": true], ["size": 1.5], ["yanked": 0],
        ["yanked": ""], ["url": "https://evil.example/packages/" + d5Filename],
        ["url": "https://files.example/packages/other.whl"],
        ["url": "https://files.example/packages/" + d5Filename + "?signature=canary"],
        ["url": "https://files.example/packages/%2e%2e/" + d5Filename],
        ["url": "https://127.0.0.1/" + d5Filename] ]
    for change in variants {
        var file = d5File(); file.merge(change) { _, new in new }
        let backend = try d5DefaultBackend(d5Index(files: [file]))
        #expect(try await d5PyPI(backend).response(to: d5Request(d5FileTarget)).status == 403)
        #expect(backend.calls.count == 1)
    }
}

@Test func pypiHashAndSizeMismatchOrChangedFinalMetadataNeverReleaseBytes() async throws {
    let initial = try d5Index()
    var changed = d5File(); changed["requires-python"] = ">=3.12"
    let final = try d5Index(files: [changed])
    for scenario in 0..<3 {
        let backend = D5Backend { _, request, index in
            if request.target.hasPrefix("/simple/") { return D5Wire(body: index == 3 && scenario == 2 ? final : initial) }
            return D5Wire(body: scenario == 0 ? Data(repeating: 0, count: d5Bytes.count) : scenario == 1 ? d5Bytes + Data([0]) : d5Bytes)
        }
        let handler = try d5PyPI(backend)
        #expect(try await handler.response(to: d5Request(d5FileTarget)).status == 403)
        #expect(await handler.downloadRecords().isEmpty)
    }
}

@Test func pypiEveryRedirectAndNonJSONMetadataFailClosed() async throws {
    for status in [301, 302, 303, 307, 308, 304, 401, 500] {
        let data = try d5Index()
        let backend = D5Backend { _, request, _ in
            request.target.hasPrefix("/simple/") ? D5Wire(body: data) : D5Wire(status: status, headers: ["Location": "https://files.example/next"], body: Data())
        }
        #expect(try await d5PyPI(backend).response(to: d5Request(d5FileTarget)).status != 200)
        #expect(backend.calls.count == 2)
    }
    for type in ["text/html", "application/json"] {
        let data = try d5Index(); let backend = D5Backend { _, _, _ in D5Wire(type: type, body: data) }
        #expect(try await d5PyPI(backend).response(to: d5Request(d5FileTarget)).status == 502)
    }
}

@Test func pypiRejectsClientAuthorityCredentialsAlternatePathsAndRangesBeforeNetwork() async throws {
    let backend = try d5DefaultBackend(); let handler = try d5PyPI(backend)
    for target in ["https://evil.example/", "/pypi/simple/Fixture/", "/pypi/simple/a%2fb/", "/pypi/simple/fixture/?x=1",
                   "/pypi/files/fixture/../file.whl", d5FileTarget + ".metadata", d5FileTarget + "#sha256=aaa",
                   "/pypi/files/fixture/%66ixture.whl", "/pypi/simple/fixture"] {
        #expect(try await handler.response(to: d5Request(target)).status == 400)
    }
    for header in ["Authorization", "cookie", "Range", "If-None-Match", "content-encoding"] {
        #expect(try await handler.response(to: d5Request(d5FileTarget, headers: [header: "synthetic"])).status == 403)
    }
    #expect(try await handler.response(to: d5Request(d5FileTarget, method: "POST")).status == 403)
    #expect(try await handler.response(to: d5Request(d5FileTarget, body: Data([0]))).status == 403)
    #expect(backend.calls.isEmpty)
}

@Test func pypiFinalDNSRebindingClockRollbackAndAuditCapacityDeny() async throws {
    let backend = try d5DefaultBackend()
    #expect(try await d5PyPI(backend, dns: D5DNS(["8.8.8.8", "8.8.8.8", "127.0.0.1"])).response(to: d5Request(d5FileTarget)).status == 502)
    #expect(backend.calls.count == 2)
    let clock = D5Clock()
    let handler = try d5PyPI(d5DefaultBackend(), now: { clock.read() })
    clock.rollback = true
    #expect(try await handler.response(to: d5Request(d5FileTarget)).status == 403)
    let config = try PyPIConfiguration(registryHostname: "index.example", artifactHostnames: ["files.example"], publicOrigin: "http://127.0.0.1:8765", cooldown: 3600,
        limits: RegistryLimits(auditRecords: 1))
    let audit = try d5PyPI(d5DefaultBackend(), configuration: config)
    let first = try await audit.response(to: d5Request(d5FileTarget))
    #expect(try await audit.response(to: d5Request(d5FileTarget)).status == 503)
    await first.completion?(false)
    #expect(await audit.takeCompletedDownloadRecords().map(\.state) == [.sendFailed])
    #expect(try await audit.response(to: d5Request(d5FileTarget)).status == 200)
}
private final class D5Clock: @unchecked Sendable {
    private let lock = NSLock()
    var rollback = false // configured before use
    private var reads = 0
    func read() -> Date { lock.withLock { reads += 1; return rollback && reads > 1 ? d5Now.addingTimeInterval(-1) : d5Now } }
}

@Test func pypiLimitsCancellationDeadlineAndConcurrencyReleaseCapacity() async throws {
    let data = try d5Index()
    let backend = D5Backend(delay: .milliseconds(100)) { _, request, _ in D5Wire(body: request.target.hasPrefix("/simple/") ? data : d5Bytes) }
    let config = try PyPIConfiguration(registryHostname: "index.example", artifactHostnames: ["files.example"], publicOrigin: "http://127.0.0.1:8765", cooldown: 3600,
        limits: RegistryLimits(operations: 1, auditRecords: 1, lifetime: .milliseconds(20)))
    let handler = try d5PyPI(backend, configuration: config)
    let first = Task { try await handler.response(to: d5Request(d5FileTarget)) }
    while backend.calls.isEmpty { await Task.yield() }
    #expect(try await handler.response(to: d5Request(d5FileTarget)).status == 503)
    #expect(try await first.value.status == 502)
    #expect(await handler.downloadRecords().isEmpty)
    let cancelled = Task { try await handler.response(to: d5Request(d5FileTarget)) }
    cancelled.cancel()
    do { _ = try await cancelled.value; Issue.record("Cancellation was swallowed") } catch is CancellationError {} catch { Issue.record("Wrong cancellation error") }
    #expect(await handler.downloadRecords().isEmpty)
    let small = try PyPIConfiguration(registryHostname: "index.example", artifactHostnames: ["files.example"], publicOrigin: "http://127.0.0.1:8765", cooldown: 3600,
        limits: RegistryLimits(metadataBytes: 10))
    #expect(try await d5PyPI(d5DefaultBackend(), configuration: small).response(to: d5Request(d5FileTarget)).status == 413)
    #expect(throws: Error.self) { try RegistryLimits(artifactBytes: Int.max) }
    #expect(throws: Error.self) { try PyPIConfiguration(publicOrigin: "http://localhost:8080", cooldown: 0) }
}

@Test func pypiFilenameIdentityIsBoundToProjectAndVersionForDirectRequests() async throws {
    #expect(try pypiVersion("some_package-1.2.3-1build-py3-none-any.whl", project: PyPIName("some-package")) == "1.2.3")
    #expect(try pypiVersion("some-package-1.2.3.tar.gz", project: PyPIName("some-package")) == "1.2.3")
    for filename in ["other-1.0.0-py3-none-any.whl", "fixture-name.whl", "fixture-1.0-badbuild-py3-none-any.whl", "fixture-noversion.tar.gz"] {
        let backend = try d5DefaultBackend(d5Index(files: [d5File(filename: filename)]))
        #expect(try await d5PyPI(backend).response(to: d5Request("/pypi/files/fixture/" + filename)).status == 403)
        #expect(backend.calls.count == 1)
    }
}
