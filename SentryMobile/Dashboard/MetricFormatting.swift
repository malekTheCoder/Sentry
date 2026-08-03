import Foundation
import SentryKit

/// iOS counterpart of `Sentry/Dropdown/MetricFormatting.swift` (the Mac app
/// target's nil-handling wrapper around `SentryKit.MetricFormatter`).
///
/// **Why this is a separate file instead of sharing the Mac one.** Same
/// reasoning as `ThemeColor+SwiftUI.swift` in `SentryMobile/Theme/`: the Mac
/// file's code is pure Foundation with no AppKit dependency and could run
/// unmodified here, but it's a member of the `Sentry` app target, not
/// `SentryKit`, and Xcode app targets can't import each other. Duplicating
/// this one small, stable file (rather than promoting it into `SentryKit`,
/// which would mean deciding a shared public formatting API for two apps
/// while three other agents are mid-flight on unrelated tabs) keeps that
/// refactor possible later without blocking this task on it now.
///
/// If/when someone does promote this to `SentryKit`, this file and its Mac
/// counterpart both get deleted in favor of the shared one; until then, a
/// change to either should be mirrored in the other by hand.
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

    static func integer(_ value: Int?) -> String {
        self.value(value.map { Double($0) }, unit: .count)
    }

    static func bytes(_ value: UInt64?) -> String {
        self.value(value.map { Double($0) }, unit: .bytes)
    }

    static func bytesPerSecond(_ value: Double?) -> String {
        self.value(value, unit: .bytesPerSecond)
    }

    static func megahertz(_ value: Double?) -> String {
        self.value(value, unit: .megahertz)
    }

    static func decimal(_ value: Double?) -> String {
        self.value(value, unit: .decimal)
    }

    static func decibelMilliwatts(_ value: Int?) -> String {
        self.value(value.map { Double($0) }, unit: .decibelMilliwatts)
    }

    static func megabitsPerSecond(_ value: Double?) -> String {
        self.value(value, unit: .megabitsPerSecond)
    }

    static func boolean(_ value: Bool?) -> String {
        guard let value else { return placeholder }
        return self.value(value ? 1.0 : 0.0, unit: .boolean)
    }

    /// Battery time-to-full/empty. IOKit uses negative values (commonly -1)
    /// for "still calculating", which must not render as a duration.
    static func minutesRemaining(_ minutes: Int?) -> String {
        guard let minutes, minutes >= 0 else { return placeholder }
        return value(Double(minutes), unit: .minutes)
    }

    /// Word form of `ThermalStats.PressureLevel` / `MemoryPressureLevel`,
    /// matching `MetricUnit.thermalLevel`'s vocabulary ("Nominal"/"Fair"/
    /// "Serious"/"Critical") so the two pressure concepts read consistently
    /// even though they're different enums with different raw representations.
    static func pressureLevel(_ level: ThermalStats.PressureLevel?) -> String {
        guard let level else { return placeholder }
        switch level {
        case .nominal: return String(localized: "Nominal")
        case .fair: return String(localized: "Fair")
        case .serious: return String(localized: "Serious")
        case .critical: return String(localized: "Critical")
        }
    }

    static func memoryPressureLevel(_ level: MemoryPressureLevel?) -> String {
        guard let level else { return placeholder }
        switch level {
        case .normal: return String(localized: "Normal")
        case .warning: return String(localized: "Warning")
        case .critical: return String(localized: "Critical")
        }
    }
}
