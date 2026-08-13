import Foundation
import SentryKit

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
/// Dashboard panel data for the AI-agent-integration pass (see
/// Sentry-AI-Features-Research.md item #15) — a summary of
/// `HistoryStore.agentActivityEvents` over the currently selected
/// `TimeRangePicker` window. `eventCount == 0` is the honest "no AI agent
/// activity in this range" state, not an error — most users, most of the
/// time, won't have any agent connected at all, and the panel should say so
/// plainly rather than hide itself (plan §3.2 P5).
struct AgentActivitySummary: Equatable {
    var eventCount: Int
    var mostActiveClient: String?
    var distinctToolCount: Int
}

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
    /// only routes `.day` to `.raw` (see its doc comment for why that one
    /// lands under `HistoryStore`'s 48h raw-tier cutoff), but even that
    /// single case — 24h at a 3s cadence — is up to 28,800 raw rows for one
    /// metric. Swift Charts has no trouble laying out that many
    /// `LineMark`s, but there is no visual benefit to a 900pt-wide chart
    /// plotting 28,800 x-positions: at that density, adjacent points are
    /// sub-pixel apart, so every point beyond what the chart can actually
    /// resolve is pure CPU cost (path construction) with zero perceptible
    /// payoff. `.hourly`/`.month` and `.daily`/`.halfYear`
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

    /// The last non-nil battery reading this session. Battery lives on the
    /// slow (30s) tier, so the first fast-tier snapshots after launch carry
    /// no battery at all — rendering "unavailable" during that window is a
    /// lie the hero card used to tell. `nil` only if no battery has ever
    /// been reported this run.
    @Published private(set) var latestBattery: BatteryStats?

    /// When the first snapshot of this session arrived — lets the hero card
    /// distinguish "still warming up" from "this Mac genuinely has no
    /// battery" without hardcoding tier timing knowledge into a view.
    private(set) var firstSnapshotAt: Date?

    /// Queried history per chart metric, already downsampled to
    /// `maxPointsPerSeries`. Only metrics whose module is in
    /// `enabledModules` are populated — a disabled module's key is simply
    /// absent rather than present-but-empty, so `series(for:)` can't
    /// confuse "queried and genuinely empty" with "not requested."
    @Published private(set) var series: [ChartMetric: RangedSamples] = [:]

    /// Per-metric expected spacing between the points in `series`, published
    /// alongside it because only this type knows both halves of the
    /// derivation: the tier `timeRange` picked (and therefore the raw row
    /// cadence) and how many rows `downsample` folded into each output bucket.
    ///
    /// Charts need it to tell "the Mac was asleep" apart from "these two
    /// samples are simply an hour apart because this is a 30-day chart" — see
    /// `ChartScrubbing.expectedCadence(baseInterval:inputCount:outputCount:)`.
    /// Kept as a sibling dictionary rather than folded into `RangedSamples`
    /// because `RangedSamples` is deliberately the exact tuple shape
    /// `HistoryStore.samplesWithRange` returns (see its typealias comment) and
    /// wrapping it here would put a translation step back between the store
    /// and `DashboardChart`.
    @Published private(set) var expectedCadence: [ChartMetric: TimeInterval] = [:]

    /// The exact `(since, now)` span the last `refresh()` queried, for the
    /// charts to pin their x-axis to.
    ///
    /// **Why this is published rather than recomputed in the views.** Every
    /// chart could call `timeRange.queryWindow()` itself, and every one of them
    /// would get a slightly different `now` — a body evaluation is not an
    /// instant, and seven cards each anchoring to their own millisecond means
    /// seven axes that don't line up and, worse, an axis that doesn't line up
    /// with the rows underneath it. The window is a property of the query that
    /// produced `series`, so it is published beside `series` and moves only when
    /// `series` does.
    ///
    /// `nil` until `refresh()` has run — same "absent means not queried yet"
    /// contract as `series` and `expectedCadence`. A chart handed `nil` keeps
    /// Swift Charts' auto-fitted domain, which is the pre-existing behaviour and
    /// the correct one for a chart that has not been told what was asked for.
    @Published private(set) var window: ClosedRange<Date>?

    /// How much of `window` this Mac's history actually covers, folded across
    /// every queried metric — the number the Dashboard header states beside the
    /// range picker.
    ///
    /// One statement for the whole window rather than per card, because "when
    /// does my history start" is a fact about the database, not about whichever
    /// metric a card happens to plot. Per-card coverage still exists and can
    /// legitimately differ (a module enabled last week has a much later first
    /// row); `DashboardChart` derives its own from the samples it was handed.
    @Published private(set) var historyCoverage: HistoryCoverage?

    /// AI-agent-integration pass (see Sentry-AI-Features-Research.md item
    /// #15) — a `HistoryStore.agentActivityEvents` summary for the current
    /// `timeRange`, refreshed alongside `series`. `nil` until `refresh()`
    /// has run at least once, same "absent means not queried yet" contract
    /// as `series`.
    @Published private(set) var agentActivity: AgentActivitySummary?

    /// Per-session grouping of the same activity events `agentActivity`
    /// summarizes — one entry per MCP connection (agent-session attribution
    /// pass, see `AgentSessionReport.sessions`), refreshed alongside it.
    /// Empty until `refresh()` runs, same contract as `anomalies`.
    @Published private(set) var agentSessions: [AgentSessionSummary] = []

    /// Supplies `PowerControlService.awakeHolds` for per-session awake-time
    /// attribution without this view model owning (or importing the
    /// concerns of) the power service itself — `AppDelegate` wires it to the
    /// real service at construction; the default keeps this type
    /// constructible in tests with no power dependency.
    var awakeHoldsProvider: () -> [AgentAwakeHold] = { [] }

    /// Plan §17 Phase 8 — see `AnomalyDetector`. Empty (not nil) until
    /// `refresh()` has run, same "absent means not queried yet vs. queried
    /// and genuinely clean" contract `series`/`agentActivity` already use;
    /// an empty array here means "queried, nothing stood out," which is the
    /// expected common case, not an error state.
    @Published private(set) var anomalies: [MetricAnomaly] = []

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
    /// `MainWindowController` reuses one `NSHostingController` forever
    /// (`isReleasedWhenClosed = false`): a theme captured at first-`show()`
    /// would freeze for the rest of the app's run, since `DashboardView`'s
    /// `init` only ever runs once. Publishing it through the view model
    /// `DashboardView` already observes makes a theme change reach the
    /// window live, exactly like the dropdown's popover rebuild does for
    /// its own case.
    @Published var theme: Theme

    /// Mirrors `AppSettings.detailedCharts`, pushed by `AppDelegate` the
    /// same way `theme` is and for the same reason: the Dashboard's hosting
    /// controller is built once and reused, so it must observe live values,
    /// not capture launch-time ones.
    @Published var detailedCharts: Bool = false

    /// Mirrors `AppSettings.globalRefreshInterval`, pushed by `AppDelegate`
    /// the same way `theme` and `detailedCharts` are and for the same reason.
    /// It is the `.raw` tier's row cadence — the base input to
    /// `expectedCadence` — and a user who changes the refresh interval in
    /// Settings changes what "a gap" means on a 24h chart, so a launch-time
    /// capture would go stale in a window that is never rebuilt.
    @Published var samplingInterval: TimeInterval = 3

    /// Whether this copy is entitled to `ProFeature.historyExport`, pushed
    /// by `AppDelegate` the same way `theme`/`detailedCharts` are and for
    /// the same launch-time seed + `applySettings` reasons — a license
    /// paste or override flip must re-gate the export menu on the next
    /// body evaluation, not after a relaunch of a window that is never
    /// rebuilt. This type never queries entitlement itself (same one-way
    /// flow as `FanControlService.isProUnlocked`), and it defaults locked:
    /// a view model nobody seeded must not offer export.
    @Published var isProUnlocked = false

    /// Whether this copy is entitled to `ProFeature.conditionalKeepAwake`,
    /// pushed by `AppDelegate` exactly like `isProUnlocked` above and read
    /// live by `DashboardView` when it constructs `SleepControlCard`. Its
    /// own flag rather than a reuse of `isProUnlocked` so each mirrored
    /// feature names the `ProFeature` case it answers for — the same
    /// no-ambient-`isPro`-boolean rule `ProFeature`'s doc comment states.
    /// Defaults locked: an unseeded view model withholds rather than leaks.
    @Published var isConditionalKeepAwakeUnlocked = false

    private let historyStore: HistoryStore

    /// Drives periodic re-querying while the Dashboard window is visible —
    /// see `startAutoRefresh()`. `nil` whenever auto-refresh isn't running
    /// (window hidden, or never started), which doubles as the guard
    /// `startAutoRefresh()` uses to avoid stacking a second loop on top of
    /// an existing one.
    private var autoRefreshTask: Task<Void, Never>?

    /// - Parameters:
    ///   - historyStore: shared with `AppDelegate`'s single instance — this
    ///     view model never opens its own database connection.
    ///   - enabledModules: typically `AppSettings.enabledModules` from the
    ///     current settings snapshot.
    ///   - timeRange: initial selection; `.day` is a reasonable default
    ///     landing view (recent enough to be relevant, wide enough to show a
    ///     trend).
    init(
        historyStore: HistoryStore,
        enabledModules: Set<MetricModule> = AppSettings.defaultEnabledModules,
        timeRange: TimeRangePicker = .day,
        theme: Theme = .defaultTheme
    ) {
        self.historyStore = historyStore
        self.enabledModules = enabledModules
        self.timeRange = timeRange
        self.theme = theme
        // Deliberately not calling `refresh()` here: constructing this view
        // model (e.g. as an `AppDelegate` property, alongside every other
        // lazy controller) must stay cheap even though the window itself is
        // lazy — see `MainWindowController`'s doc comment for
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
        if firstSnapshotAt == nil { firstSnapshotAt = Date() }
        if let battery = snapshot.battery { latestBattery = battery }
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
    ///
    /// **Deliberately still synchronous, on the main actor, despite being
    /// the known window-open hitch and per-tap lag:** `HistoryStore`'s
    /// `dbQueue.read` calls are individually thread-safe (GRDB's
    /// `DatabaseQueue` serializes its own access internally, and
    /// `HistoryStore` is `@unchecked Sendable` on that basis), so moving the
    /// 13 queries below onto a background `Task` is possible in isolation.
    /// What isn't clean is the rest of what this method does with the
    /// results: every one of `series`/`expectedCadence`/`agentActivity`/
    /// `agentSessions`/`anomalies` gets fully replaced in one pass, read by
    /// `timeRange`'s `didSet` (itself synchronous) and now by
    /// `startAutoRefresh()`'s loop above — an async `refresh()` would let a
    /// slow query for a range the user has since tapped away from resolve
    /// *after* a newer, faster one and clobber it with stale data, exactly
    /// the bug this task is fixing at the window-freshness level. Avoiding
    /// that needs a generation counter or task-cancellation scheme around
    /// every call site, plus rewriting every test below from the
    /// call-then-assert shape they all currently use (`refresh(); assert on
    /// series`) into an async/expectation shape — a real refactor, not a
    /// clean lift, and out of scope for what this task asked for. Left
    /// synchronous; the auto-refresh cadence in `TimeRangePicker
    /// .autoRefreshInterval` is deliberately conservative (30s–15min, never
    /// per-tick) partly *because* each call still pays this full cost.
    func refresh(now: Date = Date()) {
        let (since, tier) = timeRange.queryWindow(now: now)
        let rowInterval = timeRange.expectedRowInterval(samplingInterval: samplingInterval)
        var next: [ChartMetric: RangedSamples] = [:]
        var nextCadence: [ChartMetric: TimeInterval] = [:]
        var coverages: [HistoryCoverage] = []
        // `since...now`, not a fresh `Date()` per chart — see `window`'s doc
        // comment. `queryWindow` only ever subtracts from `now`, so the range is
        // well-formed by construction.
        let queried = since...now
        for metric in ChartMetric.allCases where enabledModules.contains(metric.module) {
            let raw = historyStore.samplesWithRange(
                metric: metric.metricID.rawValue,
                since: since,
                tier: tier
            )
            let reduced = Self.downsample(raw, cap: Self.maxPointsPerSeries)
            next[metric] = reduced
            let cadence = ChartScrubbing.expectedCadence(
                baseInterval: rowInterval,
                inputCount: raw.count,
                outputCount: reduced.count
            )
            nextCadence[metric] = cadence
            // Built from `raw`, not `reduced`: `downsample` stamps each bucket
            // with its *middle* sample's timestamp, so the reduced series' first
            // point sits up to half a bucket after the first row that actually
            // exists. Coverage is a claim about when recording began, and that
            // is a question for the rows, not for the plotting compromise.
            coverages.append(
                HistoryCoverage(
                    requested: queried,
                    timestamps: raw.map(\.timestamp),
                    resolution: cadence
                )
            )
        }
        series = next
        expectedCadence = nextCadence
        window = queried
        // A window with no enabled modules still has a truthful answer
        // ("nothing recorded"), and the header should say it rather than go
        // blank — an absent caption reads as "everything is fine".
        historyCoverage = HistoryCoverage.combining(coverages)
            ?? HistoryCoverage(requested: queried, earliest: nil, latest: nil, resolution: rowInterval)
        let agentEvents = historyStore.agentActivityEvents(since: since)
        agentActivity = Self.summarize(agentEvents)
        agentSessions = AgentSessionReport.sessions(from: agentEvents, awakeHolds: awakeHoldsProvider(), now: now)
        anomalies = refreshAnomalies(now: now)
    }

    // MARK: - Auto-refresh while the window is open

    /// Keeps `series`/`agentActivity`/`anomalies` live while the Dashboard
    /// window is on screen, by calling `refresh()` on a loop cadenced to the
    /// current `timeRange` (see `TimeRangePicker.autoRefreshInterval`).
    ///
    /// **Why this exists:** before this, `refresh()` only ran once per
    /// window show (`AppDelegate`'s `onShow`) and once more on
    /// `didSet`/first appearance — everything below the header's own live
    /// 10s `TimelineView` was a frozen snapshot from whenever the window
    /// opened. Leave the window open across an hour and the charts silently
    /// stop matching reality while the header's "updated Ns ago" caption
    /// keeps implying they're live.
    ///
    /// **Why a `Task` loop instead of a second `TimelineView`:** this type
    /// has no view of its own to attach one to — `DashboardView`'s header
    /// already owns the one `TimelineView` this window has, purely to age
    /// its caption text (see that view's doc comment), and duplicating that
    /// machinery here just to call a side-effecting method on a timer would
    /// mean two different mechanisms driving "is this window still alive"
    /// for no benefit. A plain cancellable `Task` sleeping in a loop is the
    /// same idiom `InsightsViewModel` already uses for its own
    /// window-scoped background work (see `cancelRefresh`'s doc comment) —
    /// following that precedent instead of inventing a second one.
    ///
    /// **Lifecycle — tied to window visibility, not a fire-and-forget
    /// timer:** `AppDelegate`'s `MainWindowController.onShow`/`onHide` are
    /// the single existing place window visibility already gates work
    /// (`ProcessMonitor.start`/`stop` uses the same hooks) — this just adds
    /// `startAutoRefresh()`/`stopAutoRefresh()` calls alongside the existing
    /// `refresh()`/`processMonitor.stop()` calls there, rather than starting
    /// a `Timer` at construction time that would run for the app's entire
    /// life whether or not the window is even open.
    ///
    /// Cancels and restarts idempotently: calling this while a loop is
    /// already running (e.g. a redundant `onShow`) replaces it rather than
    /// stacking a second one, so there's never more than one outstanding
    /// sleep at a time.
    func startAutoRefresh() {
        stopAutoRefresh()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Re-read `timeRange` on every iteration, not just at loop
                // start — the interval must follow the *current* selection.
                // Without this, switching from `.day` (30s cadence) to
                // `.halfYear` mid-loop would keep polling every 30s until
                // the in-flight sleep happens to finish, undermining the
                // whole point of a range-dependent cadence.
                let interval = self.timeRange.autoRefreshInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                self.refresh()
            }
        }
    }

    /// Stops the loop `startAutoRefresh()` started, if any. Safe to call
    /// when no loop is running (e.g. `onHide` firing for a window that was
    /// never shown) — `Task.cancel()` on `nil` is simply a no-op via the
    /// optional chain.
    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    /// Plan §17 Phase 8: "anomaly detection / baselining." Independent of
    /// `timeRange` — a baseline is always the trailing `baselineWindowDays`
    /// full days, not whatever range the charts above happen to be showing
    /// (same "this card manages its own query, not the picker's" reasoning
    /// `BatteryHealthTrendCard` gives for its own all-time query).
    private static let baselineWindowDays = 14

    private func refreshAnomalies(now: Date) -> [MetricAnomaly] {
        guard let snapshot else { return [] }

        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let since = calendar.date(byAdding: .day, value: -Self.baselineWindowDays, to: now) ?? now.addingTimeInterval(-Double(Self.baselineWindowDays) * 86400)

        var baselines: [MetricID: AnomalyDetector.Baseline] = [:]
        var currentValues: [MetricID: Double] = [:]
        for metricID in AnomalyDetector.candidateMetrics {
            // Excludes today's (partial) day — comparing a still-accumulating
            // day's rollup against itself would be circular, not a baseline.
            let dailyValues = historyStore.samples(metric: metricID.rawValue, since: since, tier: .daily)
                .filter { $0.timestamp < todayStart }
                .map(\.value)
            if !dailyValues.isEmpty {
                baselines[metricID] = AnomalyDetector.Baseline(
                    averageValue: dailyValues.reduce(0, +) / Double(dailyValues.count),
                    sampleDayCount: dailyValues.count
                )
            }
            if let value = snapshot.value(for: metricID) {
                currentValues[metricID] = value
            }
        }

        return AnomalyDetector.detect(currentValues: currentValues, baselines: baselines)
    }

    /// Pure so it's independently testable without a real `HistoryStore` —
    /// same reasoning as `downsample` below.
    static func summarize(_ events: [AgentActivityEvent]) -> AgentActivitySummary {
        var countByClient: [String: Int] = [:]
        var countByTool: [String: Int] = [:]
        for event in events {
            countByClient[event.clientName, default: 0] += 1
            countByTool[event.tool, default: 0] += 1
        }
        return AgentActivitySummary(
            eventCount: events.count,
            mostActiveClient: countByClient.max(by: { $0.value < $1.value })?.key,
            distinctToolCount: countByTool.count
        )
    }

    /// `nil` when the metric's module isn't enabled, or `refresh()` hasn't
    /// run yet — same "absent means not requested" contract as `series`
    /// itself, just with the empty-dictionary-lookup boilerplate hidden.
    func series(for metric: ChartMetric) -> RangedSamples? {
        series[metric]
    }

    /// Companion to `series(for:)` with the same "absent means not requested"
    /// contract. A chart handed `nil` falls back to the observed median
    /// spacing of its own points (see
    /// `ChartScrubbing.effectiveCadence(expected:timestamps:)`).
    func cadence(for metric: ChartMetric) -> TimeInterval? {
        expectedCadence[metric]
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
