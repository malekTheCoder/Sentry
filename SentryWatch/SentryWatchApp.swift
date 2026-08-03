import SwiftUI

// MARK: - SentryWatchApp: entry point for the Watch companion app

/// The minimal standalone watch app half of the Watch feature — mostly a
/// vehicle for `WatchSessionController` to activate `WCSession` and receive
/// relays even when no complication reload is in flight, plus a plain
/// screen so the feature is inspectable without a complication configured
/// on any watch face. `ComplicationView`
/// (`SentryWatchWidget/ComplicationView.swift`) is the actually-glanceable
/// surface this feature is really for; this app exists because a
/// complication needs a companion watch app to be installed at all.
@main
struct SentryWatchApp: App {
    /// Owns the one `WCSession` this process talks through — a `@StateObject`
    /// here (rather than a bare `WatchSessionController.shared.start()` call
    /// in `.task`, the phone-side convention) because `ContentView` also
    /// needs to observe `latestSnapshot` reactively as new relays arrive
    /// while the app is on screen, not just read `WatchRelayStore.read()`
    /// once at appear time.
    @StateObject private var sessionController = WatchSessionController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionController)
                .task {
                    sessionController.start()
                }
        }
    }
}
