import Foundation
import MacStatKit

/// Feeds the Dashboard window: live "current value" headlines plus
/// on-demand historical charts, from two different sources that update at
/// two very different cadences.
///
/// **Two data paths, deliberately not unified:**
///   - `ingest(_:)` is called from `AppDelegate`'s existing snapshot loop —
///     the same shape as `DropdownViewModel.ingest`/`DebugDumpViewModel.ingest`
///     — so a "current CPU: 42%" headline never goes stale. This is cheap
///     (a struct copy) and safe to run on every tick (plan §3.2 P3: one poll
///     loop, many consumers; no second `StatsCoordinator` subscription here).
///   - `refresh()` queries `HistoryStore.samplesWithRange` for every enabled
///     module's chart metric. This is **not** called from `ingest` and must
///     never be — a GRDB read on every ~3s tick for every chart the
///     Dashboard shows would be the exact always-on cost plan R9 warns
///     against, for a window that (unlike the dropdown) usually isn't even
///     open. The intended call sites are: once when the Dashboard window
///     appears, and again whenever `timeRange` (or `enabledModules`) changes
///     — the latter two happen automatically via `didSet` below, so a caller
///     only needs to call `refresh()` explicitly on first appearance.
///
/// **Not `DropdownViewModel` stretched to a longer window:** `DropdownViewModel`
/// is deliberately capped at an in-memory 60-sample ring (its own doc
/// comment is explicit about this) — it has no way to answer "what did CPU
/// look like 6 days ago" because it never kept that data. This type answers
/// exactly that question by going to `HistoryStore` instead, and does not
/// touch `DropdownViewModel` at all.
@MainActor
final class DashboardViewModel: ObservableObject {

    /// A queried-and-downsampled per-metric history, ready for
    /// `DashboardChart`. Kept as the same tuple shape
    /// `HistoryStore.samplesWithRange` returns rather than a wrapper type —
    /// `DashboardChart` is built to consume that shape directly (see its doc
    /// comment), so there's no translation step for either side to keep in
    /// sync.
    typealias RangedSamples = [(timestamp: Date, min: Double, avg: Double, max: Double)]

    /// Chart data points a single dashboard card is ever downsampled to.
    ///
    /// **Why downsampling is needed at all:** `.raw`-tier data has no
    /// rollup — one row per sample, at whatever cadence
    /// `globalRefreshInterval` is set to (3s default). `TimeRangePicker`
    /// only routes `.oneHour`/`.oneDay` to `.raw` (see its doc comment for
    /// why those two land under `HistoryStore`'s 48h raw-tier cutoff), but
    /// even the narrower of those two — 24h at a 3s cadence — is up to
    /// 28,800 raw rows for one metric. Swift Charts has no trouble laying
    /// out that many `LineMark`s, but there is no visual benefit to a
    /// 900pt-wide chart plotting 28,800 x-positions: at that density,
    /// adjacent points are sub-pixel apart, so every point beyond what the
    /// chart can actually resolve is pure CPU cost (path construction) with
    /// zero perceptible payoff. `.hourly`/`.thirtyDays` and `.daily`/`.all`
    /// are already far below this cap by construction (720 hourly rows at
    /// most, and years of daily rows before this would ever bind), so the
    /// cap is a no-op for those tiers in practice — it exists specifically
    /// for the `.raw` case.
    ///
    /// 360 rather than the "200-500" range's midpoint exactly: it comfortably
    /// exceeds a typical dashboard card's pixel width (so no visible loss of
    /// resolution) while still being a >98% reduction from the worst-case
    /// 28,800-row `.raw` query.
    static let maxPointsPerSeries = 360

    /// Latest live snapshot, for "current value" headlines. `nil` until the
    /// first `ingest(_:)` call.
    @Published private(set) var snapshot: SystemSnapshot?

    /// Queried history per chart metric, already downsampled to
    /// `maxPointsPerSeries`. Only metrics whose module is in
    /// `enabledModules` are populated — a disabled module's key is simply
    /// absent rather than present-but-empty, so `series(for:)` can't
    /// confuse "queried and genuinely empty" with "not requested."
    @Published private(set) var series: [ChartMetric: RangedSamples] = [:]

    /// Which modules' charts to query. Reuses `AppSettings.enabledModules`'s
    /// concept (the same set, not a copy of its logic) rather than
    /// hardcoding "chart everything" — a module the user turned off in
    /// Settings shouldn't reappear in the Dashboard just because history for
    /// it still exists in the database.
    @Published var enabledModules: Set<MetricModule> {
        didSet {
            guard enabledModules != oldValue else { return }
            refresh()
        }
    }

    /// The selected time window. Changing this is the normal way a refresh
    /// happens after the initial one — see the type doc comment.
    @Published var timeRange: TimeRangePicker {
        didSet {
            guard timeRange != oldValue else { return }
            refresh()
        }
    }

    /// Live theme, pushed by `AppDelegate` whenever the user changes it in
    /// Settings — the same value `applySettings` already keeps
    /// `lastAppliedTheme` in sync with for the dropdown. Living here rather
    /// than as a `let` captured once by `DashboardView` matters because
    /// `HistoryWindowController` reuses one `NSHostingController` forever
    /// (`isReleasedWhenClosed = false`): a theme captured at first-`show()`
    /// would freeze for the rest of the app's run, since `DashboardView`'s
    /// `init` only ever runs once. Publishing it through the view model
    /// `DashboardView` already observes makes a theme change reach the
    /// window live, exactly like the dropdown's popover rebuild does for
    /// its own case.
    @Published var theme: Theme

    private let historyStore: HistoryStore

    /// - Parameters:
    ///   - historyStore: shared with `AppDelegate`'s single instance — this
    ///     view model never opens its own database connection.
    ///   - enabledModules: typically `AppSettings.enabledModules` from the
    ///     current settings snapshot.
    ///   - timeRange: initial selection; `.oneDay` is a reasonable default
    ///     landing view (recent enough to be relevant, wide enough to show a
    ///     trend).
    init(
        historyStore: HistoryStore,
        enabledModules: Set<MetricModule> = AppSettings.defaultEnabledModules,
        timeRange: TimeRangePicker = .oneDay,
        theme: Theme = .terminal
    ) {
        self.historyStore = historyStore
        self.enabledModules = enabledModules
        self.timeRange = timeRange
        self.theme = theme
        // Deliberately not calling `refresh()` here: constructing this view
        // model (e.g. as an `AppDelegate` property, alongside every other
        // lazy controller) must stay cheap even though the Dashboard window
        // itself is lazy — see `HistoryWindowController`'s doc comment for
        // why paying a GRDB read cost at app-launch time for a window the
        // user may never open would be wrong. The caller (the Dashboard
        // view, on first appearance) calls `refresh()` explicitly instead.
        // AppDelegate's `dashboardViewModel.ingest` wiring covers the live
        // side; history intentionally starts empty until that happens.
    }

    // MARK: - Live path

    /// Called from `AppDelegate`'s snapshot loop on every tick, same shape
    /// as `DropdownViewModel.ingest`/`DebugDumpViewModel.ingest`. Cheap —
    /// only a struct reference is retained, no history query happens here.
    func ingest(_ snapshot: SystemSnapshot) {
        self.snapshot = snapshot
    }

    // MARK: - History path

    /// Re-queries every enabled module's chart metric for the current
    /// `timeRange` and republishes `series`. Safe to call repeatedly —
    /// there's no incremental/diffing logic here, each call fully replaces
    /// `series` with a fresh read, which keeps this type simple at the cost
    /// of a full re-query on every call. That tradeoff is fine because
    /// callers only invoke it on genuine range/appearance events, never per
    /// tick (see the type doc comment).
    ///
    /// - Parameter now: injectable for tests; defaults to the wall clock.
    func refresh(now: Date = Date()) {
        let (since, tier) = timeRange.queryWindow(now: now)
        var next: [ChartMetric: RangedSamples] = [:]
        for metric in ChartMetric.allCases where enabledModules.contains(metric.module) {
            let raw = historyStore.samplesWithRange(
                metric: metric.metricID.rawValue,
                since: since,
                tier: tier
            )
            next[metric] = Self.downsample(raw, cap: Self.maxPointsPerSeries)
        }
        series = next
    }

    /// `nil` when the metric's module isn't enabled, or `refresh()` hasn't
    /// run yet — same "absent means not requested" contract as `series`
    /// itself, just with the empty-dictionary-lookup boilerplate hidden.
    func series(for metric: ChartMetric) -> RangedSamples? {
        series[metric]
    }

    // MARK: - Downsampling

    /// Reduces `samples` to at most `cap` points by averaging over
    /// contiguous, roughly-equal-sized buckets — not by simple striding
    /// (taking every Nth point). Striding would silently discard a brief
    /// spike that happened to fall on a skipped index (e.g. a 30-second CPU
    /// burst inside a hard-to-visualize 24h/28,800-row raw query); bucket
    /// aggregation instead folds every sample into some bucket's min/max/avg,
    /// so a real spike still shows up in the widened band even after
    /// reduction — just less precisely located in time.
    ///
    /// Each output bucket's `min`/`max` are the true min/max across every
    /// sample the bucket absorbed (so the band never shrinks below what the
    /// data actually contained), `avg` is the unweighted mean of the
    /// bucketed averages, and `timestamp` is the bucket's middle sample's
    /// timestamp — a genuine sample time from the data rather than an
    /// interpolated one.
    ///
    /// No-ops (returns `samples` unchanged) when already at or under `cap`,
    /// or when `cap <= 0` — the latter is a defensive guard against a
    /// misconfigured caller, not an expected call pattern.
    static func downsample(_ samples: RangedSamples, cap: Int) -> RangedSamples {
        guard cap > 0, samples.count > cap else { return samples }

        let bucketSize = Double(samples.count) / Double(cap)
        var result: RangedSamples = []
        result.reserveCapacity(cap)

        var start = 0
        for bucket in 0..<cap {
            // The last bucket absorbs any remainder from integer rounding,
            // so every input sample lands in exactly one bucket and none
            // are silently dropped at the tail.
            let end = bucket == cap - 1
                ? samples.count
                : min(samples.count, Int((Double(bucket + 1) * bucketSize).rounded()))
            guard end > start else { continue }

            let slice = samples[start..<end]
            let lo = slice.map(\.min).min() ?? 0
            let hi = slice.map(\.max).max() ?? 0
            let avg = slice.reduce(0.0) { $0 + $1.avg } / Double(slice.count)
            let mid = slice[slice.index(slice.startIndex, offsetBy: slice.count / 2)]

            result.append((timestamp: mid.timestamp, min: lo, avg: avg, max: hi))
            start = end
        }
        return result
    }
}
