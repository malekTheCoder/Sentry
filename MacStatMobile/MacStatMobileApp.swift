import MacStatKit
import SwiftUI

/// Entry point for the iPhone companion app (plan §12 — "iPhone App &
/// Widget"). Was a one-screen `Text("MacStat")` stub before this task;
/// now hands off to `RootTabView`, the plan §12.1 four-tab shell
/// (Dashboard/History/Alerts/Settings).
///
/// **Local-network sync resolution (plan §7.1's "v4" transport).** The
/// `.task` below is the one place `AppDataSource.shared.resolveIfNeeded()`
/// is called — see that type's doc comment
/// (`MacStatMobile/Data/AppDataSource.swift`) for why discovery has to
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
/// with the Camera app opens a `macstat://pair` URL (`RemotePairing` in
/// MacStatKit) which lands in `onOpenURL` below. The endpoint is held in
/// `pendingPairing` and applied only after an explicit confirmation alert —
/// a URL is an unauthenticated input (anything can open one), so it gets to
/// *propose* overwriting the saved remote-Mac settings, never to do it
/// silently.
@main
struct MacStatMobileApp: App {

    /// A scanned-but-not-yet-confirmed pairing; non-nil drives the alert.
    @State private var pendingPairing: RemotePairing.Endpoint?

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
        }
    }
}
