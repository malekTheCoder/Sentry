import SwiftUI
import MacStatKit

/// Plan §12.1's "cycle count over time" item. Deliberately scoped to
/// "current value + trend indicator," not a second chart — a plot of
/// "0, 1, 2, 3, ..., 142" is a straight line whose only informative point is
/// its right-hand endpoint, the exact reasoning
/// `BatteryHealthTrendCard.currentCycleCount`'s doc comment already gives
/// on the Mac side for why cycle count doesn't get its own `DashboardChart`
/// there either. Building a chart here anyway just because `DailyHealth` has
/// a `cycleCount` field would be doing more work to show less information.
///
/// What a bare "142 cycles" wouldn't convey, and this view does: whether the
/// Mac has logged more cycles across the *currently selected range* — i.e.
/// is this device seeing heavier or lighter use lately — computed as
/// `series.last.cycleCount - series.first.cycleCount`.
struct CycleCountSection: View {
    @Environment(\.themePalette) private var palette
    let series: [DailyHealth]

    private var current: Int? { series.last?.cycleCount }

    private var delta: Int? {
        guard let first = series.first?.cycleCount, let last = series.last?.cycleCount else { return nil }
        return last - first
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: palette.spacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cycle Count")
                    .font(palette.font(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(current.map { "\($0)" } ?? MetricFormatting.placeholder)
                    .font(palette.font(size: 22, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(palette.textPrimary)
            }
            Spacer(minLength: palette.spacing)
            trendLabel
        }
        .padding(palette.spacing * 1.6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                .stroke(palette.separator, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var trendLabel: some View {
        switch delta {
        case .some(let value) where value > 0:
            Label("+\(value) this range", systemImage: "arrow.up.right")
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
        case .some(0):
            Text("No change this range")
                .font(.caption)
                .foregroundStyle(palette.textTertiary)
        // A negative delta shouldn't be reachable — cycle count only
        // increases in `SyntheticDailyHealth.series` — but rendering it
        // plainly rather than force-unwrapping/crashing is the same
        // defensive stance `Freshness.init` takes for a future `lastSeen`.
        case .some(let value):
            Label("\(value) this range", systemImage: "arrow.down.right")
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
        case .none:
            EmptyView()
        }
    }
}
