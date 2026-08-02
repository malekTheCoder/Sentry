import Foundation

#if os(macOS)

/// Mach service name `MacStat.app` registers an `NSXPCListener` under (plan
/// §13.2). `MacStatMCP` connects to this exact string via
/// `NSXPCConnection(machServiceName:options:)` — it must match on both ends,
/// so it's hoisted here rather than duplicated as a string literal in both
/// `AppDelegate` and `MacStatMCP/main.swift`.
public enum MacStatXPCServiceName {
    public static let machService = "com.sentry.macstat.xpc"
}

/// The XPC contract between `MacStat.app` (which implements this protocol,
/// listening on `MacStatXPCServiceName.machService`) and `MacStatMCP` (which
/// connects as a client and calls it). This is the *entire* API surface the
/// spawned MCP binary has to the rest of the app — plan §13.2's architecture
/// diagram exists specifically so that binary never touches IOKit, SQLite, or
/// `StatsCoordinator`/`PowerControlService`/`HistoryStore`/`AlertEngine`
/// directly. If a capability isn't a method on this protocol, `MacStatMCP`
/// cannot do it, full stop — that's the enforcement mechanism for "one
/// sampling loop, one SQLite owner, permission gating lives in the app."
///
/// **Why every method carries `clientName` and returns `(Data?, String?)` /
/// `(Bool, String?)` rather than throwing:** `NSXPCConnection` requires an
/// `@objc` protocol, which means every parameter and return type must be
/// `@objc`-bridgeable — no Swift `Codable` structs, no `throws` (Objective-C
/// exceptions don't cross an XPC boundary the way Swift errors do; the
/// standard pattern is a reply block that carries either a value or an error
/// description). `Data` is `@objc`-bridgeable and is where every
/// already-`Codable` payload (`SystemSnapshot`, history rows, alert log
/// entries) gets JSON-encoded before crossing — the wire format is JSON, not
/// a bespoke binary layout, so a future non-Swift MCP host (unlikely, but
/// the JSON-RPC spec itself is language-agnostic) wouldn't need to
/// understand Swift's XPC coder to still make sense of a captured payload.
///
/// **`clientName` exists for the activity log and rate limiter, not for
/// authentication.** Plan §13.4 wants "client identity" in the activity log,
/// but there's no cryptographic identity to check here — any process that
/// can resolve this Mach service name can connect (this app ships
/// unsandboxed with `CODE_SIGNING_REQUIRED: NO`, so there's no
/// code-signing-based connection validation to add either). The real
/// security boundary is `MCPAccessController.evaluate(tool:settings:)` on
/// the app side, gating *what a connected client is allowed to do*, not
/// *who's allowed to connect*. `clientName` is a self-reported label
/// (`MacStatMCP` sends the MCP client's own `Implementation.name` from the
/// `initialize` handshake) purely so the activity log reads "Claude Desktop
/// asked for X" instead of an anonymous timestamp.
///
/// **Every method is independently gated.** `MCPXPCService`'s
/// implementation calls `MCPAccessController.evaluate(tool:settings:)` for
/// the corresponding `MCPToolID` before touching any real service, for
/// *every* method here — including the read tools. A denied call replies
/// with `(nil, "<reason>")` / `(false, "<reason>")`, never silently returns
/// stale/empty data, so `MacStatMCP` can surface the real reason ("MCP
/// access is disabled in MacStat Settings") to the calling agent instead of
/// a confusing empty result.
@objc public protocol MacStatXPCServiceProtocol {

    /// Cheap reachability/handshake check — lets `MacStatMCP` fail fast with
    /// a clear "MacStat isn't running" message instead of a bare connection
    /// timeout on its very first real tool call.
    func ping(reply: @escaping (Bool) -> Void)

    // MARK: - Read tools (plan §13.3)

    func getSystemSnapshot(clientName: String, reply: @escaping (Data?, String?) -> Void)
    func getBatteryStatus(clientName: String, reply: @escaping (Data?, String?) -> Void)
    /// - Parameter sinceDays: how many days of daily battery health/cycle
    ///   history to return, counting back from today.
    func getBatteryHealthHistory(clientName: String, sinceDays: Int, reply: @escaping (Data?, String?) -> Void)
    /// - Parameters:
    ///   - metric: a `MetricID` raw value (e.g. `"cpu.total_percent"`).
    ///   - sinceSeconds: how far back, in seconds from now, to query —
    ///     `HistoryStore.samples(metric:since:)`'s automatic tier selection
    ///     picks raw/hourly/daily based on this range.
    func getMetricHistory(clientName: String, metric: String, sinceSeconds: Double, reply: @escaping (Data?, String?) -> Void)
    func getThermalStatus(clientName: String, reply: @escaping (Data?, String?) -> Void)
    func getResourceUsage(clientName: String, reply: @escaping (Data?, String?) -> Void)
    func getAlertHistory(clientName: String, limit: Int, reply: @escaping (Data?, String?) -> Void)
    func getDeviceInfo(clientName: String, reply: @escaping (Data?, String?) -> Void)
    func getSleepState(clientName: String, reply: @escaping (Data?, String?) -> Void)

    // MARK: - AI-agent-integration read tools (see MacStat-AI-Features-Research.md)

    /// `preflight_check`: one-shot go/wait recommendation — see
    /// `SystemAdvisor.recommend`.
    func preflightCheck(clientName: String, reply: @escaping (Data?, String?) -> Void)
    /// `get_resource_events_since`: alert firings plus a peak-value summary
    /// over `[now - sinceSeconds, now]`.
    func getResourceEventsSince(clientName: String, sinceSeconds: Double, reply: @escaping (Data?, String?) -> Void)
    /// `get_agent_capacity`: headroom heuristic for `requestedAgents` more
    /// local processes.
    func getAgentCapacity(clientName: String, requestedAgents: Int, reply: @escaping (Data?, String?) -> Void)
    /// `get_agent_activity`: the last `limit` entries of `MCPActivityLog`.
    func getAgentActivity(clientName: String, limit: Int, reply: @escaping (Data?, String?) -> Void)
    /// `get_session_resource_report`: aggregated CPU/thermal/memory "cost"
    /// over `[now - sinceSeconds, now]`.
    func getSessionResourceReport(clientName: String, sinceSeconds: Double, reply: @escaping (Data?, String?) -> Void)

    // MARK: - Write tools (plan §13.4 — off by default, individually gated)

    /// - Parameters:
    ///   - mode: an `AwakeMode` raw value.
    ///   - durationSeconds: `0` means indefinite (mirrors
    ///     `PowerControlService.startAssertion`'s `duration: nil`).
    func keepAwake(clientName: String, mode: String, durationSeconds: Double, reason: String, reply: @escaping (Bool, String?) -> Void)
    func releaseAwake(clientName: String, reply: @escaping (Bool, String?) -> Void)
    /// - Parameters:
    ///   - tier: `"fast"`, `"medium"`, or `"slow"` — matches
    ///     `StatsCoordinator.Tier`'s cases.
    func setRefreshInterval(clientName: String, tier: String, seconds: Double, reply: @escaping (Bool, String?) -> Void)
    func setAlertRuleEnabled(clientName: String, ruleID: String, enabled: Bool, reply: @escaping (Bool, String?) -> Void)
    /// - Parameter ruleJSON: a JSON-encoded `AlertRule` (minus `id`, which
    ///   the app mints server-side — an agent proposing a rule shouldn't be
    ///   trusted to generate a collision-free UUID, and there's no reason to
    ///   ask it to).
    func createAlertRule(clientName: String, ruleJSON: Data, reply: @escaping (Bool, String?) -> Void)

    /// `wait_until_ready`: blocks (server-side, subscribing to
    /// `StatsCoordinator.snapshots()`) until `condition` (a `WaitCondition`
    /// raw string) is satisfied or `timeoutSeconds` elapses, then replies
    /// with a `MCPPayloads.WaitResult`. Uses the `(Data?, String?)` read-tool
    /// reply shape, not `(Bool, String?)`, because a caller needs the rich
    /// result (satisfied vs. timed out, how long it waited, the final
    /// snapshot) — the write-tool classification here is about risk
    /// (stalling the caller's turn), not about this method's reply shape.
    func waitUntilReady(clientName: String, condition: String, timeoutSeconds: Double, reply: @escaping (Data?, String?) -> Void)
}

#endif
