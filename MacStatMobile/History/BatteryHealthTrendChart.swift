import SwiftUI
import Charts
import MacStatKit

/// The History tab's headline long-term chart (plan §12.1's "battery health
/// trend") — a real-axis line of synthetic `DailyHealth.healthPercent` over
/// time. The iOS counterpart to `MacStat/Dashboard/BatteryHealthTrendCard.swift`
/// / `DashboardChart.swift`, not a port of either:
///
/// - `DashboardChart` is built around `HistoryStore.samplesWithRange`'s
///   `(timestamp, min, avg, max)` tuple shape and draws a min/max band
///   because a `.hourly`/`.daily` rollup genuinely has a spread within each
///   bucket. `DailyHealth` has no such spread — it's one summary value per
///   day — so this draws a single `LineMark`/`AreaMark`-under-the-line per
///   day instead of pretending a band exists where the data has none.
/// - There is no `HistoryStore` on this platform at all (no GRDB, no local
///   database — see `MockDataSource`'s doc comment on why); the series this
///   view renders is entirely `SyntheticDailyHealth`-fabricated, surfaced
///   through `HistoryViewModel.dailyHealth`.
struct BatteryHealthTrendChart: View {
    @Environment(\.themePalette) private var palette
    let series: [DailyHealth]

    var body: some View {
        Group {
            if series.isEmpty {
                emptyState
            } else {
                chart
            }
        }
        .frame(height: 180)
    }

    private var chart: some View {
        Chart(series, id: \.day) { record in
            AreaMark(
                x: .value("Day", record.day),
                y: .value("Health", record.healthPercent)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(palette.success.opacity(0.14))

            LineMark(
                x: .value("Day", record.day),
                y: .value("Health", record.healthPercent)
            )
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
            .foregroundStyle(palette.success)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(palette.chartGrid)
                AxisTick().foregroundStyle(palette.chartGrid)
                AxisValueLabel(format: xAxisFormat)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(palette.chartGrid)
                AxisValueLabel()
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .chartYScale(domain: yDomain)
        .accessibilityLabel("Battery health trend, \(series.count) days")
        .accessibilityValue(rangeDescription)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("No battery health history yet")
                .font(palette.font(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Scaling

    /// Pads the domain so a nearly-flat series (health barely moves
    /// day-to-day, by design — see `SyntheticDailyHealth`'s doc comment)
    /// doesn't collapse to an unreadably thin band at the very top of the
    /// chart, same reasoning as `DashboardChart.yDomain`.
    private var yDomain: ClosedRange<Double> {
        let values = series.map(\.healthPercent)
        let low = values.min() ?? 0
        let high = values.max() ?? 100
        guard high > low else {
            return max(0, low - 2)...min(100, high + 2)
        }
        let padding = max((high - low) * 0.4, 1)
        return max(0, low - padding)...min(100, high + padding)
    }

    /// Coarser as the visible span widens, same reasoning as
    /// `DashboardChart.xAxisFormat`.
    private var xAxisFormat: Date.FormatStyle {
        guard let first = series.first?.day, let last = series.last?.day else {
            return .dateTime.month(.abbreviated).day()
        }
        let span = last.timeIntervalSince(first)
        if span <= 14 * 86400 {
            return .dateTime.month(.abbreviated).day()
        } else {
            return .dateTime.month(.abbreviated).year(.twoDigits)
        }
    }

    private var rangeDescription: String {
        guard let first = series.first, let last = series.last else { return "no data" }
        return "ranging from \(first.healthPercent) to \(last.healthPercent) percent"
    }
}
