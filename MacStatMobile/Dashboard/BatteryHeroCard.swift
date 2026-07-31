import SwiftUI
import MacStatKit

/// Plan §12.1: "Battery hero card (charge arc, W in, health, cycles, time
/// remaining)." iOS sibling of `MacStat/Dropdown/ModuleCards/BatteryHeroCard.swift`
/// — same charge-arc technique (`Circle().trim(from:to:)`), same "every field
/// below `chargePercent` is Optional, missing renders an em dash not a
/// fabricated zero" discipline (P5). Not a byte-for-byte port: no sparkline
/// (this build's `DashboardViewModel` only exposes `latestSnapshot`, a single
/// point, not a `MetricSeries` history), and the diagnostics banner
/// (charging-paused reasons, adapter clause assembly) is trimmed to the
/// handful of rows plan §12.1 actually calls out — a phone card competing for
/// space with 7 metric cards below it doesn't need the Mac dropdown's full
/// diagnostic sentence.
struct BatteryHeroCard: View {
    @Environment(\.themePalette) private var palette

    /// `nil` when the latest snapshot has no `battery` sub-struct — a Mac
    /// with no smart battery controller (a desktop, or a laptop mid-IOKit
    /// hiccup), not "0%". See `SystemSnapshot`'s doc comment: every
    /// sub-struct is optional precisely so a missing capability produces a
    /// smaller valid snapshot, never a fake reading.
    let battery: BatteryStats?

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            if let battery {
                HStack(alignment: .center, spacing: palette.spacing * 2) {
                    chargeArc(for: battery)
                    summary(for: battery)
                }
            } else {
                unavailable
            }
        }
        .padding(palette.spacing * 1.6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(palette)
    }

    // MARK: Unavailable

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Battery Unavailable", systemImage: "battery.slash")
                .font(palette.font(size: 13, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
            Text("This Mac reported no battery data.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }

    // MARK: Arc

    private func chargeArc(for battery: BatteryStats) -> some View {
        let fraction = min(max(battery.chargePercent / 100, 0), 1)
        let tint = arcColor(for: battery)
        return ZStack {
            Circle()
                .stroke(palette.separator, lineWidth: 8)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))  // 12 o'clock start, matches Mac arc
                .animation(.easeInOut(duration: 0.3), value: fraction)
            VStack(spacing: 0) {
                // Big numeric readout — true SF Mono (`design: .monospaced`),
                // not just `.monospacedDigit()` on the system font, per the
                // Nocturne redesign spec's "SF Mono tabular for every
                // numeric readout."
                Text(MetricFormatting.percent(battery.chargePercent))
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.textPrimary)
                if battery.isCharging {
                    // Paired icon so charge state isn't color-only.
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(tint)
                }
            }
        }
        .frame(width: 86, height: 86)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Charge \(MetricFormatting.percent(battery.chargePercent))")
    }

    private func arcColor(for battery: BatteryStats) -> Color {
        if battery.isCharging { return palette.success }
        if battery.chargePercent <= 10 { return palette.danger }
        if battery.chargePercent <= 20 { return palette.warning }
        return palette.metricColor(.batteryChargePercent)
    }

    // MARK: Summary

    private func summary(for battery: BatteryStats) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(wattageHeadline(for: battery))
                .font(palette.font(size: 14, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
            Text(stateLabel(for: battery))
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)

            DashboardDetailRow(label: timeLabel(for: battery), value: timeValue(for: battery))
            DashboardDetailRow(label: "Health", value: MetricFormatting.percent(battery.healthPercent, decimals: 1))
            DashboardDetailRow(label: "Cycles", value: MetricFormatting.integer(battery.cycleCount))
        }
    }

    /// Charging shows what's going *in*; on battery it shows what's being
    /// drawn *out*. Both come from different fields, either of which can be
    /// nil — matches the Mac hero card's `wattageHeadline(for:)` exactly, so
    /// "W in" (plan's phrasing) and "on-battery draw" share one code path
    /// rather than the phone silently only ever showing one of the two.
    private func wattageHeadline(for battery: BatteryStats) -> String {
        let watts = battery.isCharging ? battery.chargingWatts : battery.systemPowerInWatts
        return MetricFormatting.watts(watts)
    }

    private func stateLabel(for battery: BatteryStats) -> String {
        if battery.isCharging { return "Charging" }
        if battery.isPluggedIn { return "Plugged in, not charging" }
        return "On battery"
    }

    private func timeLabel(for battery: BatteryStats) -> String {
        battery.isCharging ? "Time to full" : "Time remaining"
    }

    private func timeValue(for battery: BatteryStats) -> String {
        MetricFormatting.minutesRemaining(
            battery.isCharging ? battery.timeToFullMinutes : battery.timeToEmptyMinutes
        )
    }
}

// MARK: - DashboardDetailRow

/// Label/value pair shared by every card built in this task — battery
/// summary rows, sleep-status rows, and each of the 7 metric card detail
/// sections. Mirrors `MacStat/Dropdown/ModuleCards/MetricCard.swift`'s
/// `MetricDetailRow` (values arrive pre-formatted so nil-handling stays
/// centralized in `MetricFormatting`, not scattered across call sites).
struct DashboardDetailRow: View {
    @Environment(\.themePalette) private var palette

    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
            Spacer(minLength: palette.spacing)
            Text(value)
                .font(palette.font(size: 11))
                .monospacedDigit()
                .foregroundStyle(palette.textSecondary)
        }
    }
}
