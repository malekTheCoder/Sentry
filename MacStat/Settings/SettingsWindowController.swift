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

    /// The window is built on first `show()` rather than in `init` so that
    /// constructing the controller at launch costs nothing.
    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
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
        let root = SettingsView(store: settingsStore)
        let hosting = NSHostingController(rootView: root)

        let settingsWindow = NSWindow(contentViewController: hosting)
        settingsWindow.title = "MacStat Settings"
        settingsWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        settingsWindow.setContentSize(NSSize(width: 720, height: 520))
        settingsWindow.contentMinSize = NSSize(width: 640, height: 440)
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
