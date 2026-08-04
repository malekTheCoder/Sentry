import AppIntents
import SentryKit
import SwiftUI
import WidgetKit

// MARK: - iOS-only: Control Center has no macOS 14 equivalent

// `ControlWidget`/`AppIntentControlConfiguration` need iOS 18 / macOS 15 —
// this project's macOS deployment target is 14.0 (`project.yml`), same
// floor `SentryWidgetExtension_macOS` builds against, so this whole file
// would refuse to compile there. `SentryWidget/` is one shared source
// directory for both the iOS and macOS widget-extension targets (see
// `SentryWidgetBundle.swift`'s `families` doc comment for the same
// iOS-vs-macOS split on a different axis), so the guard has to be a
// compile-time `#if os(iOS)` around the whole file rather than an
// `@available` annotation alone — `@available` would still need the
// declarations to *type-check* against a macOS 14 SDK, which the Control
// Center types don't.
#if os(iOS)

// MARK: - WidgetControlTransport

/// The widget extension's own `StatsTransport` connection, entirely
/// separate from `AppDataSource.shared`
/// (`SentryMobile/Data/AppDataSource.swift`) for the same reason
/// `WidgetRefreshIntent`'s doc comment gives for not reusing
/// `RefreshWidgetIntent` directly: an app extension is a different
/// process from its containing app, so there is no in-process singleton to
/// share even if the module boundary allowed referencing one. Every
/// `ToggleMacAwakeIntent` invocation needs *a* `LocalSyncClient`
/// (`SentryKit/LocalSync/LocalSyncClient.swift`) the same way
/// `AppDataSource` needs one — one Bonjour browser and one socket per
/// process, not one per toggle tap.
///
/// Deliberately never falls back to a mock transport the way
/// `AppDataSource.resolveIfNeeded()` falls back to `MockDataSource` for
/// browsing purposes. A Control Center toggle that silently "succeeds"
/// against fabricated data would be the control-surface equivalent of the
/// dishonest widget `WidgetSnapshot.sourceIsDemoData`'s doc comment warns
/// against — so `ToggleMacAwakeIntent` below throws, and the toggle
/// visibly reverts, when there is no real Mac to reach.
actor WidgetControlTransport {
    static let shared = WidgetControlTransport()

    /// Mirrors `SentryIntents.statusTimeout` — long enough for a real
    /// Bonjour discovery + TCP handshake on a healthy local network, short
    /// enough that a Control Center tap doesn't hang the system UI waiting
    /// on a Mac that isn't there at all.
    static let discoveryTimeout: TimeInterval = 5

    private let client = LocalSyncClient()

    /// Returns the shared client, having attempted a connection if one
    /// isn't already up. `waitForFirstConnection(timeout:)` returns
    /// immediately (`true`) when already connected — see that method's own
    /// doc comment — so calling this on every intent invocation costs
    /// nothing once a connection exists, and re-attempts discovery on every
    /// call while one doesn't, rather than latching a permanent "gave up"
    /// state that would keep failing for the rest of the extension
    /// process's lifetime after one transient miss.
    func connectedClient() async -> LocalSyncClient {
        _ = await client.waitForFirstConnection(timeout: Self.discoveryTimeout)
        return client
    }
}

// MARK: - WidgetControlError

/// What `ToggleMacAwakeIntent.perform()` throws on anything short of the
/// Mac actually completing the command. `SetValueIntent`'s contract is
/// that a thrown `perform()` reverts the Control Center toggle to its
/// previous state — the correct visible outcome here, matching
/// `SentryIntents.sendAndDescribe(_:whenCompleted:)`'s honesty rule
/// (`SentryMobile/Intents/SentryIntents.swift`) that a command with no
/// confirmed effect is never reported as having succeeded, just expressed
/// through a thrown error instead of a dialog string since a Control
/// Center toggle has nowhere to show one.
enum WidgetControlError: LocalizedError {
    case noReply
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .noReply:
            return String(localized: "Didn't hear back from your Mac — make sure Sentry is open and your iPhone is on the same Wi-Fi network.")
        case .rejected(let message):
            return String(localized: "Your Mac declined that: \(message)")
        }
    }
}

// MARK: - ToggleMacAwakeIntent

/// The Control Center counterpart to `KeepAwakeIntent`/`ReleaseAwakeIntent`
/// (`SentryMobile/Intents/SentryIntents.swift`) — one `SetValueIntent`
/// instead of two separate action intents, because
/// `AppIntentControlConfiguration`'s toggle shape (`ControlWidgetToggle`)
/// needs a single intent whose `value: Bool` parameter *is* the desired
/// end state, not two independently-invoked commands. `true` sends the
/// same `keepAwake` command `KeepAwakeIntent` sends (fixed one-hour
/// duration — Control Center has no room for a duration picker the way
/// `KeepAwakeIntent`'s Siri parameter or `SleepStatusCard`'s duration
/// stepper do); `false` sends the same `releaseAwake` command
/// `ReleaseAwakeIntent` sends. Both go through `WidgetControlTransport`
/// rather than `AppDataSource.shared` — see that type's doc comment for
/// why an app-extension intent can't reach the app's singleton at all,
/// module boundary aside.
struct ToggleMacAwakeIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Keep Mac Awake"
    static var description = IntentDescription(
        "Keeps your Mac awake, or lets it sleep normally again. Needs Sentry open on a Mac on the same Wi-Fi network."
    )

    /// How long a Control Center-initiated keep-awake hold lasts — same
    /// value `KeepAwakeIntent`'s `durationMinutes` defaults to, since a
    /// toggle has no UI of its own to ask for a different one. Extending
    /// or shortening it afterward is still available through
    /// `ExtendAwakeIntent`/`TruncateAwakeIntent` via Siri, or
    /// `SleepStatusCard`'s adjust buttons in the app itself.
    static let toggleDurationMinutes = 60

    @Parameter(title: "Keep Awake")
    var value: Bool

    func perform() async throws -> some IntentResult {
        let command = Self.command(turningOn: value)
        let client = await WidgetControlTransport.shared.connectedClient()
        try await client.send(command: command)
        guard let status = await client.awaitStatus(forNonce: command.nonce, timeout: WidgetControlTransport.discoveryTimeout) else {
            throw WidgetControlError.noReply
        }
        guard status.state == "completed" else {
            throw WidgetControlError.rejected(status.message)
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }

    /// Builds the `keepAwake`/`releaseAwake` `ControlCommand`, mirroring
    /// `KeepAwakeIntent`/`ReleaseAwakeIntent`'s construction exactly (same
    /// `parametersJSON` shape, same 5-minute expiry window) so
    /// `LocalCommandExecutor` on the Mac side (`SentryKit/Services/
    /// LocalCommandExecutor.swift`) sees an identical command regardless of
    /// which surface — Siri, the app's sleep card, or this toggle — sent
    /// it. `deviceID: "unknown"` matches `SentryIntents.targetDeviceID()`'s
    /// own fallback for exactly the same reason: this transport's wire
    /// protocol has no `Device` catalog, only whatever `deviceID` the most
    /// recent received `SystemSnapshot` carried (`LocalSyncClient
    /// .lastKnownDeviceID()`), which may still be `nil` immediately after a
    /// fresh connection — `LocalSyncServer` does not reject a command over
    /// its `deviceID` field (see `LocalSyncClient.send(command:)`'s doc
    /// comment: the receiving connection is itself the authentication), so
    /// this is honestly a label, not a routing key.
    static func command(turningOn: Bool) -> ControlCommand {
        let nonce = UUID().uuidString
        let expiresAt = Date().addingTimeInterval(5 * 60)
        if turningOn {
            return ControlCommand(
                deviceID: "unknown",
                issuedAt: Date(),
                commandType: "keepAwake",
                parametersJSON: #"{"durationSeconds":\#(toggleDurationMinutes * 60),"mode":"systemOnly"}"#,
                nonce: nonce,
                expiresAt: expiresAt
            )
        } else {
            return ControlCommand(
                deviceID: "unknown",
                issuedAt: Date(),
                commandType: "releaseAwake",
                parametersJSON: "{}",
                nonce: nonce,
                expiresAt: expiresAt
            )
        }
    }
}

// MARK: - MacAwakeControlValueProvider

/// Reports the toggle's displayed state from the same App-Group cache the
/// home screen widgets read (`WidgetSnapshotStore`,
/// `SentryKit/Sync/WidgetSnapshot.swift`) rather than opening a live
/// connection just to render Control Center — Control Center calls
/// `currentValue()` far more often (any time it's opened, previewed, or
/// periodically refreshed by the system) than a real Bonjour round trip
/// should run for a read-only display, and a cached-but-possibly-stale
/// reading here fails the same honest way every other cached read in this
/// app does: it can lag a few polling intervals behind, exactly like
/// `Provider.getTimeline`'s own cache read, but never fabricates a state
/// with no cache behind it (`false`/"not awake" whenever the cache is
/// empty, matching `WidgetSnapshotWriter`'s own `.inactive` default noted
/// in `MediumWidgetView.sleepRow`'s doc comment).
struct MacAwakeControlValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        guard let snapshot = WidgetSnapshotStore.read() else { return false }
        if case .active = snapshot.sleepAssertion {
            return true
        }
        return false
    }
}

// MARK: - MacAwakeControlWidget

/// The Control Center entry for keeping this Mac awake — plan §12.3's
/// home-screen widget families' Control Center counterpart, added directly
/// against `ToggleMacAwakeIntent` rather than any Siri/Shortcuts surface.
/// `ControlWidget` conforms to `Widget`, so it's registered the same way
/// as `SentryWidget` itself: added to `SentryWidgetBundle`'s `body`, guarded
/// there by the same `#available(iOS 18.0, *)` this type requires.
///
/// **`StaticControlConfiguration`, not `AppIntentControlConfiguration`.**
/// The latter exists for a control whose *identity/configuration* itself
/// comes from an `AppIntent` parameter (Apple's own sample is a control
/// configured to a specific user-chosen item, e.g. "which timer"). This
/// control has exactly one fixed target — the one Mac `AppDataSource`
/// (and, in this extension, `WidgetControlTransport`) already assumes is
/// the only one — so there is no configuration surface to pick from, only
/// a value to read and toggle: precisely what `StaticControlConfiguration
/// (kind:provider:content:)` paired with `ControlValueProvider` is for.
@available(iOS 18.0, *)
struct MacAwakeControlWidget: ControlWidget {
    /// Reverse-DNS kind string, namespaced under the same bundle identifier
    /// prefix `SentryWidget`'s own `kind` ("SentryWidget") and every other
    /// product identifier in this project use
    /// (`dev.malekswilam.sentry.mobile.widget` is this extension's own
    /// `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`) — Control Center kinds
    /// share the same global namespace as widget kinds, so this can't
    /// collide with `SentryWidget.kind` or a future control this project
    /// adds.
    static let kind = "dev.malekswilam.sentry.mobile.widget.keepawake"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: Self.kind,
            provider: MacAwakeControlValueProvider()
        ) { isAwake in
            ControlWidgetToggle(
                "Keep Mac Awake",
                isOn: isAwake,
                action: ToggleMacAwakeIntent()
            ) { isOn in
                // `Label`, not raw text — Control Center renders this at
                // sizes/contexts (the toggle row, the Lock Screen control
                // gallery) that already respect Dynamic Type through the
                // system's own control chrome; there is no custom `Font`
                // here to get wrong the way a hand-laid-out widget view
                // would need to (see `SmallWidgetView`'s watts/freshness
                // labels for where that discipline matters instead).
                Label(
                    isOn ? String(localized: "Awake") : String(localized: "Keep Awake"),
                    systemImage: isOn ? "moon.zzz.fill" : "moon.zzz"
                )
            }
        }
        .displayName("Keep Mac Awake")
        .description("Keeps your Mac awake, or lets it sleep normally again, from Control Center.")
    }
}

#endif
