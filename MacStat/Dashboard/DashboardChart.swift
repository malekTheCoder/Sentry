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
/// intermediate wrapper type. Per the redesign handoff there are no
/// gridlines and no y-axis even at full size: a stat sentence under the
/// plot ("avg … · peak … at …") carries the numbers a reader actually
/// wants, and time labels appear only at the plot's edges.
// MARK: - Detailed-charts environment

/// Mirrors `AppSettings.detailedCharts` into the view tree. An environment
/// key (rather than a parameter threaded through every card) because the
/// charts live several layers deep in cards that otherwise don't care.
private struct DetailedChartsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var detailedCharts: Bool {
        get { self[DetailedChartsKey.self] }
        set { self[DetailedChartsKey.self] = newValue }
    }
}

struct DashboardChart: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.detailedCharts) private var detailedCharts

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

    /// The Nocturne Dashboard mock's per-module grid card wants a 36px "mini
    /// sparkline area tinted in the module's own color" — a shape to glance
    /// at, not a chart to read exact values off of (that's what the full
    /// `DashboardMetricCard` detail rows and this same view's non-compact
    /// mode, used elsewhere on the card, are for). Compact mode hides the
    /// axis chrome (labels/ticks/gridlines would just be illegible noise at
    /// 36-44pt) and skips the "No history yet" prose empty state in favor of
    /// a bare baseline hairline, matching the mock's flat gradient-over-a-line
    /// treatment.
    var compact: Bool = false

    var body: some View {
        if points.isEmpty {
            Group {
                if compact {
                    compactEmptyState
                } else {
                    emptyState
                }
            }
            .frame(height: height)
        } else if compact {
            chart.frame(height: height)
        } else if detailedCharts {
            // Settings ▸ General ▸ "Detailed charts": full axis chrome for
            // readers who want to read values off the plot. The sentence is
            // omitted — axes and sentence together would say it twice.
            chart.frame(height: height)
        } else {
            // The default: the stat sentence lives under the plot and
            // *replaces* axis labels (handoff chart rules) — one line a
            // person actually wants (average, peak, when) instead of a
            // ladder of gridline numbers nobody reads.
            VStack(alignment: .leading, spacing: 4) {
                chart.frame(height: height)
                Text(statSentence)
                    .font(palette.font(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(palette.textTertiary)
            }
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var chart: some View {
        let base = Chart(points) { point in
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
        .chartYScale(domain: yDomain)
        .accessibilityLabel("\(metricTitle) history, \(samples.count) samples")
        .accessibilityValue(rangeDescription)

        if compact {
            base
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartPlotStyle { plot in plot.background(Color.clear) }
        } else if detailedCharts {
            // The detailed rendering: gridlines, y-axis, and intermediate
            // time labels — for readers who opted back into axes.
            base
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
                .shadow(color: tint.opacity(palette.glow * 0.8), radius: palette.glow * 4)
        } else {
            // Handoff chart rules: no gridlines, no y-axis — the stat
            // sentence under the plot carries the numbers. Time labels
            // appear at the plot edges only, 10pt tertiary. The plot area
            // itself is the one quiet surface fill a chart is allowed.
            base
                .chartXAxis {
                    AxisMarks(values: edgeTimestamps) { _ in
                        AxisValueLabel(format: xAxisFormat)
                            .font(palette.font(size: 10))
                            .foregroundStyle(palette.textTertiary)
                    }
                }
                .chartYAxis(.hidden)
                .chartPlotStyle { plot in
                    plot.background(
                        RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                            .fill(palette.surface.opacity(0.6))
                    )
                }
                .shadow(color: tint.opacity(palette.glow * 0.8), radius: palette.glow * 4)
        }
    }

    /// First and last sample times — the only two x labels the handoff wants.
    private var edgeTimestamps: [Date] {
        guard let first = samples.first?.timestamp, let last = samples.last?.timestamp, first != last else {
            return samples.first.map { [$0.timestamp] } ?? []
        }
        return [first, last]
    }

    /// "avg 18 · peak 91 at 10:42" — the axis replacement. Values use
    /// compact notation so byte-scale metrics stay readable; the peak time
    /// comes from the sample whose max was highest.
    private var statSentence: String {
        let avgValue = samples.map(\.avg).reduce(0, +) / Double(max(samples.count, 1))
        guard let peak = samples.max(by: { $0.max < $1.max }) else { return "" }
        let fmt: (Double) -> String = { value in
            value.formatted(.number.notation(.compactName).precision(.significantDigits(3)))
        }
        let peakTime = peak.timestamp.formatted(date: .omitted, time: .shortened)
        return String(localized: "avg \(fmt(avgValue)) · peak \(fmt(peak.max)) at \(peakTime)")
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

    /// A single hairline baseline — the same "no wallpaper, color as a thin
    /// signal" language the mock's own empty sparkline area uses, rather than
    /// prose that would overflow a 36pt-tall cell.
    private var compactEmptyState: some View {
        VStack {
            Spacer(minLength: 0)
            Rectangle()
                .fill(palette.separator)
                .frame(height: 1)
        }
        .accessibilityLabel("\(metricTitle) history, no samples")
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
        guard let first = samples.first, let last = samples.last else { return String(localized: "no data") }
        let fromText = String(first.min)
        let toText = String(last.max)
        return String(localized: "ranging from \(fromText) to \(toText)")
    }
}

// MARK: - Activity overlay

/// The redesign handoff's full-width Activity chart: up to three metric
/// lines overlaid in one plot, a text legend in each metric's own tint,
/// and a CPU stat sentence in place of axes.
///
/// **The honesty caveat, stated rather than hidden:** the overlaid series
/// have incompatible units (percent vs bytes), so each line is normalized
/// to its own observed peak — the plot shows each metric's *shape*, and
/// the only absolute numbers on the chart are the ones in the sentence
/// below it. That is exactly how the mock treats it (no y-axis at all),
/// and it is why this view deliberately offers no hover-to-read-values:
/// a read-off value from a normalized line would be a fabricated number.
struct ActivityOverlayChart: View {
    @Environment(\.themePalette) private var palette

    /// Metric → its ranged samples, in the order the legend should list
    /// them. Empty series are skipped; if everything is empty the view
    /// renders the standard sentence empty state.
    let series: [(metric: ChartMetric, samples: DashboardViewModel.RangedSamples)]

    var height: CGFloat = 120

    private var drawable: [(metric: ChartMetric, samples: DashboardViewModel.RangedSamples)] {
        series.filter { !$0.samples.isEmpty }
    }

    var body: some View {
        if drawable.isEmpty {
            Text("No activity recorded for this range yet.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .center)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                legend
                plot
                    .frame(height: height)
                if let sentence = cpuSentence {
                    Text(sentence)
                        .font(palette.font(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(palette.textTertiary)
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: palette.spacingRow) {
            ForEach(drawable, id: \.metric) { entry in
                HStack(spacing: 4) {
                    Circle()
                        .fill(palette.metricColor(entry.metric.colorID))
                        .frame(width: 6, height: 6)
                    Text(entry.metric.title)
                        .font(palette.font(size: 10))
                        .foregroundStyle(palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    private var plot: some View {
        Chart {
            ForEach(drawable, id: \.metric) { entry in
                let peak = max(entry.samples.map(\.max).max() ?? 1, .leastNonzeroMagnitude)
                ForEach(Array(entry.samples.enumerated()), id: \.offset) { _, sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Relative", sample.avg / peak),
                        series: .value("Metric", entry.metric.title)
                    )
                    .lineStyle(StrokeStyle(lineWidth: palette.theme.chartLineWidth, lineJoin: .round))
                    .foregroundStyle(palette.metricColor(entry.metric.colorID))
                    .interpolationMethod(.monotone)
                }
            }
        }
        .chartYScale(domain: 0...1.05)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { plotArea in
            plotArea.background(
                RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                    .fill(palette.surface.opacity(0.6))
            )
        }
        .accessibilityLabel("Activity chart, \(drawable.map(\.metric.title).joined(separator: ", "))")
        .accessibilityValue(cpuSentence ?? String(localized: "relative activity shapes"))
    }

    /// "avg CPU 18% · peak 91% at 10:42" — real, unnormalized numbers for
    /// the one metric whose unit needs no compaction.
    private var cpuSentence: String? {
        guard let cpu = drawable.first(where: { $0.metric == .cpu }) else { return nil }
        let avg = cpu.samples.map(\.avg).reduce(0, +) / Double(max(cpu.samples.count, 1))
        guard let peak = cpu.samples.max(by: { $0.max < $1.max }) else { return nil }
        let time = peak.timestamp.formatted(date: .omitted, time: .shortened)
        // Pre-formatted numbers so the whole sentence goes through the
        // catalog as one key with `%@` placeholders, instead of a
        // `String(format:)` whose word order no translator could change.
        let avgText = String(format: "%.0f%%", avg)
        let peakText = String(format: "%.0f%%", peak.max)
        return String(localized: "avg CPU \(avgText) · peak \(peakText) at \(time)")
    }
}
