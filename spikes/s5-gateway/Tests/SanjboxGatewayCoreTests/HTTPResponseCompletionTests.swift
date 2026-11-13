import Foundation
import Synchronization
import Testing
import SanjboxGatewayCore

@Test func responseTransportCompletionIsOnceAcrossCopiesAndConcurrentCallers() async {
    let calls = Mutex<[Bool]>([])
    let response = HTTPResponse(body: Data(), completion: { value in calls.withLock { $0.append(value) } })
    let copy = response
    await response.completeTransport(true)
    await withTaskGroup(of: Void.self) { tasks in
        for _ in 0..<20 { tasks.addTask { await copy.completeTransport(false) } }
    }
    #expect(calls.withLock { $0 } == [true])
}

@Test func localCapacityRefusalIsSeparateFromAnUntyped503() {
    #expect(HTTPResponse.error(503).rejection == nil)
    #expect(HTTPResponse.error(503, rejection: .capacity).rejection == .capacity)
}

@Test func simultaneousTransportCompletionsOnlyInvokeTheCallbackOnce() async {
    let calls = Mutex(0)
    let response = HTTPResponse(body: Data(), completion: { _ in calls.withLock { $0 += 1 } })
    await withTaskGroup(of: Void.self) { tasks in
        for index in 0..<20 { tasks.addTask { await response.completeTransport(index.isMultiple(of: 2)) } }
    }
    #expect(calls.withLock { $0 } == 1)
}
