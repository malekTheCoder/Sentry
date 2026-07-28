import SwiftUI

/// Reusable collapsible module card: title row with the current value, then a
/// sparkline, min/avg/max for the visible window, and any per-module detail
/// rows the caller supplies.
///
/// Collapse state is local `@State` for this pass — persisting it (plan §8.3
/// "state persists") belongs with the settings store, not here.
struct MetricCard<Detail: View>: View {
    @Environment(\.themePalette) private var palette

    private let metric: ChartMetric
    /// nil when the module reported no usable reading — the card then says so
    /// instead of drawing a zero.
    private let series: MetricSeries?
    private let headlineValue: String
    private let subtitle: String?
    private let detail: () -> Detail

    @State private var isExpanded = true

    // Explicit init: the synthesized memberwise one would inherit the private
    // access level of `isExpanded` and be unreachable from other files.
    init(
        metric: ChartMetric,
        series: MetricSeries?,
        headlineValue: String,
        subtitle: String? = nil,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.metric = metric
        self.series = series
        self.headlineValue = headlineValue
        self.subtitle = subtitle
        self.detail = detail
    }

    private var tint: Color { palette.metricColor(metric.colorID) }

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            header
            if isExpanded {
                if let series, !series.isEmpty {
                    SparklineChart(series: series, tint: tint)
                    statsRow(for: series)
                } else {
                    Text("Unavailable")
                        .font(palette.font(size: 11))
                        .foregroundStyle(palette.textTertiary)
                }
                detail()
            }
        }
        .padding(palette.spacing * 1.4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                .stroke(palette.separator, lineWidth: 1)
        )
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: palette.spacing) {
                Image(systemName: metric.symbolName)
                    .foregroundStyle(tint)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(metric.title)
                        .font(palette.font(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(palette.font(size: 10))
                            .foregroundStyle(palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: palette.spacing)
                Text(headlineValue)
                    .font(palette.font(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(palette.textPrimary)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(metric.title), \(headlineValue)")
        .accessibilityHint(isExpanded ? "Collapse card" : "Expand card")
    }

    private func statsRow(for series: MetricSeries) -> some View {
        HStack(spacing: palette.spacing * 2) {
            statistic("min", series.minimum)
            statistic("avg", series.average)
            statistic("max", series.maximum)
            Spacer(minLength: 0)
            Text("\(series.samples.count)/\(DropdownViewModel.historyLimit)")
                .font(palette.font(size: 9))
                .monospacedDigit()
                .foregroundStyle(palette.textTertiary)
        }
    }

    private func statistic(_ label: String, _ value: Double?) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(palette.font(size: 9))
                .foregroundStyle(palette.textTertiary)
            Text(MetricFormatting.seriesValue(value, metric: metric))
                .font(palette.font(size: 10))
                .monospacedDigit()
                .foregroundStyle(palette.textSecondary)
        }
    }
}

extension MetricCard where Detail == EmptyView {
    init(metric: ChartMetric, series: MetricSeries?, headlineValue: String, subtitle: String? = nil) {
        self.init(
            metric: metric,
            series: series,
            headlineValue: headlineValue,
            subtitle: subtitle,
            detail: { EmptyView() }
        )
    }
}

/// Label/value pair used by card detail sections. Values are pre-formatted so
/// the nil handling stays in `MetricFormatting`.
struct MetricDetailRow: View {
    @Environment(\.themePalette) private var palette

    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)
            Spacer(minLength: palette.spacing)
            Text(value)
                .font(palette.font(size: 10))
                .monospacedDigit()
                .foregroundStyle(palette.textSecondary)
        }
    }
}
