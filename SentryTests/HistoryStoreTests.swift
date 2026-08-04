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

    // MARK: - agent_activity_log v5 columns (agent-session attribution pass)

    func testLogAgentActivityFullSessionRowRoundTrips() {
        let store = tempHistoryStore()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionID = UUID().uuidString
        store.logAgentActivity(
            clientName: "Claude Code",
            sessionID: sessionID,
            tool: "keep_awake",
            argsSummary: "mode=system_only, durationSeconds=600",
            durationMs: 42,
            outcome: .succeeded,
            at: at
        )

        let events = store.agentActivityEvents(since: Date(timeIntervalSince1970: 1_699_999_000))
        XCTAssertEqual(events, [
            AgentActivityEvent(
                timestamp: at,
                clientName: "Claude Code",
                tool: "keep_awake",
                sessionID: sessionID,
                durationMs: 42,
                argsSummary: "mode=system_only, durationSeconds=600",
                outcome: .succeeded
            )
        ])
    }

    func testDeniedAndRateLimitedOutcomesRoundTrip() {
        // Unlike the pre-v5 log, refused calls are recorded too — `outcome`
        // is what separates "did X" from "asked for X and was refused."
        let store = tempHistoryStore()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        store.logAgentActivity(clientName: "Cursor", sessionID: "s1", tool: "keep_awake", argsSummary: nil, durationMs: nil, outcome: .denied, at: at)
        store.logAgentActivity(clientName: "Cursor", sessionID: "s1", tool: "get_system_snapshot", argsSummary: nil, durationMs: 3, outcome: .rateLimited, at: at.addingTimeInterval(1))
        store.logAgentActivity(clientName: "Cursor", sessionID: "s1", tool: "get_battery_status", argsSummary: nil, durationMs: 7, outcome: .errored, at: at.addingTimeInterval(2))

        let events = store.agentActivityEvents(since: at.addingTimeInterval(-1))
        XCTAssertEqual(events.map(\.outcome), [.denied, .rateLimited, .errored])
        XCTAssertNil(events[0].durationMs)
        XCTAssertEqual(events[1].durationMs, 3)
    }

    func testLegacyOverloadWritesMigrationBackfillDefaults() {
        // The pre-v5 overload must keep compiling AND produce rows
        // indistinguishable from what the v5 migration backfills for old
        // rows: unknown ("") session, no duration/summary, succeeded.
        let store = tempHistoryStore()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        store.logAgentActivity(clientName: "Claude Code", tool: "release_awake", at: at)

        let events = store.agentActivityEvents(since: at.addingTimeInterval(-1))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].sessionID, "")
        XCTAssertNil(events[0].durationMs)
        XCTAssertNil(events[0].argsSummary)
        XCTAssertEqual(events[0].outcome, .succeeded)
    }

    func testV5MigrationUpgradesAV3EraDatabaseInPlace() throws {
        // Round-trip across the actual migration boundary: write a
        // three-column row the way v3-era code did (raw SQL, no v5 columns),
        // then confirm the widened read path decodes it with the backfill
        // defaults rather than dropping it.
        let store = tempHistoryStore()
        let dbQueue = try XCTUnwrap(store.databaseQueue)
        let at: Double = 1_700_000_000

        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO agent_activity_log (ts, client_name, tool) VALUES (?, ?, ?)",
                arguments: [at, "Old Client", "keep_awake"]
            )
        }

        let events = store.agentActivityEvents(since: Date(timeIntervalSince1970: at - 1))
        XCTAssertEqual(events, [
            AgentActivityEvent(timestamp: Date(timeIntervalSince1970: at), clientName: "Old Client", tool: "keep_awake")
        ])
    }

    func testAgentActivityEventsToleratesUnknownOutcomeString() throws {
        // A future migration (or hand-edited database) writing an outcome
        // this build doesn't know must degrade to the backfill default, not
        // silently shrink history by dropping the row.
        let store = tempHistoryStore()
        let dbQueue = try XCTUnwrap(store.databaseQueue)
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO agent_activity_log (ts, client_name, tool, session_id, outcome) VALUES (?, ?, ?, ?, ?)",
                arguments: [1_700_000_000, "Future Client", "keep_awake", "s9", "partially_applied"]
            )
        }

        let events = store.agentActivityEvents(since: Date(timeIntervalSince1970: 1_699_999_999))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].outcome, .succeeded)
        XCTAssertEqual(events[0].sessionID, "s9")
    }

    // MARK: - recentAlertFirings filters (get_alert_history, verified-bug pass)

    func testRecentAlertFiringsWithNoFiltersReturnsEverything() {
        let store = tempHistoryStore()
        let ruleA = UUID()
        let ruleB = UUID()
        store.logAlertFiring(ruleID: ruleA, ruleName: "A", metric: "m", value: 1, at: Date(timeIntervalSince1970: 100), delivered: true, suppressed: false)
        store.logAlertFiring(ruleID: ruleB, ruleName: "B", metric: "m", value: 2, at: Date(timeIntervalSince1970: 200), delivered: true, suppressed: false)

        let entries = store.recentAlertFirings()
        XCTAssertEqual(entries.count, 2, "the default call, with no filters, must behave exactly as it did before `since`/`ruleID` existed")
    }

    func testRecentAlertFiringsSinceFiltersOutOlderRows() {
        let store = tempHistoryStore()
        let ruleID = UUID()
        store.logAlertFiring(ruleID: ruleID, ruleName: "Old", metric: "m", value: 1, at: Date(timeIntervalSince1970: 100), delivered: true, suppressed: false)
        store.logAlertFiring(ruleID: ruleID, ruleName: "New", metric: "m", value: 2, at: Date(timeIntervalSince1970: 300), delivered: true, suppressed: false)

        let entries = store.recentAlertFirings(since: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.ruleName, "New")
    }

    func testRecentAlertFiringsRuleIDFiltersToOneRule() {
        let store = tempHistoryStore()
        let ruleA = UUID()
        let ruleB = UUID()
        store.logAlertFiring(ruleID: ruleA, ruleName: "A", metric: "m", value: 1, at: Date(timeIntervalSince1970: 100), delivered: true, suppressed: false)
        store.logAlertFiring(ruleID: ruleB, ruleName: "B", metric: "m", value: 2, at: Date(timeIntervalSince1970: 200), delivered: true, suppressed: false)

        let entries = store.recentAlertFirings(ruleID: ruleA)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.ruleID, ruleA)
    }

    func testRecentAlertFiringsCombinesSinceAndRuleIDFilters() {
        let store = tempHistoryStore()
        let ruleID = UUID()
        let otherRuleID = UUID()
        store.logAlertFiring(ruleID: ruleID, ruleName: "Too old", metric: "m", value: 1, at: Date(timeIntervalSince1970: 100), delivered: true, suppressed: false)
        store.logAlertFiring(ruleID: ruleID, ruleName: "Right rule, recent", metric: "m", value: 2, at: Date(timeIntervalSince1970: 300), delivered: true, suppressed: false)
        store.logAlertFiring(ruleID: otherRuleID, ruleName: "Wrong rule, recent", metric: "m", value: 3, at: Date(timeIntervalSince1970: 300), delivered: true, suppressed: false)

        let entries = store.recentAlertFirings(since: Date(timeIntervalSince1970: 200), ruleID: ruleID)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.ruleName, "Right rule, recent")
    }

    // MARK: - Write-amplification fix: shouldWrite decision logic

    /// `shouldWrite(metric:value:ts:)` is the pure decision `record(_:)`
    /// filters every metric pair through. These exercise it directly (no
    /// database, no snapshot) against fabricated in-memory scenarios — see
    /// `HistoryStore.shouldWrite`'s doc comment for the "changed OR heartbeat
    /// due" rule this pins.
    func testShouldWriteFirstSampleForAMetricAlwaysWrites() {
        let store = tempHistoryStore()
        XCTAssertTrue(store.shouldWrite(metric: "cpu.total_percent", value: 12.0, ts: 1_700_000_000))
    }

    func testShouldWriteSameValueWithinHeartbeatWindowSkips() {
        let store = tempHistoryStore()
        XCTAssertTrue(store.shouldWrite(metric: "thermal.is_throttling", value: 0.0, ts: 1_700_000_000))
        // 59s later, same value: still inside the 60s heartbeat window.
        XCTAssertFalse(store.shouldWrite(metric: "thermal.is_throttling", value: 0.0, ts: 1_700_000_059))
    }

    func testShouldWriteSameValuePastHeartbeatWindowWrites() {
        let store = tempHistoryStore()
        XCTAssertTrue(store.shouldWrite(metric: "thermal.is_throttling", value: 0.0, ts: 1_700_000_000))
        // Exactly 60s later, same value: heartbeat is due.
        XCTAssertTrue(store.shouldWrite(metric: "thermal.is_throttling", value: 0.0, ts: 1_700_000_060))
    }

    func testShouldWriteChangedValueAlwaysWritesEvenSecondsLater() {
        let store = tempHistoryStore()
        XCTAssertTrue(store.shouldWrite(metric: "cpu.total_percent", value: 12.0, ts: 1_700_000_000))
        // 1s later but the value moved: write regardless of the heartbeat.
        XCTAssertTrue(store.shouldWrite(metric: "cpu.total_percent", value: 13.0, ts: 1_700_000_001))
    }

    func testShouldWriteToleratesFloatingPointNoiseAsUnchanged() {
        // A value that moved by less than `changeEpsilon` (1e-6) is treated
        // as the same reading, not a real change — see the doc comment on
        // `HistoryStore.changeEpsilon` for why this is needed even though
        // most repeated-tier writes are exact bit-for-bit copies.
        let store = tempHistoryStore()
        XCTAssertTrue(store.shouldWrite(metric: "cpu.total_percent", value: 42.123456, ts: 1_700_000_000))
        XCTAssertFalse(store.shouldWrite(metric: "cpu.total_percent", value: 42.1234561, ts: 1_700_000_001))
    }

    func testShouldWriteTracksEachMetricIndependently() {
        // One metric heartbeating due doesn't affect another metric's own
        // independent last-written state.
        let store = tempHistoryStore()
        XCTAssertTrue(store.shouldWrite(metric: "cpu.total_percent", value: 10.0, ts: 1_700_000_000))
        XCTAssertTrue(store.shouldWrite(metric: "memory.used_bytes", value: 999.0, ts: 1_700_000_000))
        XCTAssertFalse(store.shouldWrite(metric: "cpu.total_percent", value: 10.0, ts: 1_700_000_010))
        XCTAssertFalse(store.shouldWrite(metric: "memory.used_bytes", value: 999.0, ts: 1_700_000_010))
    }

    // MARK: - Write-amplification fix: integration, real row counts via record(_:)

    /// A flat metric (thermal, unchanging across 10 fast-tier-style ticks 3s
    /// apart) should land far fewer than 10 rows — proof the dedup actually
    /// reduces what hits `sample_raw`, not just that the pure decision
    /// function returns the right booleans in isolation.
    func testRecordDedupsFlatMetricAcrossRepeatedTicks() throws {
        let store = tempHistoryStore()
        let dbQueue = try XCTUnwrap(store.databaseQueue)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // 10 ticks, 3s apart (StatsCoordinator's fast-tier default cadence),
        // all reporting the exact same flat thermal reading.
        for tick in 0..<10 {
            let snapshot = SystemSnapshot(
                timestamp: base.addingTimeInterval(Double(tick) * 3),
                deviceID: "test",
                thermal: ThermalStats(pressureLevel: .nominal, isThrottling: false)
            )
            store.record(snapshot)
        }
        store.flush()

        let rowCount = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sample_raw WHERE metric = 'thermal.is_throttling'") ?? 0
        }
        // First tick always writes; the next 9 (all within the 60s
        // heartbeat window, unchanged) must all be skipped.
        XCTAssertEqual(rowCount, 1)

        let samples = store.samples(metric: "thermal.is_throttling", since: base.addingTimeInterval(-1), tier: .raw)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].value, 0.0)
    }

    /// A changing metric (CPU percent moving every tick) must still get one
    /// row per tick — the dedup must never eat a real change.
    func testRecordWritesEveryRowForAChangingMetric() throws {
        let store = tempHistoryStore()
        let dbQueue = try XCTUnwrap(store.databaseQueue)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for tick in 0..<10 {
            let snapshot = SystemSnapshot(
                timestamp: base.addingTimeInterval(Double(tick) * 3),
                deviceID: "test",
                cpu: CPUStats(totalPercent: Double(tick) * 5.0)
            )
            store.record(snapshot)
        }
        store.flush()

        let rowCount = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sample_raw WHERE metric = 'cpu.total_percent'") ?? 0
        }
        XCTAssertEqual(rowCount, 10)
    }

    /// A flat metric that genuinely persists past the 60s heartbeat window
    /// still gets an occasional row — proving the dedup doesn't silently
    /// stop reporting a metric forever, which would leave `ChartScrubbing`
    /// reading a permanently flat metric as one giant gap.
    func testRecordWritesHeartbeatRowAfterWindowElapses() throws {
        let store = tempHistoryStore()
        let dbQueue = try XCTUnwrap(store.databaseQueue)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let first = SystemSnapshot(
            timestamp: base,
            deviceID: "test",
            thermal: ThermalStats(pressureLevel: .nominal, isThrottling: false)
        )
        let secondAfterHeartbeat = SystemSnapshot(
            timestamp: base.addingTimeInterval(61),
            deviceID: "test",
            thermal: ThermalStats(pressureLevel: .nominal, isThrottling: false)
        )
        store.record(first)
        store.record(secondAfterHeartbeat)
        store.flush()

        let rowCount = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sample_raw WHERE metric = 'thermal.is_throttling'") ?? 0
        }
        XCTAssertEqual(rowCount, 2)
    }
}
