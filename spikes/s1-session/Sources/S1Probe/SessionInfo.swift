import CoreGraphics
import Darwin
import Foundation
import Metal

/// A display as the session's window server reports it.
public struct DisplayInfo: Codable, Equatable, Sendable {
    public var id: UInt32
    public var isMain: Bool
    public var isBuiltin: Bool
    public var isActive: Bool
    public var isAsleep: Bool
    public var widthPoints: Int
    public var heightPoints: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Pixels per point; 2 on a Retina mode.
    public var scale: Double
    /// 0 when the mode does not report one (common for virtual displays).
    public var refreshRate: Double
    public var vendorNumber: UInt32
    public var modelNumber: UInt32

    public static func online() -> [DisplayInfo] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            let width = mode?.width ?? 0
            return DisplayInfo(
                id: id, isMain: CGDisplayIsMain(id) != 0, isBuiltin: CGDisplayIsBuiltin(id) != 0,
                isActive: CGDisplayIsActive(id) != 0, isAsleep: CGDisplayIsAsleep(id) != 0,
                widthPoints: width, heightPoints: mode?.height ?? 0,
                pixelWidth: mode?.pixelWidth ?? 0, pixelHeight: mode?.pixelHeight ?? 0,
                scale: width > 0 ? Double(mode?.pixelWidth ?? 0) / Double(width) : 0,
                refreshRate: mode?.refreshRate ?? 0,
                vendorNumber: CGDisplayVendorNumber(id), modelNumber: CGDisplayModelNumber(id)
            )
        }
    }
}

/// A Metal device. Listing one proves nothing about accelerated rendering (PLAN S1 bod 4);
/// `OffscreenResult` and `PresentationResult` are the evidence.
public struct MetalDeviceInfo: Codable, Equatable, Sendable {
    public var name: String
    public var architecture: String
    public var registryID: UInt64
    public var isLowPower: Bool
    public var isHeadless: Bool
    public var isRemovable: Bool
    public var hasUnifiedMemory: Bool
    public var recommendedMaxWorkingSetSize: UInt64
    public var isSystemDefault: Bool

    public static func all() -> [MetalDeviceInfo] {
        let defaultID = MTLCreateSystemDefaultDevice()?.registryID
        return MTLCopyAllDevices().map { device in
            MetalDeviceInfo(
                name: device.name, architecture: device.architecture.name, registryID: device.registryID,
                isLowPower: device.isLowPower, isHeadless: device.isHeadless, isRemovable: device.isRemovable,
                hasUnifiedMemory: device.hasUnifiedMemory,
                recommendedMaxWorkingSetSize: device.recommendedMaxWorkingSetSize,
                isSystemDefault: device.registryID == defaultID
            )
        }
    }
}

/// Screen Recording access of this process (GUI-10). The grant belongs to the responsible
/// app: Terminal in the zone session when the probe runs there.
public struct ScreenCaptureAccess: Codable, Equatable, Sendable {
    public var preflight: Bool
    /// Result of `CGRequestScreenCaptureAccess`, only when the run asked for the prompt.
    public var requested: Bool?

    public static func check(request: Bool) -> ScreenCaptureAccess {
        let requested = request ? CGRequestScreenCaptureAccess() : nil
        return ScreenCaptureAccess(preflight: CGPreflightScreenCaptureAccess(), requested: requested)
    }
}

/// Memory of every process of one UID (GUI-12: RAM per session), from the kernel's own
/// accounting. Without root only processes of the caller's UID are readable, which is exactly
/// the set wanted inside a zone.
public struct UIDProcesses: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var pid: Int32
        public var name: String
        public var physicalFootprintBytes: UInt64
    }

    public var uid: UInt32
    public var count: Int
    public var physicalFootprintBytes: UInt64
    /// Processes of the UID whose usage could not be read (they exited during the scan).
    public var unreadable: Int
    public var largest: [Entry]

    public static func capture(uid: uid_t = geteuid(), largest limit: Int = 10) -> UIDProcesses {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let listed = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))

        var entries: [Entry] = []
        var unreadable = 0
        for pid in pids.prefix(max(0, listed)) where pid > 0 {
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize, info.pbi_uid == uid else { continue }
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard status == 0 else {
                unreadable += 1
                continue
            }
            var name = [CChar](repeating: 0, count: 256)
            proc_name(pid, &name, UInt32(name.count))
            let processName = name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            entries.append(Entry(pid: pid, name: processName, physicalFootprintBytes: usage.ri_phys_footprint))
        }
        entries.sort { $0.physicalFootprintBytes > $1.physicalFootprintBytes }
        return UIDProcesses(
            uid: uid, count: entries.count, physicalFootprintBytes: entries.reduce(0) { $0 + $1.physicalFootprintBytes },
            unreadable: unreadable, largest: Array(entries.prefix(limit))
        )
    }
}
