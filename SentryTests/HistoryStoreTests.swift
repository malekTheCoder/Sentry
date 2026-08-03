import XCTest
import GRDB
@testable import SentryKit

/// Covers `HistoryStore.samplesWithRange`, the min/max-band read path added
/// for the Dashboard's detail charts. Nothing exercised this read path
/// before — `samples(metric:since:tier:)` only ever read `avg_value` — so
/// these tests write directly into `sample_hourly`/`sample_daily` (rather
/// than going through `RollupJob`) to isolate "does the read path decode
/// min/max correctly" from "does the rollup job compute them correctly",
/// which is `RollupJobTests`' concern.
final class HistoryStoreTests: XCTestCase {

    private func tempHistoryStore() -> HistoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString).sqlite")
        return HistoryStore(databaseURL: url)
    }

    // MARK: - .hourly / .daily: min/max read back correctly

    func testSamplesWithRangeReadsHourlyMinMax() throws {
        let store = tempHistoryStore()
        let dbQueue = try XCTUnwrap(store.databaseQueue)
        let hourStart: Double = 1_700_000_000

        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sample_hourly (hour_start, metric, min_value, max_value, avg_value, sample_count)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [hourStart, "cpu.total_percent", 10.0, 90.0, 42.5, 12]
            )
        }

        let result = store.samplesWithRange(
            metric: "cpu.total_percent",
            since: Date(timeIntervalSince1970: hourStart - 1),
            tier: .hourly
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].timestamp, Date(timeIntervalSince1970: hourStart))
        XCTAssertEqual(result[0].min, 10.0)
        XCTAssertEqual(result[0].avg, 42.5)
        XCTAssertEqual(result[0].max, 90.0)
    }

    func testSamplesWithRangeReadsDailyMinMax() throws {
        let store = tempHistoryStore()
        let dbQueue = try XCTUnwrap(store.databaseQueue)
        let dayStart: Double = 1_700_000_000

        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sample_daily (day_start, metric, min_value, max_value, avg_value, sample_count)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [dayStart, "battery.charge_percent", 20.0, 100.0, 63.0, 288]
            )
        }

        let result = store.samplesWithRange(
            metric: "battery.charge_percent",
            since: Date(timeIntervalSince1970: dayStart - 1),
            tier: .daily
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].min, 20.0)
        XCTAssertEqual(result[0].avg, 63.0)
        XCTAssertEqual(result[0].max, 100.0)
    }

    func testSamplesWithRangeOrdersAscendingByTime() throws {
        let store = tempHistoryStore()
        let dbQueue = try XCTUnwrap(store.databaseQueue)
        let base: Double = 1_700_000_000

        try dbQueue.write { db in
            for offset in [2, 0, 1] {
                try db.execute(
                    sql: """
                    INSERT INTO sample_hourly (hour_start, metric, min_value, max_value, avg_value, sample_count)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [base + Double(offset) * 3600, "cpu.total_percent", 1.0, 2.0, 1.5, 1]
                )
            }
        }

        let result = store.samplesWithRange(
            metric: "cpu.total_percent",
            since: Date(timeIntervalSince1970: base - 1),
            tier: .hourly
        )

        XCTAssertEqual(result.map(\.timestamp), [0, 1, 2].map { Date(timeIntervalSince1970: base + Double($0) * 3600) })
    }

    // MARK: - .raw: no min/max column, documented zero-width-band behavior

    func testSamplesWithRangeRawTierReturnsZeroWidthBand() {
        // .raw has no min_value/max_value column — each row IS a single
        // reading, so samplesWithRange(tier: .raw) documents (and this test
        // pins) that min == avg == max == the reading itself, rather than
        // throwing or returning some other placeholder.
        let store = tempHistoryStore()
        let snapshot = SystemSnapshot(deviceID: "test", cpu: CPUStats(totalPercent: 55.0))
        store.record(snapshot)
        store.flush()

        let result = store.samplesWithRange(
            metric: "cpu.total_percent",
            since: snapshot.timestamp.addingTimeInterval(-1),
            tier: .raw
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].min, 55.0)
        XCTAssertEqual(result[0].avg, 55.0)
        XCTAssertEqual(result[0].max, 55.0)
    }

    // MARK: - Empty / missing metric

    func testSamplesWithRangeReturnsEmptyForUnknownMetric() {
        let store = tempHistoryStore()
        let result = store.samplesWithRange(metric: "does.not.exist", since: Date.distantPast, tier: .hourly)
        XCTAssertTrue(result.isEmpty)
    }

    func testSamplesWithRangeRespectsSinceLowerBound() throws {
        let store = tempHistoryStore()
        let dbQueue = try XCTUnwrap(store.databaseQueue)
        let hourStart: Double = 1_700_000_000

        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sample_hourly (hour_start, metric, min_value, max_value, avg_value, sample_count)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [hourStart, "cpu.total_percent", 10.0, 90.0, 42.5, 12]
            )
        }

        let result = store.samplesWithRange(
            metric: "cpu.total_percent",
            since: Date(timeIntervalSince1970: hourStart + 1),
            tier: .hourly
        )

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - agent_activity_log (AI-agent-integration pass)

    func testLogAgentActivityRoundTrips() {
        let store = tempHistoryStore()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        store.logAgentActivity(clientName: "Claude Code", tool: "keep_awake", at: at)

        let events = store.agentActivityEvents(since: Date(timeIntervalSince1970: 1_699_999_000))
        XCTAssertEqual(events, [AgentActivityEvent(timestamp: at, clientName: "Claude Code", tool: "keep_awake")])
    }

    func testAgentActivityEventsRespectsSinceLowerBound() {
        let store = tempHistoryStore()
        store.logAgentActivity(clientName: "Claude Code", tool: "keep_awake", at: Date(timeIntervalSince1970: 1_700_000_000))

        let events = store.agentActivityEvents(since: Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertTrue(events.isEmpty)
    }

    func testAgentActivityEventsOrdersAscendingByTime() {
        let store = tempHistoryStore()
        store.logAgentActivity(clientName: "Cursor", tool: "set_refresh_interval", at: Date(timeIntervalSince1970: 1_700_000_100))
        store.logAgentActivity(clientName: "Claude Code", tool: "keep_awake", at: Date(timeIntervalSince1970: 1_700_000_000))

        let events = store.agentActivityEvents(since: Date(timeIntervalSince1970: 1_699_999_000))
        XCTAssertEqual(events.map(\.clientName), ["Claude Code", "Cursor"])
    }
}
