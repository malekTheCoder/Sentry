import Foundation

// MARK: - EnergyIntegrator: watts-over-time → kilowatt-hours

/// Turns a series of `(timestamp, watts)` samples into cumulative energy.
/// The arithmetic behind the Dashboard's energy card ("0.42 kWh today"),
/// factored into MacStatKit like `BatteryHealthForecast` /
/// `WidgetBatteryHistory` so the integration rule is unit-testable without a
/// database or a view.
///
/// Left-Riemann step integration with a per-gap cap, matching the convention
/// `getSessionResourceReport`'s throttling-seconds estimate already
/// established: each sample's wattage is assumed to hold until the next
/// sample, but never for longer than `maximumGap`. The cap is what makes
/// sleep honest — a Mac that slept eight hours between two 20 W samples
/// consumed ~nothing in that gap, not 160 Wh, and the samples simply aren't
/// there while it sleeps.
public enum EnergyIntegrator {

    /// Default gap cap. Comfortably above the slowest polling tier, far
    /// below any realistic sleep window.
    public static let maximumGap: TimeInterval = 300

    /// - Parameters:
    ///   - samples: `(timestamp, watts)` in any order; sorted internally.
    ///     Non-finite or negative wattages are dropped (a negative system
    ///     power reading is a sensor artifact, not generation).
    ///   - maximumGap: see `maximumGap`. Callers integrating rolled-up tiers
    ///     (hourly/daily averages) should pass ~1.5× the bucket width.
    /// - Returns: kilowatt-hours, ≥ 0.
    public static func kilowattHours(
        samples: [(timestamp: Date, watts: Double)],
        maximumGap: TimeInterval = maximumGap
    ) -> Double {
        let clean = samples
            .filter { $0.watts.isFinite && $0.watts >= 0 }
            .sorted { $0.timestamp < $1.timestamp }
        guard clean.count >= 2 else { return 0 }

        var joules: Double = 0
        for index in 1..<clean.count {
            let previous = clean[index - 1]
            let gap = clean[index].timestamp.timeIntervalSince(previous.timestamp)
            guard gap > 0 else { continue }
            joules += previous.watts * min(gap, maximumGap)
        }
        return joules / 3_600_000
    }
}
