import CryptoKit
import Darwin
import Foundation
import QuartzCore

public enum InstrumentClock {
    public static func now() -> Double { CACurrentMediaTime() }
    public static func stamp() throws -> ClockStamp {
        let before = now()
        let utc = Date().timeIntervalSince1970
        let after = now()
        var size = 0
        try require(sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0 && (2...128).contains(size), "boot clock domain unavailable")
        var bytes = [UInt8](repeating: 0, count: size)
        try require(sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0, "boot clock domain unavailable")
        let hash = SHA256.hash(data: Data(bytes.prefix(size))).map { String(format: "%02x", $0) }.joined()
        return ClockStamp(monotonic: (before + after) / 2, utc: utc, bootIDHash: hash, uncertainty: after - before)
    }
    static func wait(until deadline: Double) {
        while now() < deadline { Thread.sleep(forTimeInterval: min(0.02, deadline - now())) }
    }
}
public enum SystemRAM {
    static func sample() throws -> RAMSample {
        var physical: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        try require(sysctlbyname("hw.memsize", &physical, &size, nil, 0) == 0, "hw.memsize unavailable")
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var page: vm_size_t = 0
        try require(host_page_size(host, &page) == KERN_SUCCESS, "host page size unavailable")
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        try require(status == KERN_SUCCESS, "HOST_VM_INFO64 unavailable")
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        let swapOK = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
        var pressure: Int32 = 0
        size = MemoryLayout<Int32>.size
        let pressureOK = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0
        return RAMSample(time: InstrumentClock.now(), physicalBytes: physical, pageBytes: UInt64(page), freePages: UInt64(info.free_count),
            swapUsedBytes: swapOK ? swap.xsu_used : nil, pressure: pressureOK ? pressure : nil)
    }
}
