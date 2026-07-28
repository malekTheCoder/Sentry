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
/// private-API-backed modules are usable on this Mac. Real probing (dlopen
/// IOReport, enumerate HID services) lands in Phase 1 — this is the skeleton
/// every UI surface will query before rendering a module.
public enum CapabilityProbe {
    public static func run() -> Capabilities {
        Capabilities(
            hasIOReport: false,
            hasHIDSensors: false,
            hasGPUStats: false,
            chipName: "unknown",
            macModel: "unknown",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}
