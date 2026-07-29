import AppKit
import SwiftUI
import MacStatKit

/// Hosts the SwiftUI Dashboard root in a single, reused window — the
/// full-window counterpart to the dropdown's compact 60-sample chart,
/// backed by `HistoryStore`'s tiered raw/hourly/daily history instead of an
/// in-memory ring buffer.
///
/// **Why a controller rather than a SwiftUI `WindowGroup` scene:** same
/// reason as `SettingsWindowController` — MacStat is an `LSUIElement`
/// accessory app driven by an `NSApplicationDelegate`, so there's no `App`
/// scene graph to hang a scene off, and a menu-bar app needs "one window,
/// brought to front" semantics: clicking the dropdown's "History" button a
/// second time must focus the existing Dashboard window, not spawn another.
///
/// **The "no `DashboardView` yet" problem:** this controller is being built
/// concurrently with the actual `DashboardView` (another agent's task), so
/// it can't reference that type without risking a build break either way.
/// Rather than block on that dependency, `init` takes a `rootView` factory —
/// `@escaping () -> AnyView` — evaluated lazily on first `show()`, exactly
/// where `SettingsWindowController` builds `SettingsView`. `AppDelegate`
/// originally wired this to a placeholder (`Text("Dashboard coming soon")`)
/// while `DashboardView` didn't exist yet; now that it does, `AppDelegate`
/// builds the real view in that same closure — a one-line swap at that call
/// site, exactly as planned, with nothing here needing to change. Deferred
/// rather than evaluated eagerly in `init` for the same reason
/// `SettingsWindowController` defers its window: constructing this
/// controller at launch should cost
/// nothing until the user actually opens the Dashboard.
final class HistoryWindowController: NSWindowController, NSWindowDelegate {

    private let rootView: () -> AnyView
    private let onShow: (() -> Void)?

    /// - Parameters:
    ///   - rootView: builds the window's SwiftUI content, evaluated once on
    ///     first `show()`. See the type doc comment for why this is a
    ///     factory closure rather than a concrete `DashboardView` reference.
    ///   - onShow: called at the top of every `show()`, not just the first.
    ///     Because this window is a reused singleton, `rootView()` runs
    ///     exactly once per app launch — `DashboardView`'s own `.task` that
    ///     triggers the first history query therefore also runs exactly
    ///     once, ever, leaving the Dashboard showing stale data on every
    ///     re-show after the first (open Monday, close, reopen Friday: still
    ///     shows Monday's history until the user happens to touch the range
    ///     picker). `AppDelegate` wires this to re-run
    ///     `DashboardViewModel.refresh()` so reopening the window always
    ///     re-queries, independent of `rootView`'s one-time construction.
    init(rootView: @escaping () -> AnyView, onShow: (() -> Void)? = nil) {
        self.rootView = rootView
        self.onShow = onShow
        super.init(window: nil)
    }

    // NSWindowController conforms to NSCoding; this controller is never
    // archived, and returning nil is the honest answer without a force-unwrap
    // or a trap.
    required init?(coder: NSCoder) {
        return nil
    }

    /// Creates the window on first call, reuses it after, and brings it to
    /// front. Safe to call repeatedly.
    func show() {
        let dashboardWindow = window ?? makeWindow()

        // An accessory app is never the active app, so its windows open
        // behind whatever the user was looking at unless we activate
        // explicitly.
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow.makeKeyAndOrderFront(nil)
        onShow?()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: rootView())

        let dashboardWindow = NSWindow(contentViewController: hosting)
        dashboardWindow.title = "MacStat Dashboard"
        dashboardWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Wider than Settings' 720×520: a grid of per-metric detail charts
        // wants more breathing room than a single-column settings form.
        dashboardWindow.setContentSize(NSSize(width: 900, height: 700))
        dashboardWindow.contentMinSize = NSSize(width: 760, height: 560)
        // Closing the Dashboard must not tear down the hosting controller —
        // the window is reused, and rebuilding it would drop transient UI
        // state (selected time range, selected metric) on every close.
        dashboardWindow.isReleasedWhenClosed = false
        dashboardWindow.delegate = self
        dashboardWindow.center()

        self.window = dashboardWindow
        return dashboardWindow
    }
}
