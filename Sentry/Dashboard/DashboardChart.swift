import SwiftUI
import Charts
import Accessibility
import SentryKit
import AppKit
import UniformTypeIdentifiers

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

// MARK: - Optional x-domain

extension View {
    /// Pins a chart's x-axis to `domain`, or leaves Swift Charts to auto-fit
    /// when there is no window to pin to.
    ///
    /// Exists because `chartXScale(domain:)` takes a non-optional and the
    /// "unbounded request" case is real rather than defensive — the all-time
    /// battery-health queries genuinely have no requested window (see
    /// `DashboardChart.window`). Written as a modifier so the two call sites in
    /// this file and its `ActivityLanesChart` neighbour cannot drift apart on
    /// what `nil` means, which on a correctness fix is the failure that matters:
    /// one chart quietly keeping the auto-fit behaviour is the whole bug back
    /// again on that one chart.
    @ViewBuilder
    func chartXDomain(_ domain: ClosedRange<Date>?) -> some View {
        if let domain, domain.lowerBound < domain.upperBound {
            chartXScale(domain: domain)
        } else {
            self
        }
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

    /// The metric's real unit, used by both the scrub readout and the
    /// VoiceOver range summary. Required rather than defaulted: every number
    /// this view puts in front of a reader goes through
    /// `MetricFormatting`/`MetricFormatter` (the same path the cards and the
    /// menu bar use, so a value never renders two ways in two places), and a
    /// default here would silently label somebody's bytes as a bare decimal.
    let unit: MetricUnit

    /// Expected spacing between consecutive points, from
    /// `DashboardViewModel.cadence(for:)` — the tier's row cadence multiplied
    /// by the downsample factor. Everything about gaps and scrub snapping
    /// derives from it (see `SentryKit/History/ChartScrubbing.swift`).
    ///
    /// `nil` is legitimate for callers that run their own query and have no
    /// view model to ask; the chart then falls back to the observed median
    /// spacing of its own points, which is right whenever the series isn't
    /// mostly gap.
    var expectedCadence: TimeInterval? = nil

    /// The window the user actually asked for — `TimeRangePicker`'s
    /// `(since, now)` pair, straight off `DashboardViewModel.window` so the
    /// domain is the same instant the query used rather than a fresh `Date()`
    /// that drifts a few milliseconds on every body evaluation.
    ///
    /// **This is the fix for the chart's oldest lie.** With no domain pinned,
    /// Swift Charts auto-fits the x-axis to whatever rows came back, so three
    /// days of history under a "90d" selection render edge to edge and read as
    /// ninety days. Pinned, the same three days are a short trace at the right
    /// with 87 days of visibly empty plot to their left — and the emptiness is
    /// the data, not a rendering failure. See
    /// `SentryKit/History/HistoryCoverage.swift` for the full argument,
    /// including why padding the series to fill the window is never an option.
    ///
    /// Pinned *always* when a window is known, not only when the data falls
    /// short: the auto-fitted domain also silently moved the *right* edge, so a
    /// Mac shut since Tuesday drew its last Tuesday sample flush against the
    /// plot's right edge, where a reader reasonably reads "now". Both edges are
    /// the query's, or neither.
    ///
    /// `nil` — the default — means "this caller asked for all history"
    /// (`BatteryOverviewCard`/`BatteryHealthTrendCard`'s `.distantPast` query),
    /// which has no left edge to fall short of. The auto-fitted domain *is* the
    /// honest one there, so it is kept.
    var window: ClosedRange<Date>? = nil

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
    ///
    /// **What compact mode does and does not get from the range-honesty work.**
    /// It gets the pinned x-domain, because that costs nothing and is the
    /// difference between a 36pt cell whose line spans the cell (reads: ninety
    /// days) and one whose line occupies the right fifth of it (reads: a
    /// sliver of ninety days). It does *not* get the unrecorded-span wash or
    /// the coverage caption: a 6%-opacity fill over a 36pt plot is below the
    /// threshold of noticing, and seven grid cells each repeating "3 of 90 days
    /// recorded" would say the same sentence seven times about one window the
    /// header already states it for once. Geometry scales down; prose doesn't.
    var compact: Bool = false

    /// Enables the "Export…" context menu — see the type's `Export` section
    /// below. `nil` by default so every existing call site
    /// (`BatteryOverviewCard`, `BatteryHealthTrendCard`, and the compact grid
    /// cells in `DashboardGrid` that haven't opted in) keeps rendering
    /// exactly as before; only a caller that actually has a `HistoryStore`
    /// and a metric identity to hand it (`DashboardGrid`'s per-metric cards)
    /// passes one.
    var exportContext: ExportContext? = nil

    /// The raw (un-snapped) x-axis date under the pointer, or `nil` when not
    /// scrubbing. Raw on purpose — see `ChartScrubOverlay.scrubDate`; snapping
    /// happens in `reading`, which is also where "the pointer is inside a gap"
    /// is decided.
    @State private var scrubDate: Date?

    var body: some View {
        // A right-click context menu, not a toolbar button, for the same
        // reason the time-range picker (`TimeRangePickerView`) is plain text
        // rather than a button row: this card's whole visual budget is
        // already spent on the headline value and the plot, and a chart is
        // exactly where a reader already expects a secondary-click menu
        // (Preview, Numbers, and every other macOS chart-bearing surface use
        // the same gesture for "do something with this data"). Only attached
        // when `exportContext` is supplied — see that property's doc
        // comment — so cards that haven't opted in show no menu at all
        // rather than an empty one.
        if let exportContext {
            content.contextMenu { exportMenuItems(exportContext) }
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
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
            // omitted — axes and sentence together would say it twice. The
            // coverage note is *not* omitted: axes describe the domain that was
            // drawn, never how much of it was measured.
            VStack(alignment: .leading, spacing: 4) {
                chart.frame(height: height)
                coverageNote
            }
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
                coverageNote
            }
        }
    }

    // MARK: - Coverage

    /// How much of `window` the plotted rows actually cover. Derived here
    /// rather than passed in because this view already holds both halves — the
    /// window the caller asked for and the series that came back — and a second
    /// parameter would be one more thing a call site could get out of step with
    /// the samples beside it.
    ///
    /// Measured against the *downsampled* series this view was handed, which is
    /// marginally conservative: `DashboardViewModel.downsample` stamps each
    /// bucket with its middle sample's time, so the first plotted point sits up
    /// to half a bucket after the first row that exists. That error is bounded
    /// at 120s on the worst case in the app (24h of 3s rows folded to 360
    /// buckets) against an `edgeTolerance` of 864s on the same window, so it can
    /// never manufacture a shortfall — and it errs toward *under*stating
    /// coverage, which is the only direction an honesty feature is allowed to be
    /// wrong in. `DashboardViewModel.historyCoverage`, which has the raw rows,
    /// uses them.
    private var coverage: HistoryCoverage {
        HistoryCoverage(
            requested: window,
            timestamps: samples.map(\.timestamp),
            resolution: cadence ?? 0
        )
    }

    /// "3 of 90 days recorded · since Jun 27", under the plot, only when the
    /// window is genuinely longer than the record.
    ///
    /// **Why here as well as in the window header.** The header states the
    /// coverage for the window as a whole (the oldest row *anything* holds);
    /// this states it for the metric in front of you, and the two legitimately
    /// differ — a module enabled last week has a much later first row than CPU
    /// does, and a reader looking at that card deserves the number that
    /// describes *that* line rather than the database's optimistic best.
    ///
    /// Suppressed when the record covers the window, unlike the header caption
    /// which always speaks: seven grid cards and a hero chart each announcing
    /// "90 days recorded" on a healthy install would be eight restatements of a
    /// fact the picker already implies.
    @ViewBuilder
    private var coverageNote: some View {
        if !coverage.isComplete, let summary = coverage.summary {
            Text(summary)
                .font(palette.font(size: 10))
                .monospacedDigit()
                // `textSecondary`, a step brighter than the stat sentence above
                // it: this is the one line on the card that corrects a
                // misreading, and a correction pitched at the same weight as
                // decoration doesn't get read.
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var chart: some View {
        let base = Chart {
            // One `series` per gapless run, so Swift Charts never joins the
            // last point before a gap to the first point after it. A gapless
            // series produces exactly one run, in which case this is
            // bit-for-bit the old single-series rendering — see
            // `ChartScrubbing.segments(timestamps:threshold:)`.
            ForEach(points) { point in
                if showBand {
                    AreaMark(
                        x: .value("Time", point.timestamp),
                        yStart: .value("Min", point.min),
                        yEnd: .value("Max", point.max),
                        series: .value("Segment", point.segment)
                    )
                    .foregroundStyle(tint.opacity(0.16))
                    .interpolationMethod(.monotone)
                }
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Average", point.avg),
                    series: .value("Segment", point.segment)
                )
                .lineStyle(StrokeStyle(lineWidth: palette.theme.chartLineWidth, lineJoin: .round))
                .foregroundStyle(tint)
                .interpolationMethod(.monotone)
            }

            if let marker = scrubMarker {
                RuleMark(x: .value("Scrubbed time", marker.date))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(palette.textTertiary)
                if let value = marker.value {
                    PointMark(
                        x: .value("Scrubbed time", marker.date),
                        y: .value("Value", value)
                    )
                    .symbolSize(36)
                    .foregroundStyle(tint)
                }
            }
        }
        .chartYScale(domain: yDomain)
        // Applied here, on the `Chart` itself and *above* every overlay, rather
        // than at the end of the chain. `chartXScale` would reach the chart from
        // either position, but `chartOverlay`'s `ChartProxy` — which
        // `gapShading` uses to place the unrecorded-span wash and
        // `ChartScrubOverlay` uses to turn a pointer x into a `Date` — has to
        // resolve against the *pinned* scale. Establishing the domain before the
        // overlays exist removes any question of ordering, on a fix whose whole
        // job is that the x-axis means what it says.
        .chartXDomain(coverage.requestedDomain)
        .accessibilityLabel("\(metricTitle) history, \(samples.count) samples")
        .accessibilityValue(rangeDescription)

        if compact {
            base
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartPlotStyle { plot in plot.background(Color.clear) }
                // **Scrubbing at 36pt, minus the plate.** The original argument
                // for excluding compact cells entirely (see `interactive(_:)`)
                // was never about the *pointer* — it was about the floating
                // readout: a plate is ~18pt tall and would cover half a 36pt
                // plot, so the label would hide the very point it describes.
                // That argument rules out the plate, not the interaction. The
                // rule and the dot are hairlines and read fine at this size, and
                // the readout is published upward instead (see
                // `ChartScrubReadoutKey`) so the card can render it on a line of
                // its own, outside the plot, in the slot its subtitle already
                // occupies. Same text, same "no data" honesty, same
                // `ChartScrubOverlay` gesture handling — just parked somewhere a
                // 36pt chart has room for it.
                //
                // `anchor: nil` is what suppresses the in-plot label: the
                // overlay then installs only its hit area and draws nothing.
                .chartOverlay { proxy in
                    ChartScrubOverlay(proxy: proxy, scrubDate: $scrubDate, anchor: nil) {
                        EmptyView()
                    }
                }
                .preference(key: ChartScrubReadoutKey.self, value: compactReadoutText)
        } else if detailedCharts {
            // The detailed rendering: gridlines, y-axis, and intermediate
            // time labels — for readers who opted back into axes.
            interactive(
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
            )
        } else {
            // Handoff chart rules: no gridlines, no y-axis — the stat
            // sentence under the plot carries the numbers. Time labels
            // appear at the plot edges only, 10pt tertiary. The plot area
            // itself is the one quiet surface fill a chart is allowed.
            interactive(
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
            )
        }
    }

    // MARK: - Interaction and honesty layers

    /// Everything a full-size chart gets that a 36pt grid sparkline does not:
    /// unrecorded-span shading, an in-plot scrub readout, and a VoiceOver chart
    /// descriptor.
    ///
    /// **Revised.** This used to exclude compact mode from scrubbing outright.
    /// Two of the three reasons stand and one didn't survive contact with the
    /// owner's "any chart you should be able to hover over": the *shading* is
    /// genuinely pointless at 36pt (a 6% wash over a 36pt-tall plot is invisible),
    /// and the *descriptor* would still double every VoiceOver stop in the grid
    /// for a chart whose own design brief calls it "a shape to glance at" — both
    /// still excluded. But "the readout plate would be taller than the chart"
    /// argued only against putting the plate *inside* the plot. The interaction
    /// itself is fine; the plate just needed somewhere else to live. See the
    /// `compact` branch of `chartBody` for where it went.
    private func interactive<Content: View>(_ content: Content) -> some View {
        content
            .chartOverlay { proxy in
                gapShading(proxy: proxy)
            }
            .chartOverlay { proxy in
                ChartScrubOverlay(
                    proxy: proxy,
                    scrubDate: $scrubDate,
                    anchor: scrubMarker?.date
                ) {
                    scrubReadout
                }
            }
            .accessibilityChartDescriptor(self)
    }

    /// Every stretch of the plotted domain with no measurement in it, painted
    /// as a barely-there wash.
    ///
    /// Quiet on purpose: an unrecorded night is the normal state of a laptop,
    /// not an error, so this is a 6%-opacity tertiary fill — enough that the
    /// eye registers the broken stroke as intentional rather than as a
    /// rendering glitch, and not enough to read as a warning band. Drawn in an
    /// overlay via `ChartProxy.position(forX:)` rather than as a
    /// `RectangleMark` so it can't participate in the y-scale or the legend,
    /// and can't be mistaken for data by anything downstream.
    ///
    /// **Why the range-honesty edges share this treatment instead of getting
    /// their own.** Two different causes feed `blankRegions`: interior gaps
    /// (`ChartScrubbing.gaps` — the Mac slept) and the leading/trailing edges of
    /// a window longer than the record (`HistoryCoverage.unrecordedEdges` —
    /// Sentry wasn't installed yet, or the Mac has been shut since Tuesday).
    /// It is tempting to distinguish them visually, and it would be a mistake:
    /// to the eye they are one fact — *nothing was measured here* — and giving
    /// one absence a hatch and the other a wash would make a single chart speak
    /// two visual languages about a single thing, which is exactly the "don't
    /// double up" failure a reader would then have to decode. Where they differ
    /// is in the *words*, which is where a cause belongs: the scrub readout
    /// names it (`readoutText`'s `beforeRecordStart` branch) and the caption
    /// under the plot quantifies it.
    ///
    /// One consequence worth stating: on a fresh install at "90d" this wash can
    /// cover most of the plot. That is correct. The loud signal there is not the
    /// wash — it is the line occupying a fifth of the width, which the pinned
    /// domain is what makes possible.
    @ViewBuilder
    private func gapShading(proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            if let plotAnchor = proxy.plotFrame {
                let plot = geometry[plotAnchor]
                ZStack(alignment: .topLeading) {
                    ForEach(blankRegions, id: \.start) { region in
                        if let startX = proxy.position(forX: region.start),
                           let endX = proxy.position(forX: region.end) {
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

    /// Interior gaps plus the window's unrecorded edges, as one list.
    ///
    /// Reuses `ChartScrubbing.Gap` for the edges rather than introducing a
    /// second region type: a gap is already "a span between two instants with
    /// nothing in it", which is precisely what an unrecorded edge is, and the
    /// shading loop above should not have to care which produced it.
    private var blankRegions: [ChartScrubbing.Gap] {
        gaps + coverage.unrecordedEdges.map { ChartScrubbing.Gap(start: $0.lowerBound, end: $0.upperBound) }
    }

    // MARK: - Scrubbing

    /// The series' cadence, declared if the caller knew it and observed
    /// otherwise. See `ChartScrubbing.effectiveCadence(expected:timestamps:)`.
    private var cadence: TimeInterval? {
        ChartScrubbing.effectiveCadence(expected: expectedCadence, timestamps: samples.map(\.timestamp))
    }

    private var gaps: [ChartScrubbing.Gap] {
        guard let cadence else { return [] }
        return ChartScrubbing.gaps(
            timestamps: samples.map(\.timestamp),
            threshold: ChartScrubbing.gapThreshold(cadence: cadence)
        )
    }

    /// What the pointer is over, resolved to a real sample or to "nothing was
    /// recorded here". `nil` when not scrubbing at all.
    private var reading: ChartScrubbing.Reading? {
        guard let scrubDate else { return nil }
        return ChartScrubbing.resolve(
            at: scrubDate,
            timestamps: samples.map(\.timestamp),
            cadence: cadence ?? 0
        )
    }

    /// Where to put the rule and (when there is one) the dot.
    ///
    /// In a gap the rule stands at the pointer's own position and there is no
    /// dot — snapping the rule to the nearest sample would draw a marker on
    /// data that isn't there, which is the same lie as reading out its value.
    private var scrubMarker: (date: Date, value: Double?)? {
        switch reading {
        case .sample(let index):
            guard samples.indices.contains(index) else { return nil }
            return (samples[index].timestamp, samples[index].avg)
        case .noData:
            return scrubDate.map { ($0, nil) }
        case nil:
            return nil
        }
    }

    /// The readout string for wherever the pointer currently is, or `nil` when
    /// nothing is being scrubbed. Shared by the in-plot plate (full size) and
    /// the card's caption line (compact) so there is exactly one wording.
    private var currentReadoutText: String? {
        Self.readoutText(
            reading: reading,
            samples: samples,
            unit: unit,
            format: readoutDateFormat,
            beforeRecordStart: isScrubbingBeforeRecordStart
        )
    }

    @ViewBuilder
    private var scrubReadout: some View {
        if let text = currentReadoutText {
            Text(text)
                .font(palette.font(size: 10))
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
                .fixedSize()
                .chartScrubPlate(palette)
        }
    }

    /// What the compact grid cell publishes upward for its card to render — the
    /// same string, minus the plate the cell has no room for.
    private var compactReadoutText: String? { currentReadoutText }

    /// Whether the pointer is parked in the stretch of the window that predates
    /// the first row this metric ever recorded.
    ///
    /// The distinction is only reachable once the domain is pinned: before that
    /// there *was* no plot area to the left of the first sample, so this
    /// question could not be asked and "no data — Mac asleep" was the only
    /// answer a hover could ever produce. Now a reader can hover the empty 87
    /// days of a fresh install's 90-day chart, and blaming that on sleep would
    /// be a confidently wrong answer to the exact question this whole change
    /// exists to answer.
    private var isScrubbingBeforeRecordStart: Bool {
        guard let scrubDate, let began = coverage.beganRecording else { return false }
        return scrubDate < began
    }

    /// Pure so `SentryTests/ChartScrubbingTests.swift` can assert the exact
    /// strings — the honesty of the gap case is the whole point of this
    /// feature and it should not be verifiable only by hovering a mouse.
    ///
    /// - Parameter beforeRecordStart: the pointer sits before the first row
    ///   this series has. Kept as a caller-computed `Bool` rather than folded
    ///   into `ChartScrubbing.Reading` as a third case: `Reading` answers "is
    ///   there a sample here", which is a question about the series, and
    ///   "does history reach this far back" is a question about the window —
    ///   different inputs, and merging them would force every existing
    ///   `Reading` call site to reason about a window it may not have.
    static func readoutText(
        reading: ChartScrubbing.Reading?,
        samples: [(timestamp: Date, min: Double, avg: Double, max: Double)],
        unit: MetricUnit,
        format: Date.FormatStyle,
        beforeRecordStart: Bool = false
    ) -> String? {
        switch reading {
        case nil:
            return nil
        case .noData:
            if beforeRecordStart {
                // The answer to "is this fake?": no, and here is why the plot
                // is empty here. Blaming sleep would be wrong *and* would leave
                // the reader still wondering where the data went.
                return String(localized: "no data — Sentry wasn't recording yet")
            }
            // Names the two ordinary causes rather than saying only "no
            // data": on a laptop this is almost always sleep, and a user who
            // isn't told that reads a broken line as a bug in the app.
            return String(localized: "no data — Mac asleep or app not running")
        case .sample(let index):
            guard samples.indices.contains(index) else { return nil }
            let sample = samples[index]
            let time = sample.timestamp.formatted(format)
            let value = MetricFormatting.value(sample.avg, unit: unit, compact: true)
            return "\(time) · \(value)"
        }
    }

    /// Finer than `xAxisFormat`: an axis label on a 30-day chart can say "Mar
    /// 4" because it is labelling a region, but a readout is answering "what
    /// was it *at this moment*", and "Mar 4" is not an answer to that.
    ///
    /// Keyed to the plotted *domain* rather than the samples' own span now that
    /// the domain can be much wider than the data: on a 90-day window holding
    /// four hours of rows, the samples span four hours but the pointer can land
    /// anywhere in ninety days, and "3:42 PM" with no date on it would be an
    /// ambiguous answer to "when was this".
    private var readoutDateFormat: Date.FormatStyle {
        let span = plottedSpan
        if span <= 2 * 86400 {
            return .dateTime.hour().minute()
        } else if span <= 60 * 86400 {
            return .dateTime.month(.abbreviated).day().hour()
        } else {
            return .dateTime.month(.abbreviated).day()
        }
    }

    /// How much time the plot actually covers left to right: the requested
    /// window when one is pinned, otherwise the samples' own extent.
    private var plottedSpan: TimeInterval {
        if let domain = coverage.requestedDomain {
            return domain.upperBound.timeIntervalSince(domain.lowerBound)
        }
        guard let first = samples.first?.timestamp, let last = samples.last?.timestamp else { return 0 }
        return last.timeIntervalSince(first)
    }

    /// The two x labels the handoff wants, at the plot's edges.
    ///
    /// The *domain's* edges when a window is pinned, not the first and last
    /// sample: with a pinned domain those samples no longer sit at the edges,
    /// and labelling the far left of a 90-day plot with the date of the first
    /// row — three days ago — would put a date under a position that is
    /// eighty-seven days earlier than it. The labels have to describe the axis
    /// they are on.
    private var edgeTimestamps: [Date] {
        if let domain = coverage.requestedDomain {
            return domain.lowerBound == domain.upperBound
                ? [domain.lowerBound]
                : [domain.lowerBound, domain.upperBound]
        }
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

    /// The no-rows-at-all state.
    ///
    /// The second line now names the window ("nothing recorded in the last 90
    /// days") instead of saying "for this range" and leaving the reader to
    /// remember which range that was. It is the same `HistoryCoverage.label`
    /// the caption uses when there *is* data, so an empty chart and a short one
    /// answer the same question in the same vocabulary rather than in two
    /// unrelated sentences.
    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("No history yet")
                .font(palette.font(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
            Text(coverage.label ?? String(localized: "Data will appear here once samples accumulate for this range."))
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
        /// Which gapless run this point belongs to. Passed to the marks as
        /// their `series:` value, which is what stops Swift Charts from
        /// stroking across a period where nothing was measured.
        let segment: Int
        var id: Int { index }
    }

    private var points: [Point] {
        let segments: [Range<Int>]
        if let cadence {
            segments = ChartScrubbing.segments(
                timestamps: samples.map(\.timestamp),
                threshold: ChartScrubbing.gapThreshold(cadence: cadence)
            )
        } else {
            segments = samples.isEmpty ? [] : [0..<samples.count]
        }
        var segmentOf = [Int](repeating: 0, count: samples.count)
        for (number, range) in segments.enumerated() {
            for index in range { segmentOf[index] = number }
        }
        return samples.enumerated().map { offset, sample in
            Point(
                index: offset,
                timestamp: sample.timestamp,
                min: sample.min,
                avg: sample.avg,
                max: sample.max,
                segment: segmentOf[offset]
            )
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
    ///
    /// Reads `plottedSpan`, so on a pinned domain this follows the window the
    /// axis actually spans rather than the (possibly far shorter) span of the
    /// rows drawn on it.
    private var xAxisFormat: Date.FormatStyle {
        let span = plottedSpan
        if span <= 0 {
            return .dateTime.month(.abbreviated).day()
        }
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

    // MARK: - Accessibility

    /// The range the data actually covers, in the metric's own unit.
    ///
    /// This used to read `String(first.min)` / `String(last.max)`, which was
    /// wrong three ways at once and is worth spelling out because this string
    /// is the *only* thing VoiceOver reads off a full-size chart: it described
    /// the first sample's floor and the last sample's ceiling (two unrelated
    /// numbers that happen to sit at the ends of the array, not the range's
    /// extremes at all); `String(Double)` printed full binary-to-decimal
    /// precision, so a CPU chart announced "ranging from 23.418293671 to
    /// 61.0"; and it carried no unit, so a memory chart read out a bare byte
    /// count with no scale. All three go through
    /// `ChartScrubbing.extremes(mins:maxes:)` and `MetricFormatting` now — the
    /// same formatting path the visible cards use.
    private var rangeDescription: String {
        guard let extremes = ChartScrubbing.extremes(mins: samples.map(\.min), maxes: samples.map(\.max)) else {
            return coverage.label ?? String(localized: "no data")
        }
        let fromText = MetricFormatting.value(extremes.min, unit: unit, compact: true)
        let toText = MetricFormatting.value(extremes.max, unit: unit, compact: true)
        let values = String(localized: "ranging from \(fromText) to \(toText)")
        // The coverage clause matters *more* here than on screen, not less: a
        // sighted reader can see 87 days of empty plot, and a VoiceOver user
        // gets exactly this one sentence and nothing else. Leaving it out would
        // mean the only user who cannot see the shortfall is the only one never
        // told about it.
        guard !coverage.isComplete, let summary = coverage.summary else { return values }
        return "\(values), \(summary)"
    }

    // MARK: - Export
    //
    // No export existed anywhere in the app for history data —
    // `HistoryStore` only ever handed rows to another Swift caller. This is
    // the UI half of that gap; `SentryKit/Persistence/HistoryExport.swift`
    // owns the actual text formatting (and is what's unit-tested for exact
    // output), so everything here is just "ask the store, hand the result to
    // `HistoryExport`, ask the user where to put it."

    /// What a chart needs to answer its own "Export…" menu, supplied by
    /// whichever call site actually has a `HistoryStore` and a metric
    /// identity — `DashboardGrid`'s per-metric cards, via `DashboardView`,
    /// which already owns both. Deliberately re-queries `historyStore`
    /// rather than exporting `DashboardChart.samples` as-is: `samples` may
    /// already be downsampled to `DashboardViewModel.maxPointsPerSeries` for
    /// on-screen plotting (see that constant's doc comment), and an export a
    /// user might paste into a spreadsheet or feed to a script should be the
    /// real recorded rows for the selected range, not a chart-rendering
    /// compromise.
    struct ExportContext {
        let historyStore: HistoryStore
        /// The dotted `MetricID.rawValue` `HistoryStore` indexes rows by —
        /// also used to derive the save panel's suggested filename, so the
        /// file a user saves is named after the same identity the query used
        /// to fetch it.
        let metricID: String
        let since: Date
        let tier: HistoryStore.Tier
        /// Whether `ProFeature.historyExport` is unlocked, from the same
        /// composition-root push that seeds `DashboardViewModel
        /// .isProUnlocked`. Carried here rather than read by the menu and
        /// `export(_:format:)` separately so both consult one flag — the
        /// affordance and the enforcement can't drift apart.
        let isUnlocked: Bool

        init(historyStore: HistoryStore, metricID: String, since: Date, tier: HistoryStore.Tier, isUnlocked: Bool) {
            self.historyStore = historyStore
            self.metricID = metricID
            self.since = since
            self.tier = tier
            self.isUnlocked = isUnlocked
        }
    }

    /// The locked menu item's exact label, as a testable constant — the
    /// locked copy must stay the honest kind: it names the feature and the
    /// tier, and sells nothing it can't deliver (no Buy affordance exists
    /// anywhere until checkout does; see `ProUpsellCard.unavailableNotice`).
    static let lockedExportMenuTitle = String(localized: "Export… — Sentry Pro")

    private enum ExportFormat {
        case csv, json

        var utType: UTType {
            switch self {
            case .csv: return .commaSeparatedText
            case .json: return .json
            }
        }

        var fileExtension: String {
            switch self {
            case .csv: return "csv"
            case .json: return "json"
            }
        }
    }

    /// Two menu items rather than one save panel with a format-picker
    /// accessory: `NSSavePanel`'s accessory-view API exists for exactly this
    /// but needs its own `NSViewController` and a second round of state to
    /// keep the panel's allowed types and the chosen format in sync, for a
    /// choice that's simpler to just state twice in the menu that's already
    /// open. Matches the two-menu-items option this feature's spec called
    /// out explicitly.
    @ViewBuilder
    private func exportMenuItems(_ context: ExportContext) -> some View {
        if context.isUnlocked {
            Button("Export as CSV…") { export(context, format: .csv) }
            Button("Export as JSON…") { export(context, format: .json) }
        } else {
            // Withheld, not obscured (`ProGate`'s doctrine): the menu keeps
            // one visible, honestly-labeled item — the feature's own name in
            // a menu leaks nothing, because the withheld content is the file,
            // which is never constructed — but *disabled*, not
            // tappable-to-nothing: an item that swallows clicks is exactly
            // the inert-control pattern this codebase strips elsewhere.
            // Hiding the menu entirely was rejected too — a visible locked
            // affordance is the Insights pattern (`LockedInsightRowView`),
            // and a menu that exists for some users and not others reads as
            // a bug, not a tier.
            Button {} label: {
                Label(Self.lockedExportMenuTitle, systemImage: "lock.fill")
            }
            .disabled(true)
        }
    }

    /// Queries fresh rows for `context`'s exact metric/range, formats them,
    /// and hands the result to an `NSSavePanel` — the one macOS-native way to
    /// let the user pick where a file goes without this app inventing its
    /// own file browser.
    private func export(_ context: ExportContext, format: ExportFormat) {
        // Defense in depth with the locked menu item above: the entitlement
        // is re-checked in the same function that touches `HistoryStore`, so
        // a stale menu or a programmatic invocation can't produce a file.
        // Silent return, not an alert — the only UI path here is a menu item
        // that is disabled when locked, so a user can never reach this guard
        // to be owed an explanation by it.
        guard context.isUnlocked else { return }
        let ranged = context.historyStore.samplesWithRange(
            metric: context.metricID,
            since: context.since,
            tier: context.tier
        )
        let rows = ranged.map { HistoryExport.Sample(timestamp: $0.timestamp, value: $0.avg) }
        let data: Data
        switch format {
        case .csv:
            data = Data(HistoryExport.csv(metricID: context.metricID, unit: unit, samples: rows).utf8)
        case .json:
            data = HistoryExport.json(metricID: context.metricID, unit: unit, samples: rows)
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = "\(context.metricID).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                // Same "log and drop, never crash" posture `HistoryStore`
                // itself uses for a failed disk write (see its own doc
                // comment) — a save-panel write failure (permissions, a
                // volume that went away between picking the location and
                // writing) is not something a stats app's menu action should
                // ever turn into a crash.
                NSLog("Sentry: failed to write history export to \(url.path): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - VoiceOver chart traversal

/// Makes the plotted series itself navigable with VoiceOver's chart rotor —
/// the non-visual equivalent of the hover scrubbing this view gained on the
/// sighted side, and the reason that scrubbing isn't an accessibility
/// regression. Without it the entire chart is one element announcing a single
/// summary sentence, so a VoiceOver user can learn the range and nothing else:
/// no shape, no when, no individual reading.
///
/// **Why the descriptor and not just per-point `accessibilityValue`s.** Swift
/// Charts will happily make each mark its own accessibility element, but that
/// turns a 360-point chart into 360 sequential stops in the rotor — technically
/// traversable, practically unusable. `AXChartDescriptor` is the API VoiceOver
/// has audio-graph and summary gestures for, and it treats the series as a
/// series rather than as 360 unrelated buttons.
extension DashboardChart: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let timestamps = samples.map(\.timestamp)
        let values = samples.map(\.avg)

        // `AXNumericDataAxisDescriptor` needs a non-degenerate range. An empty
        // or single-point series has none, so both axes fall back to a unit
        // span — the descriptor still has to exist (this method is not
        // optional) and an empty series simply has no data points in it.
        let xRange = (timestamps.first?.timeIntervalSince1970 ?? 0)...(timestamps.last?.timeIntervalSince1970 ?? 1)
        let extremes = ChartScrubbing.extremes(mins: samples.map(\.min), maxes: samples.map(\.max))
        let yRange = (extremes?.min ?? 0)...(extremes.map { Swift.max($0.max, $0.min + 1) } ?? 1)

        let readoutFormat = readoutDateFormat
        let xAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Time"),
            range: xRange.lowerBound...Swift.max(xRange.upperBound, xRange.lowerBound + 1),
            gridlinePositions: []
        ) { seconds in
            Date(timeIntervalSince1970: seconds).formatted(readoutFormat)
        }

        let unit = unit
        let yAxis = AXNumericDataAxisDescriptor(
            title: metricTitle,
            range: yRange,
            gridlinePositions: []
        ) { value in
            MetricFormatting.value(value, unit: unit, compact: true)
        }

        let series = AXDataSeriesDescriptor(
            name: metricTitle,
            isContinuous: true,
            dataPoints: zip(timestamps, values).map { timestamp, value in
                AXDataPoint(x: timestamp.timeIntervalSince1970, y: value)
            }
        )

        return AXChartDescriptor(
            title: String(localized: "\(metricTitle) history"),
            summary: rangeDescription,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}


// MARK: - Activity lanes

/// The Dashboard's full-width Activity band: one short lane per metric —
/// CPU, Memory, GPU — stacked under a shared x-axis, each drawing its bucket
/// averages as a line inside the true min–max band of everything those buckets
/// absorbed.
///
/// **This replaces a single overlaid plot, and the reasons are worth stating
/// because the overlay was in the redesign handoff.** Three lines in one 120pt
/// plot were unreadable for two compounding causes, and only one of them was
/// about density:
///
/// 1. *The crossings meant nothing.* Because the three metrics have
///    incompatible units (percent vs bytes), the overlay normalised each series
///    to its own observed peak. The most visually arresting feature of the
///    drawing — three lines crossing each other dozens of times — was therefore
///    pure artifact: CPU crossing Memory is not an event, it is two unrelated
///    numbers divided by two unrelated constants happening to land on the same
///    pixel. Lanes have no crossings to misread.
/// 2. *Per-series normalisation manufactured drama.* Dividing by the observed
///    peak means an idle Mac's 3% CPU fills the plot from floor to ceiling —
///    exactly the failure `ChartMetric.isPercentage` already warns about for
///    sparklines ("so the sparkline shows absolute load instead of auto-scaling
///    idle noise into a dramatic shape"). One lane per metric means each gets
///    its own y-scale, so percent metrics can sit on a fixed 0–100 axis and
///    read as absolute load, and the type no longer has a normalisation caveat
///    to apologise for.
///
/// And the band this view now draws is not compatible with the overlay in any
/// case: three translucent fills stacked in one plot compound into a wash where
/// no band can be attributed to a line — the same argument the old overlay
/// already accepted for *gap shading*, where it drew only the window's edges
/// because "stacking three overlapping 6% washes would compound into a band
/// that looks like data." Splitting into lanes is what lets each metric have
/// both its own band and its own interior gap shading.
///
/// **What a point is now.** Not a reading. `HistoryStore`'s `.raw` tier — the
/// tier the shortest range reads — returns `(min: avg, avg: avg, max: avg)`,
/// one unaggregated value per row, and real CPU swings from 10% to 90% between
/// two of them. Each lane folds its series into `targetBuckets` equal-duration
/// cells (`ChartBucketing`), draws each cell's mean as the line and each cell's
/// true low–high as the band behind it, and says so in the caption. Nothing is
/// hidden by the averaging: a 95% spike is still the band's ceiling even when
/// the line under it reads 60%. A smoothed line *without* the band would have
/// produced the same legibility by quietly deleting that spike, which is the
/// one thing this codebase never does with a measured number.
///
/// The band's fill matches `DashboardChart`'s exactly (`tint.opacity(0.16)`),
/// because the longer ranges have always rendered their rollups this way — this
/// change removes an inconsistency rather than introducing a new visual idea.
struct ActivityLanesChart: View {
    @Environment(\.themePalette) private var palette

    /// Metric → its ranged samples, in the order the lanes should stack.
    /// Empty series are skipped; if everything is empty the view renders the
    /// standard sentence empty state.
    let series: [(metric: ChartMetric, samples: DashboardViewModel.RangedSamples)]

    /// `DashboardViewModel.expectedCadence` — the spacing of the *source* rows,
    /// which is what gap detection has to run on. Each series is checked
    /// against its own entry: three metrics queried over the same range share a
    /// cadence in practice, but they are separate queries and a metric whose
    /// module was disabled for part of the window genuinely has different gaps
    /// from its neighbours.
    var expectedCadence: [ChartMetric: TimeInterval] = [:]

    /// The selected range's `(since, now)` pair — see `DashboardChart.window`
    /// for the full argument. Pinned here for the same reason and with one
    /// extra: the lanes are independently-queried series drawn one above
    /// another, and lanes that don't share an x-axis are not small multiples,
    /// they are three unrelated charts that happen to be adjacent.
    var window: ClosedRange<Date>? = nil

    /// Per lane, not for the stack. Three 56pt lanes plus their captions come
    /// to roughly the 120pt plot this replaced plus one lane's worth — the band
    /// is the Dashboard's opening statement and it earns the extra height by
    /// finally being followable.
    var laneHeight: CGFloat = 56

    /// How many equal-duration cells each lane's series is folded into.
    ///
    /// **Why 48.** The Dashboard window opens at 960pt wide
    /// (`MainWindowController`) and never goes below 860; after the page gutter
    /// and the lanes' name rail a plot is roughly 840pt across, so 48 cells put
    /// a little over 17pt between points. That is ~11× the theme's default
    /// 1.5pt stroke, which is the threshold that matters: below roughly a dozen
    /// stroke-widths a segment reads as a corner rather than as a direction,
    /// and a line made entirely of corners is the hash this change exists to
    /// remove. The 360-point series this used to plot gave each segment about
    /// 2.3pt — under two stroke widths.
    ///
    /// It also divides the ranges cleanly, which is a courtesy rather than a
    /// requirement but makes the caption read like a round number: 48 cells
    /// across the default 24h range is exactly half an hour per point, across
    /// 7d it is 3.5 hours, across 30d it is 15.
    ///
    /// Not derived from the live plot width via a `GeometryReader`. That was
    /// tempting — the count is a statement about pixels — and it would mean the
    /// plotted series, the scrub readout, the caption's "averages 30 min" and
    /// the VoiceOver summary all silently change as the user drags the window
    /// edge. A chart whose data depends on its width is a chart no two people
    /// can compare notes about. A fixed count chosen for the window's default
    /// size holds still.
    static let targetBuckets = 48

    /// Raw x-axis date under the pointer; see `DashboardChart.scrubDate`.
    /// Owned here rather than per lane so one hover marks all three lanes at
    /// the same instant — the thing three separate charts could not do, and
    /// the reason these read as one instrument instead of three.
    @State private var scrubDate: Date?

    private var drawable: [(metric: ChartMetric, samples: DashboardViewModel.RangedSamples)] {
        series.filter { !$0.samples.isEmpty }
    }

    // MARK: - Grid

    /// The single lattice every lane's buckets are laid on: the union of the
    /// drawn series' own spans.
    ///
    /// Shared rather than per-lane because a pointer has to land on the *same*
    /// interval in every lane — otherwise the three readouts a single hover
    /// produces would each describe a slightly different half-hour and the one
    /// time span printed under them could only be right about one of them. The
    /// union of the spans (rather than the intersection) so a metric whose
    /// module was enabled later still gets cells over the whole of its own
    /// record.
    ///
    /// Deliberately *not* `window`: see `ChartBucketing`'s type comment for why
    /// bucketing over the requested range collapses a short record on a wide
    /// window to a single dot.
    private var grid: ClosedRange<Date>? {
        let starts = drawable.compactMap { $0.samples.first?.timestamp }
        let ends = drawable.compactMap { $0.samples.last?.timestamp }
        guard let low = starts.min(), let high = ends.max(), low < high else { return nil }
        return low...high
    }

    /// Everything one lane needs, computed once here so the lanes, the caption
    /// and the accessibility summaries can't disagree about what was plotted.
    private struct Lane: Identifiable {
        let metric: ChartMetric
        let bucketed: ChartBucketing.Series
        /// Spacing to reason about the *bucketed* points with — see
        /// `ChartBucketing.Series.interval` for why the view model's
        /// pre-bucketing cadence would call every neighbouring pair a gap.
        let cadence: TimeInterval
        /// Stretches of the drawn domain with no reading in them: this
        /// metric's own interior gaps plus the window's unrecorded edges.
        let blankRegions: [ChartScrubbing.Gap]
        /// Top of this lane's y-axis, and the number its rail names.
        let peak: Double
        var id: ChartMetric { metric }
    }

    private var lanes: [Lane] {
        let shared = grid
        return drawable.map { entry in
            let timestamps = entry.samples.map(\.timestamp)
            let sourceCadence = ChartScrubbing.effectiveCadence(
                expected: expectedCadence[entry.metric],
                timestamps: timestamps
            ) ?? 0
            let threshold = ChartScrubbing.gapThreshold(cadence: sourceCadence)
            let bucketed = ChartBucketing.bucket(
                entry.samples,
                over: shared,
                target: Self.targetBuckets,
                gapThreshold: threshold
            )
            // Coverage from the *source* timestamps, never the buckets: it is a
            // claim about when recording began, and that is a question for the
            // rows rather than for the plotting compromise — the same reasoning
            // `DashboardViewModel.refresh` gives for building coverage from
            // `raw` instead of from `reduced`.
            let coverage = HistoryCoverage(
                requested: window,
                timestamps: timestamps,
                resolution: sourceCadence
            )
            // Gaps likewise from the source: the wash marks where nothing was
            // *measured*, and a bucket boundary is not a measurement. It ends up
            // marginally narrower than the break in the stroke (which runs
            // between bucket midpoints), which is the conservative direction —
            // shading more than was actually missing would be the lie.
            let gaps = ChartScrubbing.gaps(timestamps: timestamps, threshold: threshold)
            return Lane(
                metric: entry.metric,
                bucketed: bucketed,
                cadence: ChartScrubbing.effectiveCadence(
                    expected: bucketed.interval,
                    timestamps: bucketed.buckets.map(\.timestamp)
                ) ?? 0,
                blankRegions: gaps + coverage.unrecordedEdges.map {
                    ChartScrubbing.Gap(start: $0.lowerBound, end: $0.upperBound)
                },
                peak: bucketed.buckets.map(\.max).max() ?? 0
            )
        }
    }

    /// One statement about the window for the whole band, folded from the
    /// lanes' own coverages — see `HistoryCoverage.combining(_:)` for why the
    /// *oldest* start across metrics is the right answer to "how far back does
    /// this record go."
    private var coverage: HistoryCoverage {
        let perMetric = drawable.map { entry in
            HistoryCoverage(
                requested: window,
                timestamps: entry.samples.map(\.timestamp),
                resolution: ChartScrubbing.effectiveCadence(
                    expected: expectedCadence[entry.metric],
                    timestamps: entry.samples.map(\.timestamp)
                ) ?? 0
            )
        }
        return HistoryCoverage.combining(perMetric)
            ?? HistoryCoverage(requested: window, earliest: nil, latest: nil)
    }

    var body: some View {
        if drawable.isEmpty {
            Text("No activity recorded for this range yet.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
                .frame(maxWidth: .infinity, minHeight: laneHeight * 2, alignment: .center)
        } else {
            let lanes = lanes
            let interval = lanes.first?.bucketed.interval ?? 0
            VStack(alignment: .leading, spacing: palette.spacingTight) {
                ForEach(lanes) { lane in
                    ActivityLane(
                        metric: lane.metric,
                        bucketed: lane.bucketed,
                        cadence: lane.cadence,
                        blankRegions: lane.blankRegions,
                        peak: lane.peak,
                        domain: coverage.requestedDomain,
                        height: laneHeight,
                        scrubDate: $scrubDate,
                        ruleAnchor: ruleAnchor
                    )
                }
                if let sentence = cpuSentence {
                    Text(sentence)
                        .font(palette.font(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(palette.textTertiary)
                }
                // The line item 5 of this change exists for: a point stopped
                // being a reading, so the caption has to say what it is now.
                // While scrubbing it becomes the interval under the pointer,
                // stated once for all three lanes rather than repeated inside
                // each lane's plate — the lanes share a lattice, so there is
                // exactly one right answer and three copies of it would just be
                // three chances to notice they disagreed.
                Text(scrubbedSpanText ?? Self.pointCaption(interval: interval))
                    .font(palette.font(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(palette.textTertiary)
                if !coverage.isComplete, let summary = coverage.summary {
                    Text(summary)
                        .font(palette.font(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(palette.textSecondary)
                }
            }
        }
    }

    // MARK: - Scrubbing

    /// The lattice cell under the pointer, or `nil` when not scrubbing / when
    /// the pointer is outside the span the buckets were laid over.
    private var scrubbedCell: ClosedRange<Date>? {
        guard let scrubDate, let grid else { return nil }
        return ChartBucketing.cell(containing: scrubDate, over: grid, target: Self.targetBuckets)
    }

    /// Where every lane stands its rule: the centre of the hovered cell.
    ///
    /// The cell's centre rather than any one lane's bucket timestamp, because
    /// one rule is drawn across three lanes and each lane's bucket sits at the
    /// midpoint of *its own* readings inside that cell — three slightly
    /// different instants. The rule marks the interval being read; each lane's
    /// dot marks where inside that interval its readings actually fell, which
    /// on a partly-filled cell is a difference worth seeing rather than one
    /// worth hiding.
    private var ruleAnchor: Date? {
        guard let cell = scrubbedCell else { return scrubDate }
        return cell.lowerBound.addingTimeInterval(
            cell.upperBound.timeIntervalSince(cell.lowerBound) / 2
        )
    }

    private var scrubbedSpanText: String? {
        guard let cell = scrubbedCell else { return nil }
        return Self.spanCaption(cell, format: readoutDateFormat)
    }

    /// How precisely to stamp the scrubbed interval. Mirrors
    /// `DashboardChart.readoutDateFormat`'s thresholds so two readouts on one
    /// window never describe the same instant at two different granularities.
    private var readoutDateFormat: Date.FormatStyle {
        let span: TimeInterval
        if let domain = coverage.requestedDomain {
            span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        } else {
            let starts = drawable.compactMap { $0.samples.first?.timestamp }
            let ends = drawable.compactMap { $0.samples.last?.timestamp }
            guard let first = starts.min(), let last = ends.max() else {
                return .dateTime.hour().minute()
            }
            span = last.timeIntervalSince(first)
        }
        if span <= 2 * 86400 {
            return .dateTime.hour().minute()
        } else if span <= 60 * 86400 {
            return .dateTime.month(.abbreviated).day().hour()
        } else {
            return .dateTime.month(.abbreviated).day()
        }
    }

    // MARK: - Pure captions (unit-tested in ChartScrubbingTests)

    /// "each point averages 30 min · the band is that interval's full range".
    ///
    /// Stated rather than implied. The previous caption on this band described
    /// only the window; a reader had no way to know that one plotted point had
    /// become a summary of thirty minutes rather than one reading, and a chart
    /// that changes what a point means without saying so is a chart that lies
    /// quietly.
    static func pointCaption(interval: TimeInterval) -> String {
        guard interval > 0 else {
            // The identity case out of `ChartBucketing` — one sample, or a
            // series with no duration to divide. Nothing was averaged, so the
            // caption must not claim anything was.
            return String(localized: "each point is a single reading")
        }
        let span = intervalLabel(interval)
        return String(localized: "each point averages \(span) · the band is that interval's full range")
    }

    /// "3:30 – 4:00 PM" — the interval a scrub is reading, never an instant.
    ///
    /// An instant is what the old readout printed, and on a bucketed chart it
    /// would be a precision the drawn line no longer has: the number beside it
    /// is the mean of a whole cell, and stamping it "3:42 PM" would invite the
    /// reader to believe CPU was 41% at 3:42, which nothing on the plot claims.
    static func spanCaption(_ cell: ClosedRange<Date>, format: Date.FormatStyle) -> String {
        "\(cell.lowerBound.formatted(format)) – \(cell.upperBound.formatted(format))"
    }

    /// A duration in the coarsest unit that still reads as a round number.
    ///
    /// Hand-rolled for the same reason `AgentActivityCard.agoLabel` is:
    /// this has to fit a 10pt caption alongside two other clauses, and the
    /// system formatters' spelled-out output ("30 minutes") is several times
    /// wider than the slot. The 90-unit thresholds (rather than 60) keep
    /// "75 min" from becoming a lumpy "1 h".
    static func intervalLabel(_ seconds: TimeInterval) -> String {
        let value = max(seconds, 0)
        if value < 1 { return String(localized: "under a second") }
        if value < 90 { return String(localized: "\(Int(value.rounded())) s") }
        if value < 90 * 60 { return String(localized: "\(Int((value / 60).rounded())) min") }
        if value < 36 * 3600 { return String(localized: "\(Int((value / 3600).rounded())) h") }
        return String(localized: "\(Int((value / 86400).rounded())) d")
    }

    /// One lane's readout row: its own real value in its own unit, plus the
    /// range the band actually spans over the same cell.
    ///
    /// **What a scrub reads, and why it is the bucket rather than the nearest
    /// real sample.** Snapping to the nearest recorded reading was the other
    /// candidate and it is wrong here for a specific reason: the drawn line is
    /// the cell's mean, so a readout quoting the nearest raw sample would print
    /// 92% while the line directly under the pointer sits at 60%. A readout
    /// that contradicts the drawing is worse than one that is coarse — it makes
    /// the reader distrust both. So the readout describes exactly what was
    /// drawn: the mean, labelled `avg`, and beside it the cell's true low and
    /// high, which is where that 92% reading is still visible and still exact.
    ///
    /// A single-reading cell prints one bare number with no `avg` and no range,
    /// because nothing was averaged and claiming otherwise would be its own
    /// small dishonesty.
    static func rowText(_ metric: ChartMetric, bucket: ChartBucketing.Bucket?) -> String {
        guard let bucket else {
            return String(localized: "\(metric.title) no data")
        }
        let average = MetricFormatting.value(bucket.avg, unit: metric.unit, compact: true)
        guard bucket.hasRange else {
            return "\(metric.title) \(average)"
        }
        let low = MetricFormatting.value(bucket.min, unit: metric.unit, compact: true)
        let high = MetricFormatting.value(bucket.max, unit: metric.unit, compact: true)
        return String(localized: "\(metric.title) avg \(average) · \(low)–\(high)")
    }

    /// VoiceOver's one sentence about a lane.
    ///
    /// The extremes come from the *band* (`min` of mins, `max` of maxes), not
    /// from the drawn line: a VoiceOver user gets this string and nothing else,
    /// and reporting the averaged line's range would tell the one reader who
    /// cannot see the band that the day's peak was 60% when it was 95%. It also
    /// names the bucket duration, so the same "a point is not a reading" fact
    /// the caption states on screen is stated here too.
    static func laneSummary(
        _ metric: ChartMetric,
        buckets: [ChartBucketing.Bucket],
        interval: TimeInterval
    ) -> String {
        guard let extremes = ChartScrubbing.extremes(
            mins: buckets.map(\.min),
            maxes: buckets.map(\.max)
        ) else {
            return String(localized: "\(metric.title), no data")
        }
        let low = MetricFormatting.value(extremes.min, unit: metric.unit, compact: true)
        let high = MetricFormatting.value(extremes.max, unit: metric.unit, compact: true)
        let count = buckets.count
        guard interval > 0 else {
            return String(localized: "\(metric.title), \(count) readings, ranging from \(low) to \(high)")
        }
        let span = intervalLabel(interval)
        return String(localized: "\(metric.title), \(count) points, each a \(span) average, ranging from \(low) to \(high)")
    }

    /// "avg CPU 18% · peak 91% at 10:42" — computed from the *source* samples
    /// rather than from the buckets, deliberately. This sentence is the one
    /// place on the band that reports an instant, and the peak's real
    /// timestamp is still in the data even though no drawn point carries it
    /// any more; rounding it to a bucket midpoint would blur the only precise
    /// "when" the band offers for no gain.
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

// MARK: - One lane

/// A single metric's lane: a name rail on the left stating what full height
/// means, and a short plot drawing the bucket means inside the true min–max
/// band.
///
/// Fileprivate and separate from `ActivityLanesChart` rather than an inlined
/// `@ViewBuilder` on it, for two reasons that are not style: each lane needs
/// its own `AXChartDescriptor` (three metrics with three units cannot share one
/// descriptor's y-axis any more honestly than they could share one plot's), and
/// `AXChartDescriptorRepresentable` is a conformance on a *type* — so each lane
/// has to be one.
private struct ActivityLane: View {
    @Environment(\.themePalette) private var palette

    let metric: ChartMetric
    let bucketed: ChartBucketing.Series
    /// Spacing between the *bucketed* points, for scrub snapping.
    let cadence: TimeInterval
    let blankRegions: [ChartScrubbing.Gap]
    /// Highest value the band reaches — the number the rail names.
    let peak: Double
    let domain: ClosedRange<Date>?
    let height: CGFloat
    @Binding var scrubDate: Date?
    /// The shared rule position, from `ActivityLanesChart.ruleAnchor`.
    let ruleAnchor: Date?

    private var tint: Color { palette.metricColor(metric.colorID) }

    /// The lane's y-domain.
    ///
    /// **Percent metrics get a fixed 0–100 and nothing else.** This is the
    /// single biggest legibility win of splitting the overlay up, and it is not
    /// a new opinion: `ChartMetric.isPercentage` already states it for the
    /// dropdown's sparklines — "so the sparkline shows absolute load instead of
    /// auto-scaling idle noise into a dramatic shape". The overlay could not
    /// obey it, because three metrics sharing one axis had to be normalised to
    /// something. A lane can. An idle Mac's GPU now draws a flat line along the
    /// floor, which is what an idle GPU is.
    ///
    /// Everything else is zero-anchored to a hair above its own peak. Zero
    /// rather than the observed minimum (which is what `DashboardChart.yDomain`
    /// pads around) because these lanes are a load band: memory that never
    /// leaves 11.8–12.4 GB should read as a flat line near its ceiling, not as
    /// a dramatic waveform filling 56pt, and anchoring at zero is what makes
    /// the flatness visible. The 5% headroom keeps the peak's stroke off the
    /// top edge.
    private var yDomain: ClosedRange<Double> {
        if metric.isPercentage { return 0...100 }
        guard peak > 0, peak.isFinite else { return 0...1 }
        return 0...(peak * 1.05)
    }

    /// "0–100%" or "0–24 GB": what the lane's full height is worth.
    ///
    /// The overlay had no y-axis and could not have one — a normalised
    /// fraction has no unit to label. Two words of rail restore the thing that
    /// absence cost: a reader can now tell a lane that is busy from a lane that
    /// is merely auto-scaled.
    private var scaleLabel: String {
        if metric.isPercentage { return String(localized: "0–100%") }
        guard peak > 0, peak.isFinite else { return String(localized: "no range") }
        return String(localized: "0–\(MetricFormatting.value(peak, unit: metric.unit, compact: true))")
    }

    /// The bucket under the pointer, or `nil` for "this lane has nothing
    /// there" — which can be true of one lane and false of its neighbours,
    /// since the three are separate queries with separate holes.
    private var reading: ChartBucketing.Bucket? {
        guard let scrubDate else { return nil }
        let resolved = ChartScrubbing.resolve(
            at: scrubDate,
            timestamps: bucketed.buckets.map(\.timestamp),
            cadence: cadence
        )
        guard case .sample(let index) = resolved, bucketed.buckets.indices.contains(index) else {
            return nil
        }
        return bucketed.buckets[index]
    }

    var body: some View {
        HStack(alignment: .center, spacing: palette.spacingRow) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(tint)
                        .frame(width: 6, height: 6)
                    Text(metric.title)
                        .font(palette.font(size: 10, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                }
                Text(scaleLabel)
                    .font(palette.font(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(palette.textTertiary)
            }
            // Fixed so the three plots start at the same x and the lanes read
            // as one instrument sharing an axis — the entire point of small
            // multiples. Sized for the longest label the set produces
            // ("Memory" over "0–24.6 GB").
            .frame(width: 68, alignment: .leading)
            .accessibilityHidden(true)

            plot
        }
    }

    private var plot: some View {
        Chart {
            ForEach(Array(bucketed.buckets.enumerated()), id: \.offset) { _, bucket in
                // Same band as `DashboardChart` draws for the rollup tiers,
                // same 16% fill: the whole argument for this change is that
                // the live range should render the way every longer range
                // already does, and a band that didn't match would undo it.
                AreaMark(
                    x: .value("Time", bucket.timestamp),
                    yStart: .value("Low", bucket.min),
                    yEnd: .value("High", bucket.max),
                    series: .value("Segment", bucket.segment)
                )
                .foregroundStyle(tint.opacity(0.16))
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("Time", bucket.timestamp),
                    y: .value("Average", bucket.avg),
                    series: .value("Segment", bucket.segment)
                )
                .lineStyle(StrokeStyle(lineWidth: palette.theme.chartLineWidth, lineJoin: .round))
                .foregroundStyle(tint)
                .interpolationMethod(.monotone)
            }

            if let ruleAnchor {
                RuleMark(x: .value("Scrubbed time", ruleAnchor))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(palette.textTertiary)
                if let reading {
                    PointMark(
                        x: .value("Scrubbed time", reading.timestamp),
                        y: .value("Average", reading.avg)
                    )
                    .symbolSize(30)
                    .foregroundStyle(tint)
                }
            }
        }
        .chartYScale(domain: yDomain)
        // Above the overlays, for the reason spelled out on `DashboardChart`'s
        // own `chartXDomain` call: the proxies below have to resolve against the
        // pinned scale, not a scale established after them.
        .chartXDomain(domain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { plotArea in
            plotArea.background(
                RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                    .fill(palette.surface.opacity(0.6))
            )
        }
        .frame(height: height)
        // Each lane now shades its *own* interior gaps as well as the window's
        // unrecorded edges — the thing the overlay explicitly could not do,
        // because three overlapping 6% washes in one plot compound into a band
        // that looks like data. One series per plot, one wash per absence.
        .chartOverlay { proxy in
            gapShading(proxy: proxy)
        }
        .chartOverlay { proxy in
            ChartScrubOverlay(
                proxy: proxy,
                scrubDate: $scrubDate,
                anchor: reading?.timestamp ?? ruleAnchor
            ) {
                scrubReadout
            }
        }
        .accessibilityLabel("\(metric.title) activity")
        .accessibilityValue(
            ActivityLanesChart.laneSummary(
                metric,
                buckets: bucketed.buckets,
                interval: bucketed.interval
            )
        )
        .accessibilityChartDescriptor(self)
    }

    /// Same quiet 6% wash `DashboardChart.gapShading` uses — see that method
    /// for why an interior gap and an unrecorded window edge share one visual
    /// treatment instead of getting two.
    @ViewBuilder
    private func gapShading(proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            if let plotAnchor = proxy.plotFrame {
                let plot = geometry[plotAnchor]
                ZStack(alignment: .topLeading) {
                    ForEach(blankRegions, id: \.start) { region in
                        if let startX = proxy.position(forX: region.start),
                           let endX = proxy.position(forX: region.end) {
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

    @ViewBuilder
    private var scrubReadout: some View {
        if scrubDate != nil {
            Text(ActivityLanesChart.rowText(metric, bucket: reading))
                .font(palette.font(size: 10))
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
                .fixedSize()
                .chartScrubPlate(palette)
        }
    }
}

// MARK: - VoiceOver lane traversal

/// One descriptor per lane, so VoiceOver's chart rotor can walk a metric's
/// shape rather than being handed a single summary sentence — the same
/// reasoning as `DashboardChart`'s own conformance, with one addition specific
/// to this view: the descriptor's data points are the *bucket means*, which is
/// exactly what is drawn. Feeding it the source readings instead would give the
/// non-visual reader a different chart from the visual one, and the summary
/// sentence already carries the band's true extremes so nothing is lost by it.
extension ActivityLane: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let buckets = bucketed.buckets

        // `AXNumericDataAxisDescriptor` needs a non-degenerate range; an empty
        // or single-point lane has none, so both axes fall back to a unit span.
        let times = buckets.map(\.timestamp.timeIntervalSince1970)
        let xLow = times.first ?? 0
        let xHigh = Swift.max(times.last ?? 1, xLow + 1)
        let xAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Time"),
            range: xLow...xHigh,
            gridlinePositions: []
        ) { seconds in
            Date(timeIntervalSince1970: seconds).formatted(.dateTime.hour().minute())
        }

        let unit = metric.unit
        let yAxis = AXNumericDataAxisDescriptor(
            title: metric.title,
            range: yDomain,
            gridlinePositions: []
        ) { value in
            MetricFormatting.value(value, unit: unit, compact: true)
        }

        let series = AXDataSeriesDescriptor(
            name: metric.title,
            isContinuous: true,
            dataPoints: buckets.map {
                AXDataPoint(x: $0.timestamp.timeIntervalSince1970, y: $0.avg)
            }
        )

        return AXChartDescriptor(
            title: String(localized: "\(metric.title) activity"),
            summary: ActivityLanesChart.laneSummary(
                metric,
                buckets: buckets,
                interval: bucketed.interval
            ),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}
