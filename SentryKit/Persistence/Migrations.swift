import Foundation
import GRDB

/// Schema definition for `HistoryStore`'s `DatabaseQueue`, per plan §6.2. One
/// migration, registered once, run via `migrator.migrate(dbQueue)` — later
/// schema changes should be added as new `registerMigration` steps here
/// rather than editing `v1Schema`, so an existing user's database upgrades
/// in place instead of being recreated.
public enum Migrations {
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1Schema") { db in
            // Tier 1: raw samples. High frequency, short retention (48h, §6.3).
            try db.create(table: "sample_raw") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .double).notNull()
                t.column("metric", .text).notNull()
                t.column("value", .double).notNull()
                t.uniqueKey(["ts", "metric"])
            }
            try db.create(index: "idx_raw_metric_ts", on: "sample_raw", columns: ["metric", "ts"])

            // Tier 2: hourly rollups. min/max/avg/count per metric per hour,
            // retained 90 days (§6.3).
            try db.create(table: "sample_hourly") { t in
                t.column("hour_start", .double).notNull()
                t.column("metric", .text).notNull()
                t.column("min_value", .double).notNull()
                t.column("max_value", .double).notNull()
                t.column("avg_value", .double).notNull()
                t.column("sample_count", .integer).notNull()
                t.primaryKey(["hour_start", "metric"])
            }

            // Tier 3: daily rollups. Kept forever — this is the long-horizon
            // battery-health history the app is built around.
            try db.create(table: "sample_daily") { t in
                t.column("day_start", .double).notNull()
                t.column("metric", .text).notNull()
                t.column("min_value", .double).notNull()
                t.column("max_value", .double).notNull()
                t.column("avg_value", .double).notNull()
                t.column("sample_count", .integer).notNull()
                t.primaryKey(["day_start", "metric"])
            }

            // Discrete events, not time-series. Kept forever, tiny.
            try db.create(table: "battery_event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .double).notNull()
                t.column("kind", .text).notNull()
                t.column("payload_json", .text)
            }

            try db.create(table: "alert_log") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .double).notNull()
                t.column("rule_id", .text).notNull()
                t.column("metric", .text).notNull()
                t.column("value", .double).notNull()
                t.column("delivered", .integer).notNull().defaults(to: 0)
            }
        }

        // `AlertEngine` (plan §11) needs two more columns on `alert_log`
        // than v1Schema shipped with: a human-readable rule name (so the
        // future history pane doesn't have to cross-reference a possibly
        // since-deleted/renamed `AlertRule` just to render a list), and a
        // `suppressed` flag for the §11.3 global rate cap — a firing that
        // exceeded the cap is still recorded (never silently dropped, so
        // the history pane can show "6 more alerts were suppressed") but
        // wasn't actually delivered as a notification. `ALTER TABLE ADD
        // COLUMN` rather than recreating the table, per this file's own
        // rule: v1Schema already shipped and must not be edited.
        migrator.registerMigration("v2AlertLogColumns") { db in
            try db.alter(table: "alert_log") { t in
                t.add(column: "rule_name", .text).notNull().defaults(to: "")
                t.add(column: "suppressed", .integer).notNull().defaults(to: 0)
            }
        }

        // AI-agent-integration pass (see Sentry-AI-Features-Research.md
        // item #15): a durable log of executed write-tool MCP calls, so the
        // Dashboard's "agent activity" panel can answer "was an agent
        // active recently" over a real window (days/weeks) instead of only
        // the session-scoped, in-memory `MCPActivityLog` (which is what
        // powers the live dropdown/AI-Access-pane views and intentionally
        // does not persist — see its own doc comment). Kept forever, same
        // as `alert_log`: this is a discrete-event log, not a time series,
        // and volume is inherently low (only *executed* write-tool calls,
        // not every read).
        migrator.registerMigration("v3AgentActivityLog") { db in
            try db.create(table: "agent_activity_log") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .double).notNull()
                t.column("client_name", .text).notNull()
                t.column("tool", .text).notNull()
            }
            try db.create(index: "idx_agent_activity_ts", on: "agent_activity_log", columns: ["ts"])
        }

        // Persistence audit: `HistoryStore.samples`/`samplesWithRange` query
        // the rollup tiers with `WHERE metric = ? AND hour_start >= ?`, but
        // the only index those tables had was the composite primary key
        // `(hour_start, metric)` — leading column wrong for that shape, so
        // SQLite range-scans *every* metric's rows in the window and filters
        // (verified via EXPLAIN QUERY PLAN: `(hour_start>?)` before, `(metric=?
        // AND hour_start>?)` after). `sample_raw` already had the right-shaped
        // `idx_raw_metric_ts` from v1; these give the hourly/daily tiers —
        // one of which grows forever — the same treatment. Purely additive.
        migrator.registerMigration("v4RollupMetricIndexes") { db in
            try db.create(index: "idx_hourly_metric_hour", on: "sample_hourly", columns: ["metric", "hour_start"])
            try db.create(index: "idx_daily_metric_day", on: "sample_daily", columns: ["metric", "day_start"])
        }

        // Agent-session attribution pass: v3's three-column log can say *that*
        // a tool ran but not which connection ran it, how long it took, or
        // whether it actually executed — which is exactly what
        // `AgentSessionReport` (SentryKit/Services/AgentSessionReport.swift)
        // needs to correlate a session against battery/thermal history.
        //   - `session_id`: per-connection UUID (see `MCPClientIdentity` /
        //     `AgentSessionIdentity`). NOT NULL with '' default so v3-era rows
        //     read back as "unknown session" rather than tripping decode.
        //   - `duration_ms`: wall-clock authorize→reply time; NULL for rows
        //     written by the pre-v5 overload, which never measured it.
        //   - `args_summary`: a SHORT human-readable summary (same string the
        //     confirmation dialog shows, sanitized/capped) — never raw
        //     arguments; NULL for pre-v5 rows.
        //   - `outcome`: one of succeeded/denied/rate_limited/errored (see
        //     `AgentActivityOutcome`). Pre-v5 rows were only written for
        //     executed calls, so 'succeeded' is the honest backfill default.
        // `ALTER TABLE ADD COLUMN`, never editing v3, per this file's rule.
        // The `(session_id, ts)` index serves `AgentSessionReport`'s
        // per-session queries the same way v4's indexes serve the rollup
        // tiers: leading column matches the WHERE shape.
        migrator.registerMigration("v5AgentActivitySessionColumns") { db in
            try db.alter(table: "agent_activity_log") { t in
                t.add(column: "session_id", .text).notNull().defaults(to: "")
                t.add(column: "duration_ms", .integer)
                t.add(column: "args_summary", .text)
                t.add(column: "outcome", .text).notNull().defaults(to: "succeeded")
            }
            try db.create(index: "idx_agent_activity_session", on: "agent_activity_log", columns: ["session_id", "ts"])
        }

        return migrator
    }
}
