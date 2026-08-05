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
    @StateObject private var sessionController = Self.makeController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionController)
                .task {
                    sessionController.start()
                }
        }
    }

    /// **Debug-only fixture hook, for looking at this UI on a simulator.**
    ///
    /// A watch simulator has no paired phone, so `WCSession` never delivers
    /// anything and every screen renders its "nothing relayed yet" state —
    /// which makes the *populated* layouts, the ones with all the fit and
    /// overflow risk, impossible to see without a real Mac, a real phone and
    /// a real watch. Seeding `WatchRelayStore`'s App Group from outside the
    /// process was tried first and does not work: a simulator build is signed
    /// with no entitlements at all, so `UserDefaults(suiteName:)` does not
    /// resolve to the container a host-side script can write.
    ///
    /// So the fixture comes in as a launch argument instead. `-SentryWatchDemo
    /// <fixture>` selects one of `WatchSessionController.PreviewFixture`'s
    /// cases and an optional `-SentryWatchTheme <id>` overrides the theme, so
    /// every page and every palette can be inspected on a real device at real
    /// size.
    ///
    /// `#if DEBUG` for exactly the reason `WatchSessionController
    /// .init(preview:)` is: this is the one path that can put a number on
    /// screen that no Mac ever sent. It must not exist in a shipping build,
    /// and the fixtures it selects all carry `sourceIsDemoData: true`, so
    /// even here the screen discloses that its numbers are fabricated.
    private static func makeController() -> WatchSessionController {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-SentryWatchDemo"),
           arguments.index(after: flag) < arguments.endIndex,
           let fixture = WatchSessionController.PreviewFixture(rawValue: arguments[arguments.index(after: flag)]) {
            var themeID: String?
            if let themeFlag = arguments.firstIndex(of: "-SentryWatchTheme"),
               arguments.index(after: themeFlag) < arguments.endIndex {
                themeID = arguments[arguments.index(after: themeFlag)]
            }
            return WatchSessionController(preview: fixture, themeID: themeID)
        }
        #endif
        return WatchSessionController()
    }
}
