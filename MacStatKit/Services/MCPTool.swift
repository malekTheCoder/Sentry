import Foundation

/// Stable identifier for every tool the MCP server (plan §13) can expose,
/// shared by three call sites that all must agree on the same 14-tool
/// surface: `MCPAccessController` (authorization decisions), the AI Access
/// settings pane (per-tool toggles), and `MacStatMCP`'s tool registration
/// (`ListTools`/`CallTool` handlers). A single enum, rather than three
/// independently-typed string constants, is what keeps those three from
/// drifting — adding a tool here is a compiler-enforced checklist for the
/// other two (an exhaustive `switch` anywhere on this type stops compiling).
///
/// Raw values match plan §13.3's tool names exactly — they're what actually
/// crosses the XPC boundary (`clientName`/tool identification) and what an
/// MCP client sees in `tools/list`, so, like `MetricID`, **never rename a
/// case's raw value after shipping.**
public enum MCPToolID: String, CaseIterable, Codable, Sendable, Hashable {

    // MARK: - Read tools (plan §13.3, "safe, enabled by default")

    case getSystemSnapshot = "get_system_snapshot"
    case getBatteryStatus = "get_battery_status"
    case getBatteryHealthHistory = "get_battery_health_history"
    case getMetricHistory = "get_metric_history"
    case getThermalStatus = "get_thermal_status"
    case getResourceUsage = "get_resource_usage"
    case getAlertHistory = "get_alert_history"
    case getDeviceInfo = "get_device_info"
    case getSleepState = "get_sleep_state"

    // MARK: - Read tools (AI-agent-integration pass — see MacStat-AI-Features-Research.md)

    /// One-shot "is now a good time" recommendation — see `SystemAdvisor`.
    case preflightCheck = "preflight_check"
    /// Correlates recent alert firings with the metric history around them,
    /// for an agent asking "was anything anomalous on this machine recently."
    case getResourceEventsSince = "get_resource_events_since"
    /// Headroom heuristic for "do I have room to start N more local agent
    /// processes."
    case getAgentCapacity = "get_agent_capacity"
    /// Exposes `MCPActivityLog`'s existing ring buffer as a tool, so an agent
    /// (or a user reading the transcript) can see recent MCP call history.
    case getAgentActivity = "get_agent_activity"
    /// Aggregated avg/peak CPU/memory/thermal "cost" of a time window, framed
    /// as a session report.
    case getSessionResourceReport = "get_session_resource_report"

    // MARK: - Write tools (plan §13.4, "each individually gated, off by default")

    case keepAwake = "keep_awake"
    case releaseAwake = "release_awake"
    case setRefreshInterval = "set_refresh_interval"
    case setAlertRuleEnabled = "set_alert_rule_enabled"
    case createAlertRule = "create_alert_rule"
    /// Blocks the call (up to a capped timeout) until a condition holds —
    /// see `WaitCondition`. Classified as a write tool, off by default,
    /// because it can stall a calling agent's turn even though it never
    /// mutates any MacStat state — the same "off by default" posture plan
    /// §13.4 gives every tool with a user-perceptible side effect.
    case waitUntilReady = "wait_until_ready"

    /// The complete surface, split by plan §13.3's own grouping. Order
    /// matters only for UI presentation (`AIAccessPane` renders read tools
    /// above write tools, matching the plan's two tables) — `CaseIterable`'s
    /// synthesized order already follows declaration order above, so this is
    /// just documentation of that fact, not a separate ordering to keep in
    /// sync.
    public static var readTools: [MCPToolID] {
        allCases.filter { !$0.isWrite }
    }

    public static var writeTools: [MCPToolID] {
        allCases.filter(\.isWrite)
    }

    /// Plan §13.4: write tools "off by default." Read tools default on
    /// (plan §13.3: "safe, enabled by default") — this is the one place that
    /// distinction is encoded, and both `AppSettings.default` and
    /// `MCPAccessController.evaluate(tool:settings:)` read it from here
    /// rather than each hardcoding their own copy of "which 5 are writes."
    public var isWrite: Bool {
        switch self {
        case .getSystemSnapshot, .getBatteryStatus, .getBatteryHealthHistory,
             .getMetricHistory, .getThermalStatus, .getResourceUsage,
             .getAlertHistory, .getDeviceInfo, .getSleepState,
             .preflightCheck, .getResourceEventsSince, .getAgentCapacity,
             .getAgentActivity, .getSessionResourceReport:
            return false
        case .keepAwake, .releaseAwake, .setRefreshInterval,
             .setAlertRuleEnabled, .createAlertRule, .waitUntilReady:
            return true
        }
    }

    /// Plan §13.4's risk column, shown next to each write tool's toggle in
    /// `AIAccessPane` so "off by default" doesn't read as an arbitrary
    /// restriction — the user can see *why* `create_alert_rule` is a bigger
    /// ask than `release_awake`. `nil` for read tools, which the plan's own
    /// table doesn't rate (they're all "safe" by construction — no write
    /// path, nothing to rate).
    public var riskLabel: String? {
        switch self {
        case .createAlertRule:
            return "Medium"
        case .keepAwake, .releaseAwake, .setRefreshInterval, .setAlertRuleEnabled:
            return "Low"
        case .waitUntilReady:
            return "Low"
        default:
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .getSystemSnapshot: return "Get System Snapshot"
        case .getBatteryStatus: return "Get Battery Status"
        case .getBatteryHealthHistory: return "Get Battery Health History"
        case .getMetricHistory: return "Get Metric History"
        case .getThermalStatus: return "Get Thermal Status"
        case .getResourceUsage: return "Get Resource Usage"
        case .getAlertHistory: return "Get Alert History"
        case .getDeviceInfo: return "Get Device Info"
        case .getSleepState: return "Get Sleep State"
        case .preflightCheck: return "Preflight Check"
        case .getResourceEventsSince: return "Get Resource Events Since"
        case .getAgentCapacity: return "Get Agent Capacity"
        case .getAgentActivity: return "Get Agent Activity"
        case .getSessionResourceReport: return "Get Session Resource Report"
        case .keepAwake: return "Keep Awake"
        case .releaseAwake: return "Release Awake"
        case .setRefreshInterval: return "Set Refresh Interval"
        case .setAlertRuleEnabled: return "Enable/Disable Alert Rule"
        case .createAlertRule: return "Create Alert Rule"
        case .waitUntilReady: return "Wait Until Ready"
        }
    }

    public var toolDescription: String {
        switch self {
        case .getSystemSnapshot: return "Current values for all enabled metrics."
        case .getBatteryStatus: return "Detailed battery: charge, W in/out, health, cycles, adapter, charging diagnostics."
        case .getBatteryHealthHistory: return "Daily health/cycle series over a date range."
        case .getMetricHistory: return "Any metric, any range, with automatic tier selection."
        case .getThermalStatus: return "Temps, fans, thermal pressure, throttling state."
        case .getResourceUsage: return "CPU/GPU/ANE/memory/disk/network in one call."
        case .getAlertHistory: return "Recently fired alerts."
        case .getDeviceInfo: return "Model, chip, OS, capabilities."
        case .getSleepState: return "Current assertion state + expiry."
        case .preflightCheck: return "One-shot go/wait recommendation for starting a heavy job now (thermal, CPU, battery)."
        case .getResourceEventsSince: return "Alert firings + peak thermal/CPU/memory/disk values since a given time — for root-causing a failed/flaky run."
        case .getAgentCapacity: return "Whether this Mac has memory/CPU headroom for N more local agent processes."
        case .getAgentActivity: return "Recent MCP tool calls (client, tool, decision) — what agents have been asking this Mac for."
        case .getSessionResourceReport: return "Aggregated CPU/thermal/memory cost over a time window, framed as a session report."
        case .keepAwake: return "Start a sleep assertion with mode + duration."
        case .releaseAwake: return "Release the current sleep assertion."
        case .setRefreshInterval: return "Change polling cadence for a tier."
        case .setAlertRuleEnabled: return "Toggle an alert rule on or off."
        case .createAlertRule: return "Define a new alert rule."
        case .waitUntilReady: return "Block (capped) until a condition holds — e.g. thermal_normal, cpu_below:50 — then return what changed."
        }
    }

    /// Read tools ship enabled; write tools ship disabled. Used both by
    /// `AppSettings.default`'s `mcpEnabledToolIDs` and as the fallback
    /// `MCPAccessController` applies for a tool ID a hand-edited settings
    /// file simply omits — see that type's doc comment.
    public var enabledByDefault: Bool { !isWrite }
}
