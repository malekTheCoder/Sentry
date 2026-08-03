import Foundation
import GRDB
import os

/// Local time-series store for `SystemSnapshot`s (plan §6). Wraps a single
/// GRDB `DatabaseQueue` opened at `~/Library/Application
/// Support/Sentry/history.sqlite` (plan §14.3) and flattens each snapshot's
/// populated numeric fields into `(ts, metric, value)` rows in the
/// long-and-narrow `sample_raw` table, using the dotted metric IDs from the
/// plan's Appendix A.
///
/// **Write batching (§6.3):** `record(_:)` never touches disk itself — it
/// only appends to an in-memory buffer. A background timer flushes the
/// buffer as one transaction every 30s, or immediately once the buffer
/// crosses `flushThreshold` rows, whichever comes first. Callers that need a
/// guaranteed write (app quit, sleep) should call `flush()` explicitly.
///
/// **Failure handling (P5, "never crash"):** every GRDB call in this type is
/// wrapped in `do/catch`. A disk-write hiccup is logged and dropped, never
/// thrown up into caller code — a stats app has no business crashing the
/// whole process over a failed SQLite write.
public final class HistoryStore: @unchecked Sendable {

    public enum Tier {
        case raw, hourly, daily
    }

    private static let logger = Logger(subsystem: "dev.malekswilam.sentry.kit", category: "HistoryStore")

    /// `nil` only if the database failed to open (see `init`) — every public
    /// method no-ops gracefully in that case rather than force-unwrapping.
    private let dbQueue: DatabaseQueue?

    private let queue = DispatchQueue(label: "dev.malekswilam.sentry.historystore", qos: .utility)
    private var buffer: [(ts: Double, metric: String, value: Double)] = []
    private var flushTimer: DispatchSourceTimer?

    private let flushInterval: TimeInterval
    private let flushThreshold: Int

    /// - Parameters:
    ///   - databaseURL: override for tests; defaults to the real on-disk
    ///     location under Application Support.
    ///   - flushInterval: seconds between automatic flushes (plan default: 30s).
    ///   - flushThreshold: buffered row count that forces an immediate flush
    ///     even if `flushInterval` hasn't elapsed (plan default: ~500 rows).
    public init(
        databaseURL: URL = HistoryStore.defaultDatabaseURL(),
        flushInterval: TimeInterval = 30,
        flushThreshold: Int = 500
    ) {
        self.flushInterval = flushInterval
        self.flushThreshold = flushThreshold

        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let queue = try DatabaseQueue(path: databaseURL.path)
            // Must be set before any table is created (SQLite only honors it
            // at creation time otherwise) so `RollupJob`'s weekly
            // `PRAGMA incremental_vacuum` actually reclaims space instead of
            // silently no-op'ing on a database that defaults to auto_vacuum=NONE.
            try queue.write { db in
                try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
            }
            try Migrations.migrator().migrate(queue)
            self.dbQueue = queue
        } catch {
            Self.logger.error("Failed to open history database at \(databaseURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            self.dbQueue = nil
        }

        startFlushTimer()
    }

    deinit {
        flushTimer?.cancel()
    }

    /// `~/Library/Application Support/Sentry/history.sqlite` (plan §14.3).
    ///
    /// The fallback isn't `homeDirectoryForCurrentUser` — that's unavailable
    /// on iOS at all (a compile error, not just sandboxed away), and
    /// `SentryKit` is a shared cross-platform module (plan §12, Phase 5's
    /// iOS app). See `SettingsStore.defaultSettingsURL()`'s doc comment for
    /// the same reasoning, applied identically here.
    public static func defaultDatabaseURL() -> URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory

        return appSupport
            .appendingPathComponent("Sentry", isDirectory: true)
            .appendingPathComponent("history.sqlite")
    }

    /// Exposes the underlying GRDB queue for maintenance jobs (`RollupJob`)
    /// that need direct SQL access this type doesn't otherwise provide —
    /// e.g. cross-table rollup INSERT/DELETE statements. `nil` if the
    /// database failed to open (see `init`).
    public var databaseQueue: DatabaseQueue? { dbQueue }

    // MARK: - Write path

    /// Flattens every populated numeric field on `snapshot` into buffered
    /// `sample_raw` rows. Cheap and synchronous-looking to the caller — the
    /// actual disk write happens later, in a batch, off this call stack.
    public func record(_ snapshot: SystemSnapshot) {
        let ts = snapshot.timestamp.timeIntervalSince1970
        let pairs = Self.metricPairs(for: snapshot)
        guard !pairs.isEmpty else { return }

        queue.async { [weak self] in
            guard let self else { return }
            for (metric, value) in pairs {
                self.buffer.append((ts: ts, metric: metric, value: value))
            }
            if self.buffer.count >= self.flushThreshold {
                self.flushLocked()
            }
        }
    }

    /// Forces an immediate write of whatever is currently buffered. Safe to
    /// call when the buffer is empty or the database failed to open. Safe
    /// to call from any thread **except** a closure already executing on
    /// this store's own private `queue` (e.g. from inside `record`'s
    /// `queue.async` block) — that would deadlock on the `queue.sync`
    /// below. In practice every current caller (app quit/sleep handlers)
    /// runs on the main thread, which is fine.
    public func flush() {
        queue.sync { [weak self] in
            self?.flushLocked()
        }
    }

    /// Must only be called while already on `queue`.
    private func flushLocked() {
        guard let dbQueue else {
            // The database never opened (see `init`). Rows buffered anyway
            // must be *dropped*, not retained: `record` keeps appending and
            // this method is the only thing that empties the buffer, so
            // returning without clearing would grow the buffer unboundedly
            // for the whole process lifetime — a slow leak of ~35 tuples per
            // snapshot, forever. Same "log and drop" posture as a failed
            // write below; there is nowhere durable for these rows to go.
            buffer.removeAll(keepingCapacity: false)
            return
        }
        guard !buffer.isEmpty else { return }
        let rows = buffer
        buffer.removeAll(keepingCapacity: true)

        do {
            try dbQueue.write { db in
                for row in rows {
                    // OR REPLACE: a metric can legitimately be sampled twice
                    // within the same second by two different tiers: last
                    // write wins rather than throwing away the whole batch on
                    // a UNIQUE(ts, metric) conflict.
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO sample_raw (ts, metric, value) VALUES (?, ?, ?)",
                        arguments: [row.ts, row.metric, row.value]
                    )
                }
            }
        } catch {
            Self.logger.error("Failed to flush \(rows.count) history rows: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        timer.setEventHandler { [weak self] in
            self?.flushLocked()
        }
        timer.resume()
        flushTimer = timer
    }

    // MARK: - Alert log (plan §11.3)

    /// Records one `AlertEngine` rule firing. Unlike `record(_:)`'s
    /// buffered/batched write path, this writes immediately: alert firings
    /// are, by design, rare (`sustainedFor`, `cooldown`, and the global
    /// rate cap all exist specifically to keep them rare — see
    /// `AlertEngine`), so there's no throughput reason to defer the write,
    /// and a reviewable history pane wants each entry durable as soon as
    /// possible rather than lost if the app quits before the next flush.
    ///
    /// - Parameters:
    ///   - suppressed: `true` when the rule's condition genuinely fired but
    ///     the global notification rate cap held it back — still logged
    ///     (never silently dropped) so a misconfigured rule's impact is
    ///     visible in history rather than invisible.
    public func logAlertFiring(
        ruleID: UUID,
        ruleName: String,
        metric: String,
        value: Double,
        at date: Date = Date(),
        delivered: Bool,
        suppressed: Bool
    ) {
        guard let dbQueue else { return }
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO alert_log (ts, rule_id, rule_name, metric, value, delivered, suppressed)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        date.timeIntervalSince1970,
                        ruleID.uuidString,
                        ruleName,
                        metric,
                        value,
                        delivered ? 1 : 0,
                        suppressed ? 1 : 0
                    ]
                )
            }
        } catch {
            Self.logger.error("Failed to log alert firing for rule \(ruleID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads back recent `alert_log` rows, most recent first — the data
    /// source for the future history pane (out of scope for this task, but
    /// there's no reason to make that pane reach into raw SQL to get it).
    public func recentAlertFirings(limit: Int = 200) -> [AlertLogEntry] {
        guard let dbQueue else { return [] }
        do {
            return try dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT ts, rule_id, rule_name, metric, value, delivered, suppressed
                    FROM alert_log ORDER BY ts DESC LIMIT ?
                    """,
                    arguments: [limit]
                )
                return rows.compactMap { row -> AlertLogEntry? in
                    guard
                        let ts: Double = row["ts"],
                        let ruleIDString: String = row["rule_id"],
                        let ruleID = UUID(uuidString: ruleIDString),
                        let metric: String = row["metric"],
                        let value: Double = row["value"],
                        let delivered: Int = row["delivered"],
                        let suppressed: Int = row["suppressed"]
                    else { return nil }
                    let ruleName: String = row["rule_name"] ?? ""
                    return AlertLogEntry(
                        timestamp: Date(timeIntervalSince1970: ts),
                        ruleID: ruleID,
                        ruleName: ruleName,
                        metric: metric,
                        value: value,
                        delivered: delivered != 0,
                        suppressed: suppressed != 0
                    )
                }
            }
        } catch {
            Self.logger.error("Failed to read alert_log: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Persists one executed write-tool MCP call (AI-agent-integration pass
    /// — see Sentry-AI-Features-Research.md item #15). Called only for
    /// calls that actually reached `StatsCoordinator`/`PowerControlService`/
    /// `AlertEngine` (i.e. `MCPAccessController.Decision.allow`), not every
    /// attempted call — same "record what actually happened" posture as
    /// `logAlertFiring`'s `delivered` flag, and the reason this is a
    /// separate durable log from the in-memory `MCPActivityLog` (which
    /// records every decision, including denials, for the live AI Access
    /// pane view) rather than a duplicate of it.
    public func logAgentActivity(clientName: String, tool: String, at date: Date = Date()) {
        // Backward-compatible overload from before the v5 migration widened
        // the table (agent-session attribution pass): pre-v5 call sites only
        // ever logged *executed* calls, so `.succeeded` with an unknown
        // ("") session and no duration is the honest translation, matching
        // the migration's own backfill defaults for old rows.
        logAgentActivity(
            clientName: clientName,
            sessionID: "",
            tool: tool,
            argsSummary: nil,
            durationMs: nil,
            outcome: .succeeded,
            at: date
        )
    }

    /// Full write path for the v5 schema (agent-session attribution pass) —
    /// records which per-connection session made the call (see
    /// `AgentSessionIdentity`, `SentryKit/Services/AgentSessionIdentity.swift`),
    /// how long it took, a short human-readable arguments summary (never raw
    /// arguments — the caller is responsible for sanitizing/capping, see
    /// `MCPXPCService`), and whether it actually executed. Unlike the pre-v5
    /// path, *every* attempted tool call is logged, including denials —
    /// `outcome` is what distinguishes "an agent did X" from "an agent asked
    /// for X and was refused," which the session report and the Dashboard's
    /// activity card both need to render honestly.
    public func logAgentActivity(
        clientName: String,
        sessionID: String,
        tool: String,
        argsSummary: String?,
        durationMs: Int?,
        outcome: AgentActivityOutcome,
        at date: Date = Date()
    ) {
        guard let dbQueue else { return }
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO agent_activity_log (ts, client_name, tool, session_id, duration_ms, args_summary, outcome)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        date.timeIntervalSince1970,
                        clientName,
                        tool,
                        sessionID,
                        durationMs,
                        argsSummary,
                        outcome.rawValue
                    ]
                )
            }
        } catch {
            Self.logger.error("Failed to log agent activity for tool \(tool, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads back `agent_activity_log` rows at or after `since`, oldest
    /// first — the data source for the Dashboard's agent-activity panel and
    /// `AgentSessionReport`'s per-session grouping.
    public func agentActivityEvents(since: Date) -> [AgentActivityEvent] {
        guard let dbQueue else { return [] }
        do {
            return try dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT ts, client_name, tool, session_id, duration_ms, args_summary, outcome
                    FROM agent_activity_log WHERE ts >= ? ORDER BY ts ASC
                    """,
                    arguments: [since.timeIntervalSince1970]
                )
                return rows.compactMap { row -> AgentActivityEvent? in
                    guard
                        let ts: Double = row["ts"],
                        let clientName: String = row["client_name"],
                        let tool: String = row["tool"]
                    else { return nil }
                    // v5 columns decode leniently: an unknown outcome string
                    // (from a future migration or a hand-edited database)
                    // degrades to `.succeeded` — matching the migration's
                    // backfill default — rather than dropping the row, which
                    // would make history silently shrink.
                    let outcomeRaw: String = row["outcome"] ?? AgentActivityOutcome.succeeded.rawValue
                    return AgentActivityEvent(
                        timestamp: Date(timeIntervalSince1970: ts),
                        clientName: clientName,
                        tool: tool,
                        sessionID: row["session_id"] ?? "",
                        durationMs: row["duration_ms"],
                        argsSummary: row["args_summary"],
                        outcome: AgentActivityOutcome(rawValue: outcomeRaw) ?? .succeeded
                    )
                }
            }
        } catch {
            Self.logger.error("Failed to read agent_activity_log: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Read path

    /// Reads samples for one metric from the tier the caller specifies. The
    /// returned tuple's `value` is the raw sample value for `.raw`, or the
    /// hour/day's `avg_value` for `.hourly`/`.daily` — a single-number
    /// summary is what a history chart line plots, min/max stay in the DB
    /// for callers that want a band later.
    public func samples(metric: String, since: Date, tier: Tier) -> [(timestamp: Date, value: Double)] {
        guard let dbQueue else { return [] }
        let sinceEpoch = since.timeIntervalSince1970

        do {
            return try dbQueue.read { db -> [(timestamp: Date, value: Double)] in
                let rows: [Row]
                switch tier {
                case .raw:
                    rows = try Row.fetchAll(
                        db,
                        sql: "SELECT ts AS x, value AS y FROM sample_raw WHERE metric = ? AND ts >= ? ORDER BY ts ASC",
                        arguments: [metric, sinceEpoch]
                    )
                case .hourly:
                    rows = try Row.fetchAll(
                        db,
                        sql: "SELECT hour_start AS x, avg_value AS y FROM sample_hourly WHERE metric = ? AND hour_start >= ? ORDER BY hour_start ASC",
                        arguments: [metric, sinceEpoch]
                    )
                case .daily:
                    rows = try Row.fetchAll(
                        db,
                        sql: "SELECT day_start AS x, avg_value AS y FROM sample_daily WHERE metric = ? AND day_start >= ? ORDER BY day_start ASC",
                        arguments: [metric, sinceEpoch]
                    )
                }
                // Safe against a future migration relaxing NOT NULL on these
                // columns: GRDB's non-optional Row subscript traps on NULL,
                // which a thrown-error do/catch can't protect against —
                // decode as optionals and skip rather than risk a crash.
                return rows.compactMap { row -> (timestamp: Date, value: Double)? in
                    guard let x: Double = row["x"], let y: Double = row["y"] else { return nil }
                    return (timestamp: Date(timeIntervalSince1970: x), value: y)
                }
            }
        } catch {
            Self.logger.error("Failed to read \(metric, privacy: .public) samples: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Convenience overload with automatic tier selection (plan §6.3): a
    /// range under 48h can still be served by `sample_raw` before it's
    /// rolled up and deleted; under 90d falls back to `sample_hourly`; wider
    /// than that only `sample_daily` (kept forever) has data at all.
    ///
    /// The tier picked from the requested range alone doesn't know whether
    /// that tier has actually been populated yet — a young install (or one
    /// where `RollupJob` hasn't run) can have a full history sitting in
    /// `sample_raw` while `sample_hourly`/`sample_daily` are still empty. If
    /// the chosen tier comes back empty, fall back to the next-finer tier
    /// that might actually have the answer, rather than returning an empty
    /// chart for data that does exist.
    public func samples(metric: String, since: Date) -> [(timestamp: Date, value: Double)] {
        let chosen = tier(for: since)
        let result = samples(metric: metric, since: since, tier: chosen)
        guard result.isEmpty else { return result }

        switch chosen {
        case .daily:
            let hourly = samples(metric: metric, since: since, tier: .hourly)
            return hourly.isEmpty
                ? samples(metric: metric, since: since, tier: .raw)
                : hourly
        case .hourly:
            return samples(metric: metric, since: since, tier: .raw)
        case .raw:
            return result
        }
    }

    /// Like `samples(metric:since:tier:)`, but also surfaces the min/max
    /// band each `.hourly`/`.daily` rollup row already stores alongside its
    /// average — the Dashboard's detail charts want to draw a min/max band
    /// around the average line, which the plain `avg`-only `samples` method
    /// has no way to express. Added as a new method rather than changing
    /// `samples`'s return shape so existing callers (`AlertsPane`, the
    /// dropdown's chart) keep compiling against the tuple shape they
    /// already depend on.
    ///
    /// **`.raw` tier:** `sample_raw` has no `min_value`/`max_value` columns
    /// — each row already IS a single reading, so there's no band to
    /// surface. Rather than force every caller to special-case `.raw`, this
    /// returns the same value for `min`/`avg`/`max` in that case (a
    /// zero-width band), which is both the mathematically honest answer (a
    /// single sample's min, average, and max are all itself) and lets a
    /// caller draw the band unconditionally without an `if tier == .raw`
    /// branch. Callers that actually want a meaningful band should prefer
    /// `.hourly`/`.daily`.
    public func samplesWithRange(
        metric: String,
        since: Date,
        tier: Tier
    ) -> [(timestamp: Date, min: Double, avg: Double, max: Double)] {
        guard let dbQueue else { return [] }
        let sinceEpoch = since.timeIntervalSince1970

        do {
            return try dbQueue.read { db -> [(timestamp: Date, min: Double, avg: Double, max: Double)] in
                let rows: [Row]
                switch tier {
                case .raw:
                    rows = try Row.fetchAll(
                        db,
                        sql: "SELECT ts AS x, value AS avg FROM sample_raw WHERE metric = ? AND ts >= ? ORDER BY ts ASC",
                        arguments: [metric, sinceEpoch]
                    )
                case .hourly:
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT hour_start AS x, min_value AS lo, max_value AS hi, avg_value AS avg
                        FROM sample_hourly WHERE metric = ? AND hour_start >= ? ORDER BY hour_start ASC
                        """,
                        arguments: [metric, sinceEpoch]
                    )
                case .daily:
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT day_start AS x, min_value AS lo, max_value AS hi, avg_value AS avg
                        FROM sample_daily WHERE metric = ? AND day_start >= ? ORDER BY day_start ASC
                        """,
                        arguments: [metric, sinceEpoch]
                    )
                }
                // Safe against a future migration relaxing NOT NULL on these
                // columns, same reasoning as `samples(metric:since:tier:)`:
                // decode as optionals and skip rather than risk a trap on a
                // GRDB non-optional Row subscript.
                return rows.compactMap { row -> (timestamp: Date, min: Double, avg: Double, max: Double)? in
                    guard let x: Double = row["x"], let avg: Double = row["avg"] else { return nil }
                    switch tier {
                    case .raw:
                        return (timestamp: Date(timeIntervalSince1970: x), min: avg, avg: avg, max: avg)
                    case .hourly, .daily:
                        guard let lo: Double = row["lo"], let hi: Double = row["hi"] else { return nil }
                        return (timestamp: Date(timeIntervalSince1970: x), min: lo, avg: avg, max: hi)
                    }
                }
            }
        } catch {
            Self.logger.error("Failed to read \(metric, privacy: .public) ranged samples: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func tier(for since: Date) -> Tier {
        let range = Date().timeIntervalSince(since)
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86400
        if range < 48 * hour {
            return .raw
        } else if range < 90 * day {
            return .hourly
        } else {
            return .daily
        }
    }

    // MARK: - Metric flattening (Appendix A naming)

    /// Only fields with a straightforward single-`Double` representation and
    /// an exact Appendix A metric ID are included. Excluded, deliberately:
    /// - String fields (`adapterDescription`, `wifiSSID`, `localIPAddress`, ...)
    /// - Array fields (`cellVoltagesMV`, `perCorePercent`, `fanRPMs`) — the
    ///   long-and-narrow `(metric, value)` schema wants one row per scalar,
    ///   and per-element metric IDs (e.g. `cpu.core.{n}_percent`) are left
    ///   for a later pass rather than invented here.
    /// - Any field the plan's Appendix A doesn't already name (e.g.
    ///   `BatteryStats.isCharging`, `MemoryStats.totalBytes`,
    ///   `GPUStats.vramAllocatedBytes`) — inventing a metric ID isn't this
    ///   task's call to make; see the task report for the full list.
    static func metricPairs(for snapshot: SystemSnapshot) -> [(String, Double)] {
        var pairs: [(String, Double)] = []
        if let battery = snapshot.battery { pairs += batteryPairs(battery) }
        if let cpu = snapshot.cpu { pairs += cpuPairs(cpu) }
        if let gpu = snapshot.gpu { pairs += gpuPairs(gpu) }
        if let ane = snapshot.ane { pairs += anePairs(ane) }
        if let memory = snapshot.memory { pairs += memoryPairs(memory) }
        if let disk = snapshot.disk { pairs += diskPairs(disk) }
        if let network = snapshot.network { pairs += networkPairs(network) }
        if let thermal = snapshot.thermal { pairs += thermalPairs(thermal) }
        return pairs
    }

    private static func batteryPairs(_ b: BatteryStats) -> [(String, Double)] {
        var pairs: [(String, Double)] = [("battery.charge_percent", b.chargePercent)]
        if let v = b.chargingWatts { pairs.append(("battery.charging_watts", v)) }
        if let v = b.systemPowerInWatts { pairs.append(("battery.system_power_watts", v)) }
        if let v = b.adapterRatedWatts { pairs.append(("battery.adapter_watts", Double(v))) }
        if let v = b.voltageMV { pairs.append(("battery.voltage_mv", Double(v))) }
        if let v = b.amperageMA { pairs.append(("battery.amperage_ma", Double(v))) }
        if let v = b.cycleCount { pairs.append(("battery.cycle_count", Double(v))) }
        if let v = b.fullChargeCapacityMAh { pairs.append(("battery.full_charge_capacity_mah", Double(v))) }
        if let v = b.healthPercent { pairs.append(("battery.health_percent", v)) }
        if let v = b.temperatureCelsius { pairs.append(("battery.temperature_c", v)) }
        if let v = b.timeToFullMinutes { pairs.append(("battery.time_to_full_min", Double(v))) }
        if let v = b.timeToEmptyMinutes { pairs.append(("battery.time_to_empty_min", Double(v))) }
        return pairs
    }

    private static func cpuPairs(_ c: CPUStats) -> [(String, Double)] {
        var pairs: [(String, Double)] = [("cpu.total_percent", c.totalPercent)]
        if let v = c.ecorePercent { pairs.append(("cpu.ecore_percent", v)) }
        if let v = c.pcorePercent { pairs.append(("cpu.pcore_percent", v)) }
        if let v = c.effectiveFrequencyMHz { pairs.append(("cpu.frequency_mhz", v)) }
        if let v = c.packagePowerWatts { pairs.append(("cpu.power_watts", v)) }
        if let v = c.loadAverage1m { pairs.append(("cpu.load_avg_1m", v)) }
        if let v = c.processCount { pairs.append(("system.process_count", Double(v))) }
        return pairs
    }

    private static func gpuPairs(_ g: GPUStats) -> [(String, Double)] {
        var pairs: [(String, Double)] = []
        if let v = g.utilizationPercent { pairs.append(("gpu.utilization_percent", v)) }
        if let v = g.rendererPercent { pairs.append(("gpu.renderer_percent", v)) }
        if let v = g.tilerPercent { pairs.append(("gpu.tiler_percent", v)) }
        if let v = g.vramUsedBytes { pairs.append(("gpu.vram_used_bytes", Double(v))) }
        if let v = g.frequencyMHz { pairs.append(("gpu.frequency_mhz", v)) }
        if let v = g.powerWatts { pairs.append(("gpu.power_watts", v)) }
        return pairs
    }

    private static func anePairs(_ a: ANEStats) -> [(String, Double)] {
        var pairs: [(String, Double)] = []
        if let v = a.powerWatts { pairs.append(("ane.power_watts", v)) }
        if let v = a.isActive { pairs.append(("ane.active", v ? 1.0 : 0.0)) }
        return pairs
    }

    private static func memoryPairs(_ m: MemoryStats) -> [(String, Double)] {
        var pairs: [(String, Double)] = [
            ("memory.used_bytes", Double(m.usedBytes)),
            ("memory.wired_bytes", Double(m.wiredBytes)),
            ("memory.compressed_bytes", Double(m.compressedBytes)),
            ("memory.cached_bytes", Double(m.cachedBytes))
        ]
        if let v = m.swapUsedBytes { pairs.append(("memory.swap_used_bytes", Double(v))) }
        return pairs
    }

    private static func diskPairs(_ d: DiskStats) -> [(String, Double)] {
        var pairs: [(String, Double)] = [("disk.free_bytes", Double(d.freeBytes))]
        // disk.used_percent isn't a stored field — it's derived from
        // free/total, both of which are always present on DiskStats.
        if d.totalBytes > 0 {
            let usedPercent = (Double(d.totalBytes) - Double(d.freeBytes)) / Double(d.totalBytes) * 100
            pairs.append(("disk.used_percent", usedPercent))
        }
        if let v = d.readBytesPerSec { pairs.append(("disk.read_bytes_per_sec", v)) }
        if let v = d.writeBytesPerSec { pairs.append(("disk.write_bytes_per_sec", v)) }
        if let v = d.readIOPS { pairs.append(("disk.read_iops", v)) }
        if let v = d.writeIOPS { pairs.append(("disk.write_iops", v)) }
        return pairs
    }

    private static func networkPairs(_ n: NetworkStats) -> [(String, Double)] {
        var pairs: [(String, Double)] = [
            ("network.rx_bytes_per_sec", n.rxBytesPerSec),
            ("network.tx_bytes_per_sec", n.txBytesPerSec),
            ("network.rx_total_bytes", Double(n.rxSessionTotalBytes)),
            ("network.tx_total_bytes", Double(n.txSessionTotalBytes))
        ]
        if let v = n.wifiRSSIdBm { pairs.append(("network.wifi_rssi_dbm", Double(v))) }
        if let v = n.wifiTxRateMbps { pairs.append(("network.wifi_tx_rate_mbps", v)) }
        return pairs
    }

    private static func thermalPairs(_ t: ThermalStats) -> [(String, Double)] {
        var pairs: [(String, Double)] = [
            ("thermal.pressure_level", Double(pressureLevelCode(t.pressureLevel))),
            ("thermal.is_throttling", t.isThrottling ? 1.0 : 0.0)
        ]
        if let v = t.socTemperatureCelsius { pairs.append(("thermal.soc_temp_c", v)) }
        return pairs
    }

    /// `ThermalStats.PressureLevel` is a `String`-backed enum; `sample_raw`
    /// only stores `REAL` values, so it's encoded as an ordinal here
    /// (0 = nominal ... 3 = critical) rather than skipped.
    private static func pressureLevelCode(_ level: ThermalStats.PressureLevel) -> Int {
        switch level {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        }
    }
}

/// One row read back from `alert_log` — the future history pane's data
/// source (plan §11.3).
public struct AlertLogEntry: Equatable, Sendable {
    public let timestamp: Date
    public let ruleID: UUID
    public let ruleName: String
    public let metric: String
    public let value: Double
    public let delivered: Bool
    public let suppressed: Bool
}

/// How an attempted MCP tool call ended — the `outcome` column of
/// `agent_activity_log` (v5 migration, agent-session attribution pass).
/// Raw values are what's persisted, so, like `MCPToolID`'s raw values,
/// never rename one after shipping.
public enum AgentActivityOutcome: String, Codable, Sendable, CaseIterable, Equatable {
    /// The call was authorized and the reply carried a real result.
    case succeeded
    /// Refused by `MCPAccessController` (master switch / per-tool toggle
    /// off) or by the user declining the confirmation dialog.
    case denied
    /// Refused by the rate limiter specifically — split out from `denied`
    /// because "you're calling too fast" and "you're not allowed" are
    /// different findings for anyone auditing the log.
    case rateLimited = "rate_limited"
    /// Authorized and executed, but the reply carried an error instead of a
    /// result (bad arguments, no data available, encode failure, ...).
    case errored
}

/// One row of `agent_activity_log` — see `HistoryStore.logAgentActivity`.
/// The v5 columns default (`""`/`nil`/`.succeeded`) to what the migration
/// backfills for pre-v5 rows, so old rows and the old logging overload
/// produce identical values.
public struct AgentActivityEvent: Equatable, Sendable {
    public let timestamp: Date
    public let clientName: String
    public let tool: String
    /// Per-connection session UUID string; `""` means "unknown" (a pre-v5
    /// row, or a caller that predates the composite wire identity — see
    /// `AgentSessionIdentity`).
    public let sessionID: String
    /// Wall-clock authorize→reply time; `nil` when it wasn't measured.
    public let durationMs: Int?
    /// Short human-readable summary — never raw arguments (see
    /// `HistoryStore.logAgentActivity`'s doc comment).
    public let argsSummary: String?
    public let outcome: AgentActivityOutcome

    public init(
        timestamp: Date,
        clientName: String,
        tool: String,
        sessionID: String = "",
        durationMs: Int? = nil,
        argsSummary: String? = nil,
        outcome: AgentActivityOutcome = .succeeded
    ) {
        self.timestamp = timestamp
        self.clientName = clientName
        self.tool = tool
        self.sessionID = sessionID
        self.durationMs = durationMs
        self.argsSummary = argsSummary
        self.outcome = outcome
    }
}
