import Foundation
import GRDB
import os

/// The four-step maintenance job from plan §6.3 that keeps `sample_raw`
/// bounded while turning it into cheap, long-horizon history — plus a fifth,
/// added by a later verified-bug pass, that bounds `alert_log`:
///
/// 1. Roll complete hours of `sample_raw` into `sample_hourly` (min/max/avg/count).
/// 2. Delete `sample_raw` rows older than 48h.
/// 3. Once daily: roll `sample_hourly` into `sample_daily`, then delete
///    `sample_hourly` rows older than 90d.
/// 4. Weekly: `PRAGMA incremental_vacuum` to actually reclaim disk.
/// 5. Once daily (alongside step 3): delete `alert_log` rows older than
///    `alertLogRetentionDays` — see that constant's doc comment for why
///    `alert_log` needed this at all (it had no retention before this pass)
///    and why it isn't user-configurable like steps 2/3's windows are.
///
/// `runHourlyRollup`/`runDailyRollup` take an injected `now` so tests can
/// drive them deterministically instead of depending on the wall clock.
/// Every step is wrapped in `do/catch` — a failed maintenance pass is logged
/// and skipped, never allowed to crash the process (P5).
public final class RollupJob: @unchecked Sendable {

    private static let logger = Logger(subsystem: "dev.malekswilam.sentry.kit", category: "RollupJob")

    private let dbQueue: DatabaseQueue?
    private let queue = DispatchQueue(label: "dev.malekswilam.sentry.rollupjob", qos: .utility)
    private var hourlyTimer: DispatchSourceTimer?
    private let defaults: UserDefaults

    // User-configurable per plan §6.3 ("Make all three retention windows
    // user-configurable"). Guarded by a lock rather than `queue`, because
    // the run methods that read these already execute *on* `queue` — a
    // `queue.sync` there would deadlock on itself.
    private let retentionLock = NSLock()
    private var rawRetentionHoursStorage: Int = 48
    private var hourlyRetentionDaysStorage: Int = 90

    private var rawRetentionHours: Int {
        retentionLock.lock(); defer { retentionLock.unlock() }
        return rawRetentionHoursStorage
    }

    private var hourlyRetentionDays: Int {
        retentionLock.lock(); defer { retentionLock.unlock() }
        return hourlyRetentionDaysStorage
    }

    public func setRetention(rawHours: Int, hourlyDays: Int) {
        retentionLock.lock(); defer { retentionLock.unlock() }
        rawRetentionHoursStorage = max(rawHours, 1)
        hourlyRetentionDaysStorage = max(hourlyDays, 1)
    }

    /// Age-based retention for `alert_log` (verified-bug pass: "`alert_log`
    /// is never pruned" — a misconfigured, rapidly-refiring rule grows it
    /// forever, since it was never given a retention window the way
    /// `sample_raw`/`sample_hourly` were). Not user-configurable, unlike
    /// `rawRetentionHoursStorage`/`hourlyRetentionDaysStorage` above — plan
    /// §6.3's "make retention configurable" request is specifically about
    /// the sample tiers, and `alert_log` is a low-volume discrete-event log
    /// under normal operation (`Migrations.swift`'s v3 migration comment
    /// says as much), so a generous fixed window is enough to bound it
    /// without adding a settings-pane control nobody asked for. 180 days is
    /// comfortably longer than `hourlyRetentionDays`'s 90-day default, since
    /// alert history is exactly the kind of thing worth keeping longer than
    /// raw metric samples.
    private static let alertLogRetentionDays: Int = 180

    private static let lastDailyRollupKey = "dev.malekswilam.sentry.rollupjob.lastDailyRollup"
    private static let lastVacuumKey = "dev.malekswilam.sentry.rollupjob.lastVacuum"

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
    /// already rolled is safe: the upsert recomputes it from whatever raw
    /// data still exists, but the `DO UPDATE ... WHERE excluded.sample_count
    /// >= sample_hourly.sample_count` guard refuses to overwrite an existing
    /// rollup with one computed from *fewer* samples. Without that guard, the
    /// retention delete below corrupts the oldest hour: the 48h cutoff lands
    /// mid-hour, deletes part of that hour's raw rows, and the *next* pass
    /// would then recompute the bucket from the surviving fraction and
    /// overwrite the correct full-hour min/avg/max/count — permanently, since
    /// the raw rows are gone. Raw rows are only ever removed by that
    /// retention delete (`HistoryStore` upserts, never deletes), so a
    /// shrinking count always means "partially pruned", never "corrected
    /// data".
    public func runHourlyRollup(now: Date = Date()) {
        guard let dbQueue else { return }

        let currentHourStart = (now.timeIntervalSince1970 / 3600).rounded(.down) * 3600
        let rawCutoff = now.timeIntervalSince1970 - Double(rawRetentionHours) * 3600

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
                    WHERE excluded.sample_count >= sample_hourly.sample_count
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
    ///
    /// Carries the same `DO UPDATE ... WHERE excluded.sample_count >=`
    /// guard as `runHourlyRollup`, for the same reason: the 90d hourly
    /// cutoff lands mid-day, and without the guard the next pass would
    /// overwrite that day's correct rollup with one recomputed from only the
    /// surviving hours — worse here, because `sample_daily` is the
    /// kept-forever tier, so the corruption would be permanent.
    public func runDailyRollup(now: Date = Date()) {
        guard let dbQueue else { return }

        let currentDayStart = (now.timeIntervalSince1970 / 86400).rounded(.down) * 86400
        let hourlyCutoff = now.timeIntervalSince1970 - Double(hourlyRetentionDays) * 86400

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
                    WHERE excluded.sample_count >= sample_daily.sample_count
                    """, arguments: [currentDayStart])

                try db.execute(
                    sql: "DELETE FROM sample_hourly WHERE hour_start < ?",
                    arguments: [hourlyCutoff]
                )

                // Verified-bug pass: `alert_log` had no retention at all
                // before this. Pruned here (daily cadence) rather than in
                // `runHourlyRollup` above — `alert_log` isn't a rollup
                // source the way `sample_raw` is for `sample_hourly` (there
                // is no "alert_log_hourly" tier to protect from a
                // mid-bucket cutoff), so there's no correctness reason to
                // prune it any more often than once a day, and doing it
                // here keeps this one `dbQueue.write` transaction as the
                // single place a day's worth of retention deletes happen.
                let alertLogCutoff = now.timeIntervalSince1970 - Double(Self.alertLogRetentionDays) * 86400
                try db.execute(
                    sql: "DELETE FROM alert_log WHERE ts < ?",
                    arguments: [alertLogCutoff]
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
