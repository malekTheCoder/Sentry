import Foundation

/// Shared "is now a good time" logic used by both `preflight_check` (a
/// one-shot recommendation) and `wait_until_ready` (a blocking gate on the
/// same kind of condition). Pulled out as pure, `nonisolated` functions —
/// not methods on `AlertEngine` or `MCPXPCService` — so the thresholds a
/// caller sees here can never silently drift from `AlertEngine.defaultRules`
/// (95°C SoC temp, thermal pressure ≥ serious, 90% sustained CPU): both read
/// the same constants.
public enum SystemAdvisor {

    /// Mirrors `AlertEngine.defaultRules(cooldown:)`'s "High temperature" and
    /// "Thermal throttling" thresholds — kept here as named constants so
    /// both call sites (the alert rule factory and this advisor) can be
    /// grepped together if either ever needs to change.
    public static let highSoCTempCelsius: Double = 95
    public static let highCPUPercent: Double = 90
    public static let lowBatteryPercent: Double = 20

    public struct Recommendation: Codable, Sendable {
        public var recommendation: String // "go" | "wait"
        public var reasons: [String]
        public var thermalPressure: String
        public var socTemperatureCelsius: Double?
        public var isThrottling: Bool
        public var cpuPercent: Double?
        public var onBattery: Bool
        public var batteryChargePercent: Double?
        public var lowPowerModeEnabled: Bool
        public var timestamp: Date
        /// Regression-based estimate of when the SoC temperature crosses back
        /// under `highSoCTempCelsius`, when a "wait" is thermal and the
        /// machine is measurably cooling — see `cooldownETASeconds(...)`.
        /// `nil` means "no defensible estimate", never "no wait needed":
        /// agents should schedule on this when present and fall back to
        /// polling (`wait_until_ready`) when absent.
        public var cooldownETASeconds: Double?

        public init(
            recommendation: String,
            reasons: [String],
            thermalPressure: String,
            socTemperatureCelsius: Double?,
            isThrottling: Bool,
            cpuPercent: Double?,
            onBattery: Bool,
            batteryChargePercent: Double?,
            lowPowerModeEnabled: Bool,
            timestamp: Date,
            cooldownETASeconds: Double? = nil
        ) {
            self.recommendation = recommendation
            self.reasons = reasons
            self.thermalPressure = thermalPressure
            self.socTemperatureCelsius = socTemperatureCelsius
            self.isThrottling = isThrottling
            self.cpuPercent = cpuPercent
            self.onBattery = onBattery
            self.batteryChargePercent = batteryChargePercent
            self.lowPowerModeEnabled = lowPowerModeEnabled
            self.timestamp = timestamp
            self.cooldownETASeconds = cooldownETASeconds
        }
    }

    /// - Parameter lowPowerModeEnabled: passed in rather than read via
    ///   `ProcessInfo` directly so this stays a pure function of its inputs
    ///   (and so `SentryMCP`/tests can supply a fixed value).
    public static func recommend(_ snapshot: SystemSnapshot, lowPowerModeEnabled: Bool) -> Recommendation {
        var reasons: [String] = []

        let thermal = snapshot.thermal
        let pressure = thermal?.pressureLevel ?? .nominal
        let isThrottling = thermal?.isThrottling ?? false
        let socTemp = thermal?.socTemperatureCelsius

        if isThrottling {
            reasons.append("Thermal throttling is currently active.")
        }
        if pressure == .serious || pressure == .critical {
            reasons.append("Thermal pressure is \(pressure.rawValue).")
        }
        if let socTemp, socTemp > highSoCTempCelsius {
            reasons.append("SoC temperature is \(Int(socTemp))°C, above \(Int(highSoCTempCelsius))°C.")
        }

        let cpuPercent = snapshot.cpu?.totalPercent
        if let cpuPercent, cpuPercent > highCPUPercent {
            reasons.append("CPU is already at \(Int(cpuPercent))%.")
        }

        let onBattery = snapshot.battery.map { !$0.isPluggedIn } ?? false
        let chargePercent = snapshot.battery?.chargePercent
        if onBattery, let chargePercent, chargePercent < lowBatteryPercent {
            reasons.append("On battery at \(Int(chargePercent))% — consider plugging in first.")
        }
        if lowPowerModeEnabled {
            reasons.append("Low Power Mode is on — expect reduced performance.")
        }

        return Recommendation(
            recommendation: reasons.isEmpty ? "go" : "wait",
            reasons: reasons,
            thermalPressure: pressure.rawValue,
            socTemperatureCelsius: socTemp,
            isThrottling: isThrottling,
            cpuPercent: cpuPercent,
            onBattery: onBattery,
            batteryChargePercent: chargePercent,
            lowPowerModeEnabled: lowPowerModeEnabled,
            timestamp: snapshot.timestamp
        )
    }

    // MARK: - Cool-down ETA

    /// Minimum samples/span before the ETA fit will speak, and the cooling
    /// rate below which "cooling" is indistinguishable from sensor noise
    /// (0.3 °C per minute).
    public static let cooldownMinimumSamples = 4
    public static let cooldownMinimumSpan: TimeInterval = 120
    public static let cooldownMinimumRatePerSecond: Double = 0.005

    /// ETAs beyond this collapse to `nil` — a linear fit on a few minutes of
    /// cooling has nothing honest to say about the next hour.
    public static let cooldownMaximumETA: TimeInterval = 30 * 60

    /// Least-squares estimate of seconds until the SoC temperature crosses
    /// back under `threshold`, from recent `(timestamp, °C)` samples.
    ///
    /// This is what turns the thermal gate from a poll ("still throttled?")
    /// into a schedule ("thermal nominal in ~4 min") for autonomous agents.
    /// Returns `nil` — never a guess — when the latest reading is already
    /// under the threshold, the machine isn't measurably cooling (heating,
    /// flat, or within noise), the data is too thin (`cooldownMinimumSamples`
    /// / `cooldownMinimumSpan`), or the extrapolation lands beyond
    /// `cooldownMaximumETA`.
    public static func cooldownETASeconds(
        tempSamples: [(timestamp: Date, celsius: Double)],
        threshold: Double = highSoCTempCelsius
    ) -> TimeInterval? {
        let clean = tempSamples
            .filter { $0.celsius.isFinite }
            .sorted { $0.timestamp < $1.timestamp }
        guard clean.count >= cooldownMinimumSamples,
              let first = clean.first, let last = clean.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= cooldownMinimumSpan,
              last.celsius > threshold else {
            return nil
        }

        let n = Double(clean.count)
        let xs = clean.map { $0.timestamp.timeIntervalSince(first.timestamp) }
        let ys = clean.map(\.celsius)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let sumXX = xs.reduce(0) { $0 + $1 * $1 }
        let denominator = n * sumXX - sumX * sumX
        guard denominator > 0 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denominator          // °C/second

        guard slope <= -cooldownMinimumRatePerSecond else { return nil }
        let eta = (last.celsius - threshold) / -slope
        guard eta > 0, eta <= cooldownMaximumETA else { return nil }
        return eta
    }
}

/// Parsed form of `wait_until_ready`'s `condition` string argument —
/// `"thermal_normal"`, `"cpu_below:N"`, `"battery_above:N"`, or
/// `"memory_below:N"` (percent used). A small hand-rolled grammar rather
/// than JSON: MCP tool arguments are meant to read naturally in a client's
/// tool-call log, and a single string is easier for a model to get right
/// than a nested condition object for this small a vocabulary.
public enum WaitCondition: Sendable, Equatable {
    case thermalNormal
    case cpuBelow(Double)
    case batteryAbove(Double)
    case memoryBelow(Double)
    /// `"ready"`: `AgentPreflight`'s full snapshot-only verdict — satisfied
    /// when `preflight_check` would say `proceed` or `caution` (never blocks
    /// on caution-level reasons; see `AgentPreflight.isReady`). This is the
    /// condition that makes `wait_until_ready` and `preflight_check` two
    /// views of one policy rather than two policies.
    case ready

    public init?(_ raw: String) {
        if raw == "thermal_normal" {
            self = .thermalNormal
            return
        }
        if raw == "ready" {
            self = .ready
            return
        }
        let parts = raw.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let value = Double(parts[1]) else { return nil }
        switch parts[0] {
        case "cpu_below": self = .cpuBelow(value)
        case "battery_above": self = .batteryAbove(value)
        case "memory_below": self = .memoryBelow(value)
        default: return nil
        }
    }

    /// Absent data (no battery, no thermal sensor yet) is treated as
    /// "satisfied" — a condition Sentry can't measure shouldn't block an
    /// agent forever; see `wait_until_ready`'s doc comment.
    public func isSatisfied(by snapshot: SystemSnapshot) -> Bool {
        switch self {
        case .thermalNormal:
            guard let thermal = snapshot.thermal else { return true }
            return !thermal.isThrottling && thermal.pressureLevel != .serious && thermal.pressureLevel != .critical
        case .cpuBelow(let threshold):
            guard let cpu = snapshot.cpu else { return true }
            return cpu.totalPercent < threshold
        case .batteryAbove(let threshold):
            guard let battery = snapshot.battery else { return true }
            return battery.chargePercent > threshold
        case .memoryBelow(let threshold):
            guard let memory = snapshot.memory, memory.totalBytes > 0 else { return true }
            let percentUsed = Double(memory.usedBytes) / Double(memory.totalBytes) * 100
            return percentUsed < threshold
        case .ready:
            // Delegates to the shared preflight policy — the "absent data is
            // satisfied" posture holds automatically, since a snapshot with
            // no thermal/CPU/battery/memory data produces no reasons.
            return AgentPreflight.isReady(snapshot)
        }
    }
}
