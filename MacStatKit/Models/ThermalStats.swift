import Foundation

/// Phase 0 skeleton — fields fleshed out in Phase 1 per plan §5.8.
public struct ThermalStats: Codable, Sendable {
    public enum PressureLevel: String, Codable, Sendable {
        case nominal, fair, serious, critical
    }

    public var socTemperatureCelsius: Double?
    public var fanRPMs: [Double]
    public var pressureLevel: PressureLevel
    public var isThrottling: Bool

    public init(
        socTemperatureCelsius: Double? = nil,
        fanRPMs: [Double] = [],
        pressureLevel: PressureLevel = .nominal,
        isThrottling: Bool = false
    ) {
        self.socTemperatureCelsius = socTemperatureCelsius
        self.fanRPMs = fanRPMs
        self.pressureLevel = pressureLevel
        self.isThrottling = isThrottling
    }
}
