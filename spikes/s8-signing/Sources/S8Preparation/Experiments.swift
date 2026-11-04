import Foundation
import CoreFoundation

public struct ServiceExperiment: Encodable, Sendable {
    public let kind = "future-user-experiment-not-run"
    public var identity: String
    public var service: String
    public var bundleLocation: String
    public var registrationScope: String
    public var approvalOracle: String
    public var cleanup: String
}

public enum ServiceExperiments {
    /// Six separate rows; no inference from one service class/signature to another.
    public static func plans() -> [ServiceExperiment] {
        ["Personal Team", "self-signed (conditional after Personal Team failure)"].flatMap { identity in
            [
                ServiceExperiment(identity: identity, service: "LoginItem", bundleLocation: "Contents/Library/LoginItems/S8LoginItem.app",
                    registrationScope: "user running containing app", approvalOracle: "record status/error; observe immediate and next-login launch separately; do not assume admin approval is required",
                    cleanup: "unregister same loginItem(identifier:) from same containing app and user; verify no subsequent relaunch"),
                ServiceExperiment(identity: identity, service: "LaunchAgent", bundleLocation: "Contents/Library/LaunchAgents/org.sanjbox.s8.fixture.agent.plist",
                    registrationScope: "registration once per user while that user runs app", approvalOracle: "record status/error; observe immediate bootstrap and subsequent login; no universal admin assumption",
                    cleanup: "unregister same agent(plistName:) as every user who registered; verify no subsequent launch"),
                ServiceExperiment(identity: identity, service: "LaunchDaemon", bundleLocation: "Contents/Library/LaunchDaemons/org.sanjbox.s8.fixture.daemon.plist",
                    registrationScope: "system service, distinct admin-approved experiment", approvalOracle: "must not bootstrap before admin approval; record register and approve as separate events",
                    cleanup: "user unregisters same daemon(plistName:); verify absence at next boot and preserve unresolved cleanup as blocked slot"),
            ]
        }
    }

    /// Pure static layout example, never installed/registered. It has no KeepAlive or MachServices.
    public static func plist(daemon: Bool) -> [String: Any] {
        ["Label": "org.sanjbox.s8.fixture." + (daemon ? "daemon" : "agent"),
         "BundleProgram": "Contents/MacOS/S8DisposableHelper", "RunAtLoad": true]
    }

    public static func validate(_ plist: [String: Any], daemon: Bool) -> Bool {
        let expected = Self.plist(daemon: daemon)
        guard Set(plist.keys) == Set(expected.keys),
              plist["Label"] as? String == expected["Label"] as? String,
              plist["BundleProgram"] as? String == "Contents/MacOS/S8DisposableHelper",
              let run = plist["RunAtLoad"] as? NSNumber,
              CFGetTypeID(run) == CFBooleanGetTypeID(), run.boolValue else { return false }
        return true
    }
}
