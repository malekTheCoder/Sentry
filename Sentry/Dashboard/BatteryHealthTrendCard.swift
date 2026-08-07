import SwiftUI
import SentryKit

/// The Dashboard's headline long-term chart (plan §12.1's "battery health
/// trend" — the one metric the iPhone app treats as important enough to be
/// the very first thing in its dashboard, and Sentry had no Mac-side
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

    /// Live health from the current snapshot — the header's fallback while
    /// the daily series is still empty, so a Mac that plainly knows its
    /// health (the hero card shows it) never captions this card "— health".
    let currentHealthPercent: Double?

    @State private var samples: DashboardViewModel.RangedSamples = []
    @State private var hasLoaded = false

    private var tint: Color { palette.metricColor(.batteryHealthPercent) }

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            header
            if samples.isEmpty {
                // One quiet line, not a 160pt empty chart: on a fresh
                // install the first daily rollup is at most a day away, and
                // a card-sized void reads as breakage, not honesty.
                Text("Trend appears after a day or two of readings — daily health snapshots accumulate while Sentry runs.")
                    .font(palette.font(size: 12))
                    .foregroundStyle(palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                DashboardChart(
                    samples: samples,
                    tint: tint,
                    metricTitle: "Battery Health",
                    unit: MetricID.batteryHealthPercent.unit,
                    // Same reasoning as `BatteryOverviewCard`'s chart: this
                    // card owns its `.daily` query, so one row per day is the
                    // cadence, and no downsampling applies at this row count.
                    expectedCadence: 86400,
                    // No `window:` — see `BatteryOverviewCard`'s chart for the
                    // full argument. An all-time query has no requested left
                    // edge, so there is nothing to pin and nothing to fall
                    // short of; the header's coverage line carries the "how
                    // long is all-time, here" disclosure instead.
                    height: 160
                )
            }
        }
        .dashboardCard(palette)
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
            Text("\(MetricFormatting.percent(samples.last?.avg ?? currentHealthPercent, decimals: 1)) health · \(MetricFormatting.integer(currentCycleCount)) cycles")
                .font(palette.font(size: 12))
                .monospacedDigit()
                .foregroundStyle(palette.textTertiary)
            if let forecastLine {
                Text(forecastLine)
                    .font(palette.font(size: 12))
                    .foregroundStyle(palette.textTertiary)
            }
            if let coverageLine {
                Text(coverageLine)
                    .font(palette.font(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(palette.textTertiary)
            }
        }
    }

    /// "41 days recorded · since Jun 27" — how long this card's "all-time"
    /// actually is. See `BatteryOverviewCard.coverageLine`, which says the same
    /// thing about the same query for the same reason; a title that reads
    /// "all-time" should never be the only thing a reader has to go on when
    /// deciding how much weight to give the trend under it.
    private var coverageLine: String? {
        HistoryCoverage(
            requested: nil,
            timestamps: samples.map(\.timestamp),
            resolution: 86400
        ).summary
    }

    /// The forecast sentence, or nil when there's nothing defensible to say —
    /// `BatteryHealthForecast` owns the honesty rules (minimum span, horizon
    /// cap); this just phrases its cases. `.insufficientData` renders as
    /// nothing rather than an apology: a card already showing a short chart
    /// doesn't need a second line saying the chart is short.
    private var forecastLine: String? {
        let forecast = BatteryHealthForecast.forecast(
            samples: samples.map { (timestamp: $0.timestamp, health: $0.avg) }
        )
        switch forecast {
        case .insufficientData:
            return nil
        case .stable:
            return String(localized: "No decline in sight at the current rate")
        case .alreadyBelow:
            return String(localized: "Below 80% — consider battery service")
        case .crosses(let date, let percentPerMonth):
            let month = date.formatted(.dateTime.month(.wide).year())
            let rate = String(format: "%.1f", percentPerMonth)
            return String(localized: "On pace to cross 80% around \(month) (−\(rate)%/mo)")
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
