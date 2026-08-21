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
///
/// **Now a thin wrapper over `KeepAwakeCommandOutcome`, not its own
/// vocabulary.** This file used to own both the extension's transport
/// (`WidgetControlTransport`, an actor holding one `LocalSyncClient`) and
/// its own two-case error enum. Both moved into `SentryKit` as
/// `KeepAwakeCommandSender`/`KeepAwakeCommandOutcome` when the Live
/// Activity's End button arrived, because that intent is a
/// `LiveActivityIntent` — performed in the *app's* process, therefore
/// compiled into both binaries, therefore unable to reference anything
/// declared in this target. Rather than leave two `LocalSyncClient`s
/// discovering the same Mac from the same extension process, both control
/// surfaces now share one. The argument the old type's doc comment made
/// survives intact over there, including the one that matters most: a
/// control surface never falls back to `MockDataSource` the way
/// `AppDataSource.resolveIfNeeded()` does, because a toggle that silently
/// "succeeds" against fabricated data is the control-surface equivalent of
/// the dishonest widget `WidgetSnapshot.sourceIsDemoData` warns about.
struct WidgetControlError: LocalizedError {
    let outcome: KeepAwakeCommandOutcome

    var errorDescription: String? {
        // `failureMessage` is `nil` only for `.completed`, which
        // `ToggleMacAwakeIntent` never wraps in an error — the fallback
        // exists so this type has no way to present a blank alert.
        outcome.failureMessage
            ?? String(localized: "Didn't hear back from your Mac — make sure Sentry is open and your iPhone is on the same Wi-Fi network.")
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
/// `ReleaseAwakeIntent` sends. Both go through `KeepAwakeCommandSender`
/// (`SentryKit/Sync/KeepAwakeCommandSender.swift`) rather than
/// `AppDataSource.shared` — see that type's doc comment for why an
/// app-extension intent can't reach the app's singleton at all, module
/// boundary aside.
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
        let outcome = await KeepAwakeCommandSender.shared.send(command)
        // Every non-`completed` outcome throws, so Control Center reverts
        // the toggle. This is the same set of distinctions the old
        // hand-rolled version made (no reply, declined) plus the two it
        // silently lost: a send that threw used to propagate a raw
        // `LocalSyncClientError` with no framing, and "no Mac found at all"
        // was indistinguishable from "connected but silent."
        guard outcome.isConfirmed else {
            throw WidgetControlError(outcome: outcome)
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
                // `KeepAwakeRequest` rather than a locally-spelled JSON
                // string — same encoder as both Siri intents and the Watch
                // page, so "identical command regardless of surface" is
                // guaranteed by a shared function instead of by four string
                // literals staying in sync (see that type's doc comment).
                parametersJSON: KeepAwakeRequest.parametersJSON(minutes: toggleDurationMinutes),
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
///
/// **"Lags a few polling intervals" has one exception, and it's handled.**
/// This cache only updates while the phone app is running with a live
/// connection, so a *timed* hold in the cache can sit unchanged long past
/// its own `expiresAt` — a state the toggle used to render as ON even
/// though the hold has certainly released by its own recorded deadline
/// (the OS-level assertion timeout guarantees it, Mac app alive or not —
/// see `SleepAssertionState.isCrediblyActive(asOf:)`). Judging the cached
/// state against *now* is what keeps this toggle from being the most
/// confident surface in the app to show ON for a Mac that went to sleep
/// hours ago. A stale *indefinite* hold still reads ON, deliberately: no
/// deadline in the value disproves it, and inventing an OFF the Mac never
/// reported is the opposite lie.
struct MacAwakeControlValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        guard let snapshot = WidgetSnapshotStore.read() else { return false }
        return snapshot.sleepAssertion.isCrediblyActive(asOf: Date())
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
