import SwiftUI
import MacStatKit

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
                        samples: sparkValues(for: metric)
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, palette.spacingBlock)
                }
            }
            .padding(.horizontal, -palette.spacingBlock)
        }
    }

    private func sparkValues(for metric: ChartMetric) -> [Double] {
        guard let ranged = series[metric] else { return [] }
        // The strip's plot is ~100pt wide; more points than that is wasted
        // path complexity.
        let values = ranged.map(\.avg)
        guard values.count > 48 else { return values }
        let stride = Double(values.count) / 48
        return (0..<48).map { values[Int(Double($0) * stride)] }
    }
}

// MARK: - Tile

private struct GlanceTile: View {
    @Environment(\.themePalette) private var palette

    let metric: ChartMetric
    let value: Double?
    let samples: [Double]

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
            GlanceSparkline(samples: samples, tint: tint)
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
private struct GlanceSparkline: View {
    @Environment(\.themePalette) private var palette

    let samples: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            if samples.count >= 2,
               let lowest = samples.min(), let highest = samples.max() {
                let span = highest - lowest
                Path { path in
                    let stepX = proxy.size.width / CGFloat(samples.count - 1)
                    for (index, sample) in samples.enumerated() {
                        let fraction = span > 0.000_001 ? (sample - lowest) / span : 0.5
                        let point = CGPoint(
                            x: CGFloat(index) * stepX,
                            y: proxy.size.height * (1 - CGFloat(min(max(fraction, 0), 1)))
                        )
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
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
}
