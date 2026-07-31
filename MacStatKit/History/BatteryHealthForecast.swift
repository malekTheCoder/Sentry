import Foundation

// MARK: - BatteryHealthForecast: "80% around March 2027", from daily health rows

/// Least-squares projection of battery health decline — the answer to "at the
/// current degradation rate, when does health cross 80%?", which is the
/// service-relevant threshold (Apple's own "consider battery service" line
/// and the industry's usual warranty definition of a worn battery).
///
/// A pure function over `(Date, Double)` pairs, in MacStatKit rather than the
/// Dashboard card that displays it, for the same reason `WidgetBatteryHistory`
/// and `SyntheticDailyHealth` live here: the projection rule is the part
/// worth unit-testing, and it has nothing to do with SwiftUI.
///
/// **Honesty rules (P5), spelled out because a forecast is the easiest place
/// in this app to lie with confidence:**
/// - No projection at all from under `minimumSamples` points or under
///   `minimumSpan` of real elapsed time — two weeks of data cannot speak
///   about years.
/// - A flat or improving fit is reported as `.stable`, not as "never" —
///   "never" is not something a linear fit can know.
/// - A crossing more than `horizon` out is also `.stable`: extrapolating a
///   noisy percent-per-month slope a decade forward is astrology, and the
///   honest summary of "declining a hair per year" is "no service date in
///   sight," not a specific month in 2037.
/// - Health already at/below the threshold reports `.alreadyBelow` so the
///   caller never renders a future date for a past event.
public enum BatteryHealthForecast: Equatable, Sendable {
    /// Not enough points or span to say anything defensible.
    case insufficientData
    /// No meaningful decline within `horizon` at the fitted rate.
    case stable
    /// Latest reading is already at/below the threshold.
    case alreadyBelow
    /// Fitted decline crosses `threshold` at `date`, declining at
    /// `percentPerMonth` (a negative-slope magnitude, i.e. positive number).
    case crosses(date: Date, percentPerMonth: Double)

    /// The service-relevant health line, in percent.
    public static let threshold: Double = 80

    /// Minimum samples and minimum first→last span before projecting.
    public static let minimumSamples = 5
    public static let minimumSpan: TimeInterval = 14 * 24 * 3600

    /// Forecasts further out than this collapse to `.stable`.
    public static let horizon: TimeInterval = 5 * 365 * 24 * 3600

    /// - Parameter samples: `(timestamp, healthPercent)` in any order; sorted
    ///   internally. Non-finite health values are dropped rather than allowed
    ///   to poison the fit.
    public static func forecast(
        samples: [(timestamp: Date, health: Double)],
        now: Date = Date()
    ) -> BatteryHealthForecast {
        let clean = samples
            .filter { $0.health.isFinite }
            .sorted { $0.timestamp < $1.timestamp }
        guard clean.count >= minimumSamples,
              let first = clean.first, let last = clean.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= minimumSpan else {
            return .insufficientData
        }
        if last.health <= threshold { return .alreadyBelow }

        // Ordinary least squares on (seconds since first sample, health%).
        let n = Double(clean.count)
        let xs = clean.map { $0.timestamp.timeIntervalSince(first.timestamp) }
        let ys = clean.map(\.health)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let sumXX = xs.reduce(0) { $0 + $1 * $1 }
        let denominator = n * sumXX - sumX * sumX
        guard denominator > 0 else { return .insufficientData }
        let slope = (n * sumXY - sumX * sumY) / denominator          // %/second
        let intercept = (sumY - slope * sumX) / n

        guard slope < 0 else { return .stable }

        // a + b·t = threshold  →  t = (threshold − a) / b
        let crossingOffset = (threshold - intercept) / slope
        let crossingDate = first.timestamp.addingTimeInterval(crossingOffset)
        guard crossingDate > now else { return .alreadyBelow }
        guard crossingDate.timeIntervalSince(now) <= horizon else { return .stable }

        let secondsPerMonth: TimeInterval = 30.44 * 24 * 3600
        return .crosses(date: crossingDate, percentPerMonth: -slope * secondsPerMonth)
    }
}
