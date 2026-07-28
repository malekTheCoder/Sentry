import Foundation
import MacStatKit

/// Nil-handling wrapper around `MacStatKit.MetricFormatter`.
///
/// The number rendering itself lives in `MetricFormatter` so the menu bar and
/// the dropdown never format the same value two different ways; this layer
/// exists only to turn Optionals into `placeholder` so "no data" can never be
/// mistaken for a real zero anywhere in the dropdown (plan §3.2 P5).
enum MetricFormatting {
    static let placeholder = "—"

    /// Primary entry point: format an optional value in its metric's unit.
    static func value(_ value: Double?, unit: MetricUnit, compact: Bool = false) -> String {
        guard let value, value.isFinite else { return placeholder }
        return compact
            ? MetricFormatter.compact(value, unit: unit)
            : MetricFormatter.detailed(value, unit: unit)
    }

    static func value(_ value: Double?, metric: MetricID, compact: Bool = false) -> String {
        self.value(value, unit: metric.unit, compact: compact)
    }

    static func seriesValue(_ value: Double?, metric: ChartMetric, compact: Bool = false) -> String {
        self.value(value, unit: metric.unit, compact: compact)
    }

    // MARK: Convenience shims

    static func percent(_ value: Double?, decimals: Int = 0) -> String {
        self.value(value, unit: .percent, compact: decimals == 0)
    }

    static func watts(_ value: Double?) -> String {
        self.value(value, unit: .watts)
    }

    static func celsius(_ value: Double?) -> String {
        self.value(value, unit: .celsius)
    }

    static func volts(_ millivolts: Int?) -> String {
        value(millivolts.map { Double($0) }, unit: .millivolts)
    }

    static func amps(_ milliamps: Int?) -> String {
        value(milliamps.map { Double($0) }, unit: .milliamps)
    }

    static func integer(_ value: Int?) -> String {
        self.value(value.map { Double($0) }, unit: .count)
    }

    static func bytes(_ value: UInt64?) -> String {
        self.value(value.map { Double($0) }, unit: .bytes)
    }

    static func bytesPerSecond(_ value: Double?) -> String {
        self.value(value, unit: .bytesPerSecond)
    }

    /// "up 3d 4h". The "up " prefix is the dropdown header's phrasing; the
    /// bare duration comes from `MetricFormatter.uptime`.
    static func uptime(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return placeholder }
        return "up " + MetricFormatter.uptime(interval)
    }

    /// Battery time-to-full/empty. IOKit uses negative values (commonly -1)
    /// for "still calculating", which must not render as a duration.
    static func minutesRemaining(_ minutes: Int?) -> String {
        guard let minutes, minutes >= 0 else { return placeholder }
        return value(Double(minutes), unit: .minutes)
    }
}
