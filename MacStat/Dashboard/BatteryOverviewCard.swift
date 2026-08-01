import SwiftUI
import MacStatKit

/// The Dashboard's battery block, redesigned as ONE card: charge ring and
/// live state on top, a labeled stat grid beside it, and the long-term
/// health trend + forecast as the card's own footer. Its predecessor split
/// this across two cards ("hero" and "health trend") whose mismatched
/// heights were the root of every layout hole this window has had; battery
/// is this app's soul and deserves one composed block, not two fragments.
///
/// Owns the same all-time `.daily` health query `BatteryHealthTrendCard`
/// owned, for the same reasons documented there (health moves over months;
/// the range picker is irrelevant to it).
struct BatteryOverviewCard: View {
    @Environment(\.themePalette) private var palette

    let historyStore: HistoryStore
    let battery: BatteryStats?
    /// See `DashboardView.isBatteryWarmingUp` — true during the launch
    /// window before the slow tier's first battery sample.
    let isWarmingUp: Bool

    @State private var healthSamples: DashboardViewModel.RangedSamples = []
    @State private var hasLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            if let battery {
                hero(for: battery)
                progressHairline(for: battery)
                statGrid(for: battery)
            } else {
                emptyState
            }

            Rectangle()
                .fill(palette.separator)
                .frame(height: 1)

            healthSection
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            loadHealth()
        }
    }

    // MARK: - Hero

    /// The handoff's stat idiom in place of the old ring: a 24pt numeral
    /// with the status sentence beside it, then a 4pt hairline meter.
    /// Status color appears only as data — the bolt, the sentence, the
    /// meter fill.
    private func hero(for battery: BatteryStats) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: palette.spacingRow) {
            HStack(alignment: .center, spacing: 4) {
                Text(MetricFormatting.percent(battery.chargePercent, decimals: 0))
                    .font(palette.numericFont(size: 24, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                if battery.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.success)
                        .accessibilityHidden(true)
                }
            }
            statusLine(for: battery)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func progressHairline(for battery: BatteryStats) -> some View {
        let fraction = min(max(battery.chargePercent / 100, 0), 1)
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.surfaceElevated)
                Capsule()
                    .fill(statusTint(for: battery))
                    .frame(width: max(4, geometry.size.width * fraction))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private func statusTint(for battery: BatteryStats) -> Color {
        if battery.isCharging || Self.isEffectivelyFull(battery) { return palette.success }
        if battery.chargePercent <= 10 { return palette.danger }
        if battery.chargePercent <= 20 { return palette.warning }
        return palette.metricColor(.batteryChargePercent)
    }

    // MARK: - Stat grid

    /// Label-left/value-right rows on a fixed two-column grid — the same
    /// table discipline the dropdown's vitals use, which is what makes a
    /// block of numbers scannable in one vertical pass.
    private func statGrid(for battery: BatteryStats) -> some View {
        Grid(alignment: .leading, horizontalSpacing: palette.spacingSection, verticalSpacing: 4) {
            GridRow {
                statCell(label: "Power", value: wattageValue(for: battery))
                statCell(label: "Health", value: MetricFormatting.percent(battery.healthPercent, decimals: 1))
            }
            GridRow {
                statCell(label: timeLabel(for: battery), value: timeValue(for: battery))
                statCell(label: "Cycles", value: MetricFormatting.integer(battery.cycleCount))
            }
            GridRow {
                statCell(label: "Adapter", value: adapterValue(for: battery))
                statCell(label: "Temp", value: MetricFormatting.celsius(battery.temperatureCelsius))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(palette.font(size: 10, weight: .medium))
                .foregroundStyle(palette.textTertiary)
                .lineLimit(1)
            Text(value)
                .font(palette.numericFont(size: 13, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
        }
        .gridColumnAlignment(.leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }

    // MARK: - Status line

    /// One sentence of state under the numbers: green when charging or
    /// full, amber only for a genuine pause, quiet otherwise — the same
    /// severity discipline as everywhere else (never a warning for macOS
    /// doing its job).
    private func statusLine(for battery: BatteryStats) -> some View {
        let (text, color, symbol) = statusContent(for: battery)
        return HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10))
            Text(text)
                .font(palette.font(size: 11))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    private func statusContent(for battery: BatteryStats) -> (String, Color, String) {
        if Self.isEffectivelyFull(battery) {
            return ("Fully charged", palette.success, "battery.100")
        }
        if let reason = battery.notChargingReasonText, reason != "Charging normally", !battery.isCharging, battery.isPluggedIn {
            return (reason, palette.warning, "pause.circle")
        }
        if battery.isCharging {
            let watts = battery.chargingWatts.map { " at \(MetricFormatting.watts($0))" } ?? ""
            return ("Charging\(watts)", palette.success, "bolt.fill")
        }
        if battery.isPluggedIn {
            return ("Plugged in, not charging", palette.textSecondary, "powerplug")
        }
        return ("On battery", palette.textSecondary, "battery.50")
    }

    private static func isEffectivelyFull(_ battery: BatteryStats) -> Bool {
        battery.isPluggedIn && !battery.isCharging && battery.chargePercent >= 99.5
    }

    // MARK: - Health footer

    @ViewBuilder
    private var healthSection: some View {
        VStack(alignment: .leading, spacing: palette.spacingTight) {
            HStack {
                Text("Health · all-time")
                    .font(palette.font(size: 11, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                Spacer()
                if let forecastLine {
                    Text(forecastLine)
                        .font(palette.font(size: 11))
                        .foregroundStyle(palette.textTertiary)
                        .lineLimit(1)
                }
            }
            if healthSamples.isEmpty {
                Text("Trend appears after a day or two of readings.")
                    .font(palette.font(size: 11))
                    .foregroundStyle(palette.textTertiary)
            } else {
                DashboardChart(
                    samples: healthSamples,
                    tint: palette.metricColor(.batteryHealthPercent),
                    metricTitle: "Battery Health",
                    height: 88
                )
            }
        }
    }

    private var forecastLine: String? {
        switch BatteryHealthForecast.forecast(
            samples: healthSamples.map { (timestamp: $0.timestamp, health: $0.avg) }
        ) {
        case .insufficientData:
            return nil
        case .stable:
            return "No decline in sight"
        case .alreadyBelow:
            return "Below 80% — consider service"
        case .crosses(let date, _):
            return "80% around \(date.formatted(.dateTime.month(.abbreviated).year()))"
        }
    }

    private func loadHealth() {
        let raw = historyStore.samplesWithRange(
            metric: MetricID.batteryHealthPercent.rawValue,
            since: .distantPast,
            tier: .daily
        )
        healthSamples = DashboardViewModel.downsample(raw, cap: DashboardViewModel.maxPointsPerSeries)
    }

    // MARK: - Empty / warming up

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(isWarmingUp ? "Reading battery…" : "Battery Unavailable")
                .font(palette.font(size: 14, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text(isWarmingUp
                ? "The first battery sample lands within about half a minute."
                : "This Mac reported no battery data.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, palette.spacing)
    }

    // MARK: - Formatting helpers

    private func wattageValue(for battery: BatteryStats) -> String {
        MetricFormatting.watts(battery.isCharging ? battery.chargingWatts : battery.systemPowerInWatts)
    }

    private func timeLabel(for battery: BatteryStats) -> String {
        battery.isCharging ? "Time to full" : "Time remaining"
    }

    private func timeValue(for battery: BatteryStats) -> String {
        if !battery.isCharging && battery.isPluggedIn { return MetricFormatting.placeholder }
        return MetricFormatting.minutesRemaining(
            battery.isCharging ? battery.timeToFullMinutes : battery.timeToEmptyMinutes
        )
    }

    private func adapterValue(for battery: BatteryStats) -> String {
        if let rated = battery.adapterRatedWatts { return "\(rated) W" }
        return battery.isPluggedIn ? "Connected" : MetricFormatting.placeholder
    }
}
