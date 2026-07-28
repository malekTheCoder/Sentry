import Foundation

public struct Capabilities: Codable, Sendable {
    public var hasIOReport: Bool
    public var hasHIDSensors: Bool
    public var hasGPUStats: Bool
    public var chipName: String
    public var macModel: String
    public var macOSVersion: String

    public init(
        hasIOReport: Bool,
        hasHIDSensors: Bool,
        hasGPUStats: Bool,
        chipName: String,
        macModel: String,
        macOSVersion: String
    ) {
        self.hasIOReport = hasIOReport
        self.hasHIDSensors = hasHIDSensors
        self.hasGPUStats = hasGPUStats
        self.chipName = chipName
        self.macModel = macModel
        self.macOSVersion = macOSVersion
    }
}

/// Runs once at launch (and on macOS version change) to determine which
/// private-API-backed modules are usable on this Mac. `hasIOReport` reflects
/// a real probe (dlopen succeeded and at least one "Energy Model" channel
/// enumerated, via `IOReportBridge`/`ChannelResolver`); HID sensors and GPU
/// stats probing land separately — this is still the skeleton every UI
/// surface will query before rendering a module.
public enum CapabilityProbe {
    public static func run() -> Capabilities {
        // A fresh ChannelResolver enumerates "Energy Model" channels as
        // part of its init — cheap (no subscription/sampling), and exactly
        // what `hasIOReport` needs to answer: did dlopen succeed AND does
        // this Mac actually expose at least one channel we can read.
        let ioReportAvailable = IOReportBridge.shared.isAvailable
            && ChannelResolver(bridge: IOReportBridge.shared).hasAnyChannel

        return Capabilities(
            hasIOReport: ioReportAvailable,
            hasHIDSensors: false,
            hasGPUStats: false,
            chipName: "unknown",
            macModel: "unknown",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}
