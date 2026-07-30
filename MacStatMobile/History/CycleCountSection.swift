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
///
/// **Nocturne redesign restyle.** This used to be its own elevated card
/// (title + 22px bold headline + trend label) sitting below the battery
/// health card. The redesign spec folds "312 cycles" into that card as a
/// slim caption line under the trend chart instead — this view now renders
/// just that caption, with the same range-delta trend logic, rather than a
/// second bordered surface competing with it for visual weight.
struct CycleCountSection: View {
    @Environment(\.themePalette) private var palette
    let series: [DailyHealth]

    private var current: Int? { series.last?.cycleCount }

    private var delta: Int? {
        guard let first = series.first?.cycleCount, let last = series.last?.cycleCount else { return nil }
        return last - first
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(cycleCaption)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(palette.textTertiary)
            trendLabel
        }
    }

    private var cycleCaption: String {
        current.map { "\($0) cycles" } ?? MetricFormatting.placeholder
    }

    @ViewBuilder
    private var trendLabel: some View {
        switch delta {
        case .some(let value) where value > 0:
            Label("+\(value) this range", systemImage: "arrow.up.right")
                .font(.caption2)
                .foregroundStyle(palette.textSecondary)
        case .some(0):
            Text("No change this range")
                .font(.caption2)
                .foregroundStyle(palette.textTertiary)
        // A negative delta shouldn't be reachable — cycle count only
        // increases in `SyntheticDailyHealth.series` — but rendering it
        // plainly rather than force-unwrapping/crashing is the same
        // defensive stance `Freshness.init` takes for a future `lastSeen`.
        case .some(let value):
            Label("\(value) this range", systemImage: "arrow.down.right")
                .font(.caption2)
                .foregroundStyle(palette.textSecondary)
        case .none:
            EmptyView()
        }
    }
}
