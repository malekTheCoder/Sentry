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

    /// Plan §13.4: "'Require confirmation' checkbox per write tool → the app
    /// shows a native confirmation dialog before executing." `runModal`
    /// blocks the main thread until the user answers — acceptable here
    /// because this is already running on a `Task { @MainActor in ... }`
    /// hop off the XPC dispatch queue, not the app's snapshot-publishing
    /// loop; a user staring at a confirmation dialog is, by definition, not
    /// waiting on anything else from this process.
    private func presentConfirmationAlert(tool: MCPToolID, clientName: String, argumentsSummary: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(clientName) wants to \(tool.displayName.lowercased())"
        alert.informativeText = "\(tool.toolDescription)\n\nDetails: \(argumentsSummary)\n\nThis was requested over MCP by an AI agent connected to MacStat. Allow it?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func denialMessage(_ decision: MCPAccessController.Decision) -> String {
        switch decision {
        case .allow:
            return ""
        case .denyMasterDisabled:
            return "MCP access is disabled in MacStat → Settings → AI Access."
        case .denyToolDisabled:
            return "This tool is disabled in MacStat → Settings → AI Access."
        case .denyRateLimited:
            return "MCP rate limit exceeded — configured in MacStat → Settings → AI Access. Try again in a moment."
        case .requiresConfirmation:
            return "The user declined to confirm this action in MacStat."
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

    // MARK: - Write tools

    nonisolated func keepAwake(clientName: String, mode: String, durationSeconds: Double, reason: String, reply: @escaping (Bool, String?) -> Void) {
        Task { @MainActor in
            let summary = "mode=\(mode), durationSeconds=\(durationSeconds), reason=\(reason)"
            guard self.checkAndReplyIfDenied(.keepAwake, clientName: clientName, argumentsSummary: summary, reply: reply) else { return }
            guard let awakeMode = AwakeMode(rawValue: mode) else {
                reply(false, "Unknown mode '\(mode)'. Expected one of: \(AwakeMode.allCases.map(\.rawValue).joined(separator: ", ")).")
                return
            }
            let clampedReason = reason.isEmpty ? "Requested via MCP by \(clientName)" : reason
            do {
                try self.powerControl.startAssertion(
                    mode: awakeMode,
                    duration: durationSeconds > 0 ? durationSeconds : nil,
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
#endif
