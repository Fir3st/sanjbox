import Foundation
import Testing
@testable import SanjboxContracts

// Fixtures are synthetic design documents copied from the shape documented in
// spikes/s4-state/SCHEMA.md. Nothing is mounted, created or measured.
@Suite("Manifest stavu (duplikované schema)")
struct StateManifestTests {
    static let base = """
    {"schema":"sanjbox.state-manifest.v1","intent":"design-only","phase":"mvp",
     "zone":{"id":"t1ab","uid":4501,"gid":4500},
     "containers":[{"id":"state","planningBudgetBytes":1073741824}],
     "volumes":[{"id":"state","containerID":"state","mountPoint":"/opt/snj/t1ab","filesystem":"apfs",
                 "caseSensitive":false,"ownership":"required",
                 "quota":{"mode":"limited","limitBytes":1073741824,"reserveBytes":0}}],
     "roots":[
       {"id":"prefix","role":"prefix","volumeID":"state","relativePath":".","ownerUID":4501,
        "rollback":"whole-volume","purpose":"tools prefix"},
       {"id":"home","role":"home","volumeID":"state","relativePath":"home","ownerUID":4501,
        "rollback":"whole-volume","purpose":"zone home"},
       {"id":"project","role":"project","volumeID":"state","relativePath":"project","ownerUID":4501,
        "rollback":"whole-volume","purpose":"zone projects"},
       {"id":"cache","role":"cache","volumeID":"state","relativePath":"cache","ownerUID":4501,
        "rollback":"whole-volume","purpose":"zone caches"},
       {"id":"tmp","role":"tmp","volumeID":"state","relativePath":"tmp","ownerUID":4501,
        "rollback":"whole-volume","purpose":"zone temporary"}],
     "runtimePolicy":"deferred-f4",
     "rollback":{"unitID":"t1ab-full-state","volumeIDs":["state"],
                 "strategy":"rebuild-writable-state-then-switch","quiescence":"whole-uid-required",
                 "recoveryRequired":true,"startPolicy":"deny-until-verified"},
     "hostControl":{"directoryPath":"/var/db/sanjbox","ownerUID":0,"directoryMode":"0700",
                    "policyFile":"policy.json","recoveryFile":"recovery.json","rollback":"excluded"},
     "readOnlyInputs":[],
     "outsideWrites":"forbidden-unverified","hostAccess":"controlled-export-only"}
    """

    private func document(_ overrides: [(String, String)] = []) -> Data {
        var text = Self.base
        for (old, new) in overrides {
            guard text.contains(old) else {
                Issue.record("fixture marker '\(old)' missing")
                continue
            }
            text = text.replacingOccurrences(of: old, with: new)
        }
        return Data(text.utf8)
    }

    private func expectInvalid(_ overrides: [(String, String)], code: String,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        rejection(code, sourceLocation: sourceLocation) {
            _ = try StateManifestSchema.decode(document(overrides))
        }
    }

    @Test func decodesDocumentedFixtureAndReencodes() throws {
        let decoded = try StateManifestSchema.decode(document())
        #expect(decoded.zone.id == "t1ab")
        #expect(decoded.volumes.first?.quota.mode == "limited")
        let encoded = try StateManifestSchema.encode(decoded)
        #expect(try StateManifestSchema.decode(encoded) == decoded)
    }

    @Test func rejectsUnknownTopLevelField() {
        expectInvalid([("\"readOnlyInputs\":[]", "\"readOnlyInputs\":[],\"observedTopology\":\"x\"")], code: "unknown-field")
    }

    @Test func rejectsUnknownNestedField() {
        expectInvalid([("\"directoryMode\":\"0700\"", "\"directoryMode\":\"0700\",\"acl\":\"none\"")], code: "unknown-field")
    }

    @Test func rejectsMissingRequiredField() {
        expectInvalid([("\"outsideWrites\":\"forbidden-unverified\",", "")], code: "missing-field")
    }

    @Test func rejectsDuplicateKey() {
        expectInvalid([("\"phase\":\"mvp\"", "\"phase\":\"mvp\",\"phase\":\"f4-design\"")], code: "duplicate-key")
    }

    @Test func rejectsWrongSchemaIntentAndPhase() {
        expectInvalid([("\"sanjbox.state-manifest.v1", "\"sanjbox.state-manifest.v2")], code: "invalid-value")
        expectInvalid([("\"intent\":\"design-only\"", "\"intent\":\"verified\"")], code: "invalid-value")
        expectInvalid([("\"phase\":\"mvp\"", "\"phase\":\"prod\"")], code: "invalid-value")
    }

    @Test func rejectsZoneIdentityProblems() {
        expectInvalid([("\"id\":\"t1ab\",\"uid\"", "\"id\":\"t1\",\"uid\"")], code: "invalid-identifier")
        expectInvalid([("\"uid\":4501", "\"uid\":0")], code: "invalid-range")
        expectInvalid([("\"gid\":4500", "\"gid\":4294967296")], code: "invalid-range")
    }

    @Test func rejectsForeignHostPolicy() {
        expectInvalid([("\"hostAccess\":\"controlled-export-only\"", "\"hostAccess\":\"inherited\"")], code: "invalid-value")
        expectInvalid([("\"outsideWrites\":\"forbidden-unverified\"", "\"outsideWrites\":\"blocked\"")], code: "invalid-value")
    }

    @Test func rejectsCollectionLimits() {
        expectInvalid([("\"containers\":[{\"id\":\"state\",\"planningBudgetBytes\":1073741824}]", "\"containers\":[]")],
                      code: "collection-limit")
        expectInvalid([("\"readOnlyInputs\":[]", "\"readOnlyInputs\":[" + Array(repeating: "{\"id\":\"in\",\"path\":\"/x\",\"purpose\":\"p\"}", count: 33).joined(separator: ",") + "]")],
                      code: "collection-limit")
    }

    @Test func rejectsDuplicateAndInvalidIdentifiers() {
        expectInvalid([("\"id\":\"home\",\"role\":\"home\"", "\"id\":\"prefix\",\"role\":\"home\"")], code: "invalid-value")
        expectInvalid([("\"id\":\"cache\",\"role\":\"cache\"", "\"id\":\"CACHE\",\"role\":\"cache\"")], code: "invalid-identifier")
    }

    @Test func rejectsContainerBudgetProblems() {
        expectInvalid([("\"planningBudgetBytes\":1073741824}", "\"planningBudgetBytes\":0}")], code: "invalid-range")
        expectInvalid([("\"reserveBytes\":0", "\"reserveBytes\":4096"),
                       ("\"planningBudgetBytes\":1073741824", "\"planningBudgetBytes\":1024")], code: "invalid-value")
    }

    @Test func rejectsDeclaredUUIDProblems() {
        let uuid = "11111111-2222-3333-4444-555555555555"
        expectInvalid([("\"id\":\"state\",\"planningBudgetBytes\"", "\"id\":\"state\",\"declaredUUID\":\"not-a-uuid\",\"planningBudgetBytes\"")],
                      code: "invalid-value")
        expectInvalid([("\"id\":\"state\",\"planningBudgetBytes\"", "\"id\":\"state\",\"declaredUUID\":\"\(uuid)\",\"planningBudgetBytes\""),
                       ("\"id\":\"state\",\"containerID\":\"state\"", "\"id\":\"state\",\"containerID\":\"state\",\"declaredUUID\":\"\(uuid)\"")],
                      code: "invalid-value")
    }

    @Test func rejectsVolumeProblems() {
        expectInvalid([("\"containerID\":\"state\"", "\"containerID\":\"other\"")], code: "invalid-value")
        expectInvalid([("\"mountPoint\":\"/opt/snj/t1ab\"", "\"mountPoint\":\"/Users\"")], code: "invalid-value")
        expectInvalid([("\"mountPoint\":\"/opt/snj/t1ab\"", "\"mountPoint\":\"/opt/snj/t1ab/\"")], code: "invalid-value")
        expectInvalid([("\"filesystem\":\"apfs\"", "\"filesystem\":\"hfs\"")], code: "invalid-value")
        expectInvalid([("\"ownership\":\"required\"", "\"ownership\":\"optional\"")], code: "invalid-value")
    }

    @Test func rejectsQuotaProblems() {
        expectInvalid([("\"mode\":\"limited\",\"limitBytes\":1073741824,", "\"mode\":\"limited\",")], code: "invalid-range")
        expectInvalid([("\"mode\":\"limited\"", "\"mode\":\"unbounded\"")], code: "invalid-value")
        expectInvalid([("\"mode\":\"limited\"", "\"mode\":\"maybe\"")], code: "invalid-value")
        expectInvalid([("\"reserveBytes\":0", "\"reserveBytes\":2147483648")], code: "invalid-value")
    }

    @Test func rejectsRootRoleAndPathProblems() {
        // `tmp` demoted to an optional role: the required role set is no longer satisfied
        expectInvalid([("\"id\":\"tmp\",\"role\":\"tmp\"", "\"id\":\"tmp\",\"role\":\"additional\"")],
                      code: "invalid-value")
        expectInvalid([("\"role\":\"cache\"", "\"role\":\"shared\"")], code: "invalid-value")
        expectInvalid([("\"id\":\"home\",\"role\":\"home\",\"volumeID\":\"state\",\"relativePath\":\"home\",\"ownerUID\":4501",
                       "\"id\":\"home\",\"role\":\"home\",\"volumeID\":\"state\",\"relativePath\":\"home\",\"ownerUID\":4502")],
                      code: "invalid-value")
        expectInvalid([("\"rollback\":\"whole-volume\",\"purpose\":\"zone home\"",
                       "\"rollback\":\"per-directory\",\"purpose\":\"zone home\"")],
                      code: "invalid-value")
        expectInvalid([("\"relativePath\":\"home\"", "\"relativePath\":\"/home\"")], code: "invalid-value")
        expectInvalid([("\"relativePath\":\".\",\"ownerUID\":4501", "\"relativePath\":\"..\",\"ownerUID\":4501")], code: "invalid-value")
        expectInvalid([("\"purpose\":\"zone caches\"", "\"purpose\":\"\"")], code: "invalid-value")
        expectInvalid([("\"volumeID\":\"state\",\"relativePath\":\"cache\"", "\"volumeID\":\"other\",\"relativePath\":\"cache\"")],
                      code: "invalid-value")
    }

    @Test func rejectsPrefixLayoutDrift() {
        expectInvalid([("\"relativePath\":\".\",\"ownerUID\":4501", "\"relativePath\":\"prefix\",\"ownerUID\":4501")], code: "invalid-value")
    }

    @Test func rejectsRuntimePolicyProblems() {
        expectInvalid([("\"runtimePolicy\":\"deferred-f4\"", "\"runtimePolicy\":\"declared-unverified\"")], code: "invalid-value")
        expectInvalid([("\"phase\":\"mvp\"", "\"phase\":\"f4-design\"")], code: "invalid-value")
    }

    @Test func rejectsRollbackProblems() {
        expectInvalid([("\"volumeIDs\":[\"state\"]", "\"volumeIDs\":[]")], code: "invalid-value")
        expectInvalid([("\"volumeIDs\":[\"state\"]", "\"volumeIDs\":[\"state\",\"state\"]")], code: "invalid-value")
        expectInvalid([("\"strategy\":\"rebuild-writable-state-then-switch\"", "\"strategy\":\"rename-swap\"")], code: "invalid-value")
        expectInvalid([("\"quiescence\":\"whole-uid-required\"", "\"quiescence\":\"best-effort\"")], code: "invalid-value")
        expectInvalid([("\"recoveryRequired\":true", "\"recoveryRequired\":false")], code: "invalid-value")
        expectInvalid([("\"startPolicy\":\"deny-until-verified\"", "\"startPolicy\":\"retry\"")], code: "invalid-value")
    }

    @Test func rejectsHostControlProblems() {
        expectInvalid([("\"ownerUID\":0", "\"ownerUID\":501")], code: "invalid-value")
        expectInvalid([("\"directoryMode\":\"0700\"", "\"directoryMode\":\"0755\"")], code: "invalid-value")
        expectInvalid([("\"policyFile\":\"policy.json\"", "\"policyFile\":\"sub/policy.json\"")], code: "invalid-value")
        expectInvalid([("\"recoveryFile\":\"recovery.json\"", "\"recoveryFile\":\"policy.json\"")], code: "invalid-value")
        expectInvalid([("\"directoryPath\":\"/var/db/sanjbox\"", "\"directoryPath\":\"/opt/snj/t1ab/control\"")], code: "invalid-value")
        expectInvalid([("\"directoryPath\":\"/var/db/sanjbox\"", "\"directoryPath\":\"var/db/sanjbox\"")], code: "invalid-value")
    }

    @Test func rejectsReadOnlyInputProblems() {
        expectInvalid([("\"readOnlyInputs\":[]", "\"readOnlyInputs\":[{\"id\":\"fixtures\",\"path\":\"relative\",\"purpose\":\"p\"}]")],
                      code: "invalid-value")
        expectInvalid([("\"readOnlyInputs\":[]", "\"readOnlyInputs\":[{\"id\":\"fixtures\",\"path\":\"/opt/snj/t1ab/ro\",\"purpose\":\"p\"}]")],
                      code: "invalid-value")
        expectInvalid([("\"readOnlyInputs\":[]", "\"readOnlyInputs\":[{\"id\":\"fixtures\",\"path\":\"/var/db/sanjbox/ro\",\"purpose\":\"p\"}]")],
                      code: "invalid-value")
        expectInvalid([("\"readOnlyInputs\":[]", "\"readOnlyInputs\":[{\"id\":\"fixtures\",\"path\":\"/srv/ro\",\"purpose\":\"p\"},{\"id\":\"f2\",\"path\":\"/srv/ro\",\"purpose\":\"p\"}]")],
                      code: "invalid-value")
    }

    @Test func rejectsOversizedDocument() {
        // Body over the byte budget is refused before any schema work.
        rejection("input-too-large") {
            _ = try StateManifestSchema.decode(Data(String(repeating: " ", count: StateManifestSchema.maxBytes + 1).utf8))
        }
        // A field over its documented string budget is refused by the shape check.
        rejection("string-limit") {
            _ = try StateManifestSchema.decode(document([("\"purpose\":\"zone caches\"",
                "\"purpose\":\"\(String(repeating: "p", count: 257))\"")]))
        }
    }
}
