import AppKit
import SwiftUI
import MacStatKit

/// Hosts the SwiftUI settings root in a single, reused window.
///
/// **Why a controller rather than a SwiftUI `Settings` scene:** MacStat is an
/// `LSUIElement` accessory app driven by an `NSApplicationDelegate`, so there is
/// no `App` scene graph to hang `Settings {}` off. This also lets us guarantee
/// the "one window, brought to front" behaviour a menu-bar app needs — a second
/// "Settings…" click must focus the existing window, not open another.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private let settingsStore: SettingsStore

    /// Read-only, and used by exactly one pane (`AlertsPane`'s history mode,
    /// plan §11.3). Held here rather than reached for lazily because the
    /// hosting controller is built once and never rebuilt.
    ///
    /// Defaulted to `nil` so this is a purely additive parameter: `AppDelegate`
    /// passes the same `HistoryStore` instance it already hands to
    /// `AlertEngine` — `SettingsWindowController(settingsStore:historyStore:)`
    /// — and any call site that hasn't been updated keeps compiling and simply
    /// gets a history pane that says it's unavailable.
    private let historyStore: HistoryStore?

    /// Trigger for the Advanced pane's "Show Debug Window" button (plan
    /// Phase 1 exit criterion). Defaulted to `nil`, same reasoning as
    /// `historyStore` above: purely additive, so any call site that hasn't
    /// been updated keeps compiling and simply gets a button that does
    /// nothing rather than a broken build.
    private let onShowDebugWindow: (() -> Void)?

    /// Backs the AI Access pane's live activity log (plan §13.4). `nil` is a
    /// legitimate configuration, same convention as `historyStore`/
    /// `onShowDebugWindow` above — `AIAccessPane` shows an explicit "log
    /// unavailable" state rather than a silently-empty list.
    private let mcpActivityLog: MCPActivityLog?

    /// The window is built on first `show()` rather than in `init` so that
    /// constructing the controller at launch costs nothing.
    init(
        settingsStore: SettingsStore,
        historyStore: HistoryStore? = nil,
        onShowDebugWindow: (() -> Void)? = nil,
        mcpActivityLog: MCPActivityLog? = nil
    ) {
        self.settingsStore = settingsStore
        self.historyStore = historyStore
        self.onShowDebugWindow = onShowDebugWindow
        self.mcpActivityLog = mcpActivityLog
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
        let settingsWindow = window ?? makeWindow()

        // An accessory app is never the active app, so its windows open behind
        // whatever the user was looking at unless we activate explicitly.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let root = SettingsView(store: settingsStore, historyStore: historyStore, onShowDebugWindow: onShowDebugWindow, mcpActivityLog: mcpActivityLog)
        let hosting = NSHostingController(rootView: root)

        let settingsWindow = NSWindow(contentViewController: hosting)
        // The title is kept for Mission Control / the Window menu /
        // accessibility, but not drawn: the titlebar is transparent, content
        // is full-size, and `SettingsView`'s sidebar names the window
        // instead — one bar of chrome, not two.
        settingsWindow.title = "Sentry Settings"
        settingsWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.titleVisibility = .hidden
        // Non-opaque so the sidebar's behind-window material actually has a
        // desktop to sample — see `VisualEffect`'s doc comment. The detail
        // column paints its own opaque `windowBackgroundColor` on top.
        settingsWindow.isOpaque = false
        settingsWindow.backgroundColor = .clear
        settingsWindow.setContentSize(NSSize(width: 740, height: 540))
        settingsWindow.contentMinSize = NSSize(width: 700, height: 480)
        // Closing settings must not tear down the hosting controller — the
        // window is reused, and rebuilding it would drop transient UI state
        // (selected pane, selected bar module) on every close.
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.delegate = self
        settingsWindow.center()

        self.window = settingsWindow
        return settingsWindow
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // The debounced writer may still be holding the user's last edit;
        // closing settings is exactly the moment "eventually" isn't enough.
        settingsStore.save()
    }
}
