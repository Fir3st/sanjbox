import AppKit
import Darwin
import Foundation
import S8Preparation
import SanjboxProbeKit
import ServiceManagement

// Only these two cases can reach mutating ServiceManagement calls. The daemon API is
// confined to the read-only status adapter below; no approval/system-settings opener exists.
private enum UserService {
    case loginItem, agent
    init(_ service: FixtureService) throws {
        switch service {
        case .loginItem: self = .loginItem
        case .agent: self = .agent
        case .daemon: throw S8Error.refused("daemon mutations are unavailable")
        }
    }
    var api: SMAppService {
        switch self {
        case .loginItem: SMAppService.loginItem(identifier: FixtureService.loginItem.identifier)
        case .agent: SMAppService.agent(plistName: FixtureService.agent.plistName)
        }
    }
}

private func status(_ service: FixtureService) -> Int {
    switch service {
    case .loginItem: SMAppService.loginItem(identifier: service.identifier).status.rawValue
    case .agent: SMAppService.agent(plistName: service.plistName).status.rawValue
    case .daemon: SMAppService.daemon(plistName: service.plistName).status.rawValue
    }
}

@MainActor
final class Controller: NSObject, NSApplicationDelegate {
    let expected: S8Expectation
    let runID: String
    var window: NSWindow!
    let serviceChoice = NSPopUpButton()
    let actionChoice = NSPopUpButton()
    let output = NSTextView()
    var eventCount = 0
    var lifecycle = UserFixtureLifecycle()

    init(expected: S8Expectation, runID: String) { self.expected = expected; self.runID = runID }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "S8 disposable service experiment — dry-run by default"
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)])
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString:
            "User L2 only, after S1 and preregistration. Ad-hoc builds cannot register. Daemon registration/unregistration is unavailable. This app grants no privileges."))
        serviceChoice.addItems(withTitles: FixtureService.allCases.map(\.rawValue))
        actionChoice.addItems(withTitles: FixtureAction.allCases.map(\.rawValue))
        stack.addArrangedSubview(serviceChoice); stack.addArrangedSubview(actionChoice)
        let preview = NSButton(title: "Preview (no service API)", target: self, action: #selector(preview))
        let read = NSButton(title: "Read selected status", target: self, action: #selector(readStatus))
        let apply = NSButton(title: "Review user action…", target: self, action: #selector(reviewAction))
        stack.addArrangedSubview(NSStackView(views: [preview, read, apply]))
        output.isEditable = false
        let scroll = NSScrollView(); scroll.documentView = output; scroll.hasVerticalScroller = true
        stack.addArrangedSubview(scroll); scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        self.preview()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    var selected: FixtureService { FixtureService.allCases[serviceChoice.indexOfSelectedItem] }
    var action: FixtureAction { FixtureAction.allCases[actionChoice.indexOfSelectedItem] }
    func show(_ text: String) { output.string = text }
    @objc func preview() {
        show("DRY-RUN: \(action.rawValue) \(selected.rawValue)\nFixed ID: \(selected.identifier)\nRun: \(runID)\nNo ServiceManagement call made.\n" +
             (selected == .daemon ? "Daemon mutations are compiled out of the action adapter; separate host-only approval design remains required." :
              "A user action rechecks exact identity and signing, saves intent before the API, then saves status/error. Unregister does not prove process exit or no relaunch."))
    }
    func validatedContext() throws -> (ProbeContext, FixtureSigning) {
        let context = try captureIdentity(groups: Set(expected.requiredGroups + expected.forbiddenGroups))
        let signing = fixtureSelfSigning()
        guard expected.mismatches(in: context).isEmpty, signing.issues.isEmpty else {
            throw S8Error.refused("identity/session or signing changed; invalid observation")
        }
        return (context, signing)
    }
    func record(service: FixtureService, phase: String, action: FixtureAction, context: ProbeContext,
                observedStatus: Int, error: NSError? = nil) throws -> String {
        guard eventCount < 32 else { throw S8Error.refused("32-event UI session limit; preserve evidence") }
        var event = try ServiceEvent(runID: runID, service: service, phase: phase, context: context)
        event.action = action; event.status = observedStatus
        event.errorDomain = error?.domain; event.errorCode = error?.code
        eventCount += 1
        let path = try ServiceEventStore.write(event)
        return path
    }
    @objc func readStatus() {
        do {
            let (context, _) = try validatedContext()
            let value = status(selected)
            let path = try record(service: selected, phase: "status", action: .status, context: context, observedStatus: value)
            show("Observed status \(value). Evidence: \(path)\nStatus is not a lifecycle verdict.")
        } catch { show("Refused: \(error)") }
    }
    @objc func reviewAction() {
        do {
            let service = selected; let operation = action
            if operation == .status { readStatus(); return }
            let (context, signing) = try validatedContext()
            if let reason = FixtureActionPolicy.refusal(service: service, action: operation, apply: true,
                identityIssues: expected.mismatches(in: context), adHoc: signing.adHoc) { throw S8Error.refused(reason) }
            guard eventCount <= 30 else { throw S8Error.refused("insufficient evidence capacity for intent/result") }
            let mutable = try UserService(service)
            let alert = NSAlert()
            alert.messageText = "\(operation.rawValue) own \(service.rawValue)?"
            alert.informativeText = "USER L2 EXPERIMENT, after S1 and preregistration only.\nRun: \(runID)\nFixed ID: \(service.identifier)\nThis changes startup state for your current UID. Register may launch the bounded observer immediately and at subsequent logins. Unregister requires later process/relaunch verification. This dialog is not a trusted host authorization boundary."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "I preregistered L2; perform this action")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            let (fresh, freshSigning) = try validatedContext()
            guard !freshSigning.adHoc else { throw S8Error.refused("signing changed") }
            let before = status(service)
            try lifecycle.authorize(service, operation, status: before)
            let intent = try record(service: service, phase: "intent", action: operation, context: fresh, observedStatus: before)
            try lifecycle.begin(service, operation, status: before)
            var failure: NSError?
            do {
                switch operation {
                case .register: try mutable.api.register()
                case .unregister: try mutable.api.unregister()
                case .status: break
                }
            } catch { failure = error as NSError }
            // A failed result write leaves the intent and an explicit incomplete experiment.
            let (afterContext, _) = try validatedContext()
            let afterStatus = status(service)
            let result = try record(service: service, phase: "result", action: operation, context: afterContext,
                                    observedStatus: afterStatus, error: failure)
            lifecycle.finish(service, operation, status: afterStatus, succeeded: failure == nil)
            show("Intent: \(intent)\nResult: \(result)\n" + (failure == nil ? "API returned success; lifecycle remains unverified." : "API error \(failure!.domain)/\(failure!.code); preserve both records."))
        } catch { show("Refused/incomplete: \(error)\nIf an intent exists, inspect it and perform user cleanup before closing the slot.") }
    }
}

func fail(_ text: String) -> Never { FileHandle.standardError.write(Data((text + "\n").utf8)); exit(2) }
let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args == ["plan"] {
    print("DRY-RUN: S8ServiceHost ui --expect OWN_EXPECTATION.json; status --expect OWN_EXPECTATION.json. No service API called. Daemon mutation unavailable; no CLI apply/registration endpoint.")
    exit(0)
}
guard args.count == 3, ["ui", "status"].contains(args[0]), args[1] == "--expect" else {
    fail("Only plan, ui --expect FILE, status --expect FILE are accepted; registration is a user UI action.")
}
do {
    let expected = try readExpectation(args[2])
    let context = try captureIdentity(groups: Set(expected.requiredGroups + expected.forbiddenGroups))
    let signing = fixtureSelfSigning()
    guard expected.mismatches(in: context).isEmpty, signing.issues.isEmpty else {
        fail("invalid identity/session or signing; no service API called")
    }
    guard Bundle.main.bundleIdentifier == "org.sanjbox.s8.fixture.host" else { fail("own containing bundle required") }
    let run = try fixtureRunID()
    if args[0] == "status" {
        for service in FixtureService.allCases {
            var event = try ServiceEvent(runID: run, service: service, phase: "status", context: context)
            event.action = .status; event.status = status(service)
            _ = try ServiceEventStore.write(event)
        }
    } else {
        let app = NSApplication.shared
        let controller = Controller(expected: expected, runID: run)
        app.delegate = controller; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(controller) {}
    }
} catch { fail("S8 host refused: \(error)") }
