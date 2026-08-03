import SwiftUI
import Charts

/// The 60-sample rolling chart shared by every module card. Mark type follows
/// the theme's `chartStyle` token so a theme switch restyles all charts at
/// once.
struct SparklineChart: View {
    @Environment(\.themePalette) private var palette

    let series: MetricSeries
    let tint: Color
    var height: CGFloat = 44

    var body: some View {
        Chart(series.samples) { sample in
            switch palette.theme.chartStyle {
            case .line:
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Value", sample.value)
                )
                .lineStyle(StrokeStyle(lineWidth: palette.theme.chartLineWidth, lineJoin: .round))
                .foregroundStyle(tint)
                .interpolationMethod(.monotone)
            case .stepped:
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Value", sample.value)
                )
                .lineStyle(StrokeStyle(lineWidth: palette.theme.chartLineWidth))
                .foregroundStyle(tint)
                .interpolationMethod(.stepEnd)
            case .bars:
                BarMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Value", sample.value)
                )
                .foregroundStyle(tint)
            case .area:
                AreaMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Value", sample.value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: palette.chartFill,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Value", sample.value)
                )
                .lineStyle(StrokeStyle(lineWidth: palette.theme.chartLineWidth, lineJoin: .round))
                .foregroundStyle(tint)
                .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: yDomain)
        .chartPlotStyle { plot in
            plot.background(gridBackground)
        }
        .frame(height: height)
        // Glow is the Terminal preset's signature; 0 for every other theme.
        .shadow(color: tint.opacity(palette.glow * 0.8), radius: palette.glow * 4)
        .accessibilityLabel("\(series.metric.title) history, last \(series.samples.count) samples")
        .accessibilityValue(
            "current \(MetricFormatting.seriesValue(series.latest, metric: series.metric))"
        )
    }

    @ViewBuilder
    private var gridBackground: some View {
        if palette.theme.showChartGrid {
            // A three-line rule reads as a grid at sparkline scale without
            // Charts' full axis machinery, which would force axis labels back on.
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in
                    Rectangle().fill(palette.chartGrid).frame(height: 0.5)
                    Spacer(minLength: 0)
                }
            }
        } else {
            Color.clear
        }
    }

    /// Percent metrics pin to 0...100 so the shape reflects absolute load.
    /// Everything else auto-scales, with a floor so a perfectly flat series
    /// doesn't collapse into a zero-height domain.
    private var yDomain: ClosedRange<Double> {
        if series.metric.isPercentage { return 0...100 }
        let low = series.minimum ?? 0
        let high = series.maximum ?? 1
        guard high > low else { return low...(low + max(abs(low) * 0.1, 1)) }
        let padding = (high - low) * 0.1
        return (low - padding)...(high + padding)
    }
}
