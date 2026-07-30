import Foundation

/// JSON-shaped DTOs that cross the `MacStatXPCServiceProtocol` boundary as
/// `Data`. Kept in `MacStatKit` (not `#if os(macOS)`-guarded, unlike the
/// protocol itself) so both sides of the connection — `MacStatXPCServiceProtocol`'s
/// implementation in `MacStat.app`, and `MacStatMCP`'s tool-call handlers —
/// decode/encode against the exact same typed shape rather than each hand-rolling
/// dictionary access against loosely-agreed JSON keys. None of these types are
/// `@objc` (they don't need to be — only the protocol methods themselves,
/// which pass them pre-encoded as `Data`, cross the XPC boundary directly).
public enum MCPPayloads {

    /// `get_resource_usage` (plan §13.3): "CPU/GPU/ANE/memory/disk/network in
    /// one call" — a purpose-built aggregate rather than making the caller
    /// stitch together `get_system_snapshot`'s unrelated battery/thermal
    /// fields itself.
    public struct ResourceUsage: Codable, Sendable {
        public var cpu: CPUStats?
        public var gpu: GPUStats?
        public var ane: ANEStats?
        public var memory: MemoryStats?
        public var disk: DiskStats?
        public var network: NetworkStats?
        public var timestamp: Date

        public init(cpu: CPUStats?, gpu: GPUStats?, ane: ANEStats?, memory: MemoryStats?, disk: DiskStats?, network: NetworkStats?, timestamp: Date) {
            self.cpu = cpu
            self.gpu = gpu
            self.ane = ane
            self.memory = memory
            self.disk = disk
            self.network = network
            self.timestamp = timestamp
        }
    }

    /// One point of `get_metric_history`'s series.
    public struct MetricHistoryPoint: Codable, Sendable {
        public var timestamp: Date
        public var value: Double

        public init(timestamp: Date, value: Double) {
            self.timestamp = timestamp
            self.value = value
        }
    }

    /// `get_battery_health_history`: "Daily health/cycle series over a date
    /// range" (plan §13.3) — health percent and cycle count are two separate
    /// `sample_daily` metrics (`battery.health_percent`,
    /// `battery.cycle_count`), joined here by day so a caller gets one row
    /// per day rather than two parallel arrays to zip itself.
    public struct BatteryHealthHistoryPoint: Codable, Sendable {
        public var date: Date
        public var healthPercent: Double?
        public var cycleCount: Int?

        public init(date: Date, healthPercent: Double?, cycleCount: Int?) {
            self.date = date
            self.healthPercent = healthPercent
            self.cycleCount = cycleCount
        }
    }

    /// Codable mirror of `AlertLogEntry` (`MacStatKit/Persistence/HistoryStore.swift`),
    /// which is deliberately not itself `Codable` (it's an internal read-path
    /// return type, not a persisted/wire format) — this is the one place
    /// that needs it to cross a boundary, so the DTO lives here rather than
    /// adding a conformance to `AlertLogEntry` for a single caller.
    public struct AlertHistoryEntry: Codable, Sendable {
        public var timestamp: Date
        public var ruleID: UUID
        public var ruleName: String
        public var metric: String
        public var value: Double
        public var delivered: Bool
        public var suppressed: Bool

        public init(timestamp: Date, ruleID: UUID, ruleName: String, metric: String, value: Double, delivered: Bool, suppressed: Bool) {
            self.timestamp = timestamp
            self.ruleID = ruleID
            self.ruleName = ruleName
            self.metric = metric
            self.value = value
            self.delivered = delivered
            self.suppressed = suppressed
        }

        public init(_ entry: AlertLogEntry) {
            self.init(
                timestamp: entry.timestamp,
                ruleID: entry.ruleID,
                ruleName: entry.ruleName,
                metric: entry.metric,
                value: entry.value,
                delivered: entry.delivered,
                suppressed: entry.suppressed
            )
        }
    }

    /// `get_device_info` (plan §13.3): "Model, chip, OS, capabilities."
    public struct DeviceInfo: Codable, Sendable {
        public var deviceID: String
        public var modelIdentifier: String
        public var chipDescription: String
        public var osVersion: String
        public var macStatVersion: String
        /// Modules this Mac has data for right now — derived from which
        /// fields are actually populated on the latest snapshot rather than
        /// a hardcoded list, so a capability this build genuinely can't read
        /// (e.g. no GPU sample yet) isn't advertised as available.
        public var capableModules: [String]

        public init(deviceID: String, modelIdentifier: String, chipDescription: String, osVersion: String, macStatVersion: String, capableModules: [String]) {
            self.deviceID = deviceID
            self.modelIdentifier = modelIdentifier
            self.chipDescription = chipDescription
            self.osVersion = osVersion
            self.macStatVersion = macStatVersion
            self.capableModules = capableModules
        }
    }

    /// Body of `create_alert_rule`'s `ruleJSON` argument — every `AlertRule`
    /// field except `id` (minted server-side, never trusted from a caller —
    /// see `MacStatXPCServiceProtocol.createAlertRule`'s doc comment) and
    /// `isEnabled` (new rules from this tool always start enabled; a rule
    /// nobody wants active yet shouldn't be created via a "make a rule"
    /// call, it should be created and then toggled off via
    /// `set_alert_rule_enabled`).
    public struct NewAlertRule: Codable, Sendable {
        public var name: String
        public var metric: MetricID
        public var comparison: AlertRule.Comparison
        public var threshold: Double
        public var sustainedFor: TimeInterval
        public var cooldown: TimeInterval
        public var quietHours: AlertRule.QuietHours?
        public var onlyWhen: [AlertRule.Precondition]
        public var actions: [AlertAction]

        public init(
            name: String,
            metric: MetricID,
            comparison: AlertRule.Comparison,
            threshold: Double,
            sustainedFor: TimeInterval,
            cooldown: TimeInterval,
            quietHours: AlertRule.QuietHours? = nil,
            onlyWhen: [AlertRule.Precondition] = [],
            actions: [AlertAction]
        ) {
            self.name = name
            self.metric = metric
            self.comparison = comparison
            self.threshold = threshold
            self.sustainedFor = sustainedFor
            self.cooldown = cooldown
            self.quietHours = quietHours
            self.onlyWhen = onlyWhen
            self.actions = actions
        }

        /// Materializes a real `AlertRule` with a freshly-minted `id` and
        /// `isEnabled: true` — see the type doc comment for why both are
        /// deliberately not caller-controlled.
        public func makeAlertRule() -> AlertRule {
            AlertRule(
                name: name,
                isEnabled: true,
                metric: metric,
                comparison: comparison,
                threshold: threshold,
                sustainedFor: sustainedFor,
                cooldown: cooldown,
                quietHours: quietHours,
                onlyWhen: onlyWhen,
                actions: actions
            )
        }
    }
}
