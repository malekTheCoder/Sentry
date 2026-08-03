import XCTest
import GRDB
@testable import SentryKit

/// Covers `RollupJob`'s rollup/retention SQL — the min/max/avg/count
/// aggregation math, the retention-delete boundary, and (the reason this
/// file exists — persistence audit) the `DO UPDATE ... WHERE
/// excluded.sample_count >= ...` guard that stops the retention delete from
/// corrupting the oldest bucket of each tier: the 48h/90d cutoff lands
/// mid-bucket, deletes part of that bucket's source rows, and an unguarded
/// re-run would overwrite the previously correct rollup with one recomputed
/// from only the surviving fraction.
final class RollupJobTests: XCTestCase {

    /// An exactly hour-aligned epoch (472_223 * 3600), so tests can reason
    /// about bucket boundaries without hidden rounding.
    private let hourStart: Double = 1_700_002_800
    /// An exactly day-aligned epoch (19_676 * 86400).
    private let dayStart: Double = 1_700_006_400

    private func makeStore() throws -> (HistoryStore, DatabaseQueue) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RollupJobTests-\(UUID().uuidString).sqlite")
        let store = HistoryStore(databaseURL: url)
        let dbQueue = try XCTUnwrap(store.databaseQueue)
        return (store, dbQueue)
    }

    private func insertRaw(_ db: Database, ts: Double, metric: String = "m", value: Double) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO sample_raw (ts, metric, value) VALUES (?, ?, ?)",
            arguments: [ts, metric, value]
        )
    }

    private func insertHourly(
        _ db: Database, hour: Double, metric: String = "m",
        min: Double, max: Double, avg: Double, count: Int
    ) throws {
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO sample_hourly (hour_start, metric, min_value, max_value, avg_value, sample_count)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [hour, metric, min, max, avg, count]
        )
    }

    private func hourlyRow(_ dbQueue: DatabaseQueue, hour: Double, metric: String = "m") throws -> Row? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM sample_hourly WHERE hour_start = ? AND metric = ?",
                arguments: [hour, metric]
            )
        }
    }

    private func dailyRow(_ dbQueue: DatabaseQueue, day: Double, metric: String = "m") throws -> Row? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM sample_daily WHERE day_start = ? AND metric = ?",
                arguments: [day, metric]
            )
        }
    }

    // MARK: - Hourly rollup: aggregation and boundaries

    func testHourlyRollupComputesMinMaxAvgCountForCompleteHour() throws {
        let (store, dbQueue) = try makeStore()
        _ = store

        try dbQueue.write { db in
            for (offset, value) in [(0.0, 10.0), (600, 20), (1200, 30), (1800, 40), (2400, 50), (3000, 60)] {
                try self.insertRaw(db, ts: self.hourStart + offset, value: value)
            }
            // One sample in the NEXT (in-progress) hour — must not be rolled.
            try self.insertRaw(db, ts: self.hourStart + 3600 + 60, value: 99)
        }

        let job = RollupJob(dbQueue: dbQueue)
        job.runHourlyRollup(now: Date(timeIntervalSince1970: hourStart + 3600 + 600))

        let row = try XCTUnwrap(try hourlyRow(dbQueue, hour: hourStart))
        XCTAssertEqual(row["min_value"] as Double?, 10)
        XCTAssertEqual(row["max_value"] as Double?, 60)
        XCTAssertEqual(row["avg_value"] as Double?, 35)
        XCTAssertEqual(row["sample_count"] as Int?, 6)
        XCTAssertNil(try hourlyRow(dbQueue, hour: hourStart + 3600), "in-progress hour must not be rolled")
    }

    func testHourlyRollupRetentionDeleteIsStrictlyOlderThanCutoff() throws {
        let (store, dbQueue) = try makeStore()
        _ = store

        let now = hourStart + 2 * 3600
        let cutoff = now - 48 * 3600
        try dbQueue.write { db in
            try self.insertRaw(db, ts: cutoff - 1, value: 1)   // outside 48h: deleted
            try self.insertRaw(db, ts: cutoff, value: 2)       // exactly the 48h boundary: kept
            try self.insertRaw(db, ts: cutoff + 1, value: 3)   // inside 48h: kept
        }

        let job = RollupJob(dbQueue: dbQueue)
        job.runHourlyRollup(now: Date(timeIntervalSince1970: now))

        let remaining = try dbQueue.read { db in
            try Double.fetchAll(db, sql: "SELECT ts FROM sample_raw ORDER BY ts ASC")
        }
        XCTAssertEqual(remaining, [cutoff, cutoff + 1])
    }

    // MARK: - Hourly rollup: partial-prune guard

    func testHourlyRerollAfterPartialPruneDoesNotOverwriteCompleteRollup() throws {
        let (store, dbQueue) = try makeStore()
        _ = store

        // Hour `hourStart` was correctly rolled from 6 samples on an earlier
        // pass, after which the 48h retention delete pruned the first half of
        // its raw rows (the cutoff landed mid-hour). Only the last 2 samples
        // survive.
        try dbQueue.write { db in
            try self.insertHourly(db, hour: self.hourStart, min: 10, max: 60, avg: 35, count: 6)
            try self.insertRaw(db, ts: self.hourStart + 2400, value: 50)
            try self.insertRaw(db, ts: self.hourStart + 3000, value: 60)
        }

        let job = RollupJob(dbQueue: dbQueue)
        job.runHourlyRollup(now: Date(timeIntervalSince1970: hourStart + 2 * 3600))

        let row = try XCTUnwrap(try hourlyRow(dbQueue, hour: hourStart))
        XCTAssertEqual(row["min_value"] as Double?, 10, "partial re-roll must not overwrite the complete rollup")
        XCTAssertEqual(row["avg_value"] as Double?, 35)
        XCTAssertEqual(row["sample_count"] as Int?, 6)
    }

    func testHourlyRerollWithEqualOrMoreSamplesStillUpdates() throws {
        let (store, dbQueue) = try makeStore()
        _ = store

        // A stale 2-sample rollup and 3 raw samples for the same hour: the
        // guard is `>=`, so a recompute from at least as many samples must
        // still win (late-arriving data, or a re-run of the same pass).
        try dbQueue.write { db in
            try self.insertHourly(db, hour: self.hourStart, min: 0, max: 1, avg: 0.5, count: 2)
            try self.insertRaw(db, ts: self.hourStart + 600, value: 10)
            try self.insertRaw(db, ts: self.hourStart + 1200, value: 20)
            try self.insertRaw(db, ts: self.hourStart + 1800, value: 30)
        }

        let job = RollupJob(dbQueue: dbQueue)
        job.runHourlyRollup(now: Date(timeIntervalSince1970: hourStart + 2 * 3600))

        let row = try XCTUnwrap(try hourlyRow(dbQueue, hour: hourStart))
        XCTAssertEqual(row["avg_value"] as Double?, 20)
        XCTAssertEqual(row["sample_count"] as Int?, 3)
    }

    // MARK: - Daily rollup: count-weighted average and partial-prune guard

    func testDailyRollupWeightsAverageBySampleCount() throws {
        let (store, dbQueue) = try makeStore()
        _ = store

        // Two hours of the same day with very different sample counts: the
        // daily average must be (10*1 + 20*3) / 4 = 17.5, not the unweighted
        // mean 15.
        try dbQueue.write { db in
            try self.insertHourly(db, hour: self.dayStart, min: 5, max: 12, avg: 10, count: 1)
            try self.insertHourly(db, hour: self.dayStart + 3600, min: 8, max: 30, avg: 20, count: 3)
        }

        let job = RollupJob(dbQueue: dbQueue)
        job.runDailyRollup(now: Date(timeIntervalSince1970: dayStart + 86400 + 3600))

        let row = try XCTUnwrap(try dailyRow(dbQueue, day: dayStart))
        XCTAssertEqual(row["min_value"] as Double?, 5)
        XCTAssertEqual(row["max_value"] as Double?, 30)
        XCTAssertEqual(row["avg_value"] as Double?, 17.5)
        XCTAssertEqual(row["sample_count"] as Int?, 4)
    }

    func testDailyRerollAfterPartialPruneDoesNotOverwriteCompleteRollup() throws {
        let (store, dbQueue) = try makeStore()
        _ = store

        // Day `dayStart` was rolled from a full day (24 hourly rows, 2880
        // samples); the 90d hourly retention cutoff then pruned most of its
        // hourly rows. A re-roll from the one surviving hour must not
        // overwrite the kept-forever daily row.
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sample_daily (day_start, metric, min_value, max_value, avg_value, sample_count)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [self.dayStart, "m", 2.0, 95.0, 40.0, 2880]
            )
            try self.insertHourly(db, hour: self.dayStart + 23 * 3600, min: 50, max: 60, avg: 55, count: 120)
        }

        let job = RollupJob(dbQueue: dbQueue)
        job.runDailyRollup(now: Date(timeIntervalSince1970: dayStart + 2 * 86400))

        let row = try XCTUnwrap(try dailyRow(dbQueue, day: dayStart))
        XCTAssertEqual(row["min_value"] as Double?, 2)
        XCTAssertEqual(row["avg_value"] as Double?, 40)
        XCTAssertEqual(row["sample_count"] as Int?, 2880)
    }

    // MARK: - v4 migration: metric-leading indexes exist on the rollup tiers

    func testRollupTierMetricIndexesExist() throws {
        let (store, dbQueue) = try makeStore()
        _ = store

        let names = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        XCTAssertTrue(names.contains("idx_hourly_metric_hour"))
        XCTAssertTrue(names.contains("idx_daily_metric_day"))
    }
}
