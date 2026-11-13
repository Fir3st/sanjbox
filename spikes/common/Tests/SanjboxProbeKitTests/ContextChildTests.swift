import Darwin
import Foundation
import Testing
@testable import SanjboxProbeKit

private final class ScriptedContextChild: ContextChildIO {
    var time: UInt64 = 0
    var reads: [ContextChild.Read]
    var waits: [ContextChild.Wait]
    var signals: [Int32] = []
    var readCount = 0
    var waitCount = 0
    var signalAllowed = true
    var exitOnSignal: Int32? = SIGTERM
    var signalledExit = false
    var readAdvance: UInt64 = 0
    var waitAdvance: UInt64 = 0
    init(reads: [ContextChild.Read] = [], waits: [ContextChild.Wait] = []) {
        self.reads = reads; self.waits = waits
    }
    func now() -> UInt64 { time }
    func pause() { time += 1 }
    func readOutput(maximum: Int) -> ContextChild.Read {
        readCount += 1
        time += readAdvance
        guard !reads.isEmpty else { return .retry }
        let result = reads.removeFirst()
        if case .bytes(let bytes) = result { #expect(bytes.count <= maximum) }
        return result
    }
    func wait() -> ContextChild.Wait {
        waitCount += 1
        time += waitAdvance
        if signalledExit { return .exited(SIGTERM) }
        return waits.isEmpty ? .running : waits.removeFirst()
    }
    func signal(_ value: Int32) -> Bool {
        signals.append(value)
        signalledExit = value == exitOnSignal
        return signalAllowed
    }
}

private let fixtureLimits = ContextChild.Limits(execution: 10, termination: 3, kill: 3, output: 4)
private func collect(_ fixture: ScriptedContextChild) throws -> Data {
    try ContextChild.collect(fixture, limits: fixtureLimits)
}

@Test func contextChildDrainsOutputAfterReapingAndAcceptsExactLimit() throws {
    let fixture = ScriptedContextChild(reads: [.bytes(Data([1, 2])), .bytes(Data([3, 4])), .eof], waits: [.exited(0)])
    #expect(try collect(fixture) == Data([1, 2, 3, 4]))
    #expect(fixture.waitCount == 1)
    #expect(fixture.signals.isEmpty)
}

@Test func contextChildWaitsAfterEOFUntilSuccessfulExit() throws {
    let fixture = ScriptedContextChild(reads: [.bytes(Data([1])), .eof], waits: [.running, .running, .exited(0)])
    #expect(try collect(fixture) == Data([1]))
    #expect(fixture.readCount == 2)
    #expect(fixture.waitCount == 3)
}

@Test func contextChildEOFWhileAliveTimesOutAndReaps() {
    let fixture = ScriptedContextChild(reads: [.eof])
    #expect(throws: ContextChild.Failure.deadline) { try collect(fixture) }
    #expect(fixture.readCount == 1)
    #expect(fixture.signals == [SIGTERM])
    #expect(fixture.time == 10)
}

@Test func contextChildExitWithInheritedWriterTimesOutWithoutSignallingReapedPID() {
    let fixture = ScriptedContextChild(waits: [.exited(0)])
    #expect(throws: ContextChild.Failure.deadline) { try collect(fixture) }
    #expect(fixture.waitCount == 1)
    #expect(fixture.signals.isEmpty)
}

@Test func contextChildRejectsNonzeroAndSignalledExit() {
    for status: Int32 in [256, SIGTERM, SIGKILL] {
        let fixture = ScriptedContextChild(reads: [.eof], waits: [.exited(status)])
        #expect(throws: ContextChild.Failure.unsuccessfulExit) { try collect(fixture) }
        #expect(fixture.signals.isEmpty)
    }
}

@Test func contextChildStopsAtOneByteBeyondOutputLimit() {
    let fixture = ScriptedContextChild(reads: [.bytes(Data([1, 2, 3, 4])), .bytes(Data([5]))])
    #expect(throws: ContextChild.Failure.outputLimit) { try collect(fixture) }
    #expect(fixture.signals == [SIGTERM])
    #expect(fixture.readCount == 2)
}

@Test func contextChildReadFailureCleansUpOwnedChild() {
    let fixture = ScriptedContextChild(reads: [.failed])
    #expect(throws: ContextChild.Failure.read) { try collect(fixture) }
    #expect(fixture.signals == [SIGTERM])
}

@Test func contextChildInterruptsCannotExtendDeadline() {
    let fixture = ScriptedContextChild(reads: Array(repeating: .retry, count: 10),
                                       waits: Array(repeating: .interrupted, count: 11))
    #expect(throws: ContextChild.Failure.deadline) { try collect(fixture) }
    #expect(fixture.time == 10)
    #expect(fixture.signals == [SIGTERM])
}

@Test func contextChildLostOwnershipNeverSignals() {
    for reads: [ContextChild.Read] in [[.retry], [.failed]] {
        let fixture = ScriptedContextChild(reads: reads, waits: [.lost])
        #expect(throws: ContextChild.Failure.wait) { try collect(fixture) }
        #expect(fixture.signals.isEmpty)
    }
}

@Test func contextChildEscalatesOnlyItsStillOwnedChild() {
    let fixture = ScriptedContextChild(reads: [.failed])
    fixture.exitOnSignal = SIGKILL
    #expect(throws: ContextChild.Failure.read) { try collect(fixture) }
    #expect(fixture.signals == [SIGTERM, SIGKILL])
    #expect(fixture.time == 3)
}

@Test func contextChildCleanupHasItsOwnFiniteDeadline() {
    let fixture = ScriptedContextChild(reads: [.failed])
    fixture.exitOnSignal = nil
    #expect(throws: ContextChild.Failure.cleanupDeadline) { try collect(fixture) }
    #expect(fixture.signals == [SIGTERM, SIGKILL])
    #expect(fixture.time == 6)
}

@Test func contextChildLostOwnershipDuringCleanupNeverEscalates() {
    let fixture = ScriptedContextChild(reads: [.failed], waits: [.running, .lost])
    fixture.exitOnSignal = nil
    #expect(throws: ContextChild.Failure.wait) { try collect(fixture) }
    #expect(fixture.signals == [SIGTERM])
}

@Test func contextChildChangedSignalDispositionRefusesSignal() {
    let fixture = ScriptedContextChild(reads: [.failed])
    fixture.signalAllowed = false
    #expect(throws: ContextChild.Failure.unsafeReaping) { try collect(fixture) }
    #expect(fixture.signals == [SIGTERM]) // Attempt only; fixture refuses the actual operation.
}

@Test func contextChildRequiresDefaultSIGCHLDWithoutAutomaticReaping() {
    let standard = unsafeBitCast(SIG_DFL, to: UInt.self)
    #expect(ContextChild.permitsExclusiveReap(handlerAddress: standard, flags: 0))
    #expect(ContextChild.permitsExclusiveReap(handlerAddress: standard, flags: SA_NOCLDSTOP))
    #expect(!ContextChild.permitsExclusiveReap(handlerAddress: standard, flags: SA_NOCLDWAIT))
    #expect(!ContextChild.permitsExclusiveReap(handlerAddress: unsafeBitCast(SIG_IGN, to: UInt.self), flags: 0))
    #expect(!ContextChild.permitsExclusiveReap(handlerAddress: UInt.max, flags: 0))
}

@Test func launchctlReplyPreservesOpenEndedNamesAndUnsignedUIDs() throws {
    for name in ["Aqua", "Background", "System", "LoginWindow", "Custom Manager"] {
        let manager = try #require(LaunchctlQuery.capture { command in
            Data((command == .managerName ? " \(name)\n" : " 4294967295\n").utf8)
        })
        #expect(manager.name == name)
        #expect(manager.uid == UInt32.max)
    }
}

@Test func launchctlReplyRejectsMalformedNameAndUID() {
    let malformedNames = [Data(), Data(" \n".utf8), Data([0xFF]), Data("Aqua\0".utf8),
                          Data("Aqua\nBackground".utf8), Data("Aqua\tOther".utf8)]
    for name in malformedNames {
        #expect(LaunchctlQuery.capture { Data($0 == .managerName ? name : Data("501\n".utf8)) } == nil)
    }
    for uid in ["", "+501", "-1", "1.0", "4294967296", "501\n502", "0x1", "１２"] {
        #expect(LaunchctlQuery.capture { Data(($0 == .managerName ? "Aqua\n" : uid).utf8) } == nil)
    }
}

@Test func launchctlFailureNeverProducesPartialManager() {
    for failingCommand: LaunchctlQuery.Command in [.managerName, .managerUID] {
        #expect(LaunchctlQuery.capture {
            if $0 == failingCommand { throw ContextChild.Failure.deadline }
            return Data("Aqua\n".utf8)
        } == nil)
    }
}

@Test func contextChildRealFixedEchoReturnsAndReaps() throws {
    var pid: pid_t = 0
    let data = try ContextChild.runEchoFixture(holdInputOpen: false) { pid = $0 }
    #expect(data == Data("context-child-fixture\n".utf8))
    #expect(pid > 0)
    var status: Int32 = 0
    #expect(waitpid(pid, &status, WNOHANG) == -1)
    #expect(errno == ECHILD)
}

@Test func contextChildRealHeldPipeTimesOutAndReaps() {
    var pid: pid_t = 0
    let start = DispatchTime.now().uptimeNanoseconds
    #expect(throws: ContextChild.Failure.deadline) {
        try ContextChild.runEchoFixture(holdInputOpen: true) { pid = $0 }
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    #expect(elapsed >= ContextChild.Limits.standard.execution)
    #expect(elapsed < 5_000_000_000) // Scheduling tolerance, not a hard real-time claim.
    #expect(pid > 0)
    var status: Int32 = 0
    #expect(waitpid(pid, &status, WNOHANG) == -1)
    #expect(errno == ECHILD)
}

@Test func contextChildLateReadCannotBecomeSuccessfulObservation() {
    for advance: UInt64 in [10, 11] {
        let fixture = ScriptedContextChild(reads: [.eof], waits: [.exited(0)])
        fixture.readAdvance = advance
        #expect(throws: ContextChild.Failure.deadline) { try collect(fixture) }
        #expect(fixture.readCount == 1)
        #expect(fixture.signals.isEmpty)
    }
}

@Test func contextChildLateReapCannotBecomeSuccessfulObservation() {
    for advance: UInt64 in [10, 11] {
        let fixture = ScriptedContextChild(reads: [.eof], waits: [.exited(0)])
        fixture.waitAdvance = advance
        #expect(throws: ContextChild.Failure.deadline) { try collect(fixture) }
        #expect(fixture.waitCount == 1)
        #expect(fixture.signals.isEmpty)
    }
}
