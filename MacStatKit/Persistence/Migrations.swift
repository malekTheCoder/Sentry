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

        return migrator
    }
}
