import AppIntents
import Foundation
import MacStatKit
import WidgetKit

// MARK: - AppIntents: Phase 6 checklist — "keep awake, release, refresh"

/// Three `AppIntent`s so Siri/Shortcuts integration exists and *compiles*
/// against this build (plan §12.3: "'Hey Siri, keep my Mac awake for an
/// hour' works" is the phase's exit criterion) — while staying honest about
/// what actually happens when invoked, which today is "nothing reaches a
/// real Mac" for two of the three.
///
/// **Why `KeepAwakeIntent`/`ReleaseAwakeIntent` no-op instead of pretending
/// to succeed.** Both are meant to eventually round-trip a `ControlCommand`
/// to a real Mac over CloudKit (plan §7.6) — exactly the control path
/// `SleepStatusCard`'s doc comment (`MacStatMobile/Dashboard/SleepStatusCard.swift`)
/// already explains doesn't exist in this build, for the same reason
/// `MockDataSource.send(command:)` is a logged no-op: there is no enrolled
/// Apple Developer Program account, no `CKContainer`, and therefore no Mac
/// on the other end of any command this intent could construct. An intent
/// that returned `.result(dialog: "Done, your Mac will stay awake")` here
/// would be Siri saying something false out loud — worse than the in-app
/// "coming soon" `SleepStatusCard` settles for, because a spoken Siri
/// response carries more implied confidence than a line of secondary-gray
/// UI text. Both intents still construct and pass a real `ControlCommand`
/// through `MockDataSource.send(command:)` (rather than skipping that call
/// entirely) so the code path that will matter once a real transport exists
/// is exercised today, exactly like every other `MockDataSource` call site
/// in this app.
///
/// **Why `RefreshWidgetIntent` is different.** Re-reading the widget's
/// already-real, already-local `WidgetSnapshotStore` cache and asking
/// WidgetKit to reload from it needs no CloudKit connection at all — the
/// cache is written by `WidgetSnapshotWriter` from data the phone app
/// already has in-process. This is the one intent in this file that
/// actually does the thing its dialog claims.
enum MacStatIntents {}

// MARK: - KeepAwakeIntent

struct KeepAwakeIntent: AppIntent {
    static var title: LocalizedStringResource = "Keep Mac Awake"
    static var description = IntentDescription(
        "Requests that your Mac stay awake. Not available yet in this build — MacStat has no live connection to a Mac, so this request has nowhere to go."
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
        // Routed through the app-wide `AppDataSource.shared.transport`
        // (`MacStatMobile/Data/AppDataSource.swift`), not a locally
        // constructed `MockDataSource()` — same shared instance every other
        // call site in this app now reads from. Both conformers currently
        // fail to actually deliver a command (`MockDataSource.send(command:)`
        // is a documented no-op; `LocalSyncClient.send(command:)` throws
        // "not supported yet" — see that type's doc comment), so calling it
        // here (rather than skipping straight to the dialog below) keeps
        // this intent's code path identical in shape to what it will be once
        // a transport that actually delivers commands exists: construct the
        // command, send it, report what happened.
        let transport = await AppDataSource.shared.transport
        try? await transport.send(command: command)
        return .result(
            dialog: "MacStat can't keep your Mac awake yet — this build has no live connection to a Mac to send that request to."
        )
    }
}

// MARK: - ReleaseAwakeIntent

struct ReleaseAwakeIntent: AppIntent {
    static var title: LocalizedStringResource = "Release Mac Awake"
    static var description = IntentDescription(
        "Cancels a keep-awake request. Not available yet in this build, for the same reason as \"Keep Mac Awake.\""
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
        let transport = await AppDataSource.shared.transport
        try? await transport.send(command: command)
        return .result(
            dialog: "MacStat can't release your Mac's sleep assertion yet — this build has no live connection to a Mac to send that request to."
        )
    }
}

// MARK: - RefreshWidgetIntent

/// The one intent in this file with real, local, working behavior — see
/// this file's top-level doc comment for why it's different from the other
/// two. Re-reads `WidgetSnapshotStore` (the same App Group cache
/// `MacStatWidget`'s `Provider` reads) purely to report an honest dialog
/// back to the user/Siri; the actual reload is `WidgetCenter
/// .reloadAllTimelines()`, which doesn't need the read to succeed.
struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh MacStat Widget"
    static var description = IntentDescription(
        "Reloads the MacStat widget from the most recent data cached on this iPhone."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog {
        WidgetCenter.shared.reloadAllTimelines()
        guard let snapshot = WidgetSnapshotStore.read() else {
            return .result(dialog: "Widget reload requested, but there's no cached data yet — open MacStat first.")
        }
        let freshness = Freshness(lastSeen: snapshot.lastSeen)
        let ageLabel = freshness.label(lastSeen: snapshot.lastSeen)
        return .result(dialog: "Widget refreshed from the data cached on this iPhone (\(ageLabel)).")
    }
}

// MARK: - AppShortcutsProvider

/// Registers the plan §12.3 Siri phrases ("Hey Siri, keep my Mac awake for
/// an hour") against `RefreshWidgetIntent`/`KeepAwakeIntent`/`ReleaseAwakeIntent`
/// above. Registering the phrase doesn't change what the intent actually
/// does — `KeepAwakeIntent.perform()` still reports the honest "can't reach
/// a Mac" dialog no matter how it was invoked (Shortcuts app, widget
/// button, or Siri) — this only makes the phrase *discoverable*, which is
/// the compile-and-exist bar this task is scoped to, not a claim that the
/// underlying action works yet.
struct MacStatAppShortcuts: AppShortcutsProvider {
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
            intent: RefreshWidgetIntent(),
            phrases: [
                "Refresh my \(.applicationName) widget",
            ],
            shortTitle: "Refresh Widget",
            systemImageName: "arrow.clockwise"
        )
    }
}
