import SwiftUI
import Charts
import SentryKit

// The redesign handoff's iOS Dashboard (direction 2b): a borderless vitals
// ledger — 20pt tabular numerals, hairline dividers, a context word or a
// 70pt sparkline on the right — plus the full-width Activity chart. This
// file replaces the old 7-card grid (`DashboardMetricCardFactory`): same
// data, same "nil renders — never a fabricated zero" discipline, different
// shape. Rows expand in place for the detail the cards used to carry, with
// a tertiary chevron for disclosure per the handoff's row idiom.

// MARK: - Sparkline

/// A bare Canvas polyline — no axes, no fill (the handoff reserves the
/// under-line fill for the CPU line on the big chart), tinted in the
/// metric's own color. Renders nothing (not a flat fake line) until there
/// are at least two real samples.
///
/// **Deliberately not scrubbable, unlike every other chart in the product.**
/// This is 70×22pt on the trailing edge of a ledger row. A fingertip's contact
/// patch is roughly 44pt across — it would cover two thirds of the plot's width
/// and all of its height, so there is no position at which a reader could both
/// touch a point and see it. Even granting that, the row it sits in already
/// carries that metric's current value in 20pt type two inches to the left, and
/// the tap gesture on the row belongs to the disclosure that reveals the
/// module's detail rows; a scrub gesture here would race it and one of the two
/// would lose unpredictably. The full-width `MobileActivityChart` directly above
/// this ledger plots the same CPU/memory/GPU series at a size a finger can
/// actually address, and *that* is where hovering a point belongs. Kept as a
/// `Canvas` for the same reason: with no interaction and no axis, a `Chart` here
/// would be strictly more machinery for an identical picture.
struct LedgerSparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard values.count >= 2 else { return }
            let low = values.min() ?? 0
            let high = values.max() ?? 1
            let span = max(high - low, .leastNonzeroMagnitude)
            var path = Path()
            for (index, value) in values.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                let y = size.height - (size.height - 2) * CGFloat((value - low) / span) - 1
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Ledger row

/// One vitals row: label · context · 20pt numeral · sparkline, on a
/// hairline. The whole row is a ≥44pt tap target that expands the detail
/// rows in place.
struct VitalsLedgerRow: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let label: String
    /// Pre-formatted headline; "—" when the module is unavailable.
    let headline: String
    /// One quiet word of context ("no pressure", an SSID) — nil when the
    /// sparkline carries the story instead.
    var context: String? = nil
    var sparkline: [Double] = []
    var tint: Color = .clear
    /// Detail rows revealed by expanding; empty disables disclosure.
    var details: [(label: String, value: String)] = []

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(ThemePalette.motion(reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                AdaptiveRow(spacing: palette.spacingRow, verticalAlignment: .center) {
                    Text(label)
                        .scaledFont(palette, size: 14)
                        .foregroundStyle(palette.textSecondary)
                } trailing: {
                    readout
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(details.isEmpty)
            .accessibilityLabel("\(label), \(headline)")
            .accessibilityHint(details.isEmpty ? Text("") : Text(isExpanded ? "Collapses details" : "Expands details"))

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(details, id: \.label) { row in
                        DashboardDetailRow(label: row.label, value: row.value)
                    }
                }
                .padding(.bottom, palette.spacingRow)
            }
        }
        .ledgerDivider(palette)
    }

    /// The row's right-hand side: context word, headline numeral, sparkline,
    /// chevron.
    ///
    /// **What breaks at accessibility sizes, and what this does about it.**
    /// At default sizes this is four things sharing whatever width the label
    /// leaves — comfortable. At an accessibility size the label alone can
    /// claim most of the row, and the pieces here compete: the context word
    /// (`.lineLimit(1)`) truncates to an ellipsis, and the headline — the
    /// actual number the whole row exists to show — starts eliding. Two
    /// changes fix that:
    ///
    ///   - The sparkline is dropped entirely once text is at an accessibility
    ///     size. It is already `.accessibilityHidden(true)` decoration that
    ///     conveys nothing the headline doesn't, and at 70pt wide it is the
    ///     single largest thing crowding the number out.
    ///   - The context word drops its `.lineLimit(1)` and is allowed to wrap,
    ///     since `AdaptiveRow` has by then given this side its own full-width
    ///     line to wrap into.
    ///
    /// The chevron stays: it is the only affordance saying the row expands.
    @ViewBuilder
    private var readout: some View {
        let isAccessibility = dynamicTypeSize.isAccessibilitySize
        HStack(spacing: palette.spacingRow) {
            if let context {
                Text(context)
                    .scaledFont(palette, size: 11)
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(isAccessibility ? nil : 1)
            }
            Text(headline)
                .scaledFont(palette, size: 20, weight: .semibold, monospacedDigit: true)
                .foregroundStyle(headline == MetricFormatting.placeholder ? palette.textTertiary : palette.textPrimary)
            if !sparkline.isEmpty && !isAccessibility {
                LedgerSparkline(values: sparkline, tint: tint)
                    .frame(width: 70, height: 22)
            }
            if !details.isEmpty {
                Image(systemName: "chevron.down")
                    .scaledSystemFont(size: 10, weight: .semibold)
                    .foregroundStyle(palette.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
    }
}

// MARK: - Ledger

/// The seven modules as ledger rows. A `nil` snapshot (nothing received,
/// or the Mac is unreachable and values have been degraded on purpose)
/// renders every headline as "—".
struct VitalsLedger: View {
    @Environment(\.themePalette) private var palette

    let snapshot: SystemSnapshot?
    /// Same ring buffer `MobileActivityChart` plots. The rows only need the
    /// values (see `LedgerSparkline` for why these plots carry no time axis),
    /// so each row maps its own series down at the call site rather than this
    /// view flattening the timestamps away for everybody.
    let series: [MetricID: [RecentSample]]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VitalsLedgerRow(
                label: String(localized: "CPU"),
                headline: MetricFormatting.percent(snapshot?.cpu?.totalPercent),
                sparkline: series[.cpuTotalPercent]?.map(\.value) ?? [],
                tint: palette.metricColor(.cpuTotalPercent),
                details: snapshot?.cpu.map {
                    [
                        (String(localized: "E-Cores"), MetricFormatting.percent($0.ecorePercent)),
                        (String(localized: "P-Cores"), MetricFormatting.percent($0.pcorePercent)),
                        (String(localized: "Load Avg"), MetricFormatting.decimal($0.loadAverage1m)),
                        (String(localized: "Processes"), MetricFormatting.integer($0.processCount)),
                    ]
                } ?? []
            )
            VitalsLedgerRow(
                label: String(localized: "GPU"),
                headline: MetricFormatting.percent(snapshot?.gpu?.utilizationPercent),
                sparkline: series[.gpuUtilizationPercent]?.map(\.value) ?? [],
                tint: palette.metricColor(.gpuUtilizationPercent),
                details: snapshot?.gpu.map {
                    [
                        (String(localized: "VRAM"), MetricFormatting.bytes($0.vramUsedBytes)),
                        (String(localized: "Frequency"), MetricFormatting.megahertz($0.frequencyMHz)),
                        (String(localized: "Power"), MetricFormatting.watts($0.powerWatts)),
                    ]
                } ?? []
            )
            VitalsLedgerRow(
                label: String(localized: "Memory"),
                headline: MetricFormatting.percent(memoryUsedPercent),
                context: snapshot?.memory.map { MetricFormatting.bytes($0.usedBytes) },
                sparkline: series[.memoryUsedBytes]?.map(\.value) ?? [],
                tint: palette.metricColor(.memoryUsedBytes),
                details: snapshot?.memory.map {
                    [
                        (String(localized: "Wired"), MetricFormatting.bytes($0.wiredBytes)),
                        (String(localized: "Compressed"), MetricFormatting.bytes($0.compressedBytes)),
                        (String(localized: "Pressure"), MetricFormatting.memoryPressureLevel($0.pressureLevel)),
                    ]
                } ?? []
            )
            VitalsLedgerRow(
                label: String(localized: "Disk"),
                headline: snapshot?.disk.map { MetricFormatting.bytes($0.freeBytes) } ?? MetricFormatting.placeholder,
                context: snapshot?.disk == nil ? nil : String(localized: "free"),
                details: snapshot?.disk.map {
                    [
                        (String(localized: "Total"), MetricFormatting.bytes($0.totalBytes)),
                        (String(localized: "Read"), MetricFormatting.bytesPerSecond($0.readBytesPerSec)),
                        (String(localized: "Write"), MetricFormatting.bytesPerSecond($0.writeBytesPerSec)),
                    ]
                } ?? []
            )
            VitalsLedgerRow(
                label: String(localized: "Network"),
                headline: MetricFormatting.bytesPerSecond(snapshot?.network?.rxBytesPerSec),
                context: snapshot?.network.flatMap { $0.wifiSSID ?? $0.activeInterface },
                sparkline: series[.networkRxBytesPerSec]?.map(\.value) ?? [],
                tint: palette.metricColor(.networkRxBytesPerSec),
                details: snapshot?.network.map {
                    [
                        (String(localized: "Upload"), MetricFormatting.bytesPerSecond($0.txBytesPerSec)),
                        (String(localized: "Signal"), MetricFormatting.decibelMilliwatts($0.wifiRSSIdBm)),
                    ]
                } ?? []
            )
            VitalsLedgerRow(
                label: String(localized: "ANE"),
                headline: MetricFormatting.watts(snapshot?.ane?.powerWatts),
                context: snapshot?.ane.flatMap { ane in
                    ane.isActive.map { $0 ? String(localized: "active") : String(localized: "idle") }
                },
                details: []
            )
            VitalsLedgerRow(
                label: String(localized: "Thermals"),
                headline: MetricFormatting.celsius(snapshot?.thermal?.socTemperatureCelsius),
                context: thermalContext,
                details: snapshot?.thermal.map {
                    [
                        (String(localized: "Pressure"), MetricFormatting.pressureLevel($0.pressureLevel)),
                        (String(localized: "Throttling"), MetricFormatting.boolean($0.isThrottling)),
                        (String(localized: "Fans"), Self.fanSummary($0.fanRPMs)),
                    ]
                } ?? []
            )
        }
    }

    private var memoryUsedPercent: Double? {
        guard let memory = snapshot?.memory, memory.totalBytes > 0 else { return nil }
        return Double(memory.usedBytes) / Double(memory.totalBytes) * 100
    }

    /// The handoff's context-word idiom: "no pressure" / "fans silent"
    /// instead of a second number — only claims the data supports.
    private var thermalContext: String? {
        guard let thermal = snapshot?.thermal else { return nil }
        if thermal.isThrottling { return String(localized: "throttling") }
        switch thermal.pressureLevel {
        case .nominal:
            let fansParked = !thermal.fanRPMs.isEmpty && thermal.fanRPMs.allSatisfy { $0 < 1 }
            return fansParked ? String(localized: "fans silent") : String(localized: "no pressure")
        case .fair: return String(localized: "some pressure")
        case .serious: return String(localized: "serious pressure")
        case .critical: return String(localized: "critical")
        }
    }

    private static func fanSummary(_ rpms: [Double]) -> String {
        guard !rpms.isEmpty else { return MetricFormatting.placeholder }
        return rpms.map { String(Int($0.rounded())) }.joined(separator: ", ")
    }
}

// MARK: - Activity chart

/// The full-width Activity plot: CPU / memory / GPU overlaid, each
/// normalized to its own observed peak (their units are incompatible — the
/// plot shows shapes; the sentence below carries the real CPU numbers).
/// Same honesty contract the Mac's activity band used to carry under the same
/// design. Note that the Mac has since split its overlay into small multiples
/// (`ActivityLanesChart`) precisely because normalizing three incompatible
/// units onto one axis makes the crossings meaningless and turns idle noise
/// into a dramatic shape — the argument applies here too, and this view is a
/// candidate for the same treatment. It is left overlaid for now because a
/// phone's 60-sample ring buffer is a different data problem from the Mac's
/// history query, and splitting it is not a change to make blind from the
/// other platform.
///
/// **Why this is a `Chart` and no longer a `Canvas`.** It was a hand-stroked
/// `Canvas` polyline over bare `[Double]`s, positioned by array index. That
/// rendered the same picture at lower cost, and it made two things impossible.
/// It could not be scrubbed — the owner's "any chart you should be able to
/// hover over the line and [see a] specific checkpoint" has no answer when the
/// x-axis is an array index, because an index does not know when it was
/// captured. And it was subtly wrong about spacing: the phone drops a metric
/// from a tick where its module reported nothing (see
/// `DashboardViewModel.appendToSeries`, correctly refusing to invent a zero), so
/// evenly-spaced indices quietly compressed whatever was missed. Swift Charts
/// over a real time axis fixes both, costs one framework this app already
/// imports for `BatteryHealthTrendChart`, and lets this view reuse
/// `ChartScrubOverlay`/`ChartScrubbing` rather than growing a second,
/// nearly-identical readout of its own.
///
/// **Why the readout still refuses to give a combined number.** Unchanged from
/// the Mac counterpart's argument: the three lines are normalized to their own
/// peaks, so a y-position on this plot corresponds to no real quantity. The
/// readout lists each series' own recorded value in its own unit and never a
/// y-position, a fraction, or a total.
struct MobileActivityChart: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let series: [MetricID: [RecentSample]]

    /// Raw x-axis date under the finger; see `ChartScrubOverlay.scrubDate`.
    @State private var scrubDate: Date?

    private static let plotted: [(metric: MetricID, title: String)] = [
        (.cpuTotalPercent, String(localized: "CPU")),
        (.memoryUsedBytes, String(localized: "Memory")),
        (.gpuUtilizationPercent, String(localized: "GPU")),
    ]

    private var drawable: [(metric: MetricID, title: String, values: [RecentSample])] {
        Self.plotted.compactMap { entry in
            guard let values = series[entry.metric], values.count >= 2 else { return nil }
            return (entry.metric, entry.title, values)
        }
    }

    var body: some View {
        if drawable.isEmpty {
            Text("Activity appears after a few seconds of readings.")
                .scaledFont(palette, size: 12)
                .foregroundStyle(palette.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
        } else {
            VStack(alignment: .leading, spacing: palette.spacingTight) {
                legend
                plot
                    .frame(height: 96)
                if let sentence = cpuSentence {
                    Text(sentence)
                        .scaledFont(palette, size: 11, monospacedDigit: true)
                        .foregroundStyle(palette.textTertiary)
                }
            }
        }
    }

    private var plot: some View {
        Chart {
            ForEach(drawable, id: \.metric) { entry in
                let peak = max(entry.values.map(\.value).max() ?? 1, .leastNonzeroMagnitude)
                let segments = segmentNumbers(for: entry.values)
                ForEach(Array(entry.values.enumerated()), id: \.offset) { offset, sample in
                    // The series key carries the segment number as well as the
                    // metric, exactly as the Mac's overlay does: a phone that
                    // lost the Mac for thirty seconds mid-window leaves a hole,
                    // and three lines gliding smoothly across it would be three
                    // lies rather than one.
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Relative", sample.value / peak),
                        series: .value("Metric", "\(entry.title)#\(segments[offset])")
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    .foregroundStyle(palette.metricColor(entry.metric))
                    .interpolationMethod(.monotone)
                }
            }

            if let scrubAnchor {
                RuleMark(x: .value("Scrubbed time", scrubAnchor))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(palette.textTertiary)
                ForEach(readings, id: \.metric) { reading in
                    if let sample = reading.sample {
                        let peak = max(reading.peak, .leastNonzeroMagnitude)
                        PointMark(
                            x: .value("Scrubbed time", sample.timestamp),
                            y: .value("Relative", sample.value / peak)
                        )
                        .symbolSize(30)
                        .foregroundStyle(palette.metricColor(reading.metric))
                    }
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
        .chartOverlay { proxy in
            ChartScrubOverlay(proxy: proxy, scrubDate: $scrubDate, anchor: scrubAnchor) {
                scrubReadout
            }
        }
        .accessibilityLabel("Activity chart, last 60 seconds")
        .accessibilityValue(cpuSentence ?? String(localized: "relative activity shapes"))
    }

    // MARK: - Scrubbing

    /// One resolved row per drawn metric. `sample` is `nil` when that metric has
    /// no reading at the finger's position — which can be true of one series and
    /// false of its neighbours, since a snapshot missing one module still
    /// carries the others.
    private struct Reading {
        let metric: MetricID
        let title: String
        let sample: RecentSample?
        let peak: Double
    }

    /// The Mac's snapshot cadence as this phone sees it — observed, not
    /// declared.
    ///
    /// The Mac side can declare its cadence because it knows the tier it
    /// queried; this app knows nothing about the sender's refresh interval
    /// (`AppSettings.globalRefreshInterval` lives on the Mac and is not on the
    /// wire), so the observed median spacing is the only honest answer.
    /// `ChartScrubbing.effectiveCadence` is built for exactly this
    /// "nothing declared" case.
    private func cadence(for values: [RecentSample]) -> TimeInterval? {
        ChartScrubbing.effectiveCadence(expected: nil, timestamps: values.map(\.timestamp))
    }

    private func segmentNumbers(for values: [RecentSample]) -> [Int] {
        var numbers = [Int](repeating: 0, count: values.count)
        guard let cadence = cadence(for: values) else { return numbers }
        let segments = ChartScrubbing.segments(
            timestamps: values.map(\.timestamp),
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
                timestamps: entry.values.map(\.timestamp),
                cadence: cadence(for: entry.values) ?? 0
            )
            var sample: RecentSample?
            if case .sample(let index) = resolved, entry.values.indices.contains(index) {
                sample = entry.values[index]
            }
            return Reading(
                metric: entry.metric,
                title: entry.title,
                sample: sample,
                peak: entry.values.map(\.value).max() ?? 1
            )
        }
    }

    /// Where the rule stands: the first resolved series' own timestamp when
    /// there is one, so the rule lines up with a real dot, and the raw finger
    /// position when every series is in a hole.
    private var scrubAnchor: Date? {
        guard let scrubDate else { return nil }
        return readings.compactMap { $0.sample?.timestamp }.first ?? scrubDate
    }

    @ViewBuilder
    private var scrubReadout: some View {
        if let scrubDate, !readings.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(scrubDate.formatted(date: .omitted, time: .standard))
                    .scaledFont(palette, size: 10)
                    .foregroundStyle(palette.textTertiary)
                ForEach(readings, id: \.metric) { reading in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(palette.metricColor(reading.metric))
                            .frame(width: 5, height: 5)
                        Text(Self.rowText(metric: reading.metric, title: reading.title, sample: reading.sample))
                            .scaledFont(palette, size: 11, monospacedDigit: true)
                            .foregroundStyle(palette.textPrimary)
                    }
                }
            }
            .fixedSize()
            .chartScrubPlate(palette)
        }
    }

    /// Each metric's own real value in its own unit — never the normalized
    /// y-position the line was drawn at.
    ///
    /// Pure, and a deliberate two-line mirror of `ActivityLanesChart.rowText`
    /// on the Mac, which `SentryTests/ChartScrubbingTests.swift` does cover
    /// (the Mac's version now reads a bucket rather than a single sample, so
    /// the two have diverged on *what* is described — not on the "no data"
    /// wording this mirrors):
    /// there is no iOS test target in this build (`project.yml` — `SentryTests`
    /// depends on `SentryKit_macOS`/`Sentry` only), so nothing under
    /// `SentryMobile/` is reachable from a test. The same split
    /// `BatteryHealthTrendChart.readoutText` documents applies here — the part
    /// worth testing (`ChartScrubbing.resolve`, which decides *whether* there is
    /// a sample) is in `SentryKit` and is tested; this is the phrasing layer
    /// over its answer.
    ///
    /// The seconds-precision timestamp above these rows is not decoration: this
    /// series is a 60-sample ring at the Mac's ~3s cadence, so a minute-precision
    /// stamp would label twenty adjacent points identically.
    static func rowText(metric: MetricID, title: String, sample: RecentSample?) -> String {
        guard let sample else {
            return String(localized: "\(title) no data")
        }
        return "\(title) \(MetricFormatter.compact(sample.value, unit: metric.unit))"
    }

    /// Three swatch+name pairs and a "last 60 s" caption. On one line at
    /// normal sizes; at accessibility sizes those four items need roughly
    /// three times the width the phone has, and SwiftUI would resolve the
    /// overflow by truncating the metric names to "C…", "M…", "G…" — a legend
    /// that no longer identifies anything. Stacking the pairs vertically and
    /// moving the caption to its own line costs three lines of height in a
    /// `ScrollView` and keeps every name whole.
    @ViewBuilder
    private var legend: some View {
        let entries = ForEach(drawable, id: \.metric) { entry in
            HStack(spacing: 4) {
                Circle()
                    .fill(palette.metricColor(entry.metric))
                    .frame(width: 6, height: 6)
                Text(entry.title)
                    .scaledFont(palette, size: 11)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        let caption = Text("last 60 s")
            .scaledFont(palette, size: 11)
            .foregroundStyle(palette.textTertiary)

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: palette.spacingTight) {
                entries
                caption
            }
        } else {
            HStack(spacing: palette.spacingRow) {
                entries
                Spacer(minLength: 0)
                caption
            }
        }
    }

    private var cpuSentence: String? {
        guard let cpu = series[.cpuTotalPercent]?.map(\.value), !cpu.isEmpty else { return nil }
        let avg = cpu.reduce(0, +) / Double(cpu.count)
        let peak = cpu.max() ?? 0
        // Pre-formatted numbers so the sentence is one catalog key with
        // `%@` placeholders a translator can reorder.
        let avgText = String(format: "%.0f%%", avg)
        let peakText = String(format: "%.0f%%", peak)
        return String(localized: "avg CPU \(avgText) · peak \(peakText)")
    }
}
