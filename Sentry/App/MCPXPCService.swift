import Foundation
import SentryKit

#if os(macOS)
import AppKit

/// Implements `SentryXPCServiceProtocol` — the app-side half of plan
/// §13.2's XPC boundary. `AppDelegate` registers an `NSXPCListener` whose
/// `exportedObject` is one instance of this class; `SentryMCP` connects as
/// a client and calls its methods.
///
/// **This is the enforcement point, not `SentryMCP`.** Every method here
/// calls `authorize(tool:clientName:argumentsSummary:)` — which runs
/// `MCPAccessController.evaluate(tool:settings:)` against the *live*
/// `settingsStore.settings` — before touching `coordinator`/`powerControl`/
/// `historyStore`/`alertEngine` at all. A denied or not-yet-confirmed call
/// never reaches those four services; it gets a `(nil, "<reason>")` /
/// `(false, "<reason>")` reply instead. This is deliberate belt-and-braces
/// against the exact bug class called out in this task's brief: a write
/// tool that's "off by default" in Settings but executes anyway when called
/// would defeat the entire permission model plan §13.4 describes, and there
/// is no other checkpoint between an XPC message arriving and a real
/// `IOPMAssertionCreateWithProperties`/`AlertEngine.updateRules` call
/// happening — this method is it.
///
/// **Threading.** `NSXPCListener` dispatches incoming calls on queues of its
/// own choosing, not necessarily the main thread — but `settingsStore`,
/// `powerControl`, and `alertEngine` are all main-actor-isolated (matching
/// the rest of this app's composition root), and `MCPActivityLog` is too.
/// Every protocol method here is `nonisolated` and immediately hops onto
/// `Task { @MainActor in ... }` before touching any of that state, then
/// calls the XPC reply closure from within the hop — reply closures have no
/// actor affinity of their own, so calling one from `@MainActor` context is
/// fine. `StatsCoordinator` and `HistoryStore` are already internally
/// thread-safe (their own private serial queues), so their methods are
/// called directly without an additional hop.
@MainActor
final class MCPXPCService: NSObject, SentryXPCServiceProtocol {

    private let coordinator: StatsCoordinator
    private let historyStore: HistoryStore
    private let alertEngine: AlertEngine
    private let powerControl: PowerControlService
    private let settingsStore: SettingsStore
    private let accessController: MCPAccessController
    private let activityLog: MCPActivityLog
    /// Multi-agent coordination state (`get_agent_capacity`'s session list,
    /// `preflight_check`'s `another_agent_active` reason). Owned here rather
    /// than injected: this service's `authorize` path is the only place MCP
    /// calls flow through, so it is both the sole writer and (via the two
    /// tools above) the sole reader — see `AgentSessionRegistry`'s doc
    /// comment for the advisory/self-reported caveats.
    private let sessionRegistry = AgentSessionRegistry()

    init(
        coordinator: StatsCoordinator,
        historyStore: HistoryStore,
        alertEngine: AlertEngine,
        powerControl: PowerControlService,
        settingsStore: SettingsStore,
        accessController: MCPAccessController,
        activityLog: MCPActivityLog
    ) {
        self.coordinator = coordinator
        self.historyStore = historyStore
        self.alertEngine = alertEngine
        self.powerControl = powerControl
        self.settingsStore = settingsStore
        self.accessController = accessController
        self.activityLog = activityLog
    }

    // MARK: - Handshake

    nonisolated func ping(reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    // MARK: - Authorization (see type doc comment)

    /// Evaluates `MCPAccessController.evaluate(tool:settings:)` against the
    /// live settings, handles the `.requiresConfirmation` case by showing a
    /// native `NSAlert` and waiting for the user's choice, records the
    /// outcome to the activity log exactly once, and — only for a call that
    /// is actually going to execute — records it against the rate limiter.
    /// Returns `.allow` if (and only if) the caller should proceed.
    private func authorize(tool: MCPToolID, clientName: String, argumentsSummary: String) -> MCPAccessController.Decision {
        let settings = settingsStore.settings
        var decision = accessController.evaluate(tool: tool, settings: settings)

        // Conditional guardrails + termination controls (kill switch,
        // per-client revocation, battery floor, on-battery restriction,
        // quiet hours, thermal) — the pure engine in
        // `SentryKit/Services/AgentGuardrails.swift`, fed the live snapshot
        // the same way the permission model above is fed live settings.
        // Checked *before* the confirmation branch below on purpose: a call
        // a guardrail is going to deny must never put a confirmation dialog
        // in front of the user first — approving it would mean approving
        // something that then doesn't run, which is the dialog lying.
        if !decision.isDenied,
           case .deny(let reason) = AgentGuardrails.evaluate(
               tool: tool,
               clientName: clientName,
               settings: settings.agentGuardrails,
               context: .from(snapshot: coordinator.latestSnapshot())
           ) {
            decision = .denyGuardrail(reason: reason)
        }

        if decision == .requiresConfirmation {
            let approved = presentConfirmationAlert(tool: tool, clientName: clientName, argumentsSummary: argumentsSummary)
            decision = approved ? .allow : .requiresConfirmation
        }

        if decision == .allow {
            accessController.recordCall()
            // The durable counterpart to `activityLog` below no longer lives
            // here: `authorizeInstrumented` (end of this file) writes to
            // `historyStore.logAgentActivity` *after* the call completes, so
            // the row can carry duration and outcome — things unknowable at
            // authorize time. Agent-session attribution pass; see the v5
            // migration in SentryKit/Persistence/Migrations.swift.
        }

        activityLog.record(
            MCPActivityLogEntry(
                clientName: clientName,
                tool: tool,
                argumentsSummary: argumentsSummary,
                decision: decision
            )
        )

        // Session presence, regardless of decision — a denied client is
        // still *present*, which is what the registry measures (see its
        // `recordCall` doc comment).
        sessionRegistry.recordCall(clientName: clientName, tool: tool)

        return decision
    }

    /// Strips newlines and caps length on strings the *caller* chose —
    /// `clientName` and the arguments summary are attacker-controlled for a
    /// hostile local process, and rendered verbatim they could inject
    /// misleading multi-line copy into the very dialog asking the user to
    /// approve them.
    private static func sanitizedForDialog(_ raw: String, maxLength: Int) -> String {
        let flattened = raw
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flattened.count > maxLength
            ? String(flattened.prefix(maxLength)) + "…"
            : flattened
    }

    /// Plan §13.4: "'Require confirmation' checkbox per write tool → the app
    /// shows a native confirmation dialog before executing." `runModal`
    /// blocks the main thread until the user answers — acceptable here
    /// because this is already running on a `Task { @MainActor in ... }`
    /// hop off the XPC dispatch queue, not the app's snapshot-publishing
    /// loop; a user staring at a confirmation dialog is, by definition, not
    /// waiting on anything else from this process.
    private func presentConfirmationAlert(tool: MCPToolID, clientName: String, argumentsSummary: String) -> Bool {
        let clientName = Self.sanitizedForDialog(clientName, maxLength: 60)
        let argumentsSummary = Self.sanitizedForDialog(argumentsSummary, maxLength: 300)
        let alert = NSAlert()
        alert.messageText = String(localized: "\(clientName) wants to \(tool.displayName.lowercased())")
        alert.informativeText = String(localized: "\(tool.toolDescription)\n\nDetails: \(argumentsSummary)\n\nThis was requested over MCP by an AI agent connected to Sentry. Allow it?")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Deny"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func denialMessage(_ decision: MCPAccessController.Decision) -> String {
        switch decision {
        case .allow:
            return ""
        case .denyMasterDisabled:
            return String(localized: "MCP access is disabled in Sentry → Settings → AI Access.")
        case .denyToolDisabled:
            return String(localized: "This tool is disabled in Sentry → Settings → AI Access.")
        case .denyRateLimited:
            return String(localized: "MCP rate limit exceeded — configured in Sentry → Settings → AI Access. Try again in a moment.")
        case .requiresConfirmation:
            return String(localized: "The user declined to confirm this action in Sentry.")
        case .denyGuardrail(let reason):
            // Already a complete, honest sentence built by
            // `AgentGuardrails.evaluate` ("Sentry declined this: battery is
            // at 14% and unplugged…") — passed through verbatim so the
            // denial the agent reads names the actual condition.
            return reason
        }
    }

    // MARK: - Read tools

    nonisolated func getSystemSnapshot(clientName: String, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            guard let reply = self.authorizeInstrumented(.getSystemSnapshot, wireClientName: clientName, argumentsSummary: "—", reply: reply) else { return }
            self.encodeAndReply(self.coordinator.latestSnapshot(), reply: reply)
        }
    }

    nonisolated func getBatteryStatus(clientName: String, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            guard let reply = self.authorizeInstrumented(.getBatteryStatus, wireClientName: clientName, argumentsSummary: "—", reply: reply) else { return }
            guard let battery = self.coordinator.latestSnapshot().battery else {
                reply(nil, "No battery data available yet (or this Mac has no battery).")
                return
            }
            self.encodeAndReply(battery, reply: reply)
        }
    }

    nonisolated func getBatteryHealthHistory(clientName: String, sinceDays: Int, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            let summary = "sinceDays=\(sinceDays)"
            guard let reply = self.authorizeInstrumented(.getBatteryHealthHistory, wireClientName: clientName, argumentsSummary: summary, reply: reply) else { return }

            let since = Date().addingTimeInterval(-Double(max(1, sinceDays)) * 86400)
            let health = self.historyStore.samples(metric: MetricID.batteryHealthPercent.rawValue, since: since, tier: .daily)
            let cycles = self.historyStore.samples(metric: MetricID.batteryCycleCount.rawValue, since: since, tier: .daily)
            let cyclesByDay = Dictionary(uniqueKeysWithValues: cycles.map { ($0.timestamp, $0.value) })

            let points = health.map { point in
                MCPPayloads.BatteryHealthHistoryPoint(
                    date: point.timestamp,
                    healthPercent: point.value,
                    cycleCount: cyclesByDay[point.timestamp].map { Int($0) }
                )
            }
            self.encodeAndReply(points, reply: reply)
        }
    }

    nonisolated func getMetricHistory(clientName: String, metric: String, sinceSeconds: Double, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            let summary = "metric=\(metric), sinceSeconds=\(sinceSeconds)"
            guard let reply = self.authorizeInstrumented(.getMetricHistory, wireClientName: clientName, argumentsSummary: summary, reply: reply) else { return }

            guard sinceSeconds > 0 else {
                reply(nil, "sinceSeconds must be positive.")
                return
            }
            let since = Date().addingTimeInterval(-sinceSeconds)
            let raw = self.historyStore.samples(metric: metric, since: since)
            let points = raw.map { MCPPayloads.MetricHistoryPoint(timestamp: $0.timestamp, value: $0.value) }
            self.encodeAndReply(points, reply: reply)
        }
    }

    nonisolated func getThermalStatus(clientName: String, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            guard let reply = self.authorizeInstrumented(.getThermalStatus, wireClientName: clientName, argumentsSummary: "—", reply: reply) else { return }
            guard let thermal = self.coordinator.latestSnapshot().thermal else {
                reply(nil, "No thermal data available yet.")
                return
            }
            self.encodeAndReply(thermal, reply: reply)
        }
    }

    nonisolated func getResourceUsage(clientName: String, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            guard let reply = self.authorizeInstrumented(.getResourceUsage, wireClientName: clientName, argumentsSummary: "—", reply: reply) else { return }
            let snapshot = self.coordinator.latestSnapshot()
            let usage = MCPPayloads.ResourceUsage(
                cpu: snapshot.cpu,
                gpu: snapshot.gpu,
                ane: snapshot.ane,
                memory: snapshot.memory,
                disk: snapshot.disk,
                network: snapshot.network,
                timestamp: snapshot.timestamp
            )
            self.encodeAndReply(usage, reply: reply)
        }
    }

    nonisolated func getAlertHistory(clientName: String, limit: Int, sinceSeconds: Double, ruleID: String, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            let summary = "limit=\(limit), sinceSeconds=\(sinceSeconds), ruleID=\(ruleID)"
            guard let reply = self.authorizeInstrumented(.getAlertHistory, wireClientName: clientName, argumentsSummary: summary, reply: reply) else { return }
            let clampedLimit = min(max(1, limit), 500)
            // `0`/`""` are the wire-level "no filter" sentinels — see
            // `SentryXPCServiceProtocol.getAlertHistory`'s doc comment for
            // why an `@objc` protocol can't declare these as real Swift
            // defaults.
            let since: Date? = sinceSeconds > 0 ? Date().addingTimeInterval(-sinceSeconds) : nil
            let ruleIDFilter = ruleID.isEmpty ? nil : UUID(uuidString: ruleID)
            let entries = self.historyStore.recentAlertFirings(limit: clampedLimit, since: since, ruleID: ruleIDFilter)
                .map(MCPPayloads.AlertHistoryEntry.init)
            self.encodeAndReply(entries, reply: reply)
        }
    }

    nonisolated func getDeviceInfo(clientName: String, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            guard let reply = self.authorizeInstrumented(.getDeviceInfo, wireClientName: clientName, argumentsSummary: "—", reply: reply) else { return }
            let snapshot = self.coordinator.latestSnapshot()
            var capable: [String] = []
            if snapshot.battery != nil { capable.append(MetricModule.battery.rawValue) }
            if snapshot.cpu != nil { capable.append(MetricModule.cpu.rawValue) }
            if snapshot.gpu != nil { capable.append(MetricModule.gpu.rawValue) }
            if snapshot.ane != nil { capable.append(MetricModule.ane.rawValue) }
            if snapshot.memory != nil { capable.append(MetricModule.memory.rawValue) }
            if snapshot.disk != nil { capable.append(MetricModule.disk.rawValue) }
            if snapshot.network != nil { capable.append(MetricModule.network.rawValue) }
            if snapshot.thermal != nil { capable.append(MetricModule.thermal.rawValue) }

            let info = MCPPayloads.DeviceInfo(
                deviceID: snapshot.deviceID,
                modelIdentifier: Self.sysctlString("hw.model") ?? "Unknown Mac",
                chipDescription: Self.sysctlString("machdep.cpu.brand_string") ?? "Unknown chip",
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                sentryVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown",
                capableModules: capable
            )
            self.encodeAndReply(info, reply: reply)
        }
    }

    nonisolated func getSleepState(clientName: String, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            guard let reply = self.authorizeInstrumented(.getSleepState, wireClientName: clientName, argumentsSummary: "—", reply: reply) else { return }
            self.encodeAndReply(self.powerControl.state, reply: reply)
        }
    }

    // MARK: - AI-agent-integration read tools

    nonisolated func preflightCheck(clientName: String, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            guard let reply = self.authorizeInstrumented(.preflightCheck, wireClientName: clientName, argumentsSummary: "—", reply: reply) else { return }
            let snapshot = self.coordinator.latestSnapshot()

            // Recent temperature trend, fetched only when a thermal wait is
            // even possible — history lives here, not in the pure policy,
            // hence this seam. An agent that gets a `suggestedWaitSeconds`
            // can schedule; one that doesn't falls back to
            // wait_until_ready's polling, so skipping the query costs
            // nothing on the (common) all-clear path.
            var tempSamples: [(timestamp: Date, celsius: Double)] = []
            if let thermal = snapshot.thermal,
               thermal.isThrottling
                || thermal.pressureLevel == .serious
                || thermal.pressureLevel == .critical
                || (thermal.socTemperatureCelsius ?? 0) > SystemAdvisor.highSoCTempCelsius {
                let since = Date().addingTimeInterval(-15 * 60)
                tempSamples = self.historyStore
                    .samples(metric: MetricID.thermalSocTempC.rawValue, since: since)
                    .map { (timestamp: $0.timestamp, celsius: $0.value) }
            }

            // The caller's own session is excluded — its presence in the
            // registry (recorded by `authorize` above) must not make the
            // preflight warn about itself.
            let others = self.sessionRegistry.otherActiveSessions(excluding: self.sessionIdentity(fromWire: clientName).clientName)
            let assessment = AgentPreflight.assess(
                snapshot,
                lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                otherActiveAgentSessionCount: others.count,
                otherActiveAgentLabels: others.map(\.clientName),
                recentSoCTemperatureSamples: tempSamples
            )
            self.encodeAndReply(assessment, reply: reply)
        }
    }

    nonisolated func getResourceEventsSince(clientName: String, sinceSeconds: Double, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            let summary = "sinceSeconds=\(sinceSeconds)"
            guard let reply = self.authorizeInstrumented(.getResourceEventsSince, wireClientName: clientName, argumentsSummary: summary, reply: reply) else { return }
            guard sinceSeconds > 0 else {
                reply(nil, "sinceSeconds must be positive.")
                return
            }
            let since = Date().addingTimeInterval(-sinceSeconds)

            let firings = self.historyStore.recentAlertFirings(limit: 500)
                .filter { $0.timestamp >= since }
                .map(MCPPayloads.AlertHistoryEntry.init)

            let socTemps = self.historyStore.samples(metric: MetricID.thermalSocTempC.rawValue, since: since)
            let cpuSamples = self.historyStore.samples(metric: MetricID.cpuTotalPercent.rawValue, since: since)
            let memPressure = self.historyStore.samples(metric: MetricID.memoryPressurePercent.rawValue, since: since)
            let diskFree = self.historyStore.samples(metric: MetricID.diskFreeBytes.rawValue, since: since)
            let throttling = self.historyStore.samples(metric: MetricID.thermalIsThrottling.rawValue, since: since)

            let summaryPayload = MCPPayloads.ResourceEventsSummary(
                since: since,
                alertFirings: firings,
                peakSoCTemperatureCelsius: socTemps.map(\.value).max(),
                peakCPUPercent: cpuSamples.map(\.value).max(),
                peakMemoryPressurePercent: memPressure.map(\.value).max(),
                minDiskFreeBytes: diskFree.map(\.value).min(),
                anyThrottling: throttling.contains { $0.value > 0 }
            )
            self.encodeAndReply(summaryPayload, reply: reply)
        }
    }

    nonisolated func getAgentCapacity(clientName: String, requestedAgents: Int, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            let summary = "requestedAgents=\(requestedAgents)"
            guard let reply = self.authorizeInstrumented(.getAgentCapacity, wireClientName: clientName, argumentsSummary: summary, reply: reply) else { return }

            let snapshot = self.coordinator.latestSnapshot()
            // Upper-bounded, not just lower-bounded: a caller passing an
            // absurd value (accidental or adversarial) must not reach the
            // multiplication below with an unclamped `Int` — `UInt64(_:)`
            // would trap on a negative value, and even a merely huge
            // positive value would overflow `estimatedBytesPerAgent *
            // UInt64(clampedAgents)`'s trapping `*` and crash this
            // `@MainActor` process for every client. 10,000 is already far
            // beyond any plausible real request (this heuristic isn't
            // meaningful past a handful of agents anyway).
            let clampedAgents = min(max(1, requestedAgents), 10_000)

            // Coarse per-agent footprint estimate for a local coding-agent
            // subprocess (interpreter/runtime + working set) — deliberately
            // conservative (higher than a lean CLI, lower than a full
            // Electron app) since this is a heuristic gate, not a promise.
            let estimatedBytesPerAgent: UInt64 = 512 * 1024 * 1024
            let freeBytes: UInt64
            if let memory = snapshot.memory, memory.totalBytes > memory.usedBytes {
                freeBytes = memory.totalBytes - memory.usedBytes
            } else {
                freeBytes = 0
            }
            let cpuHeadroom = max(0, 100 - (snapshot.cpu?.totalPercent ?? 0))

            let memoryOK = freeBytes >= estimatedBytesPerAgent * UInt64(clampedAgents)
            // Each agent is assumed to want roughly one core's worth of
            // headroom (25% of total CPU on a 4+ core Mac) — again a coarse
            // heuristic, not a scheduler guarantee.
            let cpuOK = cpuHeadroom >= Double(clampedAgents) * 25
            let hasCapacity = memoryOK && cpuOK

            let reasoning: String
            if hasCapacity {
                reasoning = "Free memory (\(ByteCountFormatter.string(fromByteCount: Int64(freeBytes), countStyle: .memory))) and CPU headroom (\(Int(cpuHeadroom))%) look sufficient for \(clampedAgents) more agent(s)."
            } else if !memoryOK {
                reasoning = "Free memory (\(ByteCountFormatter.string(fromByteCount: Int64(freeBytes), countStyle: .memory))) is likely too tight for \(clampedAgents) more agent(s) at ~512 MB each."
            } else {
                reasoning = "CPU headroom (\(Int(cpuHeadroom))%) is likely too tight for \(clampedAgents) more agent(s)."
            }

            let headroom = MCPPayloads.AgentCapacity(
                requestedAgents: clampedAgents,
                hasCapacity: hasCapacity,
                freeMemoryBytes: freeBytes,
                estimatedBytesPerAgent: estimatedBytesPerAgent,
                cpuHeadroomPercent: cpuHeadroom,
                reasoning: reasoning
            )

            // Coordination picture: who else is active (caller excluded —
            // capacity for *you* shouldn't warn about *you*), and whether an
            // agent holds keep-awake. The registry's flag is cross-checked
            // against the live assertion: a timed hold can expire without
            // another MCP call arriving to tell the registry.
            let others = self.sessionRegistry.otherActiveSessions(excluding: self.sessionIdentity(fromWire: clientName).clientName)
            let assertionActive: Bool
            if case .active = self.powerControl.state {
                assertionActive = true
            } else {
                assertionActive = false
            }
            let agentHeldKeepAwake = assertionActive
                && self.sessionRegistry.activeSessions().contains(where: \.holdsKeepAwake)

            let sessions = others.map { session in
                MCPPayloads.AgentSessionInfo(
                    clientName: session.clientName,
                    connectedAt: session.connectedAt,
                    lastCallAt: session.lastCallAt,
                    recentTools: session.recentTools.map(\.rawValue),
                    holdsKeepAwake: session.holdsKeepAwake && assertionActive
                )
            }

            // One sentence weighing both halves — worded so a model reads
            // "contend", not "forbidden": this whole tool is advisory.
            var judgmentParts: [String] = []
            if !others.isEmpty {
                let names = others.map(\.clientName).joined(separator: ", ")
                if cpuHeadroom <= 100 - SystemAdvisor.highCPUPercent {
                    judgmentParts.append("\(others.count) other agent session(s) active (\(names)) and CPU is already at \(Int(100 - cpuHeadroom))% — starting another heavy workload now will contend; prefer waiting or coordinating.")
                } else {
                    judgmentParts.append("\(others.count) other agent session(s) recently active (\(names)) — currently light, but re-check before starting sustained heavy work.")
                }
            }
            judgmentParts.append(reasoning)
            let judgment = judgmentParts.joined(separator: " ")

            let payload = MCPPayloads.AgentCapacityReport(
                headroom: headroom,
                activeSessions: sessions,
                agentHeldKeepAwake: agentHeldKeepAwake,
                judgment: judgment,
                sessionIdentityNote: "Session client names are self-reported by each MCP client and are not authenticated — treat them as labels, not identities."
            )
            self.encodeAndReply(payload, reply: reply)
        }
    }

    nonisolated func getAgentActivity(clientName: String, limit: Int, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            let summary = "limit=\(limit)"
            guard let reply = self.authorizeInstrumented(.getAgentActivity, wireClientName: clientName, argumentsSummary: summary, reply: reply) else { return }
            let clampedLimit = min(max(1, limit), 200)
            let entries = self.activityLog.entries.prefix(clampedLimit).map { entry in
                MCPPayloads.AgentActivityEntry(
                    timestamp: entry.timestamp,
                    clientName: entry.clientName,
                    tool: entry.tool.rawValue,
                    argumentsSummary: entry.argumentsSummary,
                    decision: String(describing: entry.decision)
                )
            }
            self.encodeAndReply(Array(entries), reply: reply)
        }
    }

    nonisolated func getSessionResourceReport(clientName: String, sinceSeconds: Double, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            let summary = "sinceSeconds=\(sinceSeconds)"
            guard let reply = self.authorizeInstrumented(.getSessionResourceReport, wireClientName: clientName, argumentsSummary: summary, reply: reply) else { return }
            guard sinceSeconds > 0 else {
                reply(nil, "sinceSeconds must be positive.")
                return
            }
            let since = Date().addingTimeInterval(-sinceSeconds)
            let now = Date()

            let cpuSamples = self.historyStore.samples(metric: MetricID.cpuTotalPercent.rawValue, since: since).map(\.value)
            let socTemps = self.historyStore.samples(metric: MetricID.thermalSocTempC.rawValue, since: since).map(\.value)
            let throttlingSamples = self.historyStore.samples(metric: MetricID.thermalIsThrottling.rawValue, since: since)
            let memPressure = self.historyStore.samples(metric: MetricID.memoryPressurePercent.rawValue, since: since).map(\.value)
            let firings = self.historyStore.recentAlertFirings(limit: 500).filter { $0.timestamp >= since }

            // Approximates seconds spent throttling by assuming each sample
            // represents the interval since the previous one (bounded to
            // avoid one stale/late sample inflating the total) — this is a
            // best-effort estimate over already-persisted samples, not a
            // continuous measurement.
            var secondsThrottling: Double = 0
            var previousTimestamp = since
            for sample in throttlingSamples {
                let interval = min(sample.timestamp.timeIntervalSince(previousTimestamp), 300)
                if sample.value > 0 { secondsThrottling += max(0, interval) }
                previousTimestamp = sample.timestamp
            }

            // Session attribution (agent-session attribution pass): correlate
            // the *caller's own* session — identified by the composite wire
            // `clientName`, see `AgentSessionIdentity` — with the durable
            // activity log, the keep-awake ledger, and battery/thermal
            // history. Falls back to grouping by client display name when
            // this session hasn't logged any calls in the window yet (e.g.
            // this report is its very first call).
            let identity = self.sessionIdentity(fromWire: clientName)
            let allEvents = self.historyStore.agentActivityEvents(since: since)
            let sessionEvents = allEvents.filter { $0.sessionID == identity.sessionID }
            let scopedEvents = sessionEvents.isEmpty
                ? allEvents.filter { $0.clientName == identity.clientName }
                : sessionEvents
            let batterySamples = self.historyStore.samples(metric: MetricID.batteryChargePercent.rawValue, since: since)
            let pressureSamples = self.historyStore.samples(metric: MetricID.thermalPressureLevel.rawValue, since: since)
            let attribution = AgentSessionReport.attribution(
                sessionID: identity.sessionID,
                clientName: identity.clientName,
                events: scopedEvents,
                awakeHolds: self.powerControl.awakeHolds,
                batterySamples: batterySamples,
                thermalPressureSamples: pressureSamples,
                window: since...now
            )

            let report = MCPPayloads.SessionResourceReport(
                windowStart: since,
                windowEnd: now,
                averageCPUPercent: cpuSamples.isEmpty ? nil : cpuSamples.reduce(0, +) / Double(cpuSamples.count),
                peakCPUPercent: cpuSamples.max(),
                peakSoCTemperatureCelsius: socTemps.max(),
                secondsThrottling: secondsThrottling,
                peakMemoryPressurePercent: memPressure.max(),
                alertsFired: firings.count,
                sessionID: attribution.sessionID,
                sessionClientName: attribution.clientName,
                sessionStart: attribution.sessionStart,
                sessionEnd: attribution.sessionEnd,
                toolCallCounts: attribution.toolCallCounts,
                keepAwakeSecondsHeld: attribution.keepAwakeSecondsHeld,
                batteryPercentDrained: attribution.batteryPercentDrained,
                thermalPressureElevated: attribution.thermalPressureElevated,
                thermalPressureElevatedSeconds: attribution.thermalPressureElevatedSeconds
            )
            self.encodeAndReply(report, reply: reply)
        }
    }

    // MARK: - Write tools

    nonisolated func keepAwake(clientName: String, mode: String, durationSeconds: Double, reason: String, reply: @escaping (Bool, String?) -> Void) {
        Task { @MainActor in
            let summary = "mode=\(mode), durationSeconds=\(durationSeconds), reason=\(reason)"
            guard let reply = self.authorizeInstrumented(.keepAwake, wireClientName: clientName, argumentsSummary: summary, reply: reply) else { return }
            guard let awakeMode = AwakeMode(rawValue: mode) else {
                reply(false, "Unknown mode '\(mode)'. Expected one of: \(AwakeMode.allCases.map(\.rawValue).joined(separator: ", ")).")
                return
            }
            // A non-finite duration slips past both `<= 0` and `> 0` checks
            // downstream and would mint an indefinite hold no timer ever
            // releases; an agent also shouldn't be able to request a week.
            // 24h is the cap — an agent wanting longer can renew.
            guard durationSeconds.isFinite else {
                reply(false, "durationSeconds must be a finite number.")
                return
            }
            let clampedDuration = min(durationSeconds, 24 * 3600)
            // Parsed once, used three ways below. The wire string is
            // "name\u{1F}uuid" since the session-identity pass (see
            // `AgentSessionIdentity`) — every human- or policy-facing use
            // must take the parsed display name, never the wire string.
            let identity = self.sessionIdentity(fromWire: clientName)
            let clampedReason = reason.isEmpty ? "Requested via MCP by \(identity.clientName)" : reason
            do {
                // The agent-tagged variant, not plain `startAssertion` — one
                // call carries both ownership tags. The *client name* is what
                // lets the kill switch and guardrail auto-revocation release
                // an agent's hold without touching one the user started; the
                // *session ID* is what lets the awake-hold ledger
                // (`PowerControlService.awakeHolds`) attribute held time to
                // this session in `get_session_resource_report`.
                try self.powerControl.startAgentAssertion(
                    mode: awakeMode,
                    duration: clampedDuration > 0 ? clampedDuration : nil,
                    reason: clampedReason,
                    clientName: identity.clientName,
                    sessionID: identity.sessionID
                )
                // Attribute the (single) live assertion to this session for
                // get_agent_capacity's coordination picture — only after
                // the assertion actually exists.
                self.sessionRegistry.recordKeepAwake(clientName: identity.clientName)
                reply(true, nil)
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    nonisolated func releaseAwake(clientName: String, reply: @escaping (Bool, String?) -> Void) {
        Task { @MainActor in
            guard let reply = self.authorizeInstrumented(.releaseAwake, wireClientName: clientName, argumentsSummary: "—", reply: reply) else { return }
            self.powerControl.releaseAssertion()
            // One assertion app-wide, so a release clears every session's
            // keep-awake attribution — see `AgentSessionRegistry.clearKeepAwake`.
            self.sessionRegistry.clearKeepAwake()
            reply(true, nil)
        }
    }

    nonisolated func setRefreshInterval(clientName: String, tier: String, seconds: Double, reply: @escaping (Bool, String?) -> Void) {
        Task { @MainActor in
            let summary = "tier=\(tier), seconds=\(seconds)"
            guard let reply = self.authorizeInstrumented(.setRefreshInterval, wireClientName: clientName, argumentsSummary: summary, reply: reply) else { return }
            // Mutating `settingsStore.settings` (rather than calling
            // `coordinator.set*Interval` directly) is deliberate: the
            // existing `settingsStore.$settings` sink in `AppDelegate`
            // already pushes every tier interval into `coordinator` on any
            // settings change, and going through settings means the change
            // is visible in the General pane and persists across relaunch —
            // exactly what "change polling cadence" should mean coming from
            // an agent, not a one-shot in-memory override invisible to the
            // rest of the app.
            switch tier {
            case "fast":
                self.settingsStore.settings.globalRefreshInterval = seconds
            case "medium":
                self.settingsStore.settings.mediumTierRefreshInterval = seconds
            case "slow":
                self.settingsStore.settings.slowTierRefreshInterval = seconds
            default:
                reply(false, "Unknown tier '\(tier)'. Expected one of: fast, medium, slow.")
                return
            }
            reply(true, nil)
        }
    }

    nonisolated func setAlertRuleEnabled(clientName: String, ruleID: String, enabled: Bool, reply: @escaping (Bool, String?) -> Void) {
        Task { @MainActor in
            let summary = "ruleID=\(ruleID), enabled=\(enabled)"
            guard let reply = self.authorizeInstrumented(.setAlertRuleEnabled, wireClientName: clientName, argumentsSummary: summary, reply: reply) else { return }
            guard let uuid = UUID(uuidString: ruleID) else {
                reply(false, "'\(ruleID)' isn't a valid rule ID.")
                return
            }
            var rules = self.settingsStore.settings.alertRules
            guard let index = rules.firstIndex(where: { $0.id == uuid }) else {
                reply(false, "No alert rule with ID \(ruleID).")
                return
            }
            rules[index].isEnabled = enabled
            self.settingsStore.settings.alertRules = rules
            reply(true, nil)
        }
    }

    nonisolated func createAlertRule(clientName: String, ruleJSON: Data, reply: @escaping (Bool, String?) -> Void) {
        Task { @MainActor in
            let summary = String(data: ruleJSON, encoding: .utf8).map { "rule=\($0.prefix(200))" } ?? "rule=<binary>"
            // The dialog shows the JSON so the user can judge what they're
            // approving, but the durable log must not persist raw arguments
            // (`logAgentActivity`'s contract) — hence the separate short
            // persisted summary.
            guard let reply = self.authorizeInstrumented(.createAlertRule, wireClientName: clientName, argumentsSummary: summary, persistedSummary: "proposed new alert rule (JSON not persisted)", reply: reply) else { return }
            do {
                let request = try JSONDecoder().decode(MCPPayloads.NewAlertRule.self, from: ruleJSON)
                var rules = self.settingsStore.settings.alertRules
                rules.append(request.makeAlertRule())
                self.settingsStore.settings.alertRules = rules
                reply(true, nil)
            } catch {
                reply(false, "Couldn't parse the proposed rule: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func waitUntilReady(clientName: String, condition: String, timeoutSeconds: Double, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            let summary = "condition=\(condition), timeoutSeconds=\(timeoutSeconds)"
            guard let reply = self.authorizeInstrumented(.waitUntilReady, wireClientName: clientName, argumentsSummary: summary, reply: reply) else { return }

            guard let parsedCondition = WaitCondition(condition) else {
                reply(nil, "Unrecognized condition '\(condition)'. Expected ready, thermal_normal, cpu_below:N, battery_above:N, or memory_below:N.")
                return
            }

            // Capped well below any reasonable MCP client request timeout —
            // a caller that wants longer should poll `preflight_check`
            // itself rather than hold one XPC/MCP call open indefinitely.
            let clampedTimeout = min(max(timeoutSeconds, 1), 600)
            let start = Date()

            let initial = self.coordinator.latestSnapshot()
            if parsedCondition.isSatisfied(by: initial) {
                self.encodeAndReply(
                    MCPPayloads.WaitResult(satisfied: true, timedOut: false, waitedSeconds: 0, finalSnapshot: initial),
                    reply: reply
                )
                return
            }

            let deadline = start.addingTimeInterval(clampedTimeout)

            // A deadline check made only when a new snapshot arrives (the
            // previous version of this loop) can overrun `clampedTimeout`
            // by up to a full poll-tier interval — up to 60s if the tier
            // is at its slowest setting — since nothing wakes the loop
            // between snapshots. `repliedOnce` plus a sibling timer task
            // below makes the timeout a real wall-clock bound: whichever
            // of "condition satisfied" or "clock expired" happens first
            // replies, and the other is a silent no-op.
            let repliedOnce = SingleFire()

            let timeoutTask = Task { @MainActor in
                let remaining = max(0, deadline.timeIntervalSinceNow)
                try? await Task.sleep(for: .seconds(remaining))
                guard repliedOnce.fire() else { return }
                self.encodeAndReply(
                    MCPPayloads.WaitResult(satisfied: false, timedOut: true, waitedSeconds: Date().timeIntervalSince(start), finalSnapshot: self.coordinator.latestSnapshot()),
                    reply: reply
                )
            }

            for await snapshot in self.coordinator.snapshots() {
                guard !repliedOnce.hasFired else { break }
                if parsedCondition.isSatisfied(by: snapshot) {
                    guard repliedOnce.fire() else { break }
                    timeoutTask.cancel()
                    self.encodeAndReply(
                        MCPPayloads.WaitResult(satisfied: true, timedOut: false, waitedSeconds: Date().timeIntervalSince(start), finalSnapshot: snapshot),
                        reply: reply
                    )
                    return
                }
            }

            // The stream ended (coordinator torn down) without satisfying —
            // reply with whatever's on hand rather than leaving the caller
            // hanging until `timeoutTask` fires (if it hasn't already).
            if repliedOnce.fire() {
                timeoutTask.cancel()
                self.encodeAndReply(
                    MCPPayloads.WaitResult(satisfied: false, timedOut: true, waitedSeconds: Date().timeIntervalSince(start), finalSnapshot: self.coordinator.latestSnapshot()),
                    reply: reply
                )
            }
        }
    }

    // MARK: - Helpers

    /// `authorize` already logs and applies the confirmation flow; this
    /// wrapper is for the common read-tool shape (no confirmation possible —
    /// only write tools carry a confirmation requirement — so `.allow` is
    /// the only non-denied outcome) where the call site just wants a single
    /// guard before proceeding.
    private func checkAndReplyIfDenied(_ tool: MCPToolID, clientName: String, argumentsSummary: String, reply: @escaping (Data?, String?) -> Void) -> Bool {
        let decision = authorize(tool: tool, clientName: clientName, argumentsSummary: argumentsSummary)
        guard decision == .allow else {
            reply(nil, denialMessage(decision))
            return false
        }
        return true
    }

    /// Bool-reply overload for write tools — same contract as the `Data?`
    /// overload above, just matching `SentryXPCServiceProtocol`'s write-tool
    /// reply shape (`(Bool, String?) -> Void`) instead of the read-tool one.
    private func checkAndReplyIfDenied(_ tool: MCPToolID, clientName: String, argumentsSummary: String, reply: @escaping (Bool, String?) -> Void) -> Bool {
        let decision = authorize(tool: tool, clientName: clientName, argumentsSummary: argumentsSummary)
        guard decision == .allow else {
            reply(false, denialMessage(decision))
            return false
        }
        return true
    }

    // MARK: - Instrumented authorization (agent-session attribution pass)

    /// Stable per-launch fallback session IDs for callers whose `clientName`
    /// carries no `AgentSessionIdentity` marker (e.g. the in-process
    /// `LocalXPCServiceCaller` path, or an old `SentryMCP` binary). Keyed by
    /// display name so such a caller still gets *a* stable-for-this-run ID —
    /// its calls group into one session — rather than a fresh UUID per call.
    private var fallbackSessionIDs: [String: String] = [:]

    /// Splits the composite wire `clientName` (see `AgentSessionIdentity`,
    /// SentryKit/Services/AgentSessionIdentity.swift) into the display name
    /// — what dialogs and the in-memory activity log should show — and the
    /// per-connection session ID the durable log records.
    private func sessionIdentity(fromWire wireClientName: String) -> (clientName: String, sessionID: String) {
        let parsed = AgentSessionIdentity.parse(wireClientName)
        if let sessionID = parsed.sessionID {
            return (parsed.clientName, sessionID)
        }
        if let existing = fallbackSessionIDs[parsed.clientName] {
            return (parsed.clientName, existing)
        }
        let minted = UUID().uuidString
        fallbackSessionIDs[parsed.clientName] = minted
        return (parsed.clientName, minted)
    }

    private static func durableOutcome(for decision: MCPAccessController.Decision) -> AgentActivityOutcome {
        switch decision {
        case .allow: return .succeeded
        case .denyRateLimited: return .rateLimited
        case .denyMasterDisabled, .denyToolDisabled, .requiresConfirmation: return .denied
        // A guardrail denial (battery floor, quiet hours, thermal, kill
        // switch, per-client revocation) is a policy "no", same as the
        // static permission model saying no — the durable log doesn't need
        // to distinguish them because the args-summary row already carries
        // the guardrail's specific reason.
        case .denyGuardrail: return .denied
        }
    }

    /// Writes one durable `agent_activity_log` row. The summary is
    /// sanitized/flattened and capped harder than the dialog's 300 chars —
    /// this is a persisted-forever audit line, and `logAgentActivity`'s
    /// contract is a SHORT human-readable summary, never raw arguments.
    private func logDurable(
        _ tool: MCPToolID,
        clientName: String,
        sessionID: String,
        summary: String,
        startedAt: Date,
        outcome: AgentActivityOutcome
    ) {
        historyStore.logAgentActivity(
            clientName: clientName,
            sessionID: sessionID,
            tool: tool.rawValue,
            argsSummary: Self.sanitizedForDialog(summary, maxLength: 120),
            durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
            outcome: outcome
        )
    }

    /// Supersedes `checkAndReplyIfDenied` (kept above for any parallel
    /// branch still calling it): performs the same authorize-or-deny flow,
    /// but also writes the durable per-session activity row — *after* the
    /// tool actually replies, so it can record real duration and outcome.
    /// Returns `nil` after replying with the denial (row logged as
    /// denied/rate_limited), or a wrapped `reply` the caller must use in
    /// place of the original — invoking it logs succeeded/errored and then
    /// forwards to the real reply. Call sites shadow their `reply` parameter
    /// with the returned closure so the rest of each method body is
    /// untouched.
    ///
    /// - Parameter persistedSummary: override for the durable row when the
    ///   dialog summary would leak raw arguments (see `createAlertRule`).
    private func authorizeInstrumented(
        _ tool: MCPToolID,
        wireClientName: String,
        argumentsSummary: String,
        persistedSummary: String? = nil,
        reply: @escaping (Data?, String?) -> Void
    ) -> ((Data?, String?) -> Void)? {
        let (clientName, sessionID) = sessionIdentity(fromWire: wireClientName)
        let startedAt = Date()
        let durableSummary = persistedSummary ?? argumentsSummary
        let decision = authorize(tool: tool, clientName: clientName, argumentsSummary: argumentsSummary)
        guard decision == .allow else {
            logDurable(tool, clientName: clientName, sessionID: sessionID, summary: durableSummary, startedAt: startedAt, outcome: Self.durableOutcome(for: decision))
            reply(nil, denialMessage(decision))
            return nil
        }
        return { [weak self] data, errorMessage in
            Task { @MainActor in
                self?.logDurable(
                    tool,
                    clientName: clientName,
                    sessionID: sessionID,
                    summary: durableSummary,
                    startedAt: startedAt,
                    outcome: data == nil ? .errored : .succeeded
                )
            }
            reply(data, errorMessage)
        }
    }

    /// Bool-reply overload for write tools — mirrors the pairing of the two
    /// `checkAndReplyIfDenied` overloads above; `success == false` logs as
    /// `.errored`.
    private func authorizeInstrumented(
        _ tool: MCPToolID,
        wireClientName: String,
        argumentsSummary: String,
        persistedSummary: String? = nil,
        reply: @escaping (Bool, String?) -> Void
    ) -> ((Bool, String?) -> Void)? {
        let (clientName, sessionID) = sessionIdentity(fromWire: wireClientName)
        let startedAt = Date()
        let durableSummary = persistedSummary ?? argumentsSummary
        let decision = authorize(tool: tool, clientName: clientName, argumentsSummary: argumentsSummary)
        guard decision == .allow else {
            logDurable(tool, clientName: clientName, sessionID: sessionID, summary: durableSummary, startedAt: startedAt, outcome: Self.durableOutcome(for: decision))
            reply(false, denialMessage(decision))
            return nil
        }
        return { [weak self] success, errorMessage in
            Task { @MainActor in
                self?.logDurable(
                    tool,
                    clientName: clientName,
                    sessionID: sessionID,
                    summary: durableSummary,
                    startedAt: startedAt,
                    outcome: success ? .succeeded : .errored
                )
            }
            reply(success, errorMessage)
        }
    }

    private func encodeAndReply<T: Encodable>(_ value: T, reply: @escaping (Data?, String?) -> Void) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(value)
            reply(data, nil)
        } catch {
            reply(nil, "Failed to encode response: \(error.localizedDescription)")
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// A "did this already happen" latch shared between `waitUntilReady`'s
/// snapshot-watching loop and its sibling timeout task — exactly one of
/// them should ever call `reply`, whichever wins the race. `fire()` returns
/// `true` for the caller that wins (and should proceed to reply) and
/// `false` for the loser. `@MainActor`-isolated, not locked: both callers
/// (the loop and the timeout `Task { @MainActor in ... }`) already run on
/// the main actor, which serializes access — no separate synchronization
/// needed, unlike `ResumeOnce` (`SentryXPCClient.swift`), which guards
/// against a genuine cross-thread XPC race.
@MainActor
private final class SingleFire {
    private(set) var hasFired = false

    @discardableResult
    func fire() -> Bool {
        guard !hasFired else { return false }
        hasFired = true
        return true
    }
}
#endif
