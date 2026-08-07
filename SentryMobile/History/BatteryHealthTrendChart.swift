import SwiftUI
import Charts
import Accessibility
import SentryKit

/// The History tab's headline long-term chart (plan §12.1's "battery health
/// trend") — a real-axis line of synthetic `DailyHealth.healthPercent` over
/// time. The iOS counterpart to `Sentry/Dashboard/BatteryHealthTrendCard.swift`
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

    /// Raw x-axis date under the finger while dragging; `nil` otherwise. See
    /// `ChartScrubOverlay` for why it is deliberately not pre-snapped.
    @State private var scrubDate: Date?

    /// One record per day, by construction — `DailyHealth.day` is midnight UTC
    /// and `SyntheticDailyHealth` emits at most one per day. Stated as a
    /// constant rather than derived from a query tier the way the Mac app does
    /// it, because there is no `HistoryStore` on this platform to have a tier
    /// (see the type doc comment above), so a day is the only cadence this
    /// series can have.
    private static let dayCadence: TimeInterval = 86400

    var body: some View {
        Group {
            if series.isEmpty {
                emptyState
            } else {
                chart
            }
        }
        // `minHeight`, not `height`: the empty state is a line of text in the
        // same box, and at an accessibility size that text needs more than
        // 180pt. A minimum lets it grow while leaving the chart's proportions
        // alone. (The chart's own axis labels are bounded separately — see
        // `chart` below.)
        .frame(minHeight: 180)
    }

    private var chart: some View {
        Chart {
            // Grouped into gapless runs the same way the Mac app's
            // `DashboardChart` is: a phone that was off (or an app that hadn't
            // synced) for a fortnight leaves a hole in `dailyHealth`, and a
            // smooth curve drawn across it would claim two weeks of health
            // readings that were never taken.
            ForEach(Array(series.enumerated()), id: \.offset) { offset, record in
                // **`yStart` at the domain floor, not the default zero
                // baseline.** `AreaMark(x:y:)` fills from y = 0 up to the
                // value. This chart's `yDomain` is clamped tightly around the
                // data — roughly 77...79 for a worn battery — so a fill
                // anchored at zero begins hundreds of points *below* the
                // plot's bottom edge and washes the theme's success green
                // over everything under the card. Reported twice from a real
                // phone.
                //
                // A previous pass tried to contain it with
                // `chartPlotStyle { $0.clipped() }`, and that is the fragile
                // shape of fix: it lets the mark be laid out wrongly and then
                // hides the consequence, which only holds for as long as
                // Swift Charts happens to honour the clip for marks (it does
                // not reliably — the wash survived). Bounding the mark itself
                // means there is nothing outside the plot to clip.
                AreaMark(
                    x: .value("Day", record.day),
                    yStart: .value("Floor", yDomain.lowerBound),
                    yEnd: .value("Health", record.healthPercent),
                    series: .value("Segment", segmentNumbers[offset])
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(palette.success.opacity(0.14))

                LineMark(
                    x: .value("Day", record.day),
                    y: .value("Health", record.healthPercent),
                    series: .value("Segment", segmentNumbers[offset])
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                .foregroundStyle(palette.success)
            }

            if let marker = scrubMarker {
                RuleMark(x: .value("Scrubbed day", marker.date))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(palette.textTertiary)
                if let value = marker.value {
                    PointMark(
                        x: .value("Scrubbed day", marker.date),
                        y: .value("Health", value)
                    )
                    .symbolSize(40)
                    .foregroundStyle(palette.success)
                }
            }
        }
        .chartOverlay { proxy in
            gapShading(proxy: proxy)
        }
        .chartOverlay { proxy in
            ChartScrubOverlay(proxy: proxy, scrubDate: $scrubDate, anchor: scrubMarker?.date) {
                scrubReadout
            }
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
        // Kept as a second line of defence now that the area fill is bounded
        // at the domain floor above. It is no longer load-bearing for the
        // fill, but `.monotone` interpolation genuinely can overshoot the
        // domain between two points, and a curve poking a few points past the
        // plot edge is exactly what a clip is for.
        .chartPlotStyle { plot in
            plot.clipped()
        }
        // Axis labels are furniture, not prose, and they do not reflow: the
        // y-axis reserves whatever width its widest label needs, and the
        // x-axis truncates rather than wrapping. Left unbounded they scale
        // with everything else, and at the largest accessibility sizes
        // "100.0"/"99.5" claimed roughly a third of the card's width while
        // the dates below collapsed to "J… J… J… A" — a chart whose data is
        // unreadable is the opposite of an accessibility win. Capping at
        // `xxLarge` keeps them comfortably larger than default while leaving
        // the plot legible; the surrounding card title, the empty state and
        // the summary text all still scale to the full range, because those
        // are prose and they reflow.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityLabel("Battery health trend, \(series.count) days")
        .accessibilityValue(rangeDescription)
        .accessibilityChartDescriptor(self)
    }

    // MARK: - Gaps and scrubbing

    private var days: [Date] { series.map(\.day) }

    private var gaps: [ChartScrubbing.Gap] {
        ChartScrubbing.gaps(
            timestamps: days,
            threshold: ChartScrubbing.gapThreshold(cadence: Self.dayCadence)
        )
    }

    /// Which gapless run each record belongs to, as the marks' `series` value.
    private var segmentNumbers: [Int] {
        var numbers = [Int](repeating: 0, count: series.count)
        let segments = ChartScrubbing.segments(
            timestamps: days,
            threshold: ChartScrubbing.gapThreshold(cadence: Self.dayCadence)
        )
        for (number, range) in segments.enumerated() {
            for index in range { numbers[index] = number }
        }
        return numbers
    }

    /// A barely-there wash over days with no record — see the same treatment
    /// in `Sentry/Dashboard/DashboardChart.swift` for why it is this quiet.
    @ViewBuilder
    private func gapShading(proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            if let plotAnchor = proxy.plotFrame {
                let plot = geometry[plotAnchor]
                ZStack(alignment: .topLeading) {
                    ForEach(gaps, id: \.start) { gap in
                        if let startX = proxy.position(forX: gap.start),
                           let endX = proxy.position(forX: gap.end) {
                            Rectangle()
                                .fill(palette.textTertiary.opacity(0.06))
                                .frame(width: max(endX - startX, 1), height: plot.height)
                                .offset(x: plot.minX + startX, y: plot.minY)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var reading: ChartScrubbing.Reading? {
        guard let scrubDate else { return nil }
        return ChartScrubbing.resolve(at: scrubDate, timestamps: days, cadence: Self.dayCadence)
    }

    private var scrubMarker: (date: Date, value: Double?)? {
        switch reading {
        case .sample(let index):
            guard series.indices.contains(index) else { return nil }
            return (series[index].day, series[index].healthPercent)
        case .noData:
            return scrubDate.map { ($0, nil) }
        case nil:
            return nil
        }
    }

    @ViewBuilder
    private var scrubReadout: some View {
        if let text = Self.readoutText(reading: reading, series: series) {
            Text(text)
                .scaledFont(palette, size: 11, monospacedDigit: true)
                .foregroundStyle(palette.textPrimary)
                .fixedSize()
                .chartScrubPlate(palette)
        }
    }

    /// Pure so the gap wording is testable without a touch —
    /// `SentryTests/ChartScrubbingTests.swift` covers the Mac app's twin of
    /// this; the phrasing here is deliberately the phone's own, since a phone
    /// has no "Mac asleep" to blame.
    static func readoutText(reading: ChartScrubbing.Reading?, series: [DailyHealth]) -> String? {
        switch reading {
        case nil:
            return nil
        case .noData:
            return String(localized: "no reading for this day")
        case .sample(let index):
            guard series.indices.contains(index) else { return nil }
            let record = series[index]
            let day = record.day.formatted(.dateTime.month(.abbreviated).day())
            // Through `MetricFormatter`, like every other number in both apps
            // — `healthPercent` is a `.percent`-unit metric and this is the
            // one formatting path for that unit.
            let value = MetricFormatter.compact(record.healthPercent, unit: .percent)
            return "\(day) · \(value)"
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("No battery health history yet")
                .scaledFont(palette, size: 12, weight: .medium)
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

    /// The lowest and highest health the range actually contains.
    ///
    /// Was `String(first.healthPercent)` / `String(last.healthPercent)`: the
    /// first and last *days*' values rather than the range's extremes, printed
    /// at full `Double` precision ("ranging from 92.41739 to 91.0 percent").
    /// Same bug, same fix, as `DashboardChart.rangeDescription` — see its
    /// comment for the full account. This string is what VoiceOver reads as
    /// the chart's value, so it has to be the truth in a readable form.
    private var rangeDescription: String {
        let values = series.map(\.healthPercent)
        guard let extremes = ChartScrubbing.extremes(mins: values, maxes: values) else {
            return String(localized: "no data")
        }
        let fromText = MetricFormatter.compact(extremes.min, unit: .percent, includeUnit: false)
        let toText = MetricFormatter.compact(extremes.max, unit: .percent, includeUnit: false)
        return String(localized: "ranging from \(fromText) to \(toText) percent")
    }
}

// MARK: - VoiceOver chart traversal

/// Lets VoiceOver walk the health series day by day, the non-visual
/// counterpart to the drag scrubbing above. Same reasoning as
/// `Sentry/Dashboard/DashboardChart.swift`'s conformance — see it for why an
/// `AXChartDescriptor` beats making every mark its own accessibility element.
extension BatteryHealthTrendChart: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let values = series.map(\.healthPercent)
        let extremes = ChartScrubbing.extremes(mins: values, maxes: values)

        // Degenerate ranges are illegal for `AXNumericDataAxisDescriptor`, and
        // a battery whose health never moved across the window is the *normal*
        // case here (see `SyntheticDailyHealth`), not an edge case — so the
        // y-range is widened to at least a point rather than assumed to span.
        let low = extremes?.min ?? 0
        let high = Swift.max(extremes?.max ?? 100, low + 1)
        let firstDay = series.first?.day.timeIntervalSince1970 ?? 0
        let lastDay = Swift.max(series.last?.day.timeIntervalSince1970 ?? 1, firstDay + 1)

        let xAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Day"),
            range: firstDay...lastDay,
            gridlinePositions: []
        ) { seconds in
            Date(timeIntervalSince1970: seconds).formatted(.dateTime.month(.abbreviated).day())
        }

        let yAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Battery health"),
            range: low...high,
            gridlinePositions: []
        ) { value in
            MetricFormatter.compact(value, unit: .percent)
        }

        let dataSeries = AXDataSeriesDescriptor(
            name: String(localized: "Battery health"),
            isContinuous: true,
            dataPoints: series.map { record in
                AXDataPoint(x: record.day.timeIntervalSince1970, y: record.healthPercent)
            }
        )

        return AXChartDescriptor(
            title: String(localized: "Battery health trend"),
            summary: rangeDescription,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [dataSeries]
        )
    }
}
