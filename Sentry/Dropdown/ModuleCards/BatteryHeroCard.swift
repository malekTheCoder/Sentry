import SwiftUI
import SentryKit

/// The dropdown's battery hero, per the redesign handoff: a 34pt numeral
/// with a status sentence beside it, a 4pt progress hairline underneath,
/// then the detail ledger — flat on the popover, no card chrome, no arc.
/// The status color appears only as data (the hairline's fill and the
/// charging bolt), matching the handoff's accent rules.
///
/// Every field below `chargePercent` is Optional on `BatteryStats`; rows whose
/// value is missing render an em dash rather than a fabricated zero (P5).
struct BatteryHeroCard: View {
    @Environment(\.themePalette) private var palette

    let battery: BatteryStats?
    let powerSeries: MetricSeries?

    /// True while the app hasn't had a fair chance to hear from the slow
    /// battery tier yet — the caller computes it from session age. Renders a
    /// calm "Reading battery…" instead of a false "unavailable".
    var isWarmingUp: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacingRow) {
            if let battery {
                hero(for: battery)
                progressHairline(for: battery)
                detailLedger(for: battery)
                diagnostics(for: battery)
                if let powerSeries, !powerSeries.isEmpty {
                    SparklineChart(series: powerSeries, tint: statusColor(for: battery), height: 32)
                }
            } else {
                Text(isWarmingUp ? "Reading battery…" : "Battery Unavailable")
                    .font(palette.font(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                Text(isWarmingUp
                    ? "The first battery sample lands within about half a minute."
                    : "This Mac reported no battery data.")
                    .font(palette.font(size: 10))
                    .foregroundStyle(palette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Hero

    private func hero(for battery: BatteryStats) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: palette.spacingRow) {
            HStack(alignment: .center, spacing: 4) {
                Text(MetricFormatting.percent(battery.chargePercent))
                    .font(palette.font(size: 34, weight: .semibold))
                    .monospacedDigit()
                    .tracking(-0.5)
                    .foregroundStyle(palette.textPrimary)
                if battery.isCharging {
                    // Paired icon so charge state isn't color-only (plan §9.4).
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(statusColor(for: battery))
                        .accessibilityHidden(true)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(statusSentence(for: battery))
                    .font(palette.font(size: 12))
                    .foregroundStyle(palette.textSecondary)
                Text(wattageHeadline(for: battery))
                    .font(palette.font(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(palette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(MetricFormatting.percent(battery.chargePercent)), \(statusSentence(for: battery))")
    }

    /// One sentence carrying state and time together — "Charging — full in
    /// 48m", "On battery — 4h 12m left" — with clauses dropped when their
    /// field is nil rather than filled with zeros.
    private func statusSentence(for battery: BatteryStats) -> String {
        if battery.isCharging {
            let time = MetricFormatting.minutesRemaining(battery.timeToFullMinutes)
            return time == MetricFormatting.placeholder
                ? "Charging"
                : "Charging — full in \(time)"
        }
        if battery.isPluggedIn { return "Plugged in, not charging" }
        let time = MetricFormatting.minutesRemaining(battery.timeToEmptyMinutes)
        return time == MetricFormatting.placeholder
            ? "On battery"
            : "On battery — \(time) left"
    }

    private func progressHairline(for battery: BatteryStats) -> some View {
        let fraction = min(max(battery.chargePercent / 100, 0), 1)
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.surfaceElevated)
                Capsule()
                    .fill(statusColor(for: battery))
                    .frame(width: max(4, geometry.size.width * fraction))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private func statusColor(for battery: BatteryStats) -> Color {
        if battery.isCharging { return palette.success }
        if battery.chargePercent <= 10 { return palette.danger }
        if battery.chargePercent <= 20 { return palette.warning }
        return palette.metricColor(MetricID.batteryChargePercent)
    }

    // MARK: Details

    private func detailLedger(for battery: BatteryStats) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !battery.isCharging && !battery.isPluggedIn {
                MetricDetailRow(label: "Time remaining", value: timeValue(for: battery))
            } else if battery.isCharging {
                MetricDetailRow(label: "Time to full", value: timeValue(for: battery))
            }
            MetricDetailRow(label: "Health", value: MetricFormatting.percent(battery.healthPercent, decimals: 1))
            MetricDetailRow(label: "Cycles", value: MetricFormatting.integer(battery.cycleCount))
            MetricDetailRow(label: "Temp", value: MetricFormatting.celsius(battery.temperatureCelsius))
            MetricDetailRow(label: "Adapter", value: adapterDescription(for: battery))
        }
    }

    /// Charging shows what's going *in*; on battery it shows what's being
    /// drawn *out*. Both come from different fields, either of which can be nil.
    private func wattageHeadline(for battery: BatteryStats) -> String {
        let watts = battery.isCharging ? battery.chargingWatts : battery.systemPowerInWatts
        return MetricFormatting.watts(watts)
    }

    private func timeValue(for battery: BatteryStats) -> String {
        // Plugged in and not charging: neither clock is running — time to
        // empty reads 0m from IOKit, which would render as "0m remaining"
        // on a Mac that isn't draining at all.
        if !battery.isCharging && battery.isPluggedIn {
            return MetricFormatting.placeholder
        }
        return MetricFormatting.minutesRemaining(
            battery.isCharging ? battery.timeToFullMinutes : battery.timeToEmptyMinutes
        )
    }

    private func adapterDescription(for battery: BatteryStats) -> String {
        if let description = battery.adapterDescription, !description.isEmpty {
            if let rated = battery.adapterRatedWatts {
                return "\(description) · \(rated) W"
            }
            return description
        }
        if let rated = battery.adapterRatedWatts { return "\(rated) W" }
        return battery.isPluggedIn ? "Connected" : MetricFormatting.placeholder
    }

    // MARK: Diagnostics

    @ViewBuilder
    private func diagnostics(for battery: BatteryStats) -> some View {
        let text = diagnosticsText(for: battery)
        HStack(spacing: 5) {
            Image(systemName: diagnosticsSymbol(for: battery))
                .font(.system(size: 10))
            Text(text)
                .font(palette.font(size: 10))
                .monospacedDigit()
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(diagnosticsColor(for: battery))
        .frame(maxWidth: .infinity, alignment: .leading)
        // Plain sentence, no tinted pill behind it — the handoff allows
        // fills only on surface/hover/track, and status color is already
        // carried by the glyph and text.
    }

    /// The plan's example line is "Charging at 45.8 W — 20 V / 2.3 A via 100 W
    /// adapter"; each clause is dropped independently when its field is nil
    /// rather than substituting zeros.
    /// `BatteryStats.notChargingReasonText` already reads e.g. "Paused (code
    /// 4194305)" or "Paused — Optimized Battery Charging" — it's a full,
    /// human sentence, not a bare reason fragment, so this must not prepend
    /// its own "Paused —" on top (that produced "Paused — Paused (code …)").
    /// It can also legitimately read "Charging normally" when the reason
    /// code is present but zero, which is not a pause at all and must fall
    /// through to the ordinary charging/discharging text below.
    /// A full battery held at 100% on AC is macOS working as designed —
    /// the pause "reason" IOKit reports in that state must not render as a
    /// warning about anything.
    private static func isEffectivelyFull(_ battery: BatteryStats) -> Bool {
        battery.isPluggedIn && !battery.isCharging && battery.chargePercent >= 99.5
    }

    private func diagnosticsText(for battery: BatteryStats) -> String {
        if Self.isEffectivelyFull(battery) {
            return "Fully charged"
        }
        if let reason = battery.notChargingReasonText, Self.isPauseReason(reason) {
            return reason
        }
        if battery.isThermallyLimited {
            return "Paused — battery temperature"
        }
        guard battery.isCharging else {
            guard let draw = battery.systemPowerInWatts else {
                return battery.isPluggedIn ? "Plugged in" : "Discharging"
            }
            return "Drawing \(MetricFormatting.watts(draw))"
        }

        var line = battery.chargingWatts.map { "Charging at \(MetricFormatting.watts($0))" }
            ?? "Charging"
        var clauses: [String] = []
        if battery.voltageMV != nil || battery.amperageMA != nil {
            clauses.append("\(MetricFormatting.volts(battery.voltageMV)) / \(MetricFormatting.amps(battery.amperageMA))")
        }
        if let rated = battery.adapterRatedWatts {
            clauses.append("via \(rated) W adapter")
        }
        if !clauses.isEmpty {
            line += " — " + clauses.joined(separator: " ")
        }
        return line
    }

    private func diagnosticsColor(for battery: BatteryStats) -> Color {
        if Self.isEffectivelyFull(battery) { return palette.success }
        if battery.notChargingReasonText.map(Self.isPauseReason) == true || battery.isThermallyLimited {
            return palette.warning
        }
        return battery.isCharging ? palette.success : palette.textSecondary
    }

    private func diagnosticsSymbol(for battery: BatteryStats) -> String {
        if Self.isEffectivelyFull(battery) { return "battery.100" }
        if battery.notChargingReasonText.map(Self.isPauseReason) == true || battery.isThermallyLimited {
            return "exclamationmark.triangle.fill"
        }
        return battery.isCharging ? "bolt.fill" : "battery.50"
    }

    private static func isPauseReason(_ text: String) -> Bool {
        !text.isEmpty && text != "Charging normally"
    }
}
