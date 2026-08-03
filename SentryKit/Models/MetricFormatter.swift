import Foundation

/// Formats metric values for display. Shared between the menu bar renderer,
/// the dropdown, and (later) the CLI, so the same number never renders two
/// different ways in two places.
public enum MetricFormatter {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f
    }()

    /// Placeholder for a value that isn't a real reading. Callers render
    /// this rather than a zero, so "no data" never masquerades as data (P5).
    public static let unavailable = "—"

    /// Compact form for the menu bar, where horizontal space is scarce:
    /// "72%", "45.8W", "1.2 GB", "8.4 MB/s".
    ///
    /// Pass `includeUnit: false` to get the bare number. That's a real
    /// parameter rather than something callers string-strip afterwards,
    /// because several units are *transformed* on the way out (mV→V, mA→A,
    /// MHz→GHz, °C→"58°") — string-stripping the declared suffix silently
    /// fails for those, and leaves a trailing space for the spaced ones.
    public static func compact(_ value: Double, unit: MetricUnit, includeUnit: Bool = true) -> String {
        // A public formatter on the every-3s draw path must not trap: Int()
        // and Int64() of NaN/infinity are runtime traps that no do/catch can
        // rescue, and `max(nan, 0)` returns nan rather than clamping (P5).
        guard value.isFinite else { return unavailable }
        let number = compactNumber(value, unit: unit)
        guard includeUnit else { return number }
        return number + compactSuffix(value, unit: unit)
    }

    /// The numeric portion only, already scaled to whatever unit
    /// `compactSuffix` will name.
    private static func compactNumber(_ value: Double, unit: MetricUnit) -> String {
        switch unit {
        case .percent:
            return "\(Int(value.rounded()))"
        case .watts:
            return value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        case .celsius:
            return String(format: "%.0f", value)
        case .megahertz:
            return value >= 1000
                ? String(format: "%.1f", value / 1000)
                : String(format: "%.0f", value)
        case .bytes:
            return byteFormatter.string(fromByteCount: Int64(clampToInt64(value)))
        case .bytesPerSecond:
            return byteFormatter.string(fromByteCount: Int64(clampToInt64(value)))
        case .operationsPerSecond, .count:
            return String(format: "%.0f", value)
        case .minutes:
            // IOKit reports -1 for time-to-full/empty while it recalculates
            // (plan §5.1). Rendering that as "-1m" states a negative
            // duration as fact; it means "not known yet".
            guard value >= 0 else { return unavailable }
            // Same rounding trap as `clampToInt64` above: `Double(Int.max - 1)`
            // rounds up to 2^63 and traps `Int(...)` for a huge input.
            let total = Int(min(value, Double(Int.max).nextDown))
            let hours = total / 60
            let mins = total % 60
            return hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
        case .seconds:
            return uptime(value)
        case .decimal:
            return String(format: "%.2f", value)
        case .thermalLevel:
            switch Int(value.rounded()) {
            case ..<1: return "Nominal"
            case 1: return "Fair"
            case 2: return "Serious"
            default: return "Critical"
            }
        case .millivolts:
            return String(format: "%.2f", value / 1000)
        case .milliamps:
            return String(format: "%.2f", value / 1000)
        case .decibelMilliwatts:
            return String(format: "%.0f", value)
        case .megabitsPerSecond:
            return String(format: "%.0f", value)
        case .boolean:
            return value > 0 ? "Yes" : "No"
        }
    }

    /// The suffix that matches whatever scaling `compactNumber` applied —
    /// note this is value-dependent (MHz vs GHz), which is exactly why a
    /// static `MetricUnit.suffix` can't be string-stripped reliably.
    private static func compactSuffix(_ value: Double, unit: MetricUnit) -> String {
        switch unit {
        case .percent: return "%"
        case .watts: return "W"
        case .celsius: return "°"
        case .megahertz: return value >= 1000 ? "GHz" : "MHz"
        case .bytes: return ""
        case .bytesPerSecond: return "/s"
        case .operationsPerSecond: return " IOPS"
        case .minutes, .seconds, .boolean, .count, .decimal, .thermalLevel: return ""
        case .millivolts: return "V"
        case .milliamps: return "A"
        case .decibelMilliwatts: return " dBm"
        case .megabitsPerSecond: return " Mbps"
        }
    }

    /// Saturates rather than traps. `Int64(someHugeDouble)` is a runtime trap.
    ///
    /// The upper bound is deliberately `Double(Int64.max).nextDown`, not
    /// `Double(Int64.max)`: `Int64.max` (2^63 - 1) isn't exactly
    /// representable as a `Double` (52-bit mantissa vs. 63-bit integer), so
    /// it rounds *up* to 2^63 on conversion — which then traps when
    /// converted back to `Int64` for a huge input value. `.nextDown` is the
    /// largest `Double` that is still safely < `Int64.max`.
    private static func clampToInt64(_ value: Double) -> Double {
        min(max(value, 0), Double(Int64.max).nextDown)
    }

    /// Longer form for the dropdown, where a couple more characters are fine.
    public static func detailed(_ value: Double, unit: MetricUnit) -> String {
        guard value.isFinite else { return unavailable }
        switch unit {
        case .percent:
            return String(format: "%.1f%%", value)
        case .watts:
            // One decimal, not two: charge wattage wanders by whole watts
            // sample to sample, so "25.50 W" is false precision — and it
            // read that way on the dashboard hero ("Charging at 25.50 W").
            return String(format: "%.1f W", value)
        case .celsius:
            return String(format: "%.1f °C", value)
        default:
            return compact(value, unit: unit)
        }
    }

    /// "up 3d 4h" / "up 5h 12m" / "up 42m".
    public static func uptime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return unavailable }
        // Same rounding trap as `clampToInt64` above: `Double(Int.max - 1)`
        // rounds up to 2^63 and traps `Int(...)` for a huge input.
        let total = Int(min(max(seconds, 0), Double(Int.max).nextDown))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
