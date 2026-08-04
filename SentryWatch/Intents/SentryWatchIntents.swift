import AppIntents
import Foundation
import SentryKit
import WatchConnectivity

// MARK: - WatchControlBridge: the watch's half of "send a command to the Mac"

/// A watch has no direct network path to the Mac (see `WatchRelayManager`'s
/// doc comment, `SentryMobile/Watch/WatchRelayManager.swift` — "a Watch
/// cannot reach the Mac directly"). Every write intent below routes through
/// this bridge instead: it ships a `ControlCommand` to the already-running
/// iPhone app over `WCSession.sendMessage(_:replyHandler:errorHandler:)`,
/// and that phone forwards it through whatever `AppDataSource.shared
/// .transport` it currently has (Bonjour on the LAN, or the TLS-PSK remote
/// listener away from it) — the exact same transport every
/// iPhone Siri intent (`SentryMobile/Intents/SentryIntents.swift`)
/// already uses. Away-from-home Watch control therefore falls out of that
/// work for free, as long as the phone itself is reachable from the watch
/// (ordinary `WCSession` semantics, unrelated to this type).
///
/// **Every failure mode gets its own honest sentence**, mirroring
/// `SentryIntents.sendAndDescribe(_:whenCompleted:)`'s discipline on the
/// phone: not paired/no `WCSession` support, iPhone not reachable right
/// now, iPhone received it but the Mac declined/expired it, or no reply
/// within the timeout. None of these collapse into a generic "something
/// went wrong" — a user tapping through Siri on their wrist deserves to
/// know specifically which link in phone→Mac broke.
enum WatchControlBridge {

    /// How long to wait for the iPhone's reply before telling the user it
    /// didn't hear back. Generous: this covers `WCSession` delivery *plus*
    /// the phone's own `SentryIntents.statusTimeout`-bounded wait for the
    /// Mac's `ControlStatus` — a tight timeout here would cut off a reply
    /// that was already on its way.
    static let timeout: TimeInterval = 10

    /// Sends `command` to the iPhone and returns the dialog every watch
    /// write intent below reports to Siri.
    static func sendAndDescribe(_ command: ControlCommand, whenCompleted successVerb: String) async -> String {
        guard WCSession.isSupported() else {
            return String(localized: "Apple Watch connectivity isn't available on this device.")
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            return String(localized: "Not connected to your iPhone yet.")
        }
        guard session.isReachable else {
            return String(localized: "Your iPhone isn't reachable right now — bring it nearby and make sure Sentry is installed.")
        }
        guard let payload = try? JSONEncoder().encode(command) else {
            return String(localized: "Couldn't build that request.")
        }

        switch await raceReply(payload: ["watchControlCommand": payload], timeout: timeout) {
        case .reply(let reply):
            return describe(reply, whenCompleted: successVerb)
        case .timeout:
            return String(localized: "Sent the request, but didn't hear back from your iPhone in time.")
        case .failed(let message):
            return String(localized: "Couldn't reach your iPhone: \(message)")
        }
    }

    private enum Outcome {
        case reply([String: Any])
        case timeout
        case failed(String)
    }

    /// Races `WCSession`'s callback-based reply against a plain timeout,
    /// the same `withTaskGroup` shape `GetBatteryStatusIntent.firstSnapshot`
    /// (`SentryMobile/Intents/SentryIntents.swift`) already established
    /// for an identical "don't let Siri hang forever" requirement. Only two
    /// resume paths reach the inner continuation (`replyHandler`/
    /// `errorHandler` — `WCSession`'s own contract guarantees exactly one
    /// fires), so no extra guarding against a double-resume is needed there;
    /// the timeout race lives one level up, in the task group, instead of a
    /// third path into the same continuation.
    private static func raceReply(payload: [String: Any], timeout: TimeInterval) async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                    WCSession.default.sendMessage(payload, replyHandler: { reply in
                        continuation.resume(returning: .reply(reply))
                    }, errorHandler: { error in
                        continuation.resume(returning: .failed(error.localizedDescription))
                    })
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                return .timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }
    }

    /// Classifies the iPhone's reply — `["controlStatus": Data]` on success,
    /// `["error": String]` otherwise, matching `WatchRelayManager
    /// .handleWatchControlCommand(_:replyHandler:)`'s exact reply shapes on
    /// the phone side.
    private static func describe(_ reply: [String: Any], whenCompleted successVerb: String) -> String {
        if let errorMessage = reply["error"] as? String {
            return String(localized: "Your iPhone couldn't complete that: \(errorMessage)")
        }
        guard let statusData = reply["controlStatus"] as? Data,
              let status = try? JSONDecoder().decode(ControlStatus.self, from: statusData)
        else {
            return String(localized: "Got an unexpected reply from your iPhone.")
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
}

// MARK: - WatchKeepAwakeIntent

struct WatchKeepAwakeIntent: AppIntent {
    static var title: LocalizedStringResource = "Keep Mac Awake"
    static var description = IntentDescription(
        "Asks your Mac to stay awake for a while, relayed through your iPhone."
    )

    @Parameter(title: "Duration", description: "How long to keep the Mac awake, in minutes.", default: 60)
    var durationMinutes: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let command = ControlCommand(
            deviceID: "unknown",
            issuedAt: Date(),
            commandType: "keepAwake",
            parametersJSON: #"{"durationSeconds":\#(max(durationMinutes, 0) * 60),"mode":"systemOnly"}"#,
            nonce: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
        let dialog = await WatchControlBridge.sendAndDescribe(
            command,
            whenCompleted: String(localized: "Your Mac will stay awake for \(String(durationMinutes)) minutes.")
        )
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - WatchReleaseAwakeIntent

struct WatchReleaseAwakeIntent: AppIntent {
    static var title: LocalizedStringResource = "Release Mac Awake"
    static var description = IntentDescription(
        "Cancels a keep-awake request on your Mac, relayed through your iPhone."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let command = ControlCommand(
            deviceID: "unknown",
            issuedAt: Date(),
            commandType: "releaseAwake",
            parametersJSON: "{}",
            nonce: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
        let dialog = await WatchControlBridge.sendAndDescribe(
            command,
            whenCompleted: String(localized: "Your Mac can sleep normally again.")
        )
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - WatchExtendAwakeIntent / WatchTruncateAwakeIntent

struct WatchExtendAwakeIntent: AppIntent {
    static var title: LocalizedStringResource = "Extend Mac Awake Time"
    static var description = IntentDescription(
        "Adds time to your Mac's current keep-awake countdown, relayed through your iPhone."
    )

    @Parameter(title: "Minutes", description: "How many extra minutes to add.", default: 30)
    var minutes: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let command = ControlCommand(
            deviceID: "unknown",
            issuedAt: Date(),
            commandType: "extendAwake",
            parametersJSON: #"{"deltaSeconds":\#(max(minutes, 0) * 60)}"#,
            nonce: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
        let dialog = await WatchControlBridge.sendAndDescribe(
            command,
            whenCompleted: String(localized: "Added \(String(minutes)) minutes to your Mac's keep-awake time.")
        )
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct WatchTruncateAwakeIntent: AppIntent {
    static var title: LocalizedStringResource = "Shorten Mac Awake Time"
    static var description = IntentDescription(
        "Cuts time off your Mac's current keep-awake countdown, relayed through your iPhone."
    )

    @Parameter(title: "Minutes", description: "How many minutes to cut short.", default: 15)
    var minutes: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let command = ControlCommand(
            deviceID: "unknown",
            issuedAt: Date(),
            commandType: "truncateAwake",
            parametersJSON: #"{"deltaSeconds":\#(max(minutes, 0) * 60)}"#,
            nonce: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
        let dialog = await WatchControlBridge.sendAndDescribe(
            command,
            whenCompleted: String(localized: "Cut \(String(minutes)) minutes off your Mac's keep-awake time.")
        )
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - WatchStopAgentsIntent

/// The kill switch as a Siri intent — "stop the agents on my Mac" from the
/// wrist without opening the app. Sends the same `setAgentAccessPaused`
/// `ControlCommand` the Agent Activity page's button does (see
/// `ContentView.sendStopAgents`), so the two paths cannot diverge in what
/// the Mac receives.
///
/// **No longer engage-only.** This intent used to be paired with a doc
/// comment arguing resume belonged only where the paused state was visible
/// — true when the watch had no way to know whether agent access was
/// paused at all. Now that `WatchRelaySnapshot.agentAccessPaused` carries
/// that state (once the Mac-side hook documented on
/// `StatsCoordinator.agentAccessPaused` lands), the watch can render a
/// truthful resume control, and does: see `WatchResumeAgentsIntent` below
/// and `AgentActivityPage`'s "Resume Agents" button.
struct WatchStopAgentsIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Agents on Mac"
    static var description = IntentDescription(
        "Pauses all AI agent access to your Mac (every MCP tool call is declined and agent keep-awake holds are released), relayed through your iPhone."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let command = ControlCommand(
            deviceID: "unknown",
            issuedAt: Date(),
            commandType: "setAgentAccessPaused",
            parametersJSON: #"{"paused":true}"#,
            nonce: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
        let dialog = await WatchControlBridge.sendAndDescribe(
            command,
            whenCompleted: String(localized: "Agent access on your Mac is paused. Resume it from Sentry on the Mac.")
        )
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - WatchResumeAgentsIntent

/// The un-pause half of the kill switch — "resume agent access on my Mac"
/// from the wrist. Sends the identical `setAgentAccessPaused` command type
/// `WatchStopAgentsIntent` does, with `paused:false` instead of `true` —
/// `LocalCommandExecutor`'s handler for that command type already accepts
/// either value (`SentryKit/Services/LocalCommandExecutor.swift`,
/// `parameters.paused ?? true`), so no new `ControlCommand` type or Mac-side
/// handling was needed for this, only the second value of the one that
/// already existed.
struct WatchResumeAgentsIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Agents on Mac"
    static var description = IntentDescription(
        "Resumes AI agent access to your Mac after it was paused, relayed through your iPhone."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let command = ControlCommand(
            deviceID: "unknown",
            issuedAt: Date(),
            commandType: "setAgentAccessPaused",
            parametersJSON: #"{"paused":false}"#,
            nonce: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
        let dialog = await WatchControlBridge.sendAndDescribe(
            command,
            whenCompleted: String(localized: "Agent access on your Mac has been resumed.")
        )
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - WatchGetBatteryStatusIntent

/// Answered **locally**, no phone round-trip needed — reads
/// `WatchRelayStore.read()` (`SentryKit/Watch/WatchRelayStore.swift`), the
/// exact same cache `WatchSessionController`/the complication already read,
/// rather than a live request. Consistent with the complication's own
/// design: a Watch reading is always "as of the last relay," never
/// guaranteed live, so this intent is honest about that rather than
/// pretending a round-trip would make it any fresher than what's already
/// cached (the phone only relays every 5 minutes at minimum, or sooner on a
/// significant change — see `WatchRelayManager.shouldRelay`).
struct WatchGetBatteryStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Mac Battery Status"
    static var description = IntentDescription(
        "Reports your Mac's battery charge and charging state, from the last update your iPhone relayed."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let snapshot = WatchRelayStore.read() else {
            return .result(dialog: "No battery data yet — open Sentry on your iPhone first.")
        }

        let freshness = Freshness(lastSeen: snapshot.lastSeen)
        let ageLabel = freshness.label(lastSeen: snapshot.lastSeen)

        // Whole localized sentences per charging state, mirroring the
        // iPhone intent's shape — never English fragments glued together.
        let chargeText = String(Int(snapshot.batteryPercent.rounded()))
        var sentence: String
        if snapshot.isCharging {
            sentence = String(localized: "Your Mac's battery is at \(chargeText)%, charging")
        } else if snapshot.isPluggedIn {
            sentence = String(localized: "Your Mac's battery is at \(chargeText)%, plugged in")
        } else {
            sentence = String(localized: "Your Mac's battery is at \(chargeText)%, on battery")
        }
        sentence += " (\(ageLabel))."
        if snapshot.sourceIsDemoData {
            sentence += " " + String(localized: "This is demo data, not a real Mac.")
        }

        return .result(dialog: IntentDialog(stringLiteral: sentence))
    }
}

// MARK: - AppShortcutsProvider

struct SentryWatchAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WatchKeepAwakeIntent(),
            phrases: [
                "Keep my Mac awake with \(.applicationName)",
                "Keep my Mac awake for an hour with \(.applicationName)",
            ],
            shortTitle: "Keep Mac Awake",
            systemImageName: "moon.zzz.fill"
        )
        AppShortcut(
            intent: WatchReleaseAwakeIntent(),
            phrases: [
                "Let my Mac sleep with \(.applicationName)",
                "Release my Mac's keep-awake with \(.applicationName)",
            ],
            shortTitle: "Release Mac Awake",
            systemImageName: "moon.zzz"
        )
        AppShortcut(
            intent: WatchExtendAwakeIntent(),
            phrases: [
                "Give my Mac more awake time with \(.applicationName)",
            ],
            shortTitle: "Extend Awake Time",
            systemImageName: "clock.badge.checkmark"
        )
        AppShortcut(
            intent: WatchTruncateAwakeIntent(),
            phrases: [
                "Shorten my Mac's awake time with \(.applicationName)",
            ],
            shortTitle: "Shorten Awake Time",
            systemImageName: "clock.badge.xmark"
        )
        AppShortcut(
            intent: WatchStopAgentsIntent(),
            phrases: [
                "Stop the agents on my Mac with \(.applicationName)",
                "Pause agent access with \(.applicationName)",
            ],
            shortTitle: "Stop Agents",
            systemImageName: "bolt.slash"
        )
        AppShortcut(
            intent: WatchResumeAgentsIntent(),
            phrases: [
                "Resume the agents on my Mac with \(.applicationName)",
                "Resume agent access with \(.applicationName)",
            ],
            shortTitle: "Resume Agents",
            systemImageName: "bolt"
        )
        AppShortcut(
            intent: WatchGetBatteryStatusIntent(),
            phrases: [
                "What's my Mac's battery with \(.applicationName)",
                "Check my Mac's battery with \(.applicationName)",
            ],
            shortTitle: "Mac Battery Status",
            systemImageName: "battery.100"
        )
    }
}
