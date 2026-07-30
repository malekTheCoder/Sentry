import SwiftUI
import MacStatKit

/// The lighter dropdown's 2×2 "glance" grid: CPU, Memory, Disk free, and
/// Battery, each reduced to a single current reading with no sparkline.
///
/// This intentionally does not reuse `MetricCard` — that view's chevron,
/// expand state, and sparkline are exactly the per-module depth the lighter
/// dropdown is cutting (see the redesign spec). It borrows only the visual
/// language (`palette.surface`, `palette.cornerRadius`, `palette.spacing`)
/// established there so the grid still reads as the same design system.
struct HeadlineMetricGrid: View {
    @Environment(\.themePalette) private var palette

    let snapshot: SystemSnapshot?

    /// Fixed 2-column grid rather than an adaptive one: four headline
    /// metrics at a known 320pt popover width don't need to reflow, and a
    /// fixed layout keeps the value/label baseline aligned across rows.
    private static let columns = [
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: palette.spacing) {
            metricCell(label: "CPU", value: MetricFormatting.percent(snapshot?.cpu?.totalPercent))
            metricCell(label: "Memory", value: memoryHeadline)
            metricCell(label: "Disk Free", value: MetricFormatting.bytes(snapshot?.disk?.freeBytes))
            metricCell(label: "Battery", value: MetricFormatting.percent(snapshot?.battery?.chargePercent))
        }
    }

    /// Percent-used rather than a raw byte count — consistent with CPU and
    /// Battery being the "how loaded is this right now" reading, not a
    /// capacity figure (that detail still lives in the memory module card
    /// elsewhere in the app).
    private var memoryHeadline: String {
        guard let memory = snapshot?.memory, memory.totalBytes > 0 else {
            return MetricFormatting.placeholder
        }
        let usedPercent = Double(memory.usedBytes) / Double(memory.totalBytes) * 100
        return MetricFormatting.percent(usedPercent)
    }

    private func metricCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(palette.font(size: 10, weight: .medium))
                .foregroundStyle(palette.textTertiary)
                .lineLimit(1)
            // True SF Mono, not `palette.font` — the redesign spec calls for
            // SF Mono tabular numerals on every numeric readout regardless
            // of the active theme's `fontFamily`, so this one value
            // deliberately opts out of the theme's typography token.
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
}

// MARK: - Preview

#Preview {
    HeadlineMetricGrid(snapshot: nil)
        .padding()
        .frame(width: 320)
        .background(ThemePalette(theme: .slate, scheme: .dark).background)
}
