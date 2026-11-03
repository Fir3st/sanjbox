import Darwin
import Foundation
import SanjboxProbeKit

public struct ProbeInput: Codable, Sendable {
    public var caseID: String
    public var address: String
    public var port: UInt16
    public var transport: String
    public var canary: String
    public var sendCount: Int
    public var intervalMilliseconds: Int
    public var controlledTarget: Bool

    public func validate() throws {
        guard caseID.range(of: #"^NET-(0[1-9]|1[0-9]|2[0-7])$"#, options: .regularExpression) != nil,
              port >= 1024, ["tcp", "udp"].contains(transport), controlledTarget,
              (1...32).contains(sendCount), (0...500).contains(intervalMilliseconds),
              canary.utf8.count <= 160,
              canary.range(of: #"^SANJBOX-CANARY-[A-Za-z0-9_-]{1,64}-[a-f0-9]{32}$"#, options: .regularExpression) != nil
        else { throw ProbeError.invalidInput }
        var v4 = in_addr(), v6 = in6_addr()
        let literalASCII = address.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) || byte == 46 || byte == 58
        }
        guard literalASCII, address.utf8.count <= 45,
              inet_pton(AF_INET, address, &v4) == 1 || inet_pton(AF_INET6, address, &v6) == 1
        else { throw ProbeError.invalidInput }
    }
}

public struct C1Expectation: Codable, Sendable {
    public var identity: ProbeExpectation
    public var auditSessionID: Int32
}

public enum ProbeError: Error { case invalidInput, weakExpectation, invalidIdentity, io(Int32), deadline }

public enum C1Probe {
    public static func validateExpectation(_ required: C1Expectation) throws {
        let expectation = required.identity
        guard required.auditSessionID >= 0, !(expectation.forbiddenAuditSessionIDs ?? []).contains(required.auditSessionID) else { throw ProbeError.weakExpectation }
        guard (400...60000).contains(expectation.effectiveUID),
              expectation.realUID == expectation.effectiveUID,
              expectation.effectiveGID != nil, expectation.realGID == expectation.effectiveGID,
              !(expectation.requiredGroups ?? []).isEmpty,
              Set(expectation.forbiddenGroups ?? []).isSuperset(of: [20, 80]),
              !(expectation.forbiddenAuditSessionIDs ?? []).isEmpty,
              expectation.launchdManagerName == "Aqua",
              expectation.launchdManagerUID == expectation.effectiveUID,
              expectation.windowSessionUID == expectation.effectiveUID,
              expectation.onConsole == false else { throw ProbeError.weakExpectation }
    }

    public static func matches(_ expectation: C1Expectation, _ context: ProbeContext) -> Bool {
        expectation.identity.mismatches(in: context).isEmpty && context.audit?.sessionID == expectation.auditSessionID
    }

    public static func validatedInput(expectation: C1Expectation, context: ProbeContext,
                                      read: () throws -> ProbeInput) throws -> ProbeInput {
        try validateExpectation(expectation)
        guard matches(expectation, context) else { throw ProbeError.invalidIdentity }
        let input = try read()
        try input.validate()
        return input
    }

    /// Injection exists only in the library tests, not as a CLI flag or environment setting.
    /// The socket is opened only after the same process's complete context matched.
    public static func run(input: ProbeInput, expectation: C1Expectation, context: ProbeContext,
                           send: (ProbeInput) throws -> Int) throws -> Int {
        try input.validate()
        try validateExpectation(expectation)
        guard matches(expectation, context) else { throw ProbeError.invalidIdentity }
        return try send(input)
    }
}

/// Bounded native TCP/UDP sender. No DNS, proxy, TLS or fallback path.
/// For an existing-socket test the connection stays open across all sends.
public func sendCanary(_ input: ProbeInput) throws -> Int {
    try input.validate()
    let family = input.address.contains(":") ? AF_INET6 : AF_INET
    let kind = input.transport == "tcp" ? SOCK_STREAM : SOCK_DGRAM
    let fd = socket(family, kind, 0)
    guard fd >= 0 else { throw ProbeError.io(errno) }
    defer { close(fd) }
    guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw ProbeError.io(errno) }
    var one: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else { throw ProbeError.io(errno) }
    let deadline = ProcessInfo.processInfo.systemUptime + 20
    func writable() throws {
        let left = deadline - ProcessInfo.processInfo.systemUptime
        guard left > 0 else { throw ProbeError.deadline }
        var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let result = poll(&event, 1, Int32(min(left * 1000, 20_000)))
        guard result > 0 else { throw result == 0 ? ProbeError.deadline : ProbeError.io(errno) }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout.size(ofValue: error))
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { throw ProbeError.io(errno) }
        guard error == 0 else { throw ProbeError.io(error) }
        guard event.revents & Int16(POLLOUT) != 0 else { throw ProbeError.io(ECONNRESET) }
    }
    let result: Int32
    if family == AF_INET {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = input.port.bigEndian
        guard inet_pton(AF_INET, input.address, &address.sin_addr) == 1 else { throw ProbeError.invalidInput }
        result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    } else {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = input.port.bigEndian
        guard inet_pton(AF_INET6, input.address, &address.sin6_addr) == 1 else { throw ProbeError.invalidInput }
        result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
    }
    guard result == 0 || errno == EINPROGRESS else { throw ProbeError.io(errno) }
    try writable()
    let bytes = Array((input.canary + "\n").utf8)
    var total = 0
    for index in 0..<input.sendCount {
        if index > 0 { Thread.sleep(forTimeInterval: Double(input.intervalMilliseconds) / 1000) }
        var offset = 0
        while offset < bytes.count {
            try writable()
            let sent = bytes.withUnsafeBytes { pointer in
                Darwin.send(fd, pointer.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if sent < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard sent > 0 else { throw ProbeError.io(errno) }
            if kind == SOCK_DGRAM && sent != bytes.count { throw ProbeError.io(EMSGSIZE) }
            offset += sent
            total += sent
        }
    }
    return total // bytes accepted by local kernel, NOT bytes received by oracle
}
