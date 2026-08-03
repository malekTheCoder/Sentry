import Foundation

/// One named sensor reading from `HIDSensorBridge.readAllTemperatures()` —
/// Apple Silicon exposes per-cluster (E-cluster, P-cluster0/1, GPU, etc.)
/// temperature sensors via the same private HID vendor page
/// `socTemperatureCelsius` already reads the hottest of, not truly
/// per-physical-core sensors (Apple doesn't expose those), so `name` is
/// whatever label the sensor service itself reports (or a positional
/// fallback like "Sensor 3" if it doesn't) rather than a promise of a named
/// CPU core.
public struct ThermalSensorReading: Codable, Sendable, Equatable {
    public var name: String
    public var celsius: Double

    public init(name: String, celsius: Double) {
        self.name = name
        self.celsius = celsius
    }
}

/// Phase 0 skeleton — fields fleshed out in Phase 1 per plan §5.8.
public struct ThermalStats: Codable, Sendable {
    public enum PressureLevel: String, Codable, Sendable {
        case nominal, fair, serious, critical
    }

    public var socTemperatureCelsius: Double?
    public var fanRPMs: [Double]
    public var pressureLevel: PressureLevel
    public var isThrottling: Bool
    /// Best-effort per-sensor breakdown behind `socTemperatureCelsius`'s
    /// single hottest-reading number — empty wherever the HID bridge is
    /// unavailable, same degrade-gracefully posture as every other
    /// `HIDSensorBridge`-derived field.
    public var perSensorCelsius: [ThermalSensorReading] = []

    public init(
        socTemperatureCelsius: Double? = nil,
        fanRPMs: [Double] = [],
        pressureLevel: PressureLevel = .nominal,
        isThrottling: Bool = false,
        perSensorCelsius: [ThermalSensorReading] = []
    ) {
        self.socTemperatureCelsius = socTemperatureCelsius
        self.fanRPMs = fanRPMs
        self.pressureLevel = pressureLevel
        self.isThrottling = isThrottling
        self.perSensorCelsius = perSensorCelsius
    }
}
