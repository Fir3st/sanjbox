import Foundation
import SanjboxProbeKit

/// One S1 probe run: the context it ran in, then what the session offered.
///
/// The probe only measures. Whether a value passes a gate is decided afterwards against the
/// targets written in `inputs.md` before the run (GUIDE §7), so no field here says pass or fail.
public struct S1Measurement: Codable, Sendable {
    public var timestamp: Date
    public var probe = "sanjbox-s1-probe"
    public var caseID: String?
    public var context: ProbeContext
    public var mismatches: [Mismatch]
    /// nil without an expectation; false means the run is invalid and nothing else was measured.
    public var valid: Bool?
    public var uidProcesses: UIDProcesses?
    public var displays: [DisplayInfo]?
    public var metalDevices: [MetalDeviceInfo]?
    public var offscreen: OffscreenResult?
    public var presentation: PresentationResult?
    public var screenCapture: ScreenCaptureAccess?
    /// Section name to error for measurements that could not be taken; a failed section is a
    /// result (for example GUI-05 not passing), not a probe error.
    public var errors: [String: String]

    public init(
        timestamp: Date = Date(), caseID: String?, context: ProbeContext, mismatches: [Mismatch], valid: Bool?
    ) {
        self.timestamp = timestamp
        self.caseID = caseID
        self.context = context
        self.mismatches = mismatches
        self.valid = valid
        errors = [:]
    }
}
