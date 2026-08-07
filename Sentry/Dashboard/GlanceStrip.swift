import SwiftUI
import SentryKit

/// The Dashboard's opening move: one row of uniform stat tiles, each a
/// module's headline number over a small sparkline. The uniformity is the
/// point — six identical shapes with identical internal geometry read as
/// one deliberate instrument panel, where the previous mixed-size cards
/// read as parts from different kits.
///
/// Data comes straight off what `DashboardView` already holds: the live
/// snapshot for the numbers, `DashboardViewModel.series` (the same
/// range-driven query feeding the History grid) for the sparklines — no new
/// queries, no new polling.
struct GlanceStrip: View {
    @Environment(\.themePalette) private var palette

    let snapshot: SystemSnapshot?
    let series: [ChartMetric: DashboardViewModel.RangedSamples]
    let enabledModules: Set<MetricModule>

    /// The `(since, now)` span `series` was queried over, from
    /// `DashboardViewModel.window`. See `GlanceSparkline` for what a 20pt
    /// texture does with it and why it needs it at all.
    var window: ClosedRange<Date>? = nil

    /// Fixed tile order; disabled modules drop out rather than leaving gaps.
    private static let order: [ChartMetric] = [.cpu, .memory, .gpu, .thermal, .network, .disk]

    private var visibleMetrics: [ChartMetric] {
        Self.order.filter { enabledModules.contains($0.module) }
    }

    var body: some View {
        if !visibleMetrics.isEmpty {
            // Open columns divided by vertical hairlines — no boxes. The
            // strip is one instrument row on the shared surface, not a
            // shelf of separate products; equal flex keeps it spanning the
            // window at any enabled-module count.
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(visibleMetrics.enumerated()), id: \.element.id) { index, metric in
                    if index > 0 {
                        Rectangle()
                            .fill(palette.separator)
                            .frame(width: 1, height: 58)
                    }
                    GlanceTile(
                        metric: metric,
                        value: snapshot?.value(for: metric.metricID),
                        samples: sparkSamples(for: metric),
                        window: window
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, palette.spacingBlock)
                }
            }
            .padding(.horizontal, -palette.spacingBlock)
        }
    }

    /// Up to 48 `(time, value)` pairs — the strip's plot is ~100pt wide and
    /// more points than that is wasted path complexity.
    ///
    /// Carries timestamps now, where it used to hand down bare `[Double]`s. Not
    /// because the tile labels them (it does not — see `GlanceSparkline`), but
    /// because a value with no time can only be positioned by array index, and
    /// index positioning is what let a three-day-old install's line span a tile
    /// that is supposed to represent ninety days.
    private func sparkSamples(for metric: ChartMetric) -> [(timestamp: Date, value: Double)] {
        guard let ranged = series[metric] else { return [] }
        let points = ranged.map { (timestamp: $0.timestamp, value: $0.avg) }
        guard points.count > 48 else { return points }
        let stride = Double(points.count) / 48
        return (0..<48).map { points[Int(Double($0) * stride)] }
    }
}

// MARK: - Tile

private struct GlanceTile: View {
    @Environment(\.themePalette) private var palette

    let metric: ChartMetric
    let value: Double?
    let samples: [(timestamp: Date, value: Double)]
    let window: ClosedRange<Date>?

    private var tint: Color { palette.metricColor(metric.metricID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                Text(metric.title.uppercased())
                    .font(palette.font(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(1)
            }
            Text(MetricFormatting.value(value, metric: metric.metricID))
                .font(palette.numericFont(size: 19, weight: .semibold))
                .foregroundStyle(value == nil ? palette.textTertiary : palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            GlanceSparkline(samples: samples, window: window, tint: tint)
                .frame(height: 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title), \(MetricFormatting.value(value, metric: metric.metricID))")
    }
}

// MARK: - Sparkline

/// A bare line over the sample range — no axes, no grid, no fill. At 20pt
/// tall this is a texture that says "alive and moving", not a chart to read
/// values off; the History grid below is where real charts live.
///
/// **Why a decoration still has to be honest about time.** This used to space
/// its points evenly across the tile by array index, which is fine right up
/// until the number of points stops corresponding to the width of the window:
/// three days of history under a "90d" selection produced a line spanning the
/// full tile, exactly the misreading the pinned x-domain removes from every
/// other chart on this window. It costs six lines to place each point at its own
/// fraction of the requested window instead, and then a short record draws as a
/// short line at the right — the same silhouette as the full-size chart of the
/// same metric directly below it. A strip whose six tiles disagreed with the
/// grid under them about how much history exists would be worse than no strip.
///
/// **Deliberately not scrubbable.** Two reasons, and both are about size rather
/// than principle. The tile is ~100pt × 20pt: the readout plate is ~18pt tall
/// and would cover the plot entirely, and the pointer itself would obscure most
/// of the width. And the tile already shows that metric's *current* value in
/// 19pt directly above the line, which is the one number a glance strip exists
/// to deliver — a reader wanting a specific past point is looking for the
/// full-size, scrubbable chart of the same metric in the History grid below.
/// Adding a hit area here would also put a drag gesture across the top of a
/// scrolling window, competing with the scroll for no gain.
private struct GlanceSparkline: View {
    @Environment(\.themePalette) private var palette

    let samples: [(timestamp: Date, value: Double)]
    /// The requested range. `nil` (no query has run) falls back to positioning
    /// across the samples' own extent, which is what the tile did before and is
    /// correct when there is no window to be short of.
    let window: ClosedRange<Date>?
    let tint: Color

    /// The time span the tile's width represents.
    private var domain: ClosedRange<Date>? {
        if let window, window.lowerBound < window.upperBound { return window }
        guard let first = samples.first?.timestamp,
              let last = samples.last?.timestamp,
              first < last else { return nil }
        return first...last
    }

    var body: some View {
        GeometryReader { proxy in
            if samples.count >= 2, let domain,
               let lowest = samples.map(\.value).min(), let highest = samples.map(\.value).max() {
                let valueSpan = highest - lowest
                let timeSpan = domain.upperBound.timeIntervalSince(domain.lowerBound)
                Path { path in
                    // Broken at gaps for the same reason every other chart in
                    // the app is (`ChartScrubbing.segments`): a stroke that
                    // glides across an overnight sleep claims readings nobody
                    // took, and it claims them just as confidently at 20pt.
                    let breaks = segmentStarts
                    for (index, sample) in samples.enumerated() {
                        let valueFraction = valueSpan > 0.000_001 ? (sample.value - lowest) / valueSpan : 0.5
                        let timeFraction = sample.timestamp.timeIntervalSince(domain.lowerBound) / timeSpan
                        let point = CGPoint(
                            x: proxy.size.width * CGFloat(min(max(timeFraction, 0), 1)),
                            y: proxy.size.height * (1 - CGFloat(min(max(valueFraction, 0), 1)))
                        )
                        if breaks.contains(index) { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(tint.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            } else {
                // Not enough points yet: a faint baseline holds the slot so
                // tiles never change height as data arrives.
                Rectangle()
                    .fill(palette.separator)
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .accessibilityHidden(true)
    }

    /// Indices that begin a new stroke — index 0 plus the first point after
    /// each gap.
    private var segmentStarts: Set<Int> {
        let timestamps = samples.map(\.timestamp)
        guard let cadence = ChartScrubbing.effectiveCadence(expected: nil, timestamps: timestamps) else {
            return [0]
        }
        let segments = ChartScrubbing.segments(
            timestamps: timestamps,
            threshold: ChartScrubbing.gapThreshold(cadence: cadence)
        )
        return Set(segments.map(\.lowerBound))
    }
}
