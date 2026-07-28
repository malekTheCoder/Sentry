import Foundation
import GRDB
import os

/// The four-step maintenance job from plan §6.3 that keeps `sample_raw`
/// bounded while turning it into cheap, long-horizon history:
///
/// 1. Roll complete hours of `sample_raw` into `sample_hourly` (min/max/avg/count).
/// 2. Delete `sample_raw` rows older than 48h.
/// 3. Once daily: roll `sample_hourly` into `sample_daily`, then delete
///    `sample_hourly` rows older than 90d.
/// 4. Weekly: `PRAGMA incremental_vacuum` to actually reclaim disk.
///
/// `runHourlyRollup`/`runDailyRollup` take an injected `now` so tests can
/// drive them deterministically instead of depending on the wall clock.
/// Every step is wrapped in `do/catch` — a failed maintenance pass is logged
/// and skipped, never allowed to crash the process (P5).
public final class RollupJob: @unchecked Sendable {

    private static let logger = Logger(subsystem: "dev.malekswilam.macstat.kit", category: "RollupJob")

    private let dbQueue: DatabaseQueue?
    private let queue = DispatchQueue(label: "dev.malekswilam.macstat.rollupjob", qos: .utility)
    private var hourlyTimer: DispatchSourceTimer?
    private let defaults: UserDefaults

    private static let lastDailyRollupKey = "dev.malekswilam.macstat.rollupjob.lastDailyRollup"
    private static let lastVacuumKey = "dev.malekswilam.macstat.rollupjob.lastVacuum"

    /// - Parameters:
    ///   - dbQueue: typically `historyStore.databaseQueue` — the same
    ///     underlying database `HistoryStore` writes raw samples into. `nil`
    ///     is accepted (mirrors `HistoryStore`'s own "database failed to
    ///     open" state) so composition can wire this up unconditionally;
    ///     every run method just no-ops in that case.
    ///   - defaults: override for tests; defaults to `.standard`. Stores the
    ///     last-daily-rollup/last-vacuum timestamps this type uses to decide
    ///     whether a catch-up pass is due (see `runScheduledPass`).
    public init(dbQueue: DatabaseQueue?, defaults: UserDefaults = .standard) {
        self.dbQueue = dbQueue
        self.defaults = defaults
    }

    deinit {
        hourlyTimer?.cancel()
    }

    // MARK: - Scheduler

    /// Starts an hourly timer that always runs the hourly rollup, and also
    /// runs the daily rollup / weekly vacuum whenever they're overdue (see
    /// `runScheduledPass`). Idempotent — calling this twice just replaces
    /// the existing timer.
    ///
    /// Runs one catch-up pass **immediately**, rather than waiting up to an
    /// hour for the first timer fire. Independent review flagged that
    /// without this, a menu-bar app that doesn't stay open for a full
    /// contiguous hour — a very ordinary usage pattern — would never once
    /// run the hourly rollup, and since `sample_raw`'s 48h retention delete
    /// lives inside that same method, raw samples would accumulate
    /// unbounded. That's a real correctness/disk-usage bug, not just
    /// "history shows up late."
    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.runScheduledPass(now: Date())
            self.scheduleHourlyTimer()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.hourlyTimer?.cancel()
            self?.hourlyTimer = nil
        }
    }

    private func scheduleHourlyTimer() {
        hourlyTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3600, repeating: 3600, leeway: .seconds(60))
        timer.setEventHandler { [weak self] in
            self?.runScheduledPass(now: Date())
        }
        timer.resume()
        hourlyTimer = timer
    }

    /// Fired every hour (and once immediately on `start()`). Hourly rollup
    /// always runs. Daily rollup and the weekly vacuum run whenever they're
    /// *overdue* — at least a day/week since the last successful run,
    /// tracked persistently in `defaults` — rather than only at an exact
    /// clock boundary. Exact-boundary matching (the original design: "run
    /// at hour==0 UTC") silently never fires for a Mac that's reliably
    /// asleep or the app reliably quit at that exact hour every day, which
    /// is a completely ordinary laptop usage pattern (overnight sleep). A
    /// persisted "last run" timestamp self-corrects on whatever the next
    /// opportunity turns out to be, at launch or at the next hourly tick.
    private func runScheduledPass(now: Date) {
        runHourlyRollup(now: now)

        let dayInterval: TimeInterval = 86400
        let weekInterval: TimeInterval = 7 * 86400

        let lastDaily = defaults.object(forKey: Self.lastDailyRollupKey) as? Date
        if lastDaily.map({ now.timeIntervalSince($0) >= dayInterval }) ?? true {
            runDailyRollup(now: now)
            defaults.set(now, forKey: Self.lastDailyRollupKey)
        }

        let lastVacuum = defaults.object(forKey: Self.lastVacuumKey) as? Date
        if lastVacuum.map({ now.timeIntervalSince($0) >= weekInterval }) ?? true {
            runWeeklyVacuum()
            defaults.set(now, forKey: Self.lastVacuumKey)
        }
    }

    // MARK: - Step 1 + 2: hourly rollup

    /// Rolls every complete hour of `sample_raw` into `sample_hourly`, then
    /// deletes raw rows older than 48h. "Complete hour" means `hour_start <
    /// currentHourStart` — the in-progress hour is never rolled, since it
    /// isn't finished accumulating samples yet. Re-running this for an hour
    /// already rolled is safe (`INSERT OR REPLACE` recomputes it from
    /// whatever raw data still exists), so there's no separate "already
    /// rolled up" bookkeeping to maintain.
    public func runHourlyRollup(now: Date = Date()) {
        guard let dbQueue else { return }

        let currentHourStart = (now.timeIntervalSince1970 / 3600).rounded(.down) * 3600
        let rawCutoff = now.timeIntervalSince1970 - 48 * 3600

        do {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO sample_hourly (hour_start, metric, min_value, max_value, avg_value, sample_count)
                    SELECT
                        CAST(ts / 3600 AS INTEGER) * 3600 AS hour_start,
                        metric,
                        MIN(value),
                        MAX(value),
                        AVG(value),
                        COUNT(*)
                    FROM sample_raw
                    WHERE ts < ?
                    GROUP BY hour_start, metric
                    ON CONFLICT(hour_start, metric) DO UPDATE SET
                        min_value = excluded.min_value,
                        max_value = excluded.max_value,
                        avg_value = excluded.avg_value,
                        sample_count = excluded.sample_count
                    """, arguments: [currentHourStart])

                try db.execute(
                    sql: "DELETE FROM sample_raw WHERE ts < ?",
                    arguments: [rawCutoff]
                )
            }
        } catch {
            Self.logger.error("Hourly rollup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Step 3: daily rollup

    /// Rolls every complete day of `sample_hourly` into `sample_daily`
    /// (count-weighted average, so a hour with more samples isn't diluted to
    /// the same weight as one with few), then deletes hourly rows older than
    /// 90d.
    public func runDailyRollup(now: Date = Date()) {
        guard let dbQueue else { return }

        let currentDayStart = (now.timeIntervalSince1970 / 86400).rounded(.down) * 86400
        let hourlyCutoff = now.timeIntervalSince1970 - 90 * 86400

        do {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO sample_daily (day_start, metric, min_value, max_value, avg_value, sample_count)
                    SELECT
                        CAST(hour_start / 86400 AS INTEGER) * 86400 AS day_start,
                        metric,
                        MIN(min_value),
                        MAX(max_value),
                        SUM(avg_value * sample_count) / SUM(sample_count),
                        SUM(sample_count)
                    FROM sample_hourly
                    WHERE hour_start < ?
                    GROUP BY day_start, metric
                    ON CONFLICT(day_start, metric) DO UPDATE SET
                        min_value = excluded.min_value,
                        max_value = excluded.max_value,
                        avg_value = excluded.avg_value,
                        sample_count = excluded.sample_count
                    """, arguments: [currentDayStart])

                try db.execute(
                    sql: "DELETE FROM sample_hourly WHERE hour_start < ?",
                    arguments: [hourlyCutoff]
                )
            }
        } catch {
            Self.logger.error("Daily rollup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Step 4: weekly vacuum

    /// Reclaims space freed by the retention deletes above. Only effective
    /// because `HistoryStore` sets `PRAGMA auto_vacuum = INCREMENTAL` at
    /// database creation time — incremental_vacuum is a no-op otherwise.
    public func runWeeklyVacuum() {
        guard let dbQueue else { return }
        do {
            try dbQueue.write { db in
                try db.execute(sql: "PRAGMA incremental_vacuum")
            }
        } catch {
            Self.logger.error("Weekly vacuum failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
