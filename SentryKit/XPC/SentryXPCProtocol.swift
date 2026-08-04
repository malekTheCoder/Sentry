import Foundation

#if os(macOS)

/// The well-known Mach service name for command-line access to Sentry.
///
/// **Correction, because this constant's doc comment was wrong for as long as
/// it existed.** It used to read "Mach service name `Sentry.app` registers an
/// `NSXPCListener` under". `Sentry.app` did call
/// `NSXPCListener(machServiceName:)` with it — and that call could never have
/// worked, because no launchd job anywhere in this project declared the name,
/// and only the process launchd starts as a job may vend that job's Mach
/// service. `NSXPCListener` reports a failed check-in nowhere, so the app
/// looked healthy and every client failed. See
/// `SentryKit/MCPBridge/MCPBridgeContract.swift` for the measurement and the
/// fix.
///
/// The name is now owned by `SentryMCPBridge`, an on-demand LaunchAgent that
/// brokers a direct connection to the app. **The string did not change**, and
/// that was a design goal: no MCP client config, no shell script, and no line
/// of `integrations/` documentation had to be rewritten to pick up the fix.
///
/// Pinned equal to `MCPBridgeNaming.machService` by `MCPBridgeNamingTests`.
/// The two are separate constants because `MCPBridgeNaming` is compiled into
/// the `SentryMCPBridge` tool target, which links no framework of ours; see
/// `project.yml`.
public enum SentryXPCServiceName {
    public static let machService = "dev.malekswilam.sentry.xpc"
}

/// The XPC contract between `Sentry.app` (which implements this protocol,
/// listening on `SentryXPCServiceName.machService`) and `SentryMCP` (which
/// connects as a client and calls it). This is the *entire* API surface the
/// spawned MCP binary has to the rest of the app — plan §13.2's architecture
/// diagram exists specifically so that binary never touches IOKit, SQLite, or
/// `StatsCoordinator`/`PowerControlService`/`HistoryStore`/`AlertEngine`
/// directly. If a capability isn't a method on this protocol, `SentryMCP`
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
/// (`SentryMCP` sends the MCP client's own `Implementation.name` from the
/// `initialize` handshake) purely so the activity log reads "Claude Desktop
/// asked for X" instead of an anonymous timestamp.
///
/// **Every method is independently gated.** `MCPXPCService`'s
/// implementation calls `MCPAccessController.evaluate(tool:settings:)` for
/// the corresponding `MCPToolID` before touching any real service, for
/// *every* method here — including the read tools. A denied call replies
/// with `(nil, "<reason>")` / `(false, "<reason>")`, never silently returns
/// stale/empty data, so `SentryMCP` can surface the real reason ("MCP
/// access is disabled in Sentry Settings") to the calling agent instead of
/// a confusing empty result.
@objc public protocol SentryXPCServiceProtocol {

    /// Cheap reachability/handshake check — lets `SentryMCP` fail fast with
    /// a clear "Sentry isn't running" message instead of a bare connection
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
    /// - Parameters:
    ///   - limit: maximum rows to return, clamped 1...500 by `MCPXPCService`.
    ///   - sinceSeconds: how far back, in seconds from now, to filter —
    ///     mirrors `getMetricHistory`'s `sinceSeconds` shape. `0` (not a
    ///     Swift default — `@objc` protocol requirements can't declare one;
    ///     see `MCPToolCatalog.call`'s `.getAlertHistory` case, which is
    ///     where the "0 means no filter" default is actually applied for a
    ///     caller who omitted the argument) means "no time filter", the
    ///     same "0 or omitted" convention `keepAwake`'s `durationSeconds`
    ///     already uses below.
    ///   - ruleID: an `AlertRule.id.uuidString` to filter to a single rule,
    ///     or `""` (same reasoning as `sinceSeconds` above) for "every rule".
    func getAlertHistory(clientName: String, limit: Int, sinceSeconds: Double, ruleID: String, reply: @escaping (Data?, String?) -> Void)
    func getDeviceInfo(clientName: String, reply: @escaping (Data?, String?) -> Void)
    func getSleepState(clientName: String, reply: @escaping (Data?, String?) -> Void)

    // MARK: - AI-agent-integration read tools (see Sentry-AI-Features-Research.md)

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
    /// over `[now - sinceSeconds, now]`, scoped to the calling connection's
    /// own session. Superseded by, and now forwards to, the
    /// `targetClientName` overload below with `targetClientName: ""` — kept
    /// as its own protocol requirement (rather than deleted) so no existing
    /// `@objc` caller across this boundary (`MCPToolCatalog`'s
    /// `get_session_resource_report` MCP tool dispatch, any external
    /// `SentryXPCServiceProtocol` conformance) has to change its selector.
    func getSessionResourceReport(clientName: String, sinceSeconds: Double, reply: @escaping (Data?, String?) -> Void)

    /// `sentryctl session-report --client=<name>` (CLI session-scoping pass):
    /// like `getSessionResourceReport` above, but can scope the report to one
    /// *other* self-reported MCP client's activity instead of the caller's
    /// own session — for a script that already knows which agent it cares
    /// about, typically piped straight from `sentryctl sessions`' output.
    ///
    /// Additive by construction: this is a new selector, not a change to the
    /// one above, so every existing caller keeps compiling and behaving
    /// exactly as before; only `sentryctl session-report`'s new `--client`
    /// flag calls this one directly.
    ///
    /// - Parameter targetClientName: the exact `clientName`
    ///   `SentryXPCServiceProtocol.listAgentSessions` (`sentryctl sessions`)
    ///   reports for the agent to scope to — see `AgentSessionRegistry`'s
    ///   doc comment for why that's a self-reported label, not an
    ///   authenticated identity, and why two clients sharing a name collapse
    ///   into one report here exactly as they do in `sentryctl sessions`.
    ///   `""` (same "0/empty means unset" convention as `getAlertHistory`'s
    ///   `ruleID` and `getResourceUsage`'s siblings above — `@objc` protocol
    ///   requirements can't declare a default) means "no target", falling
    ///   back to the caller's-own-session behavior of the method above.
    func getSessionResourceReport(clientName: String, sinceSeconds: Double, targetClientName: String, reply: @escaping (Data?, String?) -> Void)

    // MARK: - Write tools (plan §13.4 — off by default, individually gated)

    /// - Parameters:
    ///   - mode: an `AwakeMode` raw value.
    ///   - durationSeconds: `0` means indefinite (mirrors
    ///     `PowerControlService.startAssertion`'s `duration: nil`).
    func keepAwake(clientName: String, mode: String, durationSeconds: Double, reason: String, reply: @escaping (Bool, String?) -> Void)
    func releaseAwake(clientName: String, reply: @escaping (Bool, String?) -> Void)
    /// - Parameters:
    ///   - tier: `"fast"`, `"medium"`, `"slow"`, or `"process"` — matches
    ///     `StatsCoordinator.Tier`'s cases. `"process"` retunes the cadence
    ///     behind `SystemSnapshot.topProcesses`/process-scoped alerts (see
    ///     `StatsCoordinator.setProcessInterval(_:)`) and, unlike the other
    ///     three, is not persisted to `AppSettings` — it reverts to its
    ///     8s default on the next launch.
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

    // MARK: - Agent session management (headless equivalent of AIAccessPane's per-agent controls)

    /// `sentryctl sessions`: a snapshot of `AgentSessionRegistry.activeSessions`
    /// — the same active-session list `get_agent_capacity`'s `activeSessions`
    /// field is built from — reachable without an MCP client's own call
    /// muddying the very session list it would be asking about.
    ///
    /// **Deliberately not gated by `MCPAccessController.evaluate(tool:clientName:settings:)`.**
    /// Every method above corresponds to an `MCPToolID` case — one of plan
    /// §13's 14-tool surface an *MCP client* calls through `SentryMCP`. This
    /// method and `revokeAgentSession` below exist for a different caller
    /// entirely: `sentryctl`, a plain XPC client with no MCP handshake and no
    /// tool ID of its own (see `SentryCLI/main.swift`'s header comment). There
    /// is no per-tool toggle to check and no rate-limit budget to spend
    /// against, so there is nothing for `MCPAccessController` to gate here —
    /// this is read-only administrative visibility into state the GUI
    /// (`AIAccessPane`'s "Agents" section) already shows unconditionally
    /// whenever Sentry is running.
    func listAgentSessions(reply: @escaping (Data?, String?) -> Void)

    /// `sentryctl stop <client-name>`: the headless equivalent of
    /// `AIAccessPane`'s per-agent "Stop" button
    /// (`Sentry/Settings/Panes/AIAccessPane.swift`'s
    /// `setClientRevoked(_:revoked:)`) — same mechanism, different caller.
    /// Adds `clientName` to `AppSettings.agentGuardrails.revokedClientNames`
    /// and lets `AppDelegate.applySettings`'s existing settings sink release
    /// the held keep-awake assertion
    /// (`PowerControlService.releaseAgentAssertion(ownedBy:)`) and announce
    /// the revocation — this method does not talk to `PowerControlService`
    /// directly, so there is exactly one place (the settings sink) that ever
    /// performs that release, whether the flag was flipped by this call, the
    /// GUI button, or a hand-edited `settings.json`.
    ///
    /// - Parameter clientName: **the client to stop, not the caller's own
    ///   identity** — unlike every method above, there is nothing to log
    ///   this call under, so there is no separate "who is asking" parameter.
    ///   Self-reported, like every other client name on this boundary (see
    ///   this protocol's doc comment): stopping "Claude Desktop" only stops
    ///   whoever is currently claiming that name.
    /// - Parameter reply: `true` if `clientName` matched a currently active
    ///   session and was revoked; `false` with an explanatory message
    ///   otherwise (no such active client, or it was already stopped).
    func revokeAgentSession(clientName: String, reply: @escaping (Bool, String?) -> Void)
}

#endif
