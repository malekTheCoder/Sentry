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
    /// this file and its `ActivityOverlayChart` neighbour cannot drift apart on
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

        init(historyStore: HistoryStore, metricID: String, since: Date, tier: HistoryStore.Tier) {
            self.historyStore = historyStore
            self.metricID = metricID
            self.since = since
            self.tier = tier
        }
    }

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
        Button("Export as CSV…") { export(context, format: .csv) }
        Button("Export as JSON…") { export(context, format: .json) }
    }

    /// Queries fresh rows for `context`'s exact metric/range, formats them,
    /// and hands the result to an `NSSavePanel` — the one macOS-native way to
    /// let the user pick where a file goes without this app inventing its
    /// own file browser.
    private func export(_ context: ExportContext, format: ExportFormat) {
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

// MARK: - Activity overlay

/// The redesign handoff's full-width Activity chart: up to three metric
/// lines overlaid in one plot, a text legend in each metric's own tint,
/// and a CPU stat sentence in place of axes.
///
/// **The honesty caveat, stated rather than hidden:** the overlaid series
/// have incompatible units (percent vs bytes), so each line is normalized
/// to its own observed peak — the plot shows each metric's *shape*, and
/// the only absolute numbers on the chart are the ones in the sentence
/// below it. That is exactly how the mock treats it (no y-axis at all).
///
/// **What that caveat does and does not rule out.** This view used to say it
/// offered no hover-to-read-values at all, on the grounds that "a read-off
/// value from a normalized line would be a fabricated number." That reasoning
/// is still correct and still binding — but it argues against exactly one
/// thing: *a single shared readout*, one number for a pointer position on a
/// plot where three incommensurable series cross. It does not argue against
/// reading each series' own recorded value in its own unit. So the scrubbing
/// added here shows a small stacked list — one row per drawn metric, each
/// carrying that metric's real `MetricFormatting` value ("CPU 41%", "Memory
/// 12.4 GB") — and never a y-position, a normalized fraction, or a combined
/// figure. The y-axis stays absent and unreadable, which is the part the mock
/// and the original caveat were both about.
struct ActivityOverlayChart: View {
    @Environment(\.themePalette) private var palette

    /// Metric → its ranged samples, in the order the legend should list
    /// them. Empty series are skipped; if everything is empty the view
    /// renders the standard sentence empty state.
    let series: [(metric: ChartMetric, samples: DashboardViewModel.RangedSamples)]

    /// `DashboardViewModel.expectedCadence`, for the same gap reasoning
    /// `DashboardChart` uses. Each series is checked against its own entry:
    /// three metrics queried over the same range share a cadence in practice,
    /// but they are separate queries and a metric whose module was disabled
    /// for part of the window genuinely has different gaps from its
    /// neighbours.
    var expectedCadence: [ChartMetric: TimeInterval] = [:]

    /// The selected range's `(since, now)` pair — see `DashboardChart.window`
    /// for the full argument. Pinned here for the same reason and with one
    /// extra: this plot overlays three independently-queried series, so without
    /// a shared domain the auto-fit would size the axis to whichever metric
    /// happens to reach furthest back, and the other two would be silently
    /// stretched or squeezed against a scale nothing declared.
    var window: ClosedRange<Date>? = nil

    var height: CGFloat = 120

    /// Raw x-axis date under the pointer; see `DashboardChart.scrubDate`.
    @State private var scrubDate: Date?

    private var drawable: [(metric: ChartMetric, samples: DashboardViewModel.RangedSamples)] {
        series.filter { !$0.samples.isEmpty }
    }

    /// One statement about the window for the whole overlay, folded from the
    /// three series' own coverages — see `HistoryCoverage.combining(_:)` for
    /// why the *oldest* start across metrics is the right answer to "how far
    /// back does this plot's record go."
    private var coverage: HistoryCoverage {
        let perMetric = drawable.map { entry in
            HistoryCoverage(
                requested: window,
                timestamps: entry.samples.map(\.timestamp),
                resolution: cadence(for: entry) ?? 0
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
                if !coverage.isComplete, let summary = coverage.summary {
                    Text(summary)
                        .font(palette.font(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(palette.textSecondary)
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
                // The series key carries the segment number as well as the
                // metric, so a gap breaks the stroke here exactly as it does
                // in `DashboardChart` — three overlaid lines that all glide
                // smoothly across the same missing night would be three lies,
                // not one.
                let segments = segmentNumbers(for: entry)
                ForEach(Array(entry.samples.enumerated()), id: \.offset) { offset, sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Relative", sample.avg / peak),
                        series: .value("Metric", "\(entry.metric.title)#\(segments[offset])")
                    )
                    .lineStyle(StrokeStyle(lineWidth: palette.theme.chartLineWidth, lineJoin: .round))
                    .foregroundStyle(palette.metricColor(entry.metric.colorID))
                    .interpolationMethod(.monotone)
                }
            }

            if let scrubAnchor {
                RuleMark(x: .value("Scrubbed time", scrubAnchor))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(palette.textTertiary)
                ForEach(readings, id: \.metric) { entry in
                    if let sample = entry.sample {
                        let peak = max(entry.peak, .leastNonzeroMagnitude)
                        PointMark(
                            x: .value("Scrubbed time", sample.timestamp),
                            y: .value("Relative", sample.avg / peak)
                        )
                        .symbolSize(30)
                        .foregroundStyle(palette.metricColor(entry.metric.colorID))
                    }
                }
            }
        }
        .chartYScale(domain: 0...1.05)
        // Above the overlays, for the reason spelled out on `DashboardChart`'s
        // own `chartXDomain` call: the proxies below have to resolve against the
        // pinned scale, not a scale established after them.
        .chartXDomain(coverage.requestedDomain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { plotArea in
            plotArea.background(
                RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                    .fill(palette.surface.opacity(0.6))
            )
        }
        // Same single "nothing was measured here" wash `DashboardChart` uses —
        // see `DashboardChart.gapShading` for why the unrecorded edges of the
        // window share the interior gaps' treatment rather than getting a
        // louder one of their own. Only the edges are drawn here: the three
        // series have three different interior gap sets, and stacking three
        // overlapping 6% washes would compound into a band that looks like data.
        .chartOverlay { proxy in
            unrecordedShading(proxy: proxy)
        }
        .chartOverlay { proxy in
            ChartScrubOverlay(proxy: proxy, scrubDate: $scrubDate, anchor: scrubAnchor) {
                scrubReadout
            }
        }
        .accessibilityLabel("Activity chart, \(drawable.map(\.metric.title).joined(separator: ", "))")
        .accessibilityValue(activityAccessibilityValue)
    }

    /// VoiceOver's only sentence about this plot, extended with the coverage
    /// clause for the same reason `DashboardChart.rangeDescription` is: the
    /// empty span is visible to everyone except the person relying on this
    /// string.
    private var activityAccessibilityValue: String {
        let shapes = cpuSentence ?? String(localized: "relative activity shapes")
        guard !coverage.isComplete, let summary = coverage.summary else { return shapes }
        return "\(shapes), \(summary)"
    }

    @ViewBuilder
    private func unrecordedShading(proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            if let plotAnchor = proxy.plotFrame {
                let plot = geometry[plotAnchor]
                ZStack(alignment: .topLeading) {
                    ForEach(coverage.unrecordedEdges, id: \.lowerBound) { region in
                        if let startX = proxy.position(forX: region.lowerBound),
                           let endX = proxy.position(forX: region.upperBound) {
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

    // MARK: - Scrubbing

    /// One resolved row per drawn metric. `sample` is `nil` when that metric
    /// has no measurement at the pointer's position — which can be true of one
    /// series and false of its neighbours, since the three are separate
    /// queries with separate gaps.
    private struct Reading {
        let metric: ChartMetric
        let sample: (timestamp: Date, min: Double, avg: Double, max: Double)?
        let peak: Double
    }

    private func cadence(for entry: (metric: ChartMetric, samples: DashboardViewModel.RangedSamples)) -> TimeInterval? {
        ChartScrubbing.effectiveCadence(
            expected: expectedCadence[entry.metric],
            timestamps: entry.samples.map(\.timestamp)
        )
    }

    private func segmentNumbers(for entry: (metric: ChartMetric, samples: DashboardViewModel.RangedSamples)) -> [Int] {
        var numbers = [Int](repeating: 0, count: entry.samples.count)
        guard let cadence = cadence(for: entry) else { return numbers }
        let segments = ChartScrubbing.segments(
            timestamps: entry.samples.map(\.timestamp),
            threshold: ChartScrubbing.gapThreshold(cadence: cadence)
        )
        for (number, range) in segments.enumerated() {
            for index in range { numbers[index] = number }
        }
        return numbers
    }

    private var readings: [Reading] {
        guard let scrubDate else { return [] }
        return drawable.map { entry in
            let resolved = ChartScrubbing.resolve(
                at: scrubDate,
                timestamps: entry.samples.map(\.timestamp),
                cadence: cadence(for: entry) ?? 0
            )
            let sample: (timestamp: Date, min: Double, avg: Double, max: Double)?
            if case .sample(let index) = resolved, entry.samples.indices.contains(index) {
                sample = entry.samples[index]
            } else {
                sample = nil
            }
            return Reading(
                metric: entry.metric,
                sample: sample,
                peak: entry.samples.map(\.max).max() ?? 1
            )
        }
    }

    /// How precisely to stamp the readout's leading time.
    ///
    /// Was hardcoded to `time: .shortened` — a bare "3:42 PM", which was
    /// unambiguous only because the plot never spanned more than the data did.
    /// With the domain pinned to the selected range, a pointer on the 90-day
    /// chart can be three months from today and "3:42 PM" would be an answer to
    /// a question nobody asked. Mirrors `DashboardChart.readoutDateFormat`'s
    /// thresholds so the two readouts on one window never describe the same
    /// instant at two different granularities.
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

    /// Where the rule stands. The first resolved series' own timestamp when
    /// there is one — so the rule lines up with at least one real dot — and
    /// the raw pointer position when every series is in a gap.
    private var scrubAnchor: Date? {
        guard let scrubDate else { return nil }
        return readings.compactMap { $0.sample?.timestamp }.first ?? scrubDate
    }

    @ViewBuilder
    private var scrubReadout: some View {
        if let scrubDate, !readings.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(scrubDate.formatted(readoutDateFormat))
                    .font(palette.font(size: 9))
                    .foregroundStyle(palette.textTertiary)
                ForEach(readings, id: \.metric) { reading in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(palette.metricColor(reading.metric.colorID))
                            .frame(width: 5, height: 5)
                        Text(Self.rowText(reading.metric, sample: reading.sample))
                            .font(palette.font(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(palette.textPrimary)
                    }
                }
            }
            .fixedSize()
            .chartScrubPlate(palette)
        }
    }

    /// Each metric's own real value in its own unit — never the normalized
    /// y-position the line was drawn at. Pure so the "no data" wording is
    /// testable (`SentryTests/ChartScrubbingTests.swift`).
    static func rowText(
        _ metric: ChartMetric,
        sample: (timestamp: Date, min: Double, avg: Double, max: Double)?
    ) -> String {
        guard let sample else {
            return String(localized: "\(metric.title) no data")
        }
        return "\(metric.title) \(MetricFormatting.value(sample.avg, unit: metric.unit, compact: true))"
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
