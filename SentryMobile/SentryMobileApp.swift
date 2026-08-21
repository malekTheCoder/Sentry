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

    /// Which way the user resolved the pairing alert, or `nil` before they
    /// have.
    ///
    /// **Why the alert needs its own state at all.** Both buttons collapse
    /// `pendingPairing` to `nil`, so that value cannot tell "Pair" from
    /// "Cancel" — and those are two different things that happened, which is
    /// the one distinction this app's haptics exist to carry. Reset to `nil`
    /// in `onOpenURL` below, so a second scanned code is a fresh decision
    /// rather than a value that happens to already equal its predecessor and
    /// therefore feels like nothing.
    @State private var pairingDecision: PairingDecision?

    private enum PairingDecision { case paired, cancelled }

    /// Adopts the phone's stored temperature unit at *process* launch,
    /// before any scene exists.
    ///
    /// `RootTabView` already publishes this on `.onAppear` and on change,
    /// which covers everything a person looking at the app can do. This
    /// covers the case they can't: Siri running `GetThermalStatusIntent`
    /// (`SentryMobile/Intents/SentryIntents.swift`) without ever bringing
    /// the app forward. That launches the process but need not build the
    /// window group, so `onAppear` may never fire — and the dialog would
    /// then be spoken in Celsius to someone whose whole app is in
    /// Fahrenheit.
    ///
    /// Reads `UserDefaults` directly rather than through `@AppStorage`
    /// because this runs in `init`, before any property wrapper is
    /// projected, and because it needs to happen exactly once at startup
    /// rather than tracking changes — `RootTabView` owns the tracking.
    /// Third copy of the `"temperatureUnit"` key string, for the same
    /// reason `"selectedThemeID"` has three: `@AppStorage`/`UserDefaults`
    /// resolve by string, not by Swift symbol (see `RootTabView`'s doc
    /// comment on that duplication).
    init() {
        let stored = UserDefaults.standard.string(forKey: "temperatureUnit")
        TemperatureUnit.display = stored.flatMap(TemperatureUnit.init(rawValue:)) ?? .celsius
    }

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
                    // Starts (and, just as importantly, *cleans up after*)
                    // the keep-awake Live Activity — see
                    // `KeepAwakeActivityController` for why it belongs at
                    // the root beside the Watch relay rather than on the
                    // Dashboard's view model the way `WidgetSnapshotWriter`
                    // does. Called before `resolveIfNeeded()` deliberately:
                    // its first act is to reconcile whatever activity
                    // survived a previous process, and a hold whose deadline
                    // passed while the app was dead must be cleared whether
                    // or not a Mac is ever found on this launch.
                    KeepAwakeActivityController.shared.start()
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
                        pairingDecision = nil
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
                        pairingDecision = .paired
                        Task { await AppDataSource.shared.applyPairing(endpoint) }
                    }
                    Button("Cancel", role: .cancel) { pairingDecision = .cancelled }
                } message: { endpoint in
                    Text("This sets \(endpoint.host):\(String(endpoint.port)) as your remote Mac and replaces any saved pairing. Only pair from a QR code shown on your own Mac's screen.")
                }
                // Pairing arms a persistent thing — a saved remote endpoint
                // this phone will keep dialing until it is forgotten — which
                // is `SentryHaptic.begin`, the same case Keep Awake starting
                // gets. Cancelling only dismisses an alert, which is `.tap`.
                //
                // Deliberately *not* `.confirmed`: `applyPairing(_:)` writes
                // the endpoint and starts dialing, and returns long before
                // the Mac has agreed to anything. The outcome shows up later
                // in `AppDataSource.remoteConnectFailureReason` and the
                // Dashboard's connection line; claiming it here would be the
                // optimistic success this app refuses everywhere else.
                .haptic(.begin, on: pairingDecision) { $0 == .paired }
                .haptic(.tap, on: pairingDecision) { $0 == .cancelled }
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
                    // The outcome (Skip vs. Get Started) is routed through
                    // `WalkthroughGate.completedFlag(after:)` rather than
                    // both paths hardcoding `true` here. They *do* both
                    // resolve to `true` today — "Skip means done, not
                    // later" — but writing the policy down in one shared
                    // place is what stops the Mac and the phone drifting
                    // apart on it, and what lets a test pin it. See that
                    // function's doc comment.
                    OnboardingView { outcome in
                        hasCompletedOnboarding = WalkthroughGate.completedFlag(after: outcome)
                    }
                    .environment(\.themePalette, onboardingPalette)
                }
        }
    }
}
