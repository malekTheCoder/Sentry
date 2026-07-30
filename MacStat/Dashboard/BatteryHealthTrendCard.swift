import SwiftUI
import MacStatKit

/// The Dashboard's headline long-term chart (plan §12.1's "battery health
/// trend" — the one metric the iPhone app treats as important enough to be
/// the very first thing in its dashboard, and MacStat had no Mac-side
/// equivalent for until this card).
///
/// **Why this queries `HistoryStore` directly instead of going through
/// `DashboardViewModel.series(for:)`:** every other Dashboard chart tracks
/// the user's `TimeRangePicker` selection — "show me the last 7 days of
/// CPU" is a genuinely different question on `.sevenDays` vs `.all`. Battery
/// health is different: it changes over weeks/months, not hours, so a "last
/// hour" or "last 24h" reading of it is never useful and would render as a
/// flat, information-free line (or `DashboardChart`'s empty state, since
/// health is usually sampled far less often than every 3s). This card
/// always wants the full history regardless of what range the rest of the
/// window is showing, so it manages its own one-shot `.daily`/`.distantPast`
/// query instead of subscribing to `DashboardViewModel.timeRange` changes
/// that would otherwise force it to re-query on every picker tap for no
/// visual benefit.
///
/// **Why `.daily` unconditionally, not tier-inferred:** health barely moves
/// sample-to-sample, so raw/hourly resolution would just be
/// `RollupJob`-thinned duplicates of the same daily trend at a much larger
/// row count. `.daily` is also the only tier `RollupJob` keeps forever (see
/// `TimeRangePicker.queryWindow`'s doc comment on `.all`), which matters
/// here specifically because this card's entire premise is "show the whole
/// history," not a recent window.
struct BatteryHealthTrendCard: View {
    @Environment(\.themePalette) private var palette

    let historyStore: HistoryStore
    /// Live current cycle count, sourced from `DashboardViewModel.snapshot`
    /// rather than queried — cycle count is a single running counter, not a
    /// series worth its own chart the way health percent is (a plot of "0,
    /// 1, 2, 3, ... 412" is a straight line with no analytical value beyond
    /// its current endpoint). Optional because `BatteryStats.cycleCount`
    /// itself is optional (IOKit read can fail) and because `snapshot` is
    /// nil until the first `ingest(_:)` call.
    let currentCycleCount: Int?

    @State private var samples: DashboardViewModel.RangedSamples = []
    @State private var hasLoaded = false

    private var tint: Color { palette.metricColor(.batteryHealthPercent) }

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            header
            DashboardChart(
                samples: samples,
                tint: tint,
                metricTitle: "Battery Health",
                height: 160
            )
        }
        .padding(palette.spacing * 1.6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                .stroke(palette.separator, lineWidth: 1)
        )
        // `.task` rather than `.onAppear`: this card is a scroll-away
        // subview of `DashboardView` inside a `ScrollView`, and `.task` is
        // automatically cancelled if the view disappears mid-query — a
        // GRDB read that outlives its view can't crash anything here (it's
        // synchronous, not actually cancellable), but the automatic
        // lifecycle tie is the more honest contract for a load meant to
        // happen once per appearance. Guarded by `hasLoaded` because
        // `.task` re-runs if the view is re-created (e.g. a theme change
        // rebuilds the tree upstream), and a full-history query isn't cheap
        // enough to repeat on every incidental re-mount.
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            load()
        }
    }

    /// Title + one combined meta line, matching the Nocturne mock's "Battery
    /// health · 6 months" / "92% health · 312 cycles" pattern — this card's
    /// own query is all-time rather than a fixed 6-month window (see the type
    /// doc comment on why), so the title says so honestly instead of
    /// borrowing the mock's specific span.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Battery Health · all-time")
                .font(palette.font(size: 14, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text("\(MetricFormatting.percent(samples.last?.avg, decimals: 1)) health · \(MetricFormatting.integer(currentCycleCount)) cycles")
                .font(palette.font(size: 12))
                .monospacedDigit()
                .foregroundStyle(palette.textTertiary)
        }
    }

    private func load() {
        let raw = historyStore.samplesWithRange(
            metric: MetricID.batteryHealthPercent.rawValue,
            since: .distantPast,
            tier: .daily
        )
        // Same cap `DashboardViewModel` applies to every other chart —
        // years of daily rows is normally far below 360 anyway (see that
        // constant's doc comment), so this is a no-op in practice and only
        // matters as a defensive ceiling.
        samples = DashboardViewModel.downsample(raw, cap: DashboardViewModel.maxPointsPerSeries)
    }
}
