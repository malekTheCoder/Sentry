import AppIntents
import AppKit
import SentryKit

// MARK: - AppIntents: real Shortcuts/Siri control, entirely in-process

/// Six `AppIntent`s giving Siri/Shortcuts on **this Mac** real control over
/// (and read access to) the Mac's own `PowerControlService`/`AgentGuardrails`
/// — no network hop of any kind.
///
/// **Why this file exists, and why it looks nothing like
/// `SentryMobile/Intents/SentryIntents.swift`.** The phone's intents
/// construct a `ControlCommand`, hand it to `AppDataSource.shared.transport`
/// (a `LocalSyncClient` over Bonjour/TCP), and await a `ControlStatus` reply
/// — because a phone and a Mac are two different processes on two different
/// devices; the *only* way for one to act on the other is a message over the
/// network. A Mac asking its own Shortcuts app to keep itself awake has no
/// such gap to cross: when macOS runs an `AppIntent` that belongs to a
/// regular application (not an extension), it launches that application if
/// needed and executes `perform()` *inside that same running process* — the
/// exact process already holding the live `PowerControlService`,
/// `StatsCoordinator`, and `SettingsStore` instances `AppDelegate`
/// constructed at launch. Going out to `LocalSyncServer`'s TCP listener (the
/// same transport the phone uses) and back would work, but it would be a
/// deliberate, pointless network round-trip for a same-process call — that
/// server exists for a genuinely remote client, not for this Mac to talk to
/// itself.
///
/// **How this file reaches those live instances without editing
/// `AppDelegate.swift`.** `AppDelegate` composes `coordinator`, `powerControl`
/// and `settingsStore` as `private`/`private lazy` stored properties with no
/// public accessor — by design, `AppDelegate` is this app's single
/// composition root, and every other consumer of these services
/// (`MCPXPCService`, `LocalCommandExecutor`, `AlertEngine`'s closures) is
/// *constructed by* `AppDelegate` and handed its references directly through
/// an initializer, exactly the dependency-injection shape `MCPXPCService`'s
/// own doc comment describes. `AppIntent`s can't be constructed that way —
/// the system instantiates them itself (via their required parameterless
/// initializer) when Siri/Shortcuts invokes one, so there is no constructor
/// call site for `AppDelegate` to inject anything into. Given the added
/// constraint that `AppDelegate.swift` is off-limits to edits for this
/// change (another workstream owns that file concurrently), there is no
/// call site left to *add* a public accessor either. `SentryMacRuntimeServices`
/// below is the honest way around that: `NSApp.delegate` already publicly
/// exposes the live `AppDelegate` instance (it's what `app.delegate = delegate`
/// in `AppDelegate.main()` sets), and `Mirror(reflecting:)` can read a class
/// instance's stored properties — public API Swift provides specifically
/// for runtime introspection, unaffected by `private`'s *compile-time*
/// visibility check — to find the one child of the type we need. This is a
/// deliberate, narrowly-scoped substitute for a same-file accessor, not a
/// general pattern to reach for; if `AppDelegate.swift` is ever open for
/// edits again, replacing this with a plain `internal` accessor (or an
/// `AppDependencyManager`-registered dependency, the officially-blessed
/// `AppIntents` mechanism for exactly this problem) is strictly simpler and
/// should be preferred.
///
/// **Why dialogs here are shorter than the phone's.** Every phone intent's
/// dialog has three tiers — "couldn't reach your Mac," "sent it, but no
/// reply," and the real outcome — because a command crossing a flaky Wi-Fi
/// link genuinely has three outcomes. An in-process call has two: it either
/// runs (and its result is known synchronously, no polling/timeout needed)
/// or the app isn't far enough into launch yet for `NSApp.delegate` to be
/// the real `AppDelegate` — see `SentryMacRuntimeServices.ServiceError`,
/// the one failure mode every intent below shares.
@MainActor
enum SentryMacRuntimeServices {

    /// The one way any intent below fails before it can even try: `NSApp
    /// .delegate` isn't `AppDelegate`, or the property of the requested
    /// type hasn't been reflected yet. In practice this should not happen —
    /// macOS finishes launching the app (running `applicationDidFinishLaunching`,
    /// which touches `coordinator`/`mcpXPCService` and forces their `lazy`
    /// initializers) before handing control to an `AppIntent`'s `perform()`
    /// — but an honest failure sentence costs nothing and a force-unwrap
    /// would turn a should-never-happen edge case into a crash instead of a
    /// declined Shortcut.
    enum ServiceError: Error, LocalizedError {
        case appNotReady

        var errorDescription: String? {
            String(localized: "Sentry hasn't finished starting up yet — try again in a moment.")
        }
    }

    /// Finds the first stored property (plain or already-initialized `lazy`)
    /// on the running `AppDelegate` whose value is of type `T`. Matching by
    /// *type* rather than by property name is what keeps this resilient to
    /// `AppDelegate` renaming its stored properties — it only breaks if
    /// `AppDelegate` ever holds two properties of the same service type
    /// (unlikely: `PowerControlService`'s own doc comment guarantees "exactly
    /// one instance app-wide," and `StatsCoordinator`/`SettingsStore` are
    /// equally singular by construction) or stops holding one at all.
    private static func liveService<T>(_ type: T.Type) -> T? {
        guard let delegate = NSApp.delegate else { return nil }
        let mirror = Mirror(reflecting: delegate)
        for child in mirror.children {
            if let match = child.value as? T {
                return match
            }
        }
        return nil
    }

    static func powerControl() throws -> PowerControlService {
        guard let service = liveService(PowerControlService.self) else { throw ServiceError.appNotReady }
        return service
    }

    static func coordinator() throws -> StatsCoordinator {
        guard let service = liveService(StatsCoordinator.self) else { throw ServiceError.appNotReady }
        return service
    }

    /// The exact same live `SettingsStore` `AIAccessPane`'s "Pause all agent
    /// access (kill switch)" toggle binds to
    /// (`Sentry/Settings/Panes/AIAccessPane.swift`,
    /// `$store.settings.agentGuardrails.killSwitchEngaged`) — not a second
    /// store reading/writing the same `settings.json` file, which would only
    /// take effect after a relaunch (`SettingsStore` has no file-watcher; see
    /// its doc comment) and would leave agent calls flowing right up until
    /// then. Mutating this instance's `@Published settings` triggers the
    /// same `AppDelegate` sink that toggle triggers, live.
    static func settingsStore() throws -> SettingsStore {
        guard let service = liveService(SettingsStore.self) else { throw ServiceError.appNotReady }
        return service
    }
}

// MARK: - AwakeModeAppEnum

/// `AwakeMode` itself can't conform to `AppEnum` directly — `AppEnum`
/// requires `Sendable & CaseDisplayRepresentable`-style metadata (a
/// `TypeDisplayRepresentation` and a `caseDisplayRepresentations` dictionary)
/// that has no reason to live on a plain model type shared with non-Intents
/// code (`SentryKit/Models/AwakeMode.swift`, used by `SleepControlCard`,
/// `PowerControlService`, MCP's `keepAwake` tool, and the phone's own
/// `ControlCommand` JSON). This is the thin Intents-facing wrapper, same
/// separation of concerns as `SentryMacIntentFormatting` below.
enum AwakeModeAppEnum: String, AppEnum {
    case displayAndSystem
    case systemOnly
    case systemWhileOnAC

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Awake Mode")
    }

    static var caseDisplayRepresentations: [AwakeModeAppEnum: DisplayRepresentation] = [
        .displayAndSystem: "Keep Display On",
        .systemOnly: "System Only (Display May Sleep)",
        .systemWhileOnAC: "While Plugged In",
    ]

    var coreMode: AwakeMode {
        switch self {
        case .displayAndSystem: return .displayAndSystem
        case .systemOnly: return .systemOnly
        case .systemWhileOnAC: return .systemWhileOnAC
        }
    }
}

// MARK: - SentryMacIntentFormatting: pure, unit-testable dialog composition

/// Every sentence an intent below can say, factored out into pure functions
/// of a data value — same reason `SentryIntents.sendAndDescribe` centralizes
/// the phone's dialog phrasing: one place to keep the "every failure mode
/// gets its own honest sentence" discipline correct, and something
/// `SentryTests` can exercise without touching `AppIntents`, `NSApp`, or any
/// live service at all.
enum SentryMacIntentFormatting {

    /// Mirrors `GetBatteryStatusIntent`'s dialog
    /// (`SentryMobile/Intents/SentryIntents.swift`) minus the freshness
    /// clause — a same-process read has no transport lag to disclose,
    /// unlike a snapshot that crossed Wi-Fi to reach a phone.
    static func batteryDialog(_ battery: BatteryStats) -> String {
        let chargeText = String(Int(battery.chargePercent.rounded()))
        var sentence: String
        if battery.isCharging, let watts = battery.chargingWatts {
            let wattsText = String(format: "%.0f", watts)
            sentence = String(localized: "This Mac's battery is at \(chargeText)%, charging at \(wattsText) watts.")
        } else if battery.isPluggedIn {
            sentence = String(localized: "This Mac's battery is at \(chargeText)%, plugged in.")
        } else {
            sentence = String(localized: "This Mac's battery is at \(chargeText)%, on battery.")
        }
        if let health = battery.healthPercent {
            let healthText = String(Int(health.rounded()))
            sentence += " " + String(localized: "Battery health is \(healthText)%.")
        }
        return sentence
    }

    /// The dialog for a genuinely new intent — no phone/watch equivalent
    /// exists to mirror (see this file's type doc comment). One clause per
    /// fact, same "whole localized phrase per clause" convention
    /// `GetBatteryStatusIntent` already established, so a translator can
    /// reword any one of them independently.
    static func thermalDialog(_ thermal: ThermalStats) -> String {
        var sentence: String
        switch thermal.pressureLevel {
        case .nominal:
            sentence = String(localized: "This Mac's thermal pressure is nominal.")
        case .fair:
            sentence = String(localized: "This Mac's thermal pressure is fair — it's running a bit warm.")
        case .serious:
            sentence = String(localized: "This Mac's thermal pressure is serious.")
        case .critical:
            sentence = String(localized: "This Mac's thermal pressure is critical.")
        }
        if let soc = thermal.socTemperatureCelsius {
            let socText = String(Int(soc.rounded()))
            sentence += " " + String(localized: "SoC temperature is \(socText)°C.")
        }
        if thermal.isThrottling {
            sentence += " " + String(localized: "It's currently throttling performance to cool down.")
        }
        return sentence
    }

    /// `0` (or below) means "indefinite" — the same reading
    /// `MCPXPCService.keepAwake` gives a non-positive `durationSeconds`
    /// (`clampedDuration > 0 ? clampedDuration : nil`), so "keep my Mac
    /// awake" with no duration spoken and a `0`-defaulted parameter behaves
    /// the same over Siri as it does over MCP, rather than silently keeping
    /// the Mac awake for zero seconds.
    static func keepAwakeDialog(minutes: Int) -> String {
        minutes > 0
            ? String(localized: "This Mac will stay awake for \(minutes) minutes.")
            : String(localized: "This Mac will stay awake until you release it.")
    }

    /// Caps a requested keep-awake duration the same way
    /// `MCPXPCService.keepAwake` caps `durationSeconds` — 24 hours, "an
    /// agent (or a person) wanting longer can renew" — and floors it at
    /// zero so a negative number typed into Shortcuts can't wrap into a huge
    /// unsigned duration downstream.
    static func clampedKeepAwakeMinutes(_ requested: Int) -> Int {
        min(max(requested, 0), 24 * 60)
    }
}

// MARK: - KeepMacAwakeIntent

struct KeepMacAwakeIntent: AppIntent {
    static var title: LocalizedStringResource = "Keep This Mac Awake"
    static var description = IntentDescription(
        "Prevents this Mac from sleeping for a while. Runs entirely on this Mac — no other device needed."
    )

    @Parameter(
        title: "Duration",
        description: "How long to keep this Mac awake, in minutes. 0 keeps it awake until you release it.",
        default: 60
    )
    var durationMinutes: Int

    @Parameter(title: "Mode", description: "What to keep awake.", default: .systemOnly)
    var mode: AwakeModeAppEnum

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let powerControl: PowerControlService
        do {
            powerControl = try SentryMacRuntimeServices.powerControl()
        } catch {
            return .result(dialog: IntentDialog(stringLiteral: error.localizedDescription))
        }

        let minutes = SentryMacIntentFormatting.clampedKeepAwakeMinutes(durationMinutes)
        let duration: TimeInterval? = minutes > 0 ? TimeInterval(minutes) * 60 : nil

        do {
            try powerControl.startAssertion(
                mode: mode.coreMode,
                duration: duration,
                reason: String(localized: "Requested via Shortcuts")
            )
        } catch {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Couldn't keep this Mac awake: \(error.localizedDescription)")))
        }

        return .result(dialog: IntentDialog(stringLiteral: SentryMacIntentFormatting.keepAwakeDialog(minutes: minutes)))
    }
}

// MARK: - ReleaseMacAwakeIntent

struct ReleaseMacAwakeIntent: AppIntent {
    static var title: LocalizedStringResource = "Let This Mac Sleep"
    static var description = IntentDescription(
        "Cancels a keep-awake hold on this Mac, letting it sleep normally again."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let powerControl: PowerControlService
        do {
            powerControl = try SentryMacRuntimeServices.powerControl()
        } catch {
            return .result(dialog: IntentDialog(stringLiteral: error.localizedDescription))
        }

        guard powerControl.state != .inactive else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "This Mac wasn't being kept awake.")))
        }

        powerControl.releaseAssertion()
        return .result(dialog: IntentDialog(stringLiteral: String(localized: "This Mac can sleep normally again.")))
    }
}

// MARK: - GetMacBatteryStatusIntent

struct GetMacBatteryStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get This Mac's Battery Status"
    static var description = IntentDescription(
        "Reports this Mac's battery charge, charging state, and health."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let coordinator: StatsCoordinator
        do {
            coordinator = try SentryMacRuntimeServices.coordinator()
        } catch {
            return .result(dialog: IntentDialog(stringLiteral: error.localizedDescription))
        }

        guard let battery = coordinator.latestSnapshot().battery else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "This Mac didn't report battery data — it might be a desktop Mac with no battery.")))
        }

        return .result(dialog: IntentDialog(stringLiteral: SentryMacIntentFormatting.batteryDialog(battery)))
    }
}

// MARK: - GetMacThermalStatusIntent

/// No phone or watch equivalent exists yet — see this file's type doc
/// comment and `SentryMobile/Intents/SentryIntents.swift`, which has no
/// `GetThermalStatusIntent` at all. Built fresh here from the same
/// `StatsCoordinator.latestSnapshot().thermal` field `MCPXPCService
/// .getThermalStatus` already reads for the MCP `get_thermal_status` tool
/// (`Sentry/App/MCPXPCService.swift`), just phrased as one spoken sentence
/// instead of an encoded `ThermalStats` payload.
struct GetMacThermalStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get This Mac's Thermal Status"
    static var description = IntentDescription(
        "Reports this Mac's current thermal pressure and SoC temperature."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let coordinator: StatsCoordinator
        do {
            coordinator = try SentryMacRuntimeServices.coordinator()
        } catch {
            return .result(dialog: IntentDialog(stringLiteral: error.localizedDescription))
        }

        guard let thermal = coordinator.latestSnapshot().thermal else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "This Mac didn't report thermal data yet.")))
        }

        return .result(dialog: IntentDialog(stringLiteral: SentryMacIntentFormatting.thermalDialog(thermal)))
    }
}

// MARK: - PauseAgentAccessIntent / ResumeAgentAccessIntent

/// Flips `AppSettings.agentGuardrails.killSwitchEngaged` — the exact field
/// `AIAccessPane`'s "Pause all agent access (kill switch)" toggle binds to
/// (`Sentry/Settings/Panes/AIAccessPane.swift`). Not a new mechanism: the
/// enforcement (`MCPXPCService.authorize` calling
/// `AgentGuardrails.evaluate`, and `AppDelegate`'s settings sink releasing
/// any agent-held keep-awake the instant the switch engages) already exists
/// and needs no change here — this intent's whole job is to flip the one
/// setting that mechanism already watches, through the same live
/// `SettingsStore` the pane itself mutates (see
/// `SentryMacRuntimeServices.settingsStore()`'s doc comment for why it must
/// be that instance and not a fresh one).
struct PauseAgentAccessIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause AI Agent Access"
    static var description = IntentDescription(
        "Engages Sentry's kill switch — every AI agent's tool call is declined, and any agent-held keep-awake is released, until you resume it."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store: SettingsStore
        do {
            store = try SentryMacRuntimeServices.settingsStore()
        } catch {
            return .result(dialog: IntentDialog(stringLiteral: error.localizedDescription))
        }

        guard !store.settings.agentGuardrails.killSwitchEngaged else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Agent access is already paused.")))
        }

        store.settings.agentGuardrails.killSwitchEngaged = true
        return .result(dialog: IntentDialog(stringLiteral: String(localized: "Paused AI agent access — every tool call is being declined until you resume it.")))
    }
}

struct ResumeAgentAccessIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume AI Agent Access"
    static var description = IntentDescription(
        "Disengages Sentry's kill switch, letting AI agents call Sentry's tools again — subject to your other guardrails and per-tool settings."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store: SettingsStore
        do {
            store = try SentryMacRuntimeServices.settingsStore()
        } catch {
            return .result(dialog: IntentDialog(stringLiteral: error.localizedDescription))
        }

        guard store.settings.agentGuardrails.killSwitchEngaged else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Agent access isn't paused.")))
        }

        store.settings.agentGuardrails.killSwitchEngaged = false
        return .result(dialog: IntentDialog(stringLiteral: String(localized: "Resumed AI agent access — tool calls are allowed again, subject to your other guardrails.")))
    }
}

// MARK: - AppShortcutsProvider

/// Registers every Siri/Shortcuts phrase this Mac app exposes. Every phrase
/// includes `\(.applicationName)` per Apple's requirement for
/// `AppShortcutsProvider` phrases — same convention
/// `SentryAppShortcuts` follows on the phone
/// (`SentryMobile/Intents/SentryIntents.swift`).
struct SentryMacAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: KeepMacAwakeIntent(),
            phrases: [
                "Keep my Mac awake with \(.applicationName)",
                "Keep this Mac awake for an hour with \(.applicationName)",
            ],
            shortTitle: "Keep Mac Awake",
            systemImageName: "moon.zzz.fill"
        )
        AppShortcut(
            intent: ReleaseMacAwakeIntent(),
            phrases: [
                "Let this Mac sleep with \(.applicationName)",
                "Release this Mac's keep-awake with \(.applicationName)",
            ],
            shortTitle: "Release Mac Awake",
            systemImageName: "moon.zzz"
        )
        AppShortcut(
            intent: GetMacBatteryStatusIntent(),
            phrases: [
                "What's my Mac's battery with \(.applicationName)",
                "Check this Mac's battery with \(.applicationName)",
            ],
            shortTitle: "Mac Battery Status",
            systemImageName: "battery.100"
        )
        AppShortcut(
            intent: GetMacThermalStatusIntent(),
            phrases: [
                "What's my Mac's temperature with \(.applicationName)",
                "Check this Mac's thermal status with \(.applicationName)",
            ],
            shortTitle: "Mac Thermal Status",
            systemImageName: "thermometer.medium"
        )
        AppShortcut(
            intent: PauseAgentAccessIntent(),
            phrases: [
                "Pause AI agent access with \(.applicationName)",
                "Stop AI agents on my Mac with \(.applicationName)",
            ],
            shortTitle: "Pause Agent Access",
            systemImageName: "bolt.slash.fill"
        )
        AppShortcut(
            intent: ResumeAgentAccessIntent(),
            phrases: [
                "Resume AI agent access with \(.applicationName)",
                "Allow AI agents on my Mac with \(.applicationName)",
            ],
            shortTitle: "Resume Agent Access",
            systemImageName: "bolt.fill"
        )
    }
}
