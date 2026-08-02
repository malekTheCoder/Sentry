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

    /// One line of `macstat watch --metric <id>`'s newline-delimited JSON
    /// stream (plan §21.2.1's last row).
    ///
    /// **Why this lives here rather than in the CLI target.** §21.2.1's
    /// standing rule for the whole CLI is "the *same* schema as the MCP
    /// `get_*` tool results — one Codable model serialized two ways, not two
    /// models drifting apart." No MCP tool streams a single metric today, so
    /// there was no existing model to reuse; putting the new one in the
    /// CLI's own target would have guaranteed the drift the rule exists to
    /// prevent the moment a `stream_metric` tool is added. It sits beside
    /// `MetricHistoryPoint` — which is the same idea sampled from
    /// `HistoryStore` instead of live, and which deliberately stays a bare
    /// `{timestamp, value}` because its `metric` and `unit` are already
    /// implied by the request that returned the array. A stream has no
    /// enclosing array to carry that context, so each line restates it;
    /// `jq` over a mixed stream needs it, and so does a human reading a
    /// scrollback.
    ///
    /// **`value` is nullable and `available` exists.** They are not
    /// redundant. `value: null` alone would leave a consumer unable to
    /// distinguish "this Mac cannot report GPU power" from "the JSON shape
    /// changed"; `available: false` states it. What neither field will ever
    /// do is report `0` for a metric this Mac can't read — the reason
    /// `SystemSnapshot`'s sub-structs are optional in the first place, and
    /// the reason a watch stream is worth trusting in a log.
    public struct MetricSample: Codable, Sendable {
        /// The sampling time of the snapshot this value came from — the
        /// app's, not the CLI's. A stream stitched together from these is
        /// therefore a series of real observation times, which is what
        /// makes it usable as evidence after the fact.
        public var timestamp: Date
        /// `MetricID` raw value, e.g. `"cpu.total_percent"`.
        public var metric: String
        /// `MetricUnit` raw value, e.g. `"percent"` — restated per line so a
        /// consumer never has to hold a lookup table of metric→unit.
        public var unit: String
        public var value: Double?
        public var available: Bool
        /// Seconds between this sample and the previous one, as actually
        /// used. Not simply `--interval` echoed back: `macstat watch` widens
        /// its own interval when the app's MCP rate limiter pushes back (see
        /// `MacStatCLI/main.swift`), and a stream that silently changed
        /// cadence while claiming a fixed one would be misleading in exactly
        /// the way this whole type is built to avoid. `nil` on the first
        /// sample, which has no predecessor.
        public var intervalSeconds: Double?

        public init(
            timestamp: Date,
            metric: String,
            unit: String,
            value: Double?,
            available: Bool,
            intervalSeconds: Double?
        ) {
            self.timestamp = timestamp
            self.metric = metric
            self.unit = unit
            self.value = value
            self.available = available
            self.intervalSeconds = intervalSeconds
        }

        enum CodingKeys: String, CodingKey {
            case timestamp, metric, unit, value, available, intervalSeconds
        }

        /// Hand-written for one reason: the synthesized encoder **omits** a
        /// nil `Optional` key entirely rather than writing `null`, and that
        /// is the wrong shape for exactly the case this type cares most
        /// about.
        ///
        /// A consumer walking a stream with `jq '.value'` gets `null` from a
        /// missing key and `null` from an explicit null, so the difference
        /// looks academic — until you consider what a *missing* key means to
        /// someone reading the raw line, or to a strict schema, or to a
        /// column-oriented loader: it reads as "this version of the tool
        /// didn't have that field," not "this Mac couldn't answer." Those
        /// are different claims and only one of them is true. `encodeNil`
        /// makes the unavailability explicit and on the record.
        ///
        /// `intervalSeconds` keeps the omit-when-nil behavior, and that
        /// asymmetry is deliberate rather than an oversight: its nil means
        /// "there was no previous sample to measure from," which is a
        /// property of the sample's position in the stream, not a failed
        /// reading. There is nothing to state.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(metric, forKey: .metric)
            try container.encode(unit, forKey: .unit)
            if let value {
                try container.encode(value, forKey: .value)
            } else {
                try container.encodeNil(forKey: .value)
            }
            try container.encode(available, forKey: .available)
            try container.encodeIfPresent(intervalSeconds, forKey: .intervalSeconds)
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

    /// `wait_until_ready`'s result — whether `WaitCondition` was satisfied
    /// before the (capped) timeout, how long the call actually blocked, and
    /// the snapshot the decision was made against, so a caller doesn't need
    /// a follow-up `get_system_snapshot` call just to see what changed.
    public struct WaitResult: Codable, Sendable {
        public var satisfied: Bool
        public var timedOut: Bool
        public var waitedSeconds: Double
        public var finalSnapshot: SystemSnapshot

        public init(satisfied: Bool, timedOut: Bool, waitedSeconds: Double, finalSnapshot: SystemSnapshot) {
            self.satisfied = satisfied
            self.timedOut = timedOut
            self.waitedSeconds = waitedSeconds
            self.finalSnapshot = finalSnapshot
        }
    }

    /// `get_resource_events_since`: alert firings plus a peak/notable-value
    /// summary over the requested window, for an agent doing root-cause
    /// analysis on a flaky/failed run ("was anything anomalous on this
    /// machine recently").
    public struct ResourceEventsSummary: Codable, Sendable {
        public var since: Date
        public var alertFirings: [AlertHistoryEntry]
        public var peakSoCTemperatureCelsius: Double?
        public var peakCPUPercent: Double?
        public var peakMemoryPressurePercent: Double?
        public var minDiskFreeBytes: Double?
        public var anyThrottling: Bool

        public init(
            since: Date,
            alertFirings: [AlertHistoryEntry],
            peakSoCTemperatureCelsius: Double?,
            peakCPUPercent: Double?,
            peakMemoryPressurePercent: Double?,
            minDiskFreeBytes: Double?,
            anyThrottling: Bool
        ) {
            self.since = since
            self.alertFirings = alertFirings
            self.peakSoCTemperatureCelsius = peakSoCTemperatureCelsius
            self.peakCPUPercent = peakCPUPercent
            self.peakMemoryPressurePercent = peakMemoryPressurePercent
            self.minDiskFreeBytes = minDiskFreeBytes
            self.anyThrottling = anyThrottling
        }
    }

    /// `get_agent_capacity`: a rough go/no-go for starting `requestedAgents`
    /// more local processes, given current free memory and CPU headroom.
    /// Deliberately a heuristic, not a promise — `reasoning` explains the
    /// arithmetic so a model can sanity-check it rather than treat the
    /// boolean as gospel.
    public struct AgentCapacity: Codable, Sendable {
        public var requestedAgents: Int
        public var hasCapacity: Bool
        public var freeMemoryBytes: UInt64
        public var estimatedBytesPerAgent: UInt64
        public var cpuHeadroomPercent: Double
        public var reasoning: String

        public init(
            requestedAgents: Int,
            hasCapacity: Bool,
            freeMemoryBytes: UInt64,
            estimatedBytesPerAgent: UInt64,
            cpuHeadroomPercent: Double,
            reasoning: String
        ) {
            self.requestedAgents = requestedAgents
            self.hasCapacity = hasCapacity
            self.freeMemoryBytes = freeMemoryBytes
            self.estimatedBytesPerAgent = estimatedBytesPerAgent
            self.cpuHeadroomPercent = cpuHeadroomPercent
            self.reasoning = reasoning
        }
    }

    /// One row of `get_agent_activity` — a thin `Codable` mirror of
    /// `MCPActivityLogEntry` (which stays non-`Codable` on purpose, see its
    /// own doc comment) for the one call site that needs to cross the XPC
    /// boundary.
    public struct AgentActivityEntry: Codable, Sendable {
        public var timestamp: Date
        public var clientName: String
        public var tool: String
        public var argumentsSummary: String
        public var decision: String

        public init(timestamp: Date, clientName: String, tool: String, argumentsSummary: String, decision: String) {
            self.timestamp = timestamp
            self.clientName = clientName
            self.tool = tool
            self.argumentsSummary = argumentsSummary
            self.decision = decision
        }
    }

    /// `get_session_resource_report`: an approximate "cost of this run"
    /// summary over a wall-clock window — average/peak CPU, peak memory
    /// pressure, thermal excursions — computed from `HistoryStore` samples
    /// already being persisted for other reasons.
    public struct SessionResourceReport: Codable, Sendable {
        public var windowStart: Date
        public var windowEnd: Date
        public var averageCPUPercent: Double?
        public var peakCPUPercent: Double?
        public var peakSoCTemperatureCelsius: Double?
        public var secondsThrottling: Double
        public var peakMemoryPressurePercent: Double?
        public var alertsFired: Int

        public init(
            windowStart: Date,
            windowEnd: Date,
            averageCPUPercent: Double?,
            peakCPUPercent: Double?,
            peakSoCTemperatureCelsius: Double?,
            secondsThrottling: Double,
            peakMemoryPressurePercent: Double?,
            alertsFired: Int
        ) {
            self.windowStart = windowStart
            self.windowEnd = windowEnd
            self.averageCPUPercent = averageCPUPercent
            self.peakCPUPercent = peakCPUPercent
            self.peakSoCTemperatureCelsius = peakSoCTemperatureCelsius
            self.secondsThrottling = secondsThrottling
            self.peakMemoryPressurePercent = peakMemoryPressurePercent
            self.alertsFired = alertsFired
        }
    }
}
