import Foundation

#if os(macOS)
import MCP

/// Maps the full `MCPToolID` tool surface (20 tools today; plan §13.3 named
/// the original 14, shared with `SentryKit`'s access-control layer) onto the
/// MCP SDK's `Tool` schema
/// type and dispatches `tools/call` requests to `SentryXPCServiceProtocol`.
/// Kept as its own file/namespace rather than inlined in a server's entry
/// point so the (fairly mechanical, but long) per-tool schema/dispatch pairs
/// don't bury the actual server bootstrapping.
///
/// **Why this lives in `SentryKit`, not the `SentryMCP` executable
/// target.** See `ResourceCatalog.swift`'s doc comment — this moved here for
/// the same reason: both the stdio transport (`SentryMCP/main.swift`) and
/// the in-app remote HTTP transport (`Sentry/App/MCPRemoteServer.swift`)
/// dispatch tool calls identically, through the same
/// `SentryXPCServiceProtocol`/`MCPAccessController` pipeline, regardless of
/// which transport carried the request in.
public enum MCPToolCatalog {

    // MARK: - Tool list (tools/list)

    public static let tools: [Tool] = MCPToolID.allCases.map { id in
        Tool(
            name: id.rawValue,
            description: agentFacingDescription(for: id),
            inputSchema: inputSchema(for: id),
            annotations: .init(
                title: id.displayName,
                readOnlyHint: !id.isWrite,
                destructiveHint: id == .createAlertRule,
                idempotentHint: !id.isWrite || id == .releaseAwake,
                openWorldHint: false
            )
        )
    }

    /// The description an MCP client's *model* reads when deciding whether
    /// and how to call a tool — prompt engineering, not documentation, so
    /// the agent-coordination tools get purpose-written copy here rather
    /// than `MCPToolID.toolDescription`'s one-liners (which stay as the
    /// short human-facing text in Settings → AI Access). Everything else
    /// falls through to the shared one-liner.
    private static func agentFacingDescription(for id: MCPToolID) -> String {
        switch id {
        case .preflightCheck:
            return """
            Ask this Mac whether now is a good time to start a heavy workload (build, test suite, \
            batch job, spawning subagents). Call it BEFORE starting sustained work. Returns a JSON \
            verdict you should act on: "proceed" (start now), "caution" (start, but expect reduced \
            performance or contention — reasons say why), "wait" (conditions will improve; if \
            suggestedWaitSeconds is a number, schedule a retry after that many seconds, otherwise \
            call wait_until_ready with condition "ready"), or "do_not_start" (waiting will NOT fix \
            it — e.g. battery critically low, thermal/memory pressure critical; tell the user \
            instead of retrying). Each reason has a stable code (thermal_critical, \
            thermal_elevated, cpu_saturated, on_battery_critical, on_battery_low, \
            memory_pressure_critical, memory_pressure, low_power_mode, another_agent_active) plus a \
            human sentence, and the snapshot object carries the raw numbers behind the verdict. \
            another_agent_active means other MCP sessions (self-reported names) are using this Mac \
            — advisory, not a lock; check get_agent_capacity before starting anyway.
            """
        case .getAgentCapacity:
            return """
            Whether this Mac has memory/CPU headroom for N more local agent processes, plus who \
            else is using it right now. Returns headroom (free memory, CPU headroom, a hasCapacity \
            heuristic with its arithmetic in reasoning), activeSessions (other MCP sessions: \
            client name, connected/last-call times, recently used tools, whether one holds a \
            keep-awake assertion), agentHeldKeepAwake, and a one-sentence judgment. Check this \
            before spawning subagents or starting a heavy workload, and prefer waiting when \
            another session is mid-heavy-workload — coordination here is advisory (Sentry informs, \
            it never locks), so being a good neighbor is on you. Session names are self-reported \
            labels, not authenticated identities.
            """
        case .waitUntilReady:
            return """
            Block (up to timeoutSeconds, capped at 600) until this Mac is ready for work, then \
            return what changed. Use condition "ready" to wait on the same policy preflight_check \
            uses — it returns exactly when preflight_check would stop saying "wait", so the two \
            can never disagree; narrower conditions (thermal_normal, cpu_below:N, battery_above:N, \
            memory_below:N) wait on a single metric instead. Prefer this over polling \
            preflight_check in a loop. Note it cannot help a "do_not_start" verdict (e.g. \
            critically low battery) — waiting doesn't fix those, so check preflight_check first.
            """
        default:
            return id.toolDescription
        }
    }

    private static func inputSchema(for id: MCPToolID) -> Value {
        switch id {
        case .getSystemSnapshot, .getBatteryStatus, .getThermalStatus,
             .getResourceUsage, .getDeviceInfo, .getSleepState, .releaseAwake,
             .preflightCheck:
            return .object(["type": .string("object"), "properties": .object([:])])

        case .getBatteryHealthHistory:
            return schema(properties: [
                "sinceDays": property("integer", "How many days of history to return, counting back from today.")
            ])

        case .getMetricHistory:
            return schema(
                properties: [
                    "metric": property("string", "A MetricID, e.g. \"cpu.total_percent\" or \"battery.charge_percent\"."),
                    "sinceSeconds": property("number", "How far back, in seconds, to query.")
                ],
                required: ["metric", "sinceSeconds"]
            )

        case .getAlertHistory:
            return schema(properties: [
                "limit": property("integer", "Maximum number of recent firings to return (default 50, max 500)."),
                "sinceSeconds": property("number", "How far back, in seconds, to filter firings. Omit for no time filter."),
                "ruleID": property("string", "UUID of a single alert rule to filter to. Omit for every rule.")
            ])

        case .keepAwake:
            return schema(
                properties: [
                    "mode": property("string", "One of: displayAndSystem, systemOnly, systemWhileOnAC."),
                    "durationSeconds": property("number", "Seconds until the assertion auto-releases. 0 or omitted means indefinite."),
                    "reason": property("string", "Human-readable reason shown in Sentry's UI.")
                ],
                required: ["mode"]
            )

        case .setRefreshInterval:
            return schema(
                properties: [
                    "tier": property("string", "One of: fast, medium, slow, process. fast/medium/slow control CPU/GPU/memory/network/disk, thermal/ANE, and battery polling respectively; process controls only the process-list refresh cadence (SystemSnapshot.topProcesses and process-scoped alert responsiveness) and, unlike the other three, resets to its 8s default on Sentry's next launch instead of persisting."),
                    "seconds": property("number", "New interval in seconds for that tier. Clamped per-tier: fast 0.5-30, medium 1-60, slow 5-60, process 2-60.")
                ],
                required: ["tier", "seconds"]
            )

        case .setAlertRuleEnabled:
            return schema(
                properties: [
                    "ruleID": property("string", "UUID of the alert rule (see get_alert_history / Sentry's Alerts pane)."),
                    "enabled": property("boolean", "Whether the rule should be enabled.")
                ],
                required: ["ruleID", "enabled"]
            )

        case .createAlertRule:
            return schema(
                properties: [
                    "ruleJSON": property(
                        "string",
                        "JSON object matching Sentry's AlertRule shape (minus id/isEnabled): name, metric, comparison (\"above\"|\"below\"|\"equals\"|\"changedBy\"), threshold, sustainedFor, cooldown, onlyWhen ([\"onBattery\"|\"charging\"|\"pluggedIn\"|\"displayAsleep\"]), actions (e.g. [{\"notification\":{\"title\":\"...\",\"body\":\"...\",\"sound\":false}}])."
                    )
                ],
                required: ["ruleJSON"]
            )

        case .getResourceEventsSince:
            return schema(
                properties: [
                    "sinceSeconds": property("number", "How far back, in seconds, to look for anomalous events.")
                ],
                required: ["sinceSeconds"]
            )

        case .getAgentCapacity:
            return schema(
                properties: [
                    "requestedAgents": property("integer", "How many additional local agent/subagent processes you're considering starting.")
                ],
                required: ["requestedAgents"]
            )

        case .getAgentActivity:
            return schema(properties: [
                "limit": property("integer", "Maximum number of recent MCP calls to return (default 50, max 200).")
            ])

        case .getSessionResourceReport:
            return schema(
                properties: [
                    "sinceSeconds": property("number", "How far back, in seconds, the session/job window started.")
                ],
                required: ["sinceSeconds"]
            )

        case .waitUntilReady:
            return schema(
                properties: [
                    "condition": property("string", "One of: ready (preflight_check's own policy — use this unless you need a single metric), thermal_normal, cpu_below:N, battery_above:N, memory_below:N (N is a percent)."),
                    "timeoutSeconds": property("number", "Maximum seconds to block for, capped at 600.")
                ],
                required: ["condition"]
            )
        }
    }

    private static func property(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static func schema(properties: [String: Value], required: [String] = []) -> Value {
        var object: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties)
        ]
        if !required.isEmpty {
            object["required"] = .array(required.map(Value.string))
        }
        return .object(object)
    }

    // MARK: - Dispatch (tools/call)

    public static func call(
        name: String,
        arguments: [String: Value],
        clientName: String,
        xpcClient: any MCPServiceCalling
    ) async -> CallTool.Result {
        guard let id = MCPToolID(rawValue: name) else {
            return errorResult("Unknown tool '\(name)'.")
        }

        switch id {
        case .getSystemSnapshot:
            return await read(xpcClient) { $0.getSystemSnapshot(clientName: clientName, reply: $1) }
        case .getBatteryStatus:
            return await read(xpcClient) { $0.getBatteryStatus(clientName: clientName, reply: $1) }
        case .getBatteryHealthHistory:
            let sinceDays = arguments["sinceDays"]?.intValue ?? 90
            return await read(xpcClient) { $0.getBatteryHealthHistory(clientName: clientName, sinceDays: sinceDays, reply: $1) }
        case .getMetricHistory:
            guard let metric = arguments["metric"]?.stringValue else {
                return errorResult("Missing required argument 'metric'.")
            }
            let sinceSeconds = arguments["sinceSeconds"]?.doubleValue ?? 3600
            return await read(xpcClient) { $0.getMetricHistory(clientName: clientName, metric: metric, sinceSeconds: sinceSeconds, reply: $1) }
        case .getThermalStatus:
            return await read(xpcClient) { $0.getThermalStatus(clientName: clientName, reply: $1) }
        case .getResourceUsage:
            return await read(xpcClient) { $0.getResourceUsage(clientName: clientName, reply: $1) }
        case .getAlertHistory:
            let limit = arguments["limit"]?.intValue ?? 50
            // `0`/`""` are the wire-level "no filter" sentinels `getAlertHistory`
            // documents — same "apply the actual default here, since the
            // @objc protocol requirement itself can't" pattern this file
            // already uses for `.getMetricHistory`'s `sinceSeconds`.
            let sinceSeconds = arguments["sinceSeconds"]?.doubleValue ?? 0
            let ruleID = arguments["ruleID"]?.stringValue ?? ""
            return await read(xpcClient) { $0.getAlertHistory(clientName: clientName, limit: limit, sinceSeconds: sinceSeconds, ruleID: ruleID, reply: $1) }
        case .getDeviceInfo:
            return await read(xpcClient) { $0.getDeviceInfo(clientName: clientName, reply: $1) }
        case .getSleepState:
            return await read(xpcClient) { $0.getSleepState(clientName: clientName, reply: $1) }

        case .preflightCheck:
            return await read(xpcClient) { $0.preflightCheck(clientName: clientName, reply: $1) }
        case .getResourceEventsSince:
            let sinceSeconds = arguments["sinceSeconds"]?.doubleValue ?? 3600
            return await read(xpcClient) { $0.getResourceEventsSince(clientName: clientName, sinceSeconds: sinceSeconds, reply: $1) }
        case .getAgentCapacity:
            let requestedAgents = arguments["requestedAgents"]?.intValue ?? 1
            return await read(xpcClient) { $0.getAgentCapacity(clientName: clientName, requestedAgents: requestedAgents, reply: $1) }
        case .getAgentActivity:
            let limit = arguments["limit"]?.intValue ?? 50
            return await read(xpcClient) { $0.getAgentActivity(clientName: clientName, limit: limit, reply: $1) }
        case .getSessionResourceReport:
            let sinceSeconds = arguments["sinceSeconds"]?.doubleValue ?? 3600
            return await read(xpcClient) { $0.getSessionResourceReport(clientName: clientName, sinceSeconds: sinceSeconds, reply: $1) }
        case .waitUntilReady:
            guard let condition = arguments["condition"]?.stringValue else {
                return errorResult("Missing required argument 'condition'.")
            }
            let timeoutSeconds = arguments["timeoutSeconds"]?.doubleValue ?? 120
            return await read(xpcClient) { $0.waitUntilReady(clientName: clientName, condition: condition, timeoutSeconds: timeoutSeconds, reply: $1) }

        case .keepAwake:
            guard let mode = arguments["mode"]?.stringValue else {
                return errorResult("Missing required argument 'mode'.")
            }
            let durationSeconds = arguments["durationSeconds"]?.doubleValue ?? 0
            let reason = arguments["reason"]?.stringValue ?? ""
            return await write(xpcClient) { $0.keepAwake(clientName: clientName, mode: mode, durationSeconds: durationSeconds, reason: reason, reply: $1) }
        case .releaseAwake:
            return await write(xpcClient) { $0.releaseAwake(clientName: clientName, reply: $1) }
        case .setRefreshInterval:
            guard let tier = arguments["tier"]?.stringValue, let seconds = arguments["seconds"]?.doubleValue else {
                return errorResult("Missing required arguments 'tier' and/or 'seconds'.")
            }
            return await write(xpcClient) { $0.setRefreshInterval(clientName: clientName, tier: tier, seconds: seconds, reply: $1) }
        case .setAlertRuleEnabled:
            guard let ruleID = arguments["ruleID"]?.stringValue, let enabled = arguments["enabled"]?.boolValue else {
                return errorResult("Missing required arguments 'ruleID' and/or 'enabled'.")
            }
            return await write(xpcClient) { $0.setAlertRuleEnabled(clientName: clientName, ruleID: ruleID, enabled: enabled, reply: $1) }
        case .createAlertRule:
            guard let ruleJSONString = arguments["ruleJSON"]?.stringValue,
                  let ruleJSON = ruleJSONString.data(using: .utf8) else {
                return errorResult("Missing or invalid required argument 'ruleJSON'.")
            }
            return await write(xpcClient) { $0.createAlertRule(clientName: clientName, ruleJSON: ruleJSON, reply: $1) }
        }
    }

    // MARK: - Result shaping

    private static func read(
        _ xpcClient: any MCPServiceCalling,
        _ body: @escaping (SentryXPCServiceProtocol, @escaping (Data?, String?) -> Void) -> Void
    ) async -> CallTool.Result {
        let (data, message) = await xpcClient.readCall(body)
        guard let data else {
            return errorResult(message ?? "Sentry denied this request.")
        }
        let text = String(data: data, encoding: .utf8) ?? "<undecodable response>"
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    }

    private static func write(
        _ xpcClient: any MCPServiceCalling,
        _ body: @escaping (SentryXPCServiceProtocol, @escaping (Bool, String?) -> Void) -> Void
    ) async -> CallTool.Result {
        let (ok, message) = await xpcClient.writeCall(body)
        if ok {
            return .init(content: [.text(text: "OK" + (message.map { " — \($0)" } ?? ""), annotations: nil, _meta: nil)], isError: false)
        }
        return errorResult(message ?? "Sentry denied this request.")
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}
#endif
