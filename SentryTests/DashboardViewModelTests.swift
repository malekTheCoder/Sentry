import XCTest
import GRDB
@testable import Sentry
import SentryKit

/// Covers `DashboardViewModel`'s two independent data paths — `ingest(_:)`
/// (live headline data) and `refresh()` (queried history) — plus the pure
/// `downsample(_:cap:)` bucketing logic. Uses a real, temp-file-backed
/// `HistoryStore` rather than a mock, the same convention
/// `HistoryStoreTests`/`AlertEngineTests` already use — this is a thin
/// wrapper around GRDB reads, so a fake store would just be re-describing
/// the real one's behavior instead of exercising it.
@MainActor
final class DashboardViewModelTests: XCTestCase {

    private func tempHistoryStore() -> HistoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DashboardViewModelTests-\(UUID().uuidString).sqlite")
        return HistoryStore(databaseURL: url)
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - ingest (live path)

    func testIngestPublishesTheLatestSnapshotWithoutTouchingSeries() {
        let model = DashboardViewModel(historyStore: tempHistoryStore())
        XCTAssertNil(model.snapshot)

        let snapshot = SystemSnapshot(deviceID: "test", cpu: CPUStats(totalPercent: 55))
        model.ingest(snapshot)

        XCTAssertEqual(model.snapshot?.deviceID, "test")
        // `ingest` must never trigger a history query — see the type doc
        // comment ("never called from ingest, must never be").
        XCTAssertTrue(model.series.isEmpty)
    }

    // MARK: - refresh (history path)

    func testRefreshOnlyQueriesEnabledModules() throws {
        let store = tempHistoryStore()
        let dbQueue = try XCTUnwrap(store.databaseQueue)
        // One raw row each for CPU (enabled) and GPU (not enabled), both
        // well inside the .day range.
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO sample_raw (ts, metric, value) VALUES (?, ?, ?)",
                arguments: [now.timeIntervalSince1970 - 60, "cpu.total_percent", 33.0]
            )
            try db.execute(
                sql: "INSERT INTO sample_raw (ts, metric, value) VALUES (?, ?, ?)",
                arguments: [now.timeIntervalSince1970 - 60, "gpu.utilization_percent", 77.0]
            )
        }

        let model = DashboardViewModel(
            historyStore: store,
            enabledModules: [.cpu],
            timeRange: .day
        )
        model.refresh(now: now)

        let cpuSeries = try XCTUnwrap(model.series(for: .cpu))
        XCTAssertEqual(cpuSeries.count, 1)
        XCTAssertEqual(cpuSeries[0].avg, 33.0)

        // GPU's module isn't enabled — absent, not present-but-empty.
        XCTAssertNil(model.series(for: .gpu))
    }

    func testChangingTimeRangeTriggersAnAutomaticRefresh() throws {
        // Unlike the other tests, this one can't pin `now` — the automatic
        // refresh a `didSet` fires below has no way to receive the test's
        // injected clock (that's a one-off `refresh(now:)` parameter, not a
        // stored dependency), so it always queries against the real wall
        // clock. The data is seeded relative to `Date()` for the same
        // reason, with a wide enough margin (3 days vs. `.day`'s 24h
        // window, `.week`'s 7d window) that normal test execution
        // latency can't flip either assertion.
        let wallClockNow = Date()
        let store = tempHistoryStore()
        let dbQueue = try XCTUnwrap(store.databaseQueue)
        let hourStart = wallClockNow.timeIntervalSince1970 - 3 * 86400
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sample_hourly (hour_start, metric, min_value, max_value, avg_value, sample_count)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [hourStart, "cpu.total_percent", 10.0, 50.0, 30.0, 12]
            )
        }

        let model = DashboardViewModel(historyStore: store, enabledModules: [.cpu], timeRange: .day)
        model.refresh()
        XCTAssertEqual(model.series(for: .cpu)?.count, 0, "3 days ago is outside .day's raw-tier window")

        // Changing timeRange must re-query on its own (didSet), without a
        // second explicit refresh() call from the test.
        model.timeRange = .week

        let cpuSeries = try XCTUnwrap(model.series(for: .cpu))
        XCTAssertEqual(cpuSeries.count, 1)
        XCTAssertEqual(cpuSeries[0].avg, 30.0)
    }

    func testChangingEnabledModulesTriggersAnAutomaticRefresh() throws {
        // Same "can't pin `now`" reasoning as
        // `testChangingTimeRangeTriggersAnAutomaticRefresh` above — the
        // automatic refresh triggered by the `enabledModules` assignment
        // below always uses the real wall clock.
        let wallClockNow = Date()
        let store = tempHistoryStore()
        let dbQueue = try XCTUnwrap(store.databaseQueue)
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO sample_raw (ts, metric, value) VALUES (?, ?, ?)",
                arguments: [wallClockNow.timeIntervalSince1970 - 60, "gpu.utilization_percent", 77.0]
            )
        }

        let model = DashboardViewModel(historyStore: store, enabledModules: [.cpu], timeRange: .day)
        model.refresh()
        XCTAssertNil(model.series(for: .gpu))

        model.enabledModules = [.cpu, .gpu]

        XCTAssertEqual(model.series(for: .gpu)?.count, 1)
    }

    // MARK: - Window and coverage (range-honesty pass)
    //
    // The pure arithmetic is covered by `HistoryCoverageTests`; what these pin
    // is the *wiring* — that the span the charts pin their x-axis to is the same
    // span the query used, and that the coverage the header states is derived
    // from rows that actually came back rather than from the picker's label.

    func testRefreshPublishesTheExactWindowItQueried() throws {
        let model = DashboardViewModel(historyStore: tempHistoryStore(), enabledModules: [.cpu], timeRange: .quarter)
        XCTAssertNil(model.window, "no query has run yet, so there is no window to pin a chart to")

        model.refresh(now: now)

        let window = try XCTUnwrap(model.window)
        // Byte-for-byte the picker's own `(since, now)` pair. If these ever
        // drift, every chart on the window is drawn against a domain that
        // doesn't match the rows on it — the failure mode is silent and looks
        // exactly like correct output.
        XCTAssertEqual(window.lowerBound, TimeRangePicker.quarter.queryWindow(now: now).since)
        XCTAssertEqual(window.upperBound, now)
    }

    func testCoverageReportsAShortHistoryAgainstALongWindow() throws {
        // The headline scenario, end to end: three days of rows, "90d"
        // selected. Before this pass the chart auto-fitted those three days
        // across the full plot width and nothing anywhere said otherwise.
        let store = tempHistoryStore()
        let dbQueue = try XCTUnwrap(store.databaseQueue)
        try dbQueue.write { db in
            for hoursAgo in stride(from: 72, through: 0, by: -1) {
                try db.execute(
                    sql: """
                    INSERT INTO sample_hourly (hour_start, metric, min_value, max_value, avg_value, sample_count)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        now.timeIntervalSince1970 - Double(hoursAgo) * 3600,
                        "cpu.total_percent", 10.0, 30.0, 20.0, 1,
                    ]
                )
            }
        }

        let model = DashboardViewModel(historyStore: store, enabledModules: [.cpu], timeRange: .quarter)
        model.refresh(now: now)

        let coverage = try XCTUnwrap(model.historyCoverage)
        XCTAssertFalse(coverage.isComplete)
        XCTAssertEqual(coverage.label, "3 of 90 days recorded")
        XCTAssertEqual(coverage.unrecordedLead?.lowerBound, try XCTUnwrap(model.window).lowerBound)
        XCTAssertNil(coverage.unrecordedTail, "rows run right up to now")
    }

    func testCoverageIsCompleteWhenTheRowsSpanTheWholeWindow() throws {
        let store = tempHistoryStore()
        let dbQueue = try XCTUnwrap(store.databaseQueue)
        try dbQueue.write { db in
            for hoursAgo in [24, 12, 0] {
                try db.execute(
                    sql: "INSERT INTO sample_raw (ts, metric, value) VALUES (?, ?, ?)",
                    arguments: [now.timeIntervalSince1970 - Double(hoursAgo) * 3600, "cpu.total_percent", 42.0]
                )
            }
        }

        let model = DashboardViewModel(historyStore: store, enabledModules: [.cpu], timeRange: .day)
        model.refresh(now: now)

        let coverage = try XCTUnwrap(model.historyCoverage)
        XCTAssertTrue(coverage.isComplete)
        XCTAssertEqual(coverage.label, "24 hours recorded")
        // Complete windows drop the start date — see `HistoryCoverage.summary`.
        XCTAssertEqual(coverage.summary, "24 hours recorded")
    }

    func testCoverageWithNoRowsAtAllStillDescribesTheWindow() throws {
        // An empty database must not produce a *silent* header: an absent
        // caption reads as "everything is fine".
        let model = DashboardViewModel(historyStore: tempHistoryStore(), enabledModules: [.cpu], timeRange: .week)
        model.refresh(now: now)

        let coverage = try XCTUnwrap(model.historyCoverage)
        XCTAssertEqual(coverage.label, "nothing recorded in the last 7 days")
        XCTAssertEqual(coverage.unrecordedLead, model.window)
    }

    func testCoverageExistsEvenWithEveryModuleDisabled() throws {
        let model = DashboardViewModel(historyStore: tempHistoryStore(), enabledModules: [], timeRange: .month)
        model.refresh(now: now)
        XCTAssertNotNil(model.historyCoverage)
        XCTAssertNotNil(model.window)
    }

    // MARK: - Live theme (regression: theme used to freeze at DashboardView's
    // one-time init, since HistoryWindowController never rebuilds its
    // hosting controller — see DashboardViewModel.theme's doc comment)

    func testThemeDefaultsToTheValuePassedAtInit() {
        let model = DashboardViewModel(historyStore: tempHistoryStore(), theme: .paper)
        XCTAssertEqual(model.theme, .paper)
    }

    func testThemeCanBeReassignedLiveAfterConstruction() {
        let model = DashboardViewModel(historyStore: tempHistoryStore(), theme: .slate)
        model.theme = .paper
        XCTAssertEqual(model.theme, .paper)
    }

    func testAssigningTheSameValuesDoesNotForceAnExtraRefresh() {
        // Not directly observable from outside (refresh has no side effect
        // to spy on besides `series`), but assigning an equal Set/enum value
        // must not crash or behave differently — this pins the `didSet`
        // guard's `guard ... != oldValue else { return }` short-circuit
        // exists at all, protecting against a future edit that drops it and
        // silently reintroduces a query-per-assignment cost.
        let model = DashboardViewModel(historyStore: tempHistoryStore(), enabledModules: [.cpu], timeRange: .day)
        model.timeRange = .day
        model.enabledModules = [.cpu]
        XCTAssertTrue(model.series.isEmpty, "no refresh() was ever called explicitly, so series should still be empty")
    }

    // MARK: - Downsampling

    func testDownsampleIsANoOpUnderTheCap() {
        let samples = makeSamples(count: 10)
        let result = DashboardViewModel.downsample(samples, cap: 360)
        XCTAssertEqual(result.count, 10)
    }

    func testDownsampleReducesToExactlyTheCap() {
        let samples = makeSamples(count: 10_000)
        let result = DashboardViewModel.downsample(samples, cap: 360)
        XCTAssertEqual(result.count, 360)
    }

    func testDownsamplePreservesTrueMinAndMaxAcrossEachBucket() {
        // A single spike inside an otherwise-flat series must still show up
        // in the reduced band's max, even though it isn't its own point
        // anymore — this is the whole reason bucket-min/max was chosen over
        // plain striding (see the method's doc comment).
        var samples = makeSamples(count: 1000, min: 0, avg: 0, max: 0)
        samples[500] = (timestamp: samples[500].timestamp, min: 0, avg: 99, max: 99)

        let result = DashboardViewModel.downsample(samples, cap: 100)

        XCTAssertEqual(result.count, 100)
        XCTAssertTrue(result.contains { $0.max == 99 }, "the spike's max must survive into some bucket")
    }

    func testDownsampleKeepsChronologicalOrder() {
        let samples = makeSamples(count: 5000)
        let result = DashboardViewModel.downsample(samples, cap: 200)
        let timestamps = result.map(\.timestamp)
        XCTAssertEqual(timestamps, timestamps.sorted())
    }

    func testDownsampleWithZeroCapReturnsInputUnchanged() {
        let samples = makeSamples(count: 10)
        let result = DashboardViewModel.downsample(samples, cap: 0)
        XCTAssertEqual(result.count, 10)
    }

    private func makeSamples(
        count: Int,
        min: Double = 0,
        avg: Double = 0,
        max: Double = 0
    ) -> DashboardViewModel.RangedSamples {
        (0..<count).map { i in
            (timestamp: now.addingTimeInterval(Double(i)), min: min, avg: avg, max: max)
        }
    }

    // MARK: - summarize (AI-agent-integration pass)

    func testSummarizeEmptyEventsReturnsZeroCount() {
        let summary = DashboardViewModel.summarize([])
        XCTAssertEqual(summary.eventCount, 0)
        XCTAssertNil(summary.mostActiveClient)
        XCTAssertEqual(summary.distinctToolCount, 0)
    }

    func testSummarizeCountsAndFindsMostActiveClient() {
        let events = [
            AgentActivityEvent(timestamp: now, clientName: "Claude Code", tool: "keep_awake"),
            AgentActivityEvent(timestamp: now, clientName: "Claude Code", tool: "keep_awake"),
            AgentActivityEvent(timestamp: now, clientName: "Cursor", tool: "set_refresh_interval")
        ]
        let summary = DashboardViewModel.summarize(events)
        XCTAssertEqual(summary.eventCount, 3)
        XCTAssertEqual(summary.mostActiveClient, "Claude Code")
        XCTAssertEqual(summary.distinctToolCount, 2)
    }

    func testRefreshPopulatesAgentActivityFromHistoryStore() {
        let store = tempHistoryStore()
        store.logAgentActivity(clientName: "Claude Code", tool: "keep_awake", at: now)
        let viewModel = DashboardViewModel(historyStore: store, timeRange: .day)

        viewModel.refresh(now: now.addingTimeInterval(60))

        XCTAssertEqual(viewModel.agentActivity?.eventCount, 1)
        XCTAssertEqual(viewModel.agentActivity?.mostActiveClient, "Claude Code")
    }

    // MARK: - refreshAnomalies (AI-agent-integration / Phase 8 pass)

    func testRefreshFlagsAnAnomalyAgainstDailyBaseline() throws {
        let store = tempHistoryStore()
        let dbQueue = try XCTUnwrap(store.databaseQueue)
        // 7 days of "normal" CPU around 40%, oldest first, all strictly
        // before `now`'s calendar day so they count as baseline history.
        for daysAgo in 1...7 {
            let dayStart = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Calendar.current.startOfDay(for: now))!
            try dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO sample_daily (day_start, metric, min_value, max_value, avg_value, sample_count) VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [dayStart.timeIntervalSince1970, "cpu.total_percent", 30, 50, 40, 100]
                )
            }
        }

        let viewModel = DashboardViewModel(historyStore: store, timeRange: .day)
        // A live snapshot with CPU way above the 40% baseline.
        viewModel.ingest(SystemSnapshot(deviceID: "test", cpu: CPUStats(totalPercent: 90)))
        viewModel.refresh(now: now)

        XCTAssertTrue(viewModel.anomalies.contains { $0.metricID == .cpuTotalPercent })
    }

    func testRefreshReportsNoAnomaliesWithoutBaselineHistory() {
        let store = tempHistoryStore()
        let viewModel = DashboardViewModel(historyStore: store, timeRange: .day)
        viewModel.ingest(SystemSnapshot(deviceID: "test", cpu: CPUStats(totalPercent: 95)))

        viewModel.refresh(now: now)

        XCTAssertTrue(viewModel.anomalies.isEmpty, "no daily history yet means no trustworthy baseline")
    }
}
