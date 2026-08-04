import SentryKit
import SwiftUI

/// Entry point for the iPhone companion app (plan §12 — "iPhone App &
/// Widget"). Was a one-screen `Text("Sentry")` stub before this task;
/// now hands off to `RootTabView`, the plan §12.1 four-tab shell
/// (Dashboard/History/Alerts/Settings).
///
/// **Local-network sync resolution (plan §7.1's "v4" transport).** The
/// `.task` below is the one place `AppDataSource.shared.resolveIfNeeded()`
/// is called — see that type's doc comment
/// (`SentryMobile/Data/AppDataSource.swift`) for why discovery has to
/// happen exactly once, app-wide, rather than once per view model. It's
/// attached at the root scene rather than inside `RootTabView` so it starts
/// as early as possible (before any tab has even appeared), and it's
/// `.environmentObject`-injected here too, so any view that wants to
/// observe `isUsingLocalSync` (a future connection-status indicator) can,
/// even though today only `AppDataSource.shared` — the singleton, not the
/// environment value — is what the view models/intents actually read from
/// (see that type's doc comment on why it's a true singleton, not
/// environment-only).
///
/// **QR pairing entry point.** Scanning the Mac's Sync-settings QR code
/// with the Camera app opens a `sentry://pair` URL (`RemotePairing` in
/// SentryKit) which lands in `onOpenURL` below. The endpoint is held in
/// `pendingPairing` and applied only after an explicit confirmation alert —
/// a URL is an unauthenticated input (anything can open one), so it gets to
/// *propose* overwriting the saved remote-Mac settings, never to do it
/// silently.
@main
struct SentryMobileApp: App {

    /// True once the user has finished or skipped `OnboardingView`
    /// (`SentryMobile/Onboarding/OnboardingView.swift`). Plain
    /// `UserDefaults.standard` via `@AppStorage`, matching every other
    /// one-time/per-device flag in this target
    /// (`"selectedThemeID"` in `RootTabView`/`SettingsTabView`,
    /// `"remoteSync.host/port/code"` in `SettingsTabView`) — there's no
    /// App-Group or CloudKit-backed store anywhere in `SentryMobile` for a
    /// flag this small to justify introducing one.
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    /// Same key, same duplication tradeoff as `RootTabView`'s copy — see
    /// that type's doc comment ("Why the `@AppStorage` key is duplicated
    /// here and in `Settings/SettingsTabView.swift`"). `OnboardingView` is
    /// presented via `.fullScreenCover` below, which starts a *new* view
    /// hierarchy rather than descending from `RootTabView`'s
    /// `.environment(\.themePalette:)`, so without reading the theme here
    /// too, onboarding would render in whatever `Theme.terminal` the
    /// environment's plain default is instead of the theme the user
    /// actually picked (or the One Dark default a first-run user hasn't
    /// changed yet).
    @AppStorage("selectedThemeID") private var selectedThemeID: String = Theme.oneDark.id

    /// A scanned-but-not-yet-confirmed pairing; non-nil drives the alert.
    @State private var pendingPairing: RemotePairing.Endpoint?

    /// Drives the reconnect-on-foreground fix below — see the `.onChange`
    /// doc comment.
    @Environment(\.scenePhase) private var scenePhase

    @Environment(\.colorScheme) private var systemColorScheme

    private var onboardingPalette: ThemePalette {
        let theme = Theme.builtInPresets.first { $0.id == selectedThemeID } ?? .defaultTheme
        return ThemePalette(theme: theme, scheme: systemColorScheme)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(AppDataSource.shared)
                .task {
                    // Starts the Watch relay (`WatchRelayManager.swift`)
                    // alongside local-sync discovery — see that type's doc
                    // comment for why it's a root-level singleton rather
                    // than something a single tab's view model owns.
                    WatchRelayManager.shared.start()
                    await AppDataSource.shared.resolveIfNeeded()
                }
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    // Nothing anywhere in this app was watching `scenePhase`
                    // before this (connection-honesty review, bug #2): iOS
                    // suspends the process while backgrounded, so
                    // `LocalSyncClient`'s Bonjour browser only reconnects on
                    // resume if it happens to refire on its own, which isn't
                    // guaranteed. Foregrounding is exactly the moment a
                    // dropped or never-established connection is worth
                    // retrying, so it reuses the same `retryConnection()`
                    // path the Dashboard's demo-data banner's tap target
                    // uses (`AppDataSource.swift`) — one reconnect path, two
                    // triggers. `oldPhase` is checked so this doesn't also
                    // fire on the very first `.active` at cold launch, which
                    // `resolveIfNeeded()` above already handles.
                    guard oldPhase != .active, newPhase == .active else { return }
                    Task { await AppDataSource.shared.retryConnection() }
                }
                .onOpenURL { url in
                    if let endpoint = RemotePairing.endpoint(from: url) {
                        pendingPairing = endpoint
                    }
                }
                .alert(
                    "Pair with Mac?",
                    isPresented: Binding(
                        get: { pendingPairing != nil },
                        set: { if !$0 { pendingPairing = nil } }
                    ),
                    presenting: pendingPairing
                ) { endpoint in
                    Button("Pair") {
                        Task { await AppDataSource.shared.applyPairing(endpoint) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { endpoint in
                    Text("This sets \(endpoint.host):\(String(endpoint.port)) as your remote Mac and replaces any saved pairing. Only pair from a QR code shown on your own Mac's screen.")
                }
                // First-run onboarding (connection-honesty review's other
                // finding: a fresh install had nothing anywhere prominent
                // telling a user this app needs Sentry running on a Mac
                // too). A full-screen cover, not a `.sheet`, so it can't be
                // swiped away by accident and reads as a gate in front of
                // the app rather than an overlay on top of it — the same
                // reason `AboutView` uses a sheet and this doesn't: About is
                // optional reference material you dismiss back into a
                // working app, this is the thing that's supposed to happen
                // once before the app is used at all. Re-derives its
                // `isPresented` binding from `hasCompletedOnboarding` rather
                // than owning a separate `@State` flag, so there is exactly
                // one source of truth for "has this run" and dismissing the
                // cover (Skip or Get Started, both call the same
                // `onFinish`) is just flipping that one flag.
                .fullScreenCover(
                    isPresented: Binding(
                        get: { !hasCompletedOnboarding },
                        set: { isPresented in hasCompletedOnboarding = !isPresented }
                    )
                ) {
                    OnboardingView { hasCompletedOnboarding = true }
                        .environment(\.themePalette, onboardingPalette)
                }
        }
    }
}
