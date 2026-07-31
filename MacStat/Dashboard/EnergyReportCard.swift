import SwiftUI
import MacStatKit

/// Cumulative energy drawn by the whole system — "0.42 kWh today" — from the
/// `battery.system_power_watts` series `HistoryStore` is already recording.
///
/// The three windows are queried at the cheapest tier that can honestly
/// answer them: today from raw samples (fine-grained, small row count),
/// 7/30 days from the hourly rollup. The integration itself is
/// `EnergyIntegrator`'s per-gap-capped step rule; the cap passed for the
/// hourly tier is 1.5× the bucket width, mirroring how the raw tier's cap
/// sits comfortably above the polling interval. Values are prefixed "≈"
/// because rollup-average × bucket-width genuinely is an estimate — hours
/// the Mac spent partly asleep integrate slightly high, and saying so costs
/// one glyph.
///
/// Same one-shot `.task` + `hasLoaded` load discipline as
/// `BatteryHealthTrendCard`, and for the same reason: three history queries
/// shouldn't re-run on every incidental re-mount of the Dashboard tree.
struct EnergyReportCard: View {
    @Environment(\.themePalette) private var palette

    let historyStore: HistoryStore

    @State private var todayKWh: Double = 0
    @State private var weekKWh: Double = 0
    @State private var monthKWh: Double = 0
    @State private var hasAnyData = false
    @State private var hasLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Energy")
                    .font(palette.font(size: 14, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text("System power drawn, integrated from live sampling")
                    .font(palette.font(size: 12))
                    .foregroundStyle(palette.textTertiary)
            }
            if hasAnyData {
                VStack(alignment: .leading, spacing: palette.spacingTight) {
                    row("Today", todayKWh)
                    row("Last 7 days", weekKWh)
                    row("Last 30 days", monthKWh)
                }
            } else {
                Text("No power samples yet — leave Sentry running and this fills in.")
                    .font(palette.font(size: 12))
                    .foregroundStyle(palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dashboardCard(palette)
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            load()
        }
    }

    private func row(_ label: String, _ kWh: Double) -> some View {
        HStack(spacing: palette.spacingTight) {
            Text(label)
                .font(palette.font(size: 12))
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: palette.spacingTight)
            Text(Self.format(kWh))
                .font(palette.numericFont(size: 12, weight: .medium))
                .foregroundStyle(palette.textPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(Self.format(kWh))")
    }

    /// Wh below one kWh so "34 Wh" doesn't render as an unreadable
    /// "0.03 kWh"; one decimal above it.
    static func format(_ kWh: Double) -> String {
        guard kWh.isFinite, kWh >= 0 else { return "—" }
        if kWh < 1 {
            return "≈ \(Int((kWh * 1000).rounded())) Wh"
        }
        return String(format: "≈ %.1f kWh", kWh)
    }

    private func load() {
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: now)

        let raw = historyStore.samples(
            metric: MetricID.batterySystemPowerWatts.rawValue,
            since: dayStart
        )
        todayKWh = EnergyIntegrator.kilowattHours(
            samples: raw.map { (timestamp: $0.timestamp, watts: $0.value) }
        )

        func rolledUp(daysBack: Double) -> Double {
            let hourly = historyStore.samplesWithRange(
                metric: MetricID.batterySystemPowerWatts.rawValue,
                since: now.addingTimeInterval(-daysBack * 24 * 3600),
                tier: .hourly
            )
            return EnergyIntegrator.kilowattHours(
                samples: hourly.map { (timestamp: $0.timestamp, watts: $0.avg) },
                maximumGap: 1.5 * 3600
            )
        }
        weekKWh = rolledUp(daysBack: 7)
        monthKWh = rolledUp(daysBack: 30)
        hasAnyData = !raw.isEmpty || weekKWh > 0 || monthKWh > 0
    }
}
