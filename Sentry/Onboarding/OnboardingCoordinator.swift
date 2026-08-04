import AppKit
import SwiftUI
import SentryKit

/// Shows the one-time first-run `WelcomeView` popover the instant Sentry's
/// status item exists, and never again after that.
///
/// **Integration point.** This type is deliberately self-contained and is
/// **not** wired into `AppDelegate.swift` by this change — `AppDelegate` is
/// shared with two other in-flight onboarding-adjacent passes, so every
/// integration point lands here instead of touching that file directly. A
/// human integrator wires this in by hand with exactly one line:
///
/// ```swift
/// OnboardingCoordinator.shared.showIfNeeded(
///     anchoredTo: statusItemController.statusItem,
///     settingsStore: settingsStore,
///     theme: theme
/// )
/// ```
///
/// added near the end of `applicationDidFinishLaunching`, after
/// `statusItemController` has been constructed (so `.statusItem.button` is
/// non-nil) and after `theme`/`settingsStore` are already available in that
/// method's local scope — both are already resolved earlier in
/// `applicationDidFinishLaunching` for `configurePopover(theme:enabledModules:)`,
/// so this call can sit right after that existing call with no new plumbing.
///
/// **Why a separate `NSPopover` rather than reusing `AppDelegate`'s own.**
/// `AppDelegate.popover` is a stored, reused instance whose content view
/// controller `configurePopover` rebuilds in place — routing a one-time
/// welcome screen through it would mean either mutating that shared popover's
/// content (racy against a real click landing mid-first-launch) or adding
/// onboarding-aware branches to `togglePopover`. A second, throwaway
/// `NSPopover` that this coordinator owns for exactly as long as it's on
/// screen avoids both: zero shared mutable state with the main dropdown, and
/// nothing for `AppDelegate` to know about beyond the one call above.
@MainActor
final class OnboardingCoordinator {

    /// One instance for the process, matching the "one coordinator per
    /// concern" shape `StatusItemController`/`SettingsStore` already use as
    /// `AppDelegate`-owned singletons-in-practice. A `static let` here still
    /// requires the one call above to actually invoke `showIfNeeded` —
    /// nothing about this type shows anything on its own.
    static let shared = OnboardingCoordinator()

    /// Held only so the popover isn't deallocated the instant `showIfNeeded`
    /// returns — `NSPopover.show` does not retain the popover for you the
    /// way `AppDelegate.popover` (an ivar) is retained for the whole app
    /// lifetime. Cleared in `dismiss()` once the popover has actually closed.
    private var popover: NSPopover?

    private init() {}

    /// Shows `WelcomeView` anchored to the status item's button, exactly
    /// once ever, then flips `AppSettings.hasSeenWelcome` so it never shows
    /// again on a later launch. A no-op if the flag is already set or the
    /// status item has no button yet (e.g. called before the item has been
    /// added to the menu bar — see `StatusItemController.init`, which
    /// creates `item.button` synchronously, so this should never actually
    /// happen at the call site documented above, but failing silently here
    /// is strictly safer than force-unwrapping into a launch-time crash for
    /// what would only ever be a first-run cosmetic).
    ///
    /// - Parameters:
    ///   - statusItem: `StatusItemController.statusItem` — the popover
    ///     anchors to its button the same way `AppDelegate.togglePopover`
    ///     anchors the main dropdown to it.
    ///   - settingsStore: source of truth for `hasSeenWelcome`, and where
    ///     this method writes `true` back the moment it decides to show the
    ///     popover (not when the user dismisses it — see
    ///     `AppSettings.hasSeenWelcome`'s doc comment for why).
    ///   - theme: the user's active theme, so `WelcomeView` matches the
    ///     dropdown it's introducing rather than rendering in a default
    ///     theme the user may never have chosen.
    func showIfNeeded(anchoredTo statusItem: NSStatusItem, settingsStore: SettingsStore, theme: Theme) {
        guard !settingsStore.settings.hasSeenWelcome else { return }
        guard let button = statusItem.button else { return }

        let newPopover = NSPopover()
        newPopover.behavior = .transient
        newPopover.animates = true
        newPopover.contentViewController = NSHostingController(
            rootView: WelcomeView(theme: theme, onDismiss: { [weak self] in self?.dismiss() })
        )
        popover = newPopover

        // Written the instant the popover is shown, not on dismiss: a user
        // who quits (or the app crashes) with the popover still on screen
        // must not see it again claiming to be "first run" a second time —
        // see `AppSettings.hasSeenWelcome`'s doc comment.
        settingsStore.settings.hasSeenWelcome = true

        newPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        // Matches `AppDelegate.togglePopover`: an accessory app's popover
        // opens behind other windows without this.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismiss() {
        popover?.performClose(nil)
        popover = nil
    }
}
