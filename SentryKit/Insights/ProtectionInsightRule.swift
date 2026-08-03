import Foundation

/// One self-contained finding about this Mac.
///
/// **Contract every conforming rule must keep:**
/// 1. `evaluate` is a pure function of its `InsightContext`. No clocks, no
///    files, no `UserDefaults` — `context.now` is the only "now" there is.
/// 2. Return `nil` rather than a hedge. A rule with insufficient data says
///    nothing; it never emits a weakened insight with invented evidence.
/// 3. Every returned insight carries at least one `evidence` string quoting
///    a number actually measured on this machine.
///    `ProtectionInsightsEngine` drops evidence-free insights, so breaking
///    this makes the rule silently disappear rather than ship generic
///    advice.
/// 4. `id` is stable forever. It's the key a user's dismissal or snooze is
///    stored against.
public protocol ProtectionInsightRule: Sendable {
    /// Stable identifier, dotted, e.g. `"battery.high-soc-residency"`.
    var id: String { get }
    var category: InsightCategory { get }
    var domain: InsightDomain { get }
    func evaluate(_ context: InsightContext) -> ProtectionInsight?
}

public extension ProtectionInsightRule {
    var domain: InsightDomain { category.domain }
}

// MARK: - Phrasing

/// Number-to-copy helpers shared by every rule, so "68%" and "3.2 hours"
/// read identically no matter which rule produced them.
///
/// These deliberately round *down* the precision of what they're given —
/// a battery-health delta is quoted to one decimal, a residency percentage
/// to none. Reporting "67.8421%" would imply a measurement precision the
/// underlying 30-second sampling cadence doesn't have.
public enum InsightPhrasing {

    /// `0.68` → `"68%"`. Input is a 0…1 fraction, not an already-scaled
    /// percentage — the parameter label exists to make that unmissable at
    /// the call site.
    public static func percent(fraction: Double) -> String {
        guard fraction.isFinite else { return MetricFormatter.unavailable }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// `4.23` → `"4.2%"`. For values that are already percentages.
    public static func percentValue(_ value: Double, decimals: Int = 1) -> String {
        guard value.isFinite else { return MetricFormatter.unavailable }
        return String(format: "%.\(Swift.max(0, decimals))f%%", value)
    }

    public static func celsius(_ value: Double) -> String {
        guard value.isFinite else { return MetricFormatter.unavailable }
        return "\(Int(value.rounded()))°C"
    }

    public static func watts(_ value: Double) -> String {
        guard value.isFinite else { return MetricFormatter.unavailable }
        return value >= 10 ? String(format: "%.0f W", value) : String(format: "%.1f W", value)
    }

    /// Under an hour reads in minutes; above it, one decimal of hours.
    ///
    /// Every `String(localized:)` in this feature interpolates **only
    /// already-formatted `String`s**, never raw numerics. That's a
    /// deliberate house rule: `String.LocalizationValue`'s numeric
    /// interpolations bake a `%lld`/`%f` specifier into the extracted key,
    /// which pins the plural/decimal handling to the source language and
    /// makes the resulting catalog entries harder to translate than a plain
    /// `%@`. Formatting first also keeps rounding decisions in one place.
    public static func duration(hours: Double) -> String {
        guard hours.isFinite, hours >= 0 else { return MetricFormatter.unavailable }
        if hours < 1 {
            let minutes = "\(Int((hours * 60).rounded()))"
            return String(localized: "\(minutes) min")
        }
        let formatted = String(format: "%.1f", hours)
        return String(localized: "\(formatted) hours")
    }

    public static func days(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return MetricFormatter.unavailable }
        let whole = Int(value.rounded())
        guard whole != 1 else { return String(localized: "1 day") }
        let count = "\(whole)"
        return String(localized: "\(count) days")
    }

    /// Integer-day convenience so rules holding an `Int` day count don't
    /// round-trip through `Double`.
    public static func days(_ value: Int) -> String {
        days(Double(value))
    }

    /// Routed through `MetricFormatter` rather than a second
    /// `ByteCountFormatter` so a gigabyte renders the same here as it does
    /// in the menu bar (that type's doc comment: "the same number never
    /// renders two different ways in two places").
    public static func bytes(_ value: Double) -> String {
        MetricFormatter.compact(value, unit: .bytes)
    }
}
