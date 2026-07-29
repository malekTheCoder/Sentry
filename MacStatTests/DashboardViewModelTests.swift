import XCTest
import GRDB
@testable import MacStat
import MacStatKit

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
        // well inside the .oneHour range.
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
            timeRange: .oneHour
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
        // reason, with a wide enough margin (3 days vs. `.oneHour`'s 1h
        // window, `.sevenDays`' 7d window) that normal test execution
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

        let model = DashboardViewModel(historyStore: store, enabledModules: [.cpu], timeRange: .oneHour)
        model.refresh()
        XCTAssertEqual(model.series(for: .cpu)?.count, 0, "3 days ago is outside .oneHour's raw-tier window")

        // Changing timeRange must re-query on its own (didSet), without a
        // second explicit refresh() call from the test.
        model.timeRange = .sevenDays

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

        let model = DashboardViewModel(historyStore: store, enabledModules: [.cpu], timeRange: .oneHour)
        model.refresh()
        XCTAssertNil(model.series(for: .gpu))

        model.enabledModules = [.cpu, .gpu]

        XCTAssertEqual(model.series(for: .gpu)?.count, 1)
    }

    // MARK: - Live theme (regression: theme used to freeze at DashboardView's
    // one-time init, since HistoryWindowController never rebuilds its
    // hosting controller — see DashboardViewModel.theme's doc comment)

    func testThemeDefaultsToTheValuePassedAtInit() {
        let model = DashboardViewModel(historyStore: tempHistoryStore(), theme: .paper)
        XCTAssertEqual(model.theme, .paper)
    }

    func testThemeCanBeReassignedLiveAfterConstruction() {
        let model = DashboardViewModel(historyStore: tempHistoryStore(), theme: .terminal)
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
        let model = DashboardViewModel(historyStore: tempHistoryStore(), enabledModules: [.cpu], timeRange: .oneHour)
        model.timeRange = .oneHour
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
}
