import AppKit
import SwiftUI
import MacStatKit

/// Hosts the debug snapshot dump in its own window (plan Phase 1 exit
/// criterion: "Debug window dumping every raw value").
///
/// Modeled directly on `SettingsWindowController`: built lazily on first
/// `show()`, reused rather than recreated, and not released on close — the
/// view model keeps ingesting snapshots for as long as `AppDelegate` is
/// alive regardless of whether the window is currently visible, so there's
/// nothing to lose by keeping the window instance around too, and doing so
/// avoids rebuilding the hosting controller (and its scroll position) on
/// every open.
final class DebugWindowController: NSWindowController, NSWindowDelegate {

    private let viewModel: DebugDumpViewModel

    init(viewModel: DebugDumpViewModel) {
        self.viewModel = viewModel
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// Creates the window on first call, reuses it after, and brings it to
    /// front. Safe to call repeatedly.
    func show() {
        let debugWindow = window ?? makeWindow()

        // An accessory app (`LSUIElement`) is never the active app, so its
        // windows open behind whatever the user was looking at unless we
        // activate explicitly — same reasoning as `SettingsWindowController.show()`.
        NSApp.activate(ignoringOtherApps: true)
        debugWindow.makeKeyAndOrderFront(nil)
        // `windowDidBecomeKey`/`windowWillClose` are the actual visibility
        // signal for `viewModel.isWindowVisible`; this covers the case where
        // `show()` re-fronts an already-visible window (no delegate callback
        // fires) and the still-closed case (view model already correct).
        viewModel.isWindowVisible = true
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // The whole reason this consumer exists: stop paying for a
        // `Mirror`-reflection dump every ~3s the moment nobody can see it.
        viewModel.isWindowVisible = false
    }

    private func makeWindow() -> NSWindow {
        let root = DebugDumpView(viewModel: viewModel)
        let hosting = NSHostingController(rootView: root)

        let debugWindow = NSWindow(contentViewController: hosting)
        debugWindow.title = "Sentry Debug Snapshot"
        debugWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        debugWindow.setContentSize(NSSize(width: 560, height: 640))
        debugWindow.contentMinSize = NSSize(width: 480, height: 420)
        // Reused across opens, same as the settings window — the dump
        // itself is disposable, but the window frame/position the user
        // chose isn't worth losing every time they close it.
        debugWindow.isReleasedWhenClosed = false
        debugWindow.center()
        debugWindow.delegate = self

        self.window = debugWindow
        return debugWindow
    }
}
