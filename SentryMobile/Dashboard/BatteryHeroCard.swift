import SwiftUI
import SentryKit

/// Plan §12.1: "Battery hero card (charge arc, W in, health, cycles, time
/// remaining)." iOS sibling of `Sentry/Dropdown/ModuleCards/BatteryHeroCard.swift`
/// — same charge-arc technique (`Circle().trim(from:to:)`), same "every field
/// below `chargePercent` is Optional, missing renders an em dash not a
/// fabricated zero" discipline (P5). Not a byte-for-byte port: no sparkline
/// (this build's `DashboardViewModel` only exposes `latestSnapshot`, a single
/// point, not a `MetricSeries` history), and the diagnostics banner
/// (charging-paused reasons, adapter clause assembly) is trimmed to the
/// handful of rows plan §12.1 actually calls out — a phone card competing for
/// space with 7 metric cards below it doesn't need the Mac dropdown's full
/// diagnostic sentence.
/// The redesign handoff's battery hero (iOS 2b): a 32pt numeral with the
/// status sentence beside it, a 4pt progress hairline, then the detail
/// ledger — flat on the screen, no card, no arc. Status color appears only
/// as data (the bolt, the hairline fill).
struct BatteryHeroCard: View {
    @Environment(\.themePalette) private var palette

    /// `nil` when the latest snapshot has no `battery` sub-struct — a Mac
    /// with no smart battery controller (a desktop, or a laptop mid-IOKit
    /// hiccup), not "0%". See `SystemSnapshot`'s doc comment: every
    /// sub-struct is optional precisely so a missing capability produces a
    /// smaller valid snapshot, never a fake reading.
    let battery: BatteryStats?

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacingRow) {
            if let battery {
                hero(for: battery)
                progressHairline(for: battery)
                VStack(alignment: .leading, spacing: 3) {
                    DashboardDetailRow(label: timeLabel(for: battery), value: timeValue(for: battery))
                    DashboardDetailRow(label: String(localized: "Health"), value: MetricFormatting.percent(battery.healthPercent, decimals: 1))
                    DashboardDetailRow(label: String(localized: "Cycles"), value: MetricFormatting.integer(battery.cycleCount))
                }
            } else {
                unavailable
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: Hero

    private func hero(for battery: BatteryStats) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: palette.spacingRow) {
            HStack(alignment: .center, spacing: 4) {
                Text(MetricFormatting.percent(battery.chargePercent))
                    .font(palette.font(size: 32, weight: .semibold))
                    .monospacedDigit()
                    .tracking(-0.5)
                    .foregroundStyle(palette.textPrimary)
                if battery.isCharging {
                    // Paired icon so charge state isn't color-only.
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(statusColor(for: battery))
                        .accessibilityHidden(true)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(stateLabel(for: battery))
                    .font(palette.font(size: 14))
                    .foregroundStyle(palette.textSecondary)
                Text(wattageHeadline(for: battery))
                    .font(palette.font(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(palette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(MetricFormatting.percent(battery.chargePercent)), \(stateLabel(for: battery))")
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
        return palette.metricColor(.batteryChargePercent)
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
        if battery.isCharging { return String(localized: "Charging") }
        if battery.isPluggedIn { return String(localized: "Plugged in, not charging") }
        return String(localized: "On battery")
    }

    private func timeLabel(for battery: BatteryStats) -> String {
        battery.isCharging
            ? String(localized: "Time to full")
            : String(localized: "Time remaining")
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
/// sections. Mirrors `Sentry/Dropdown/ModuleCards/MetricCard.swift`'s
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
