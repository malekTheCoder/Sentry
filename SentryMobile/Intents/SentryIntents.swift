import AppIntents
import Foundation
import SentryKit
import WidgetKit

// MARK: - AppIntents: real Siri/Shortcuts control, over the local-network transport

/// Six `AppIntent`s giving Siri/Shortcuts real control over (and read access
/// to) a Mac on the same local Wi-Fi network, via `AppDataSource.shared
/// .transport` (`SentryMobile/Data/AppDataSource.swift`) — either a real
/// `LocalSyncClient` connected to a Mac, or `MockDataSource` if none has
/// been found yet.
///
/// **What changed from the previous "compiles but always says no" version
/// of this file.** `KeepAwakeIntent`/`ReleaseAwakeIntent` used to
/// unconditionally report "can't reach a Mac" no matter what, because
/// `StatsTransport.send(command:)` had no real conformer — `LocalSyncClient
/// .send(command:)` threw "not supported yet" and `MockDataSource.send
/// (command:)` silently no-op'd. Both now have a real implementation (see
/// `LocalSyncClient.swift`'s and `LocalSyncServer.swift`'s doc comments),
/// and `StatsTransport.awaitStatus(forNonce:timeout:)` lets an intent learn
/// what the Mac actually did with a command instead of just that it was
/// transmitted. Every intent below still reports honestly when nothing
/// answers: a connected-but-silent Mac reads as "sent, but no reply," and
/// `MockDataSource` — whose `send(command:)` is a documented no-op and whose
/// snapshots are invented — reads as demo mode outright, because "sent"
/// would be false (nothing was transmitted) and a spoken battery percentage
/// would be a fabricated reading delivered without the banner or tags the
/// in-app surfaces carry. See `demoModeSendDialog`/`demoModeReadDialog`.
///
/// **Why `sendAndDescribe(_:successVerb:)` is the one place that decides
/// what Siri says.** Every write intent below constructs a `ControlCommand`
/// then defers to this one helper for "send it, wait for a reply, phrase
/// the result" — keeping that logic in one place is what guarantees the
/// honesty rule above actually holds everywhere, instead of five
/// independently-written dialog strings that could drift out of sync with
/// each other over time.
enum SentryIntents {

    /// How long an intent waits for the Mac's `ControlStatus` reply before
    /// telling the user it sent the request but didn't hear back. Siri
    /// itself times out a spoken interaction well before this if it's much
    /// longer, so this stays short — a real local-network round trip
    /// (Bonjour-discovered TCP connection, already established) should
    /// reply in well under a second; this is generous headroom, not an
    /// expected wait.
    static let statusTimeout: TimeInterval = 5

    /// What Siri says when a *write* intent runs while the app is on demo
    /// data. `MockDataSource.send(command:)` no-ops without throwing and its
    /// `awaitStatus` returns `nil` immediately, so before this guard existed
    /// the dialog claimed "Sent the request, but didn't hear back" for a
    /// command that never left the phone. The truthful sentence is that
    /// there is no Mac to send to.
    static var demoModeSendDialog: String {
        String(localized: "Sentry is in demo mode — there's no Mac connected, so nothing was sent. Open Sentry on your Mac on the same Wi-Fi network, then try again.")
    }

    /// The read-intent counterpart: `MockDataSource.snapshots()` yields an
    /// invented reading immediately, so without this guard Siri would speak
    /// a made-up battery percentage or temperature with none of the demo
    /// disclosure every in-app surface carries. A spoken sentence has no
    /// banner, so the sentence itself has to say it.
    static var demoModeReadDialog: String {
        String(localized: "Sentry is in demo mode — there's no Mac connected, so there's no real reading to report. Open Sentry on your Mac on the same Wi-Fi network, then try again.")
    }

    /// Sends `command`, awaits its `ControlStatus` reply, and returns the
    /// dialog every write intent below reports to Siri. `successVerb` is
    /// folded into the "done" phrasing (e.g. "Your Mac will stay awake" vs.
    /// "Your Mac's keep-awake was extended") — the actual completed/
    /// rejected/expired/no-reply branching is identical for every command
    /// type, so it lives here once rather than once per intent.
    static func sendAndDescribe(_ command: ControlCommand, whenCompleted successVerb: String) async -> String {
        let transport = await AppDataSource.shared.transport
        guard !(transport is MockDataSource) else {
            return demoModeSendDialog
        }
        do {
            try await transport.send(command: command)
        } catch {
            return String(localized: "Couldn't reach your Mac — \(error.localizedDescription)")
        }
        guard let status = await transport.awaitStatus(forNonce: command.nonce, timeout: statusTimeout) else {
            return String(localized: "Sent the request, but didn't hear back from your Mac — make sure Sentry is open and your iPhone is on the same Wi-Fi network.")
        }
        switch status.state {
        case "completed":
            return successVerb
        case "rejected":
            return String(localized: "Your Mac declined that: \(status.message)")
        case "expired":
            return String(localized: "That request expired before your Mac could act on it.")
        default:
            return status.message
        }
    }

    /// The Mac this app's intents target — there's no device picker yet
    /// (only one Mac is supported per `AppDataSource`'s own documented
    /// simplification), so every intent falls back to whatever `AppDataSource
    /// .devices()` already knows, or `"unknown"` if nothing has been seen —
    /// same placeholder this file used before real transport existed.
    static func targetDeviceID() async -> String {
        await AppDataSource.shared.devices().first?.deviceID ?? "unknown"
    }
}

// MARK: - KeepAwakeIntent

struct KeepAwakeIntent: AppIntent {
    static var title: LocalizedStringResource = "Keep Mac Awake"
    static var description = IntentDescription(
        "Asks your Mac to stay awake for a while. Needs Sentry open on a Mac on the same Wi-Fi network."
    )

    @Parameter(title: "Duration", description: "How long to keep the Mac awake, in minutes.", default: 60)
    var durationMinutes: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let command = ControlCommand(
            deviceID: await SentryIntents.targetDeviceID(),
            issuedAt: Date(),
            commandType: "keepAwake",
            parametersJSON: #"{"durationSeconds":\#(max(durationMinutes, 0) * 60),"mode":"systemOnly"}"#,
            nonce: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
        let dialog = await SentryIntents.sendAndDescribe(
            command,
            whenCompleted: String(localized: "Your Mac will stay awake for \(String(durationMinutes)) minutes.")
        )
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - ReleaseAwakeIntent

struct ReleaseAwakeIntent: AppIntent {
    static var title: LocalizedStringResource = "Release Mac Awake"
    static var description = IntentDescription(
        "Cancels a keep-awake request on your Mac, letting it sleep normally again."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let command = ControlCommand(
            deviceID: await SentryIntents.targetDeviceID(),
            issuedAt: Date(),
            commandType: "releaseAwake",
            parametersJSON: "{}",
            nonce: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
        let dialog = await SentryIntents.sendAndDescribe(
            command,
            whenCompleted: String(localized: "Your Mac can sleep normally again.")
        )
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - ExtendAwakeIntent / TruncateAwakeIntent

/// Siri-facing counterparts to `SleepStatusCard`'s "+15m"/"+1h" adjust
/// buttons (`SentryMobile/Dashboard/SleepStatusCard.swift`) — same
/// `extendAwake` command type, same `deltaSeconds` parameter shape,
/// same underlying `PowerControlService.adjustAssertion(bySeconds:)` on the
/// Mac. Only meaningful against a *timed* keep-awake hold; a Mac with no
/// active hold, or an indefinite/conditional one, reports back through the
/// same "Your Mac declined that: ..." branch every other rejection uses
/// (see `LocalCommandExecutor.execute(_:)`'s `PowerControlError
/// .noAdjustableAssertion` handling).
struct ExtendAwakeIntent: AppIntent {
    static var title: LocalizedStringResource = "Extend Mac Awake Time"
    static var description = IntentDescription(
        "Adds time to your Mac's current keep-awake countdown."
    )

    @Parameter(title: "Minutes", description: "How many extra minutes to add.", default: 30)
    var minutes: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let command = ControlCommand(
            deviceID: await SentryIntents.targetDeviceID(),
            issuedAt: Date(),
            commandType: "extendAwake",
            parametersJSON: #"{"deltaSeconds":\#(max(minutes, 0) * 60)}"#,
            nonce: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
        let dialog = await SentryIntents.sendAndDescribe(
            command,
            whenCompleted: String(localized: "Added \(String(minutes)) minutes to your Mac's keep-awake time.")
        )
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct TruncateAwakeIntent: AppIntent {
    static var title: LocalizedStringResource = "Shorten Mac Awake Time"
    static var description = IntentDescription(
        "Cuts time off your Mac's current keep-awake countdown."
    )

    @Parameter(title: "Minutes", description: "How many minutes to cut short.", default: 15)
    var minutes: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let command = ControlCommand(
            deviceID: await SentryIntents.targetDeviceID(),
            issuedAt: Date(),
            commandType: "truncateAwake",
            parametersJSON: #"{"deltaSeconds":\#(max(minutes, 0) * 60)}"#,
            nonce: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
        let dialog = await SentryIntents.sendAndDescribe(
            command,
            whenCompleted: String(localized: "Cut \(String(minutes)) minutes off your Mac's keep-awake time.")
        )
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - GetBatteryStatusIntent

/// A read-only counterpart to the four control intents above — "Hey Siri,
/// what's my Mac's battery" without opening the app. Reads the next
/// `SystemSnapshot` the current transport produces rather than a command
/// round-trip (there's no `ControlCommand` for "tell me your battery,"
/// snapshots already stream continuously), bounded by the same
/// `SentryIntents.statusTimeout` every write intent uses for its own wait,
/// so a Mac that's asleep/unreachable fails the same honest way instead of
/// hanging Siri indefinitely.
struct GetBatteryStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Mac Battery Status"
    static var description = IntentDescription(
        "Reports your Mac's battery charge, charging state, and health."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let transport = await AppDataSource.shared.transport
        guard !(transport is MockDataSource) else {
            return .result(dialog: IntentDialog(stringLiteral: SentryIntents.demoModeReadDialog))
        }
        guard let snapshot = await Self.firstSnapshot(from: transport, timeout: SentryIntents.statusTimeout) else {
            return .result(dialog: "Couldn't get a reading from your Mac — make sure Sentry is open and your iPhone is on the same Wi-Fi network.")
        }
        guard let battery = snapshot.battery else {
            return .result(dialog: "Your Mac reported in, but didn't include battery data — it might be a desktop Mac with no battery.")
        }

        let freshness = Freshness(lastSeen: snapshot.timestamp)
        let ageLabel = freshness.label(lastSeen: snapshot.timestamp)

        // Each clause is a whole localized phrase, so a translator can
        // reword every fragment. The clause *order* is fixed by this
        // composition — acceptable for an enumeration of facts, where the
        // alternative (one key per combination) would be 12 near-duplicate
        // sentences no one would keep in sync.
        let chargeText = String(Int(battery.chargePercent.rounded()))
        var sentence: String
        if battery.isCharging, let watts = battery.chargingWatts {
            let wattsText = String(format: "%.0f", watts)
            sentence = String(localized: "Your Mac's battery is at \(chargeText)%, charging at \(wattsText) watts")
        } else if battery.isPluggedIn {
            sentence = String(localized: "Your Mac's battery is at \(chargeText)%, plugged in")
        } else {
            sentence = String(localized: "Your Mac's battery is at \(chargeText)%, on battery")
        }
        if let health = battery.healthPercent {
            let healthText = String(Int(health.rounded()))
            sentence += String(localized: ". Battery health is \(healthText)%")
        }
        if case .active(_, let expiresAt, _) = snapshot.sleepAssertion {
            sentence += expiresAt != nil
                ? String(localized: ". Sleep is currently being prevented")
                : String(localized: ". Sleep is being prevented indefinitely")
        }
        sentence += " (\(ageLabel))."

        return .result(dialog: IntentDialog(stringLiteral: sentence))
    }

    /// Races the transport's snapshot stream against `timeout` and returns
    /// whichever comes first — `nil` on timeout. A plain `for try await`
    /// loop over `transport.snapshots()` with no timeout would hang forever
    /// against `MockDataSource`'s slower cadence or a genuinely unreachable
    /// Mac, which is exactly the failure mode every other intent in this
    /// file already guards against.
    static func firstSnapshot(from transport: any StatsTransport, timeout: TimeInterval) async -> SystemSnapshot? {
        await withTaskGroup(of: SystemSnapshot?.self) { group in
            group.addTask {
                for await snapshot in transport.snapshots() {
                    return snapshot
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - GetThermalStatusIntent

/// A read-only counterpart to `GetBatteryStatusIntent`, same shape exactly:
/// races the transport's snapshot stream against `SentryIntents.statusTimeout`
/// via `GetBatteryStatusIntent.firstSnapshot(from:timeout:)` (reused rather
/// than duplicated — both intents want the identical "first snapshot or
/// timeout" race, and a second copy of that `withTaskGroup` would be a second
/// place to get the timeout race subtly wrong).
struct GetThermalStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Mac Thermal Status"
    static var description = IntentDescription(
        "Reports your Mac's thermal pressure and SoC temperature."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let transport = await AppDataSource.shared.transport
        guard !(transport is MockDataSource) else {
            return .result(dialog: IntentDialog(stringLiteral: SentryIntents.demoModeReadDialog))
        }
        guard let snapshot = await GetBatteryStatusIntent.firstSnapshot(from: transport, timeout: SentryIntents.statusTimeout) else {
            return .result(dialog: "Couldn't get a reading from your Mac — make sure Sentry is open and your iPhone is on the same Wi-Fi network.")
        }
        guard let thermal = snapshot.thermal else {
            return .result(dialog: "Your Mac reported in, but didn't include thermal data.")
        }

        let freshness = Freshness(lastSeen: snapshot.timestamp)
        let ageLabel = freshness.label(lastSeen: snapshot.timestamp)

        let pressureText: String
        switch thermal.pressureLevel {
        case .nominal: pressureText = String(localized: "normal")
        case .fair: pressureText = String(localized: "elevated")
        case .serious: pressureText = String(localized: "serious")
        case .critical: pressureText = String(localized: "critical")
        }

        var sentence = String(localized: "Your Mac's thermal pressure is \(pressureText)")
        if let socTemperature = thermal.socTemperatureCelsius {
            // Spelled-out form, unlike the Mac intent's "78°C" — this one is
            // spoken far more often than it is read, and Siri does not
            // reliably pronounce a degree sign. `TemperatureFormatter
            // .spoken` produces "78 degrees Celsius" / "172 degrees
            // Fahrenheit" following this phone's own Settings ▸ Units
            // choice; the reading itself arrives from the Mac in Celsius
            // either way.
            let temperatureText = TemperatureFormatter.spoken(celsius: socTemperature)
            sentence += String(localized: ", at \(temperatureText)")
        }
        if thermal.isThrottling {
            sentence += String(localized: ". Your Mac is currently throttling to cool down")
        }
        sentence += " (\(ageLabel))."

        return .result(dialog: IntentDialog(stringLiteral: sentence))
    }
}

// MARK: - GetProtectionScoreIntent

/// A read-only intent for "what's my Mac's protection score" — but a
/// deliberately scoped-down one, and the scoping is worth spelling out
/// rather than hiding.
///
/// **What a full implementation would need, and why it isn't this.** A
/// protection score comes out of `ProtectionInsightsEngine.evaluate(_:)`
/// (`SentryKit/Insights/ProtectionInsightsEngine.swift`), which
/// `InsightsViewModel`'s own doc comment
/// (`Sentry/Insights/InsightsViewModel.swift`) describes as "a
/// security-posture sweep plus fifteen `HistoryStore` reads plus forty-odd
/// rule evaluations" — expensive by design, run only when the Mac's
/// Insights tab is opened or explicitly refreshed, and explicitly never on
/// a timer ("a protection report that silently re-computed every minute
/// would spend real CPU on a screen nobody is looking at"). Building a live,
/// on-demand version of that computation reachable from an iPhone Siri
/// intent would mean either running that whole sweep on every Siri
/// invocation (defeats the entire reason it's throttled) or building a new
/// push/cache path from the Mac's Insights tab through to the transport —
/// real work, on the far side of a boundary this branch was not asked to
/// build (`SentryKit/Insights/` is explicitly off-limits here).
///
/// **What this intent actually does.** It reads
/// `SystemSnapshot.protectionScore` — the same field
/// `StatsCoordinator.protectionScore`'s doc comment describes as wired
/// end-to-end but not yet assigned by the Mac composition root (the same
/// one-line-hook gap `agentAccessPaused` has, for the identical "AppDelegate
/// is off-limits" reason). Until that hook lands, every real Mac reports
/// `nil` here, and this intent says so honestly — "hasn't reported a score"
/// is a true sentence today, not a fabricated one, and it is the same
/// honesty rule `GetBatteryStatusIntent` already applies to a Mac with no
/// battery. Once the hook lands, this intent needs no further changes: the
/// wire format and the read path are both already real.
struct GetProtectionScoreIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Mac Protection Score"
    static var description = IntentDescription(
        "Reports your Mac's protection score from Sentry's Insights tab, if one has been computed."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let transport = await AppDataSource.shared.transport
        guard !(transport is MockDataSource) else {
            return .result(dialog: IntentDialog(stringLiteral: SentryIntents.demoModeReadDialog))
        }
        guard let snapshot = await GetBatteryStatusIntent.firstSnapshot(from: transport, timeout: SentryIntents.statusTimeout) else {
            return .result(dialog: "Couldn't get a reading from your Mac — make sure Sentry is open and your iPhone is on the same Wi-Fi network.")
        }
        guard let score = snapshot.protectionScore else {
            return .result(dialog: "Your Mac hasn't reported a protection score yet — open the Insights tab in Sentry on your Mac to compute one.")
        }

        let freshness = Freshness(lastSeen: snapshot.timestamp)
        let ageLabel = freshness.label(lastSeen: snapshot.timestamp)
        let scoreText = String(score)
        return .result(dialog: IntentDialog(stringLiteral: String(localized: "Your Mac's protection score is \(scoreText) out of 100 (\(ageLabel)).")))
    }
}

// MARK: - GetAgentGuardrailsStatusIntent

/// "Is AI agent access paused right now" — reads
/// `SystemSnapshot.agentAccessPaused`, the same field
/// `WatchRelaySnapshot.agentAccessPaused` relays on to the watch (see that
/// type's doc comment for the tri-state convention this mirrors: `true`
/// paused, `false` active, `nil` unreported). This intent is a straight
/// read of a `SystemSnapshot` field, so — unlike `GetProtectionScoreIntent`
/// above — it needs no further plumbing beyond the same one-line
/// composition-root hook `StatsCoordinator.agentAccessPaused`'s doc comment
/// already documents; the wire format and this read path are both real
/// today.
struct GetAgentGuardrailsStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Agent Guardrails Status"
    static var description = IntentDescription(
        "Reports whether AI agent access to your Mac is currently paused."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let transport = await AppDataSource.shared.transport
        guard !(transport is MockDataSource) else {
            return .result(dialog: IntentDialog(stringLiteral: SentryIntents.demoModeReadDialog))
        }
        guard let snapshot = await GetBatteryStatusIntent.firstSnapshot(from: transport, timeout: SentryIntents.statusTimeout) else {
            return .result(dialog: "Couldn't get a reading from your Mac — make sure Sentry is open and your iPhone is on the same Wi-Fi network.")
        }

        let freshness = Freshness(lastSeen: snapshot.timestamp)
        let ageLabel = freshness.label(lastSeen: snapshot.timestamp)

        switch snapshot.agentAccessPaused {
        case true:
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Yes — AI agent access to your Mac is paused (\(ageLabel))."))
            )
        case false:
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "No — AI agent access to your Mac is active (\(ageLabel))."))
            )
        case nil:
            return .result(dialog: "Your Mac hasn't reported whether agent access is paused.")
        }
    }
}

// MARK: - RefreshWidgetIntent

/// Re-reads the widget's already-real, already-local `WidgetSnapshotStore`
/// cache and asks WidgetKit to reload from it — needs no live Mac
/// connection at all, since the cache is written by `WidgetSnapshotWriter`
/// from data the phone app already has in-process.
struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Sentry Widget"
    static var description = IntentDescription(
        "Reloads the Sentry widget from the most recent data cached on this iPhone."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog {
        WidgetCenter.shared.reloadAllTimelines()
        guard let snapshot = WidgetSnapshotStore.read() else {
            return .result(dialog: "Widget reload requested, but there's no cached data yet — open Sentry first.")
        }
        let freshness = Freshness(lastSeen: snapshot.lastSeen)
        let ageLabel = freshness.label(lastSeen: snapshot.lastSeen)
        return .result(dialog: "Widget refreshed from the data cached on this iPhone (\(ageLabel)).")
    }
}

// MARK: - AppShortcutsProvider

/// Registers every Siri phrase this app exposes. Registering a phrase
/// doesn't change what its intent actually does — every write intent above
/// still reports the honest outcome `sendAndDescribe(_:whenCompleted:)`
/// produces no matter how it was invoked (Shortcuts app, widget button, or
/// Siri).
struct SentryAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: KeepAwakeIntent(),
            phrases: [
                "Keep my Mac awake with \(.applicationName)",
                "Keep my Mac awake for an hour with \(.applicationName)",
            ],
            shortTitle: "Keep Mac Awake",
            systemImageName: "moon.zzz.fill"
        )
        AppShortcut(
            intent: ReleaseAwakeIntent(),
            phrases: [
                "Let my Mac sleep with \(.applicationName)",
                "Release my Mac's keep-awake with \(.applicationName)",
            ],
            shortTitle: "Release Mac Awake",
            systemImageName: "moon.zzz"
        )
        AppShortcut(
            intent: ExtendAwakeIntent(),
            phrases: [
                "Give my Mac more awake time with \(.applicationName)",
                "Extend my Mac's awake time with \(.applicationName)",
            ],
            shortTitle: "Extend Awake Time",
            systemImageName: "clock.badge.checkmark"
        )
        AppShortcut(
            intent: TruncateAwakeIntent(),
            phrases: [
                "Shorten my Mac's awake time with \(.applicationName)",
            ],
            shortTitle: "Shorten Awake Time",
            systemImageName: "clock.badge.xmark"
        )
        AppShortcut(
            intent: GetBatteryStatusIntent(),
            phrases: [
                "What's my Mac's battery with \(.applicationName)",
                "Check my Mac's battery with \(.applicationName)",
            ],
            shortTitle: "Mac Battery Status",
            systemImageName: "battery.100"
        )
        AppShortcut(
            intent: GetThermalStatusIntent(),
            phrases: [
                "What's my Mac's temperature with \(.applicationName)",
                "Check my Mac's thermal status with \(.applicationName)",
            ],
            shortTitle: "Mac Thermal Status",
            systemImageName: "thermometer.medium"
        )
        AppShortcut(
            intent: GetProtectionScoreIntent(),
            phrases: [
                "What's my Mac's protection score with \(.applicationName)",
                "Check my Mac's protection score with \(.applicationName)",
            ],
            shortTitle: "Mac Protection Score",
            systemImageName: "checkmark.shield"
        )
        AppShortcut(
            intent: GetAgentGuardrailsStatusIntent(),
            phrases: [
                "Is AI agent access paused with \(.applicationName)",
                "Check agent guardrails with \(.applicationName)",
            ],
            shortTitle: "Agent Guardrails Status",
            systemImageName: "shield.lefthalf.filled"
        )
        AppShortcut(
            intent: RefreshWidgetIntent(),
            phrases: [
                "Refresh my \(.applicationName) widget",
            ],
            shortTitle: "Refresh Widget",
            systemImageName: "arrow.clockwise"
        )
    }
}
