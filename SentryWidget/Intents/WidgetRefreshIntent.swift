import AppIntents
import SentryKit
import WidgetKit

// MARK: - WidgetRefreshIntent

/// The widget extension's own copy of `RefreshWidgetIntent`
/// (`SentryMobile/Intents/SentryIntents.swift`) — same behavior (re-read
/// `WidgetSnapshotStore`, ask WidgetKit to reload), but declared inside
/// this target rather than reused from that one.
///
/// **Why not literally `Button(intent: RefreshWidgetIntent())`.** An
/// `AppIntent` used by `Button(intent:)` inside a widget view runs *in the
/// widget extension's process*, which means the intent type itself has to
/// be compiled into the extension's own module. `RefreshWidgetIntent` is
/// declared in `SentryMobile`, the extension's *containing app* target —
/// and an app extension can depend on its host app's frameworks, never on
/// the host app's own executable module (that dependency only runs the
/// other direction: `SentryMobile` embeds `SentryWidgetExtension`, not the
/// reverse — see `project.yml`'s `SentryWidgetExtension` target). So this
/// intent is a deliberate, narrow duplication rather than a shared type,
/// exactly the same shape as `RefreshWidgetIntent` because the underlying
/// operation (`WidgetCenter.shared.reloadAllTimelines()` +
/// `WidgetSnapshotStore.read()`, both `SentryKit` APIs the extension can
/// already see) genuinely is that simple and has no reason to drift
/// between the two copies.
///
/// No `ProvidesDialog` conformance, unlike `RefreshWidgetIntent` — this
/// copy is only ever invoked from `Button(intent:)` inside the widget's own
/// UI, never from Siri/Shortcuts (only the app-side `SentryAppShortcuts`
/// registers phrases), so there is no spoken result to phrase.
struct WidgetRefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Sentry Widget"
    static var description = IntentDescription(
        "Reloads this widget from the most recent data cached on this device."
    )

    /// Interactive widget buttons run their intent without leaving the
    /// home screen / Lock Screen by default, which is exactly what a
    /// "refresh in place" action wants — `false` here is actually the
    /// `AppIntent` default, spelled out so a future reader doesn't have to
    /// go check.
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
