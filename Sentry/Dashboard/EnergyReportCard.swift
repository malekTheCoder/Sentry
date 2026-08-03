import SwiftUI
import SentryKit

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
    /// Days between the earliest hourly power sample and now — drives which
    /// rows are honest to show (a day-old install rendering identical
    /// "7 days" and "30 days" figures read as a bug, and effectively was one).
    @State private var dataSpanDays: Double = 0
    @State private var hasAnyData = false

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
                    if dataSpanDays >= 7 {
                        row("Last 7 days", weekKWh)
                    }
                    if dataSpanDays >= 30 {
                        row("Last 30 days", monthKWh)
                    } else if dataSpanDays >= 1 {
                        // Younger than the windows above: one honest
                        // since-install total instead of three identical
                        // numbers pretending to be different windows.
                        row("Since install", monthKWh)
                    }
                }
            } else {
                Text("No power samples yet — leave Sentry running and this fills in.")
                    .font(palette.font(size: 12))
                    .foregroundStyle(palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Periodic, not one-shot: under the one-window shell both tabs stay
        // alive for the app's whole run, so a `hasLoaded`-guarded `.task`
        // would freeze "Today" at whatever it was the first time the window
        // ever opened. Ten minutes keeps the figure honest at three cheap
        // queries per reload; the loop dies with the view if the window is
        // ever truly torn down.
        .task {
            while !Task.isCancelled {
                load()
                try? await Task.sleep(for: .seconds(600))
            }
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

        // One 30-day hourly fetch serves the 7-day figure (filtered), the
        // 30-day figure, and the data-span calculation.
        let hourly = historyStore.samplesWithRange(
            metric: MetricID.batterySystemPowerWatts.rawValue,
            since: now.addingTimeInterval(-30 * 24 * 3600),
            tier: .hourly
        )
        let hourlyPoints = hourly.map { (timestamp: $0.timestamp, watts: $0.avg) }
        let weekCutoff = now.addingTimeInterval(-7 * 24 * 3600)
        weekKWh = EnergyIntegrator.kilowattHours(
            samples: hourlyPoints.filter { $0.timestamp >= weekCutoff },
            maximumGap: 1.5 * 3600
        )
        monthKWh = EnergyIntegrator.kilowattHours(
            samples: hourlyPoints,
            maximumGap: 1.5 * 3600
        )
        if let earliest = hourly.first?.timestamp {
            dataSpanDays = now.timeIntervalSince(earliest) / 86400
        } else {
            dataSpanDays = 0
        }
        hasAnyData = !raw.isEmpty || monthKWh > 0
    }
}
