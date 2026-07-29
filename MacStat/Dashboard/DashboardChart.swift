import SwiftUI
import Charts

/// A full-size, axis-visible history chart for one metric's `(min, avg,
/// max)` series — the Dashboard's counterpart to `SparklineChart`.
///
/// **Why this isn't just `SparklineChart` with the axes turned back on:**
/// `SparklineChart` is built around `MetricSeries`/`MetricSample`, the
/// dropdown's 60-sample in-memory ring buffer, and it only ever plots a bare
/// value line — there's no min/max band because the ring buffer doesn't keep
/// one. This view is built around the tuple shape
/// `HistoryStore.samplesWithRange` actually returns (`timestamp`, `min`,
/// `avg`, `max`), so a Dashboard card — or a future card like
/// `BatteryHealthTrendCard` — can hand it a query result directly with no
/// intermediate wrapper type. Axes are visible here (unlike
/// `SparklineChart`'s `.chartXAxis(.hidden)`/`.chartYAxis(.hidden)`) because
/// a compact 44pt sparkline reads as a shape, but a dashboard card this size
/// is a chart someone is meant to actually read values off of.
struct DashboardChart: View {
    @Environment(\.themePalette) private var palette

    /// Ascending-by-timestamp, as every `HistoryStore` read path already
    /// guarantees. For `.raw`-tier data `min == avg == max` per sample (see
    /// `HistoryStore.samplesWithRange`'s doc comment) — the band collapses
    /// to a hairline in that case, which is the mathematically honest
    /// rendering, not a bug to special-case away.
    let samples: [(timestamp: Date, min: Double, avg: Double, max: Double)]
    let tint: Color
    let metricTitle: String

    /// Taller than `SparklineChart`'s 44pt default — this is a standalone
    /// dashboard card, not a compact accessory next to a stats row.
    var height: CGFloat = 180

    /// Lets a caller with an already-zero-width band (e.g. `.raw` tier, or a
    /// metric where min/max isn't meaningful) skip the `AreaMark` entirely
    /// rather than pay for an invisible fill.
    var showBand: Bool = true

    var body: some View {
        Group {
            if points.isEmpty {
                emptyState
            } else {
                chart
            }
        }
        .frame(height: height)
    }

    // MARK: - Chart

    private var chart: some View {
        Chart(points) { point in
            if showBand {
                AreaMark(
                    x: .value("Time", point.timestamp),
                    yStart: .value("Min", point.min),
                    yEnd: .value("Max", point.max)
                )
                .foregroundStyle(tint.opacity(0.16))
                .interpolationMethod(.monotone)
            }
            LineMark(
                x: .value("Time", point.timestamp),
                y: .value("Average", point.avg)
            )
            .lineStyle(StrokeStyle(lineWidth: palette.theme.chartLineWidth, lineJoin: .round))
            .foregroundStyle(tint)
            .interpolationMethod(.monotone)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(palette.chartGrid)
                AxisTick().foregroundStyle(palette.chartGrid)
                AxisValueLabel(format: xAxisFormat)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(palette.chartGrid)
                AxisValueLabel()
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .chartYScale(domain: yDomain)
        .shadow(color: tint.opacity(palette.glow * 0.8), radius: palette.glow * 4)
        .accessibilityLabel("\(metricTitle) history, \(samples.count) samples")
        .accessibilityValue(rangeDescription)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("No history yet")
                .font(palette.font(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
            Text("Data will appear here once samples accumulate for this range.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Points

    /// `Chart` needs `Identifiable` elements; the raw tuples this view is
    /// handed aren't (tuples can't conform to protocols), so this wraps each
    /// one with its array index as a stable-enough id — the series is
    /// re-queried wholesale on every range change rather than diffed
    /// in-place, so index identity never has to survive a mutation.
    private struct Point: Identifiable {
        let index: Int
        let timestamp: Date
        let min: Double
        let avg: Double
        let max: Double
        var id: Int { index }
    }

    private var points: [Point] {
        samples.enumerated().map { offset, sample in
            Point(index: offset, timestamp: sample.timestamp, min: sample.min, avg: sample.avg, max: sample.max)
        }
    }

    // MARK: - Scaling

    /// Pads the domain 10% beyond the observed min/max, same reasoning as
    /// `SparklineChart.yDomain`: a flat series (min == max) would otherwise
    /// collapse to a zero-height, undrawable domain.
    private var yDomain: ClosedRange<Double> {
        let low = samples.map(\.min).min() ?? 0
        let high = samples.map(\.max).max() ?? 1
        guard high > low else { return low...(low + max(abs(low) * 0.1, 1)) }
        let padding = (high - low) * 0.1
        return (low - padding)...(high + padding)
    }

    /// Coarser as the visible span widens — an hour-long chart needs
    /// minute-level ticks, but stamping "3:42 PM" every tick on a 30-day
    /// chart would be unreadable and the minutes are meaningless at that
    /// zoom level anyway.
    private var xAxisFormat: Date.FormatStyle {
        guard let first = samples.first?.timestamp, let last = samples.last?.timestamp else {
            return .dateTime.month(.abbreviated).day()
        }
        let span = last.timeIntervalSince(first)
        if span <= 2 * 3600 {
            return .dateTime.hour().minute()
        } else if span <= 2 * 86400 {
            return .dateTime.hour()
        } else if span <= 60 * 86400 {
            return .dateTime.month(.abbreviated).day()
        } else {
            return .dateTime.month(.abbreviated).year(.twoDigits)
        }
    }

    private var rangeDescription: String {
        guard let first = samples.first, let last = samples.last else { return "no data" }
        return "ranging from \(first.min) to \(last.max)"
    }
}
