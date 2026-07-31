import Foundation
import MacStatKit

#if os(macOS)
import AppKit

/// Implements `MacStatXPCServiceProtocol` — the app-side half of plan
/// §13.2's XPC boundary. `AppDelegate` registers an `NSXPCListener` whose
/// `exportedObject` is one instance of this class; `MacStatMCP` connects as
/// a client and calls its methods.
///
/// **This is the enforcement point, not `MacStatMCP`.** Every method here
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
final class MCPXPCService: NSObject, MacStatXPCServiceProtocol {

    private let coordinator: StatsCoordinator
    private let historyStore: HistoryStore
    private let alertEngine: AlertEngine
    private let powerControl: PowerControlService
    private let settingsStore: SettingsStore
    private let accessController: MCPAccessController
    private let activityLog: MCPActivityLog

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

        if decision == .requiresConfirmation {
            let approved = presentConfirmationAlert(tool: tool, clientName: clientName, argumentsSummary: argumentsSummary)
            decision = approved ? .allow : .requiresConfirmation
        }

        if decision == .allow {
            accessController.recordCall()
            // Durable counterpart to `activityLog` below — write tools only
            // (see `logAgentActivity`'s doc comment for why), so the
            // Dashboard's agent-activity panel has real history to query
            // beyond this session. Read tools aren't logged here: they're
            // high-volume and, unlike a write tool, never change anything
            // on this Mac worth correlating against a thermal/CPU chart.
            if tool.isWrite {
                historyStore.logAgentActivity(clientName: clientName, tool: tool.rawValue)
            }
        }

        activityLog.record(
            MCPActivityLogEntry(
                clientName: clientName,
                tool: tool,
                argumentsSummary: argumentsSummary,
                decision: decision
            )
        )

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
            return String(localized: "MCP access is disabled in MacStat → Settings → AI Access.")
        case .denyToolDisabled:
            return String(localized: "This tool is disabled in MacStat → Settings → AI Access.")
        case .denyRateLimited:
            return String(localized: "MCP rate limit exceeded — configured in MacStat → Settings → AI Access. Try again in a moment.")
        case .requiresConfirmation:
            return String(localized: "The user declined to confirm this action in MacStat.")
        }
    }

    // MARK: - Read tools

    nonisolated func getSystemSnapshot(clientName: String, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            guard self.checkAndReplyIfDenied(.getSystemSnapshot, clientName: clientName, argumentsSummary: "—", reply: reply) else { return }
            self.encodeAndReply(self.coordinator.latestSnapshot(), reply: reply)
        }
    }

    nonisolated func getBatteryStatus(clientName: String, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            guard self.checkAndReplyIfDenied(.getBatteryStatus, clientName: clientName, argumentsSummary: "—", reply: reply) else { return }
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
            guard self.checkAndReplyIfDenied(.getBatteryHealthHistory, clientName: clientName, argumentsSummary: summary, reply: reply) else { return }

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
            guard self.checkAndReplyIfDenied(.getMetricHistory, clientName: clientName, argumentsSummary: summary, reply: reply) else { return }

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
            guard self.checkAndReplyIfDenied(.getThermalStatus, clientName: clientName, argumentsSummary: "—", reply: reply) else { return }
            guard let thermal = self.coordinator.latestSnapshot().thermal else {
                reply(nil, "No thermal data available yet.")
                return
            }
            self.encodeAndReply(thermal, reply: reply)
        }
    }

    nonisolated func getResourceUsage(clientName: String, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            guard self.checkAndReplyIfDenied(.getResourceUsage, clientName: clientName, argumentsSummary: "—", reply: reply) else { return }
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

    nonisolated func getAlertHistory(clientName: String, limit: Int, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            let summary = "limit=\(limit)"
            guard self.checkAndReplyIfDenied(.getAlertHistory, clientName: clientName, argumentsSummary: summary, reply: reply) else { return }
            let clampedLimit = min(max(1, limit), 500)
            let entries = self.historyStore.recentAlertFirings(limit: clampedLimit).map(MCPPayloads.AlertHistoryEntry.init)
            self.encodeAndReply(entries, reply: reply)
        }
    }

    nonisolated func getDeviceInfo(clientName: String, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            guard self.checkAndReplyIfDenied(.getDeviceInfo, clientName: clientName, argumentsSummary: "—", reply: reply) else { return }
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
                macStatVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown",
                capableModules: capable
            )
            self.encodeAndReply(info, reply: reply)
        }
    }

    nonisolated func getSleepState(clientName: String, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            guard self.checkAndReplyIfDenied(.getSleepState, clientName: clientName, argumentsSummary: "—", reply: reply) else { return }
            self.encodeAndReply(self.powerControl.state, reply: reply)
        }
    }

    // MARK: - AI-agent-integration read tools

    nonisolated func preflightCheck(clientName: String, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            guard self.checkAndReplyIfDenied(.preflightCheck, clientName: clientName, argumentsSummary: "—", reply: reply) else { return }
            let snapshot = self.coordinator.latestSnapshot()
            var recommendation = SystemAdvisor.recommend(snapshot, lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled)
            // Attach the cool-down ETA only when the "wait" is thermal —
            // history lives here, not in the pure advisor, hence this seam.
            // An agent that gets a number can schedule; one that doesn't
            // falls back to wait_until_ready's polling, so nil costs nothing.
            if recommendation.recommendation == "wait",
               recommendation.isThrottling
                || recommendation.thermalPressure == "serious"
                || recommendation.thermalPressure == "critical"
                || (recommendation.socTemperatureCelsius ?? 0) > SystemAdvisor.highSoCTempCelsius {
                let since = Date().addingTimeInterval(-15 * 60)
                let temps = self.historyStore
                    .samples(metric: MetricID.thermalSocTempC.rawValue, since: since)
                    .map { (timestamp: $0.timestamp, celsius: $0.value) }
                if let eta = SystemAdvisor.cooldownETASeconds(tempSamples: temps) {
                    recommendation.cooldownETASeconds = eta
                    let minutes = max(1, Int((eta / 60).rounded()))
                    recommendation.reasons.append("Cooling — estimated thermal nominal in ~\(minutes) min.")
                }
            }
            self.encodeAndReply(recommendation, reply: reply)
        }
    }

    nonisolated func getResourceEventsSince(clientName: String, sinceSeconds: Double, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            let summary = "sinceSeconds=\(sinceSeconds)"
            guard self.checkAndReplyIfDenied(.getResourceEventsSince, clientName: clientName, argumentsSummary: summary, reply: reply) else { return }
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
            guard self.checkAndReplyIfDenied(.getAgentCapacity, clientName: clientName, argumentsSummary: summary, reply: reply) else { return }

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

            let payload = MCPPayloads.AgentCapacity(
                requestedAgents: clampedAgents,
                hasCapacity: hasCapacity,
                freeMemoryBytes: freeBytes,
                estimatedBytesPerAgent: estimatedBytesPerAgent,
                cpuHeadroomPercent: cpuHeadroom,
                reasoning: reasoning
            )
            self.encodeAndReply(payload, reply: reply)
        }
    }

    nonisolated func getAgentActivity(clientName: String, limit: Int, reply: @escaping (Data?, String?) -> Void) {
        Task { @MainActor in
            let summary = "limit=\(limit)"
            guard self.checkAndReplyIfDenied(.getAgentActivity, clientName: clientName, argumentsSummary: summary, reply: reply) else { return }
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
            guard self.checkAndReplyIfDenied(.getSessionResourceReport, clientName: clientName, argumentsSummary: summary, reply: reply) else { return }
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

            let report = MCPPayloads.SessionResourceReport(
                windowStart: since,
                windowEnd: now,
                averageCPUPercent: cpuSamples.isEmpty ? nil : cpuSamples.reduce(0, +) / Double(cpuSamples.count),
                peakCPUPercent: cpuSamples.max(),
                peakSoCTemperatureCelsius: socTemps.max(),
                secondsThrottling: secondsThrottling,
                peakMemoryPressurePercent: memPressure.max(),
                alertsFired: firings.count
            )
            self.encodeAndReply(report, reply: reply)
        }
    }

    // MARK: - Write tools

    nonisolated func keepAwake(clientName: String, mode: String, durationSeconds: Double, reason: String, reply: @escaping (Bool, String?) -> Void) {
        Task { @MainActor in
            let summary = "mode=\(mode), durationSeconds=\(durationSeconds), reason=\(reason)"
            guard self.checkAndReplyIfDenied(.keepAwake, clientName: clientName, argumentsSummary: summary, reply: reply) else { return }
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
            let clampedReason = reason.isEmpty ? "Requested via MCP by \(clientName)" : reason
            do {
                try self.powerControl.startAssertion(
                    mode: awakeMode,
                    duration: clampedDuration > 0 ? clampedDuration : nil,
                    reason: clampedReason
                )
                reply(true, nil)
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    nonisolated func releaseAwake(clientName: String, reply: @escaping (Bool, String?) -> Void) {
        Task { @MainActor in
            guard self.checkAndReplyIfDenied(.releaseAwake, clientName: clientName, argumentsSummary: "—", reply: reply) else { return }
            self.powerControl.releaseAssertion()
            reply(true, nil)
        }
    }

    nonisolated func setRefreshInterval(clientName: String, tier: String, seconds: Double, reply: @escaping (Bool, String?) -> Void) {
        Task { @MainActor in
            let summary = "tier=\(tier), seconds=\(seconds)"
            guard self.checkAndReplyIfDenied(.setRefreshInterval, clientName: clientName, argumentsSummary: summary, reply: reply) else { return }
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
            guard self.checkAndReplyIfDenied(.setAlertRuleEnabled, clientName: clientName, argumentsSummary: summary, reply: reply) else { return }
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
            guard self.checkAndReplyIfDenied(.createAlertRule, clientName: clientName, argumentsSummary: summary, reply: reply) else { return }
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
            guard self.checkAndReplyIfDenied(.waitUntilReady, clientName: clientName, argumentsSummary: summary, reply: reply) else { return }

            guard let parsedCondition = WaitCondition(condition) else {
                reply(nil, "Unrecognized condition '\(condition)'. Expected thermal_normal, cpu_below:N, battery_above:N, or memory_below:N.")
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
    /// overload above, just matching `MacStatXPCServiceProtocol`'s write-tool
    /// reply shape (`(Bool, String?) -> Void`) instead of the read-tool one.
    private func checkAndReplyIfDenied(_ tool: MCPToolID, clientName: String, argumentsSummary: String, reply: @escaping (Bool, String?) -> Void) -> Bool {
        let decision = authorize(tool: tool, clientName: clientName, argumentsSummary: argumentsSummary)
        guard decision == .allow else {
            reply(false, denialMessage(decision))
            return false
        }
        return true
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
/// needed, unlike `ResumeOnce` (`MacStatXPCClient.swift`), which guards
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
