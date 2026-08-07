import AppKit
import SwiftUI
import SentryKit

/// Owns the first-run walkthrough popover: shows it once, ever, on first
/// launch, and re-shows it on demand when the user asks from
/// Settings ▸ General ▸ Walkthrough.
///
/// **Integration point — unchanged, deliberately.** `AppDelegate` already
/// contains exactly one call into this type:
///
/// ```swift
/// OnboardingCoordinator.shared.showIfNeeded(
///     anchoredTo: controller.statusItem,
///     settingsStore: settingsStore,
///     theme: theme
/// )
/// ```
///
/// and this rewrite keeps that call site byte-for-byte valid. Every new
/// dependency this walkthrough wants is either resolvable from
/// `settingsStore` (which the call already passes) or arrives through a
/// parameter with a default, so a file that is currently owned by other
/// in-flight work needs no edit to keep working. See
/// `endpointPublisher`'s parameter documentation for the one capability
/// that is *degraded* rather than absent without an AppDelegate change,
/// and what it degrades to.
///
/// **Why `showIfNeeded` now attaches before it gates.** The replay button in
/// Settings has no way to reach the status item on its own —
/// `NSStatusBar` does not enumerate its items, `AppDelegate`'s
/// `statusItemController` is private, and `MainWindowController` (which owns
/// the settings window) knows nothing about the menu bar. The alternative
/// designs were: (a) add a second `attach(...)` call to `AppDelegate`, which
/// the task forbids; (b) present the replay in a standalone window instead
/// of a popover, which throws away the one thing that makes step 1 work —
/// the popover physically points at the icon it is describing; or (c) have
/// the launch-time call remember its arguments even when it decides not to
/// show anything. (c) costs three stored properties and no new call sites,
/// so (c) it is. The gate moved below the attach; nothing else about the
/// first-run decision changed.
///
/// **Why a separate `NSPopover` rather than reusing `AppDelegate`'s own.**
/// Unchanged from this file's first version, and worth restating because
/// the walkthrough is now long-lived enough for it to matter more:
/// `AppDelegate.popover` is a stored, reused instance whose content view
/// controller `configurePopover` rebuilds in place. Routing a nine-step
/// walkthrough through it would mean either mutating that shared popover's
/// content (racy against a real click landing mid-walkthrough) or teaching
/// `togglePopover` about onboarding. A second popover that this coordinator
/// owns for exactly as long as it is on screen avoids both.
@MainActor
final class OnboardingCoordinator: ObservableObject {

    /// One instance for the process, matching the "one coordinator per
    /// concern" shape `StatusItemController`/`SettingsStore` already use as
    /// `AppDelegate`-owned singletons-in-practice. A `static let` here still
    /// requires the one call above to actually invoke `showIfNeeded` —
    /// nothing about this type shows anything on its own.
    static let shared = OnboardingCoordinator()

    /// Whether `replay()` can currently do anything.
    ///
    /// Published so `GeneralPane` can disable its button and *say why*
    /// rather than offering a control that silently does nothing — the
    /// failure mode `SyncPane`'s doc comment names as this codebase's
    /// canonical prior bug. False only before `showIfNeeded` has ever run,
    /// which in the shipping app means "never", but is a real state in a
    /// preview or a unit-test host.
    @Published private(set) var canReplay = false

    /// True while the walkthrough popover is on screen. Lets the replay
    /// button read "Showing…" instead of restarting a flow the user is
    /// already looking at behind the settings window.
    @Published private(set) var isShowing = false

    /// Held only so the popover isn't deallocated the instant the
    /// presenting method returns — `NSPopover.show` does not retain the
    /// popover for you the way `AppDelegate.popover` (an ivar) is retained
    /// for the whole app lifetime. Cleared once it has actually closed.
    private var popover: NSPopover?

    // MARK: - Attached dependencies

    /// Weak because `NSStatusBar` owns its items for the process lifetime
    /// and this coordinator has no business extending that — if the status
    /// item is ever removed (`StatusItemController.remove()`), a replay
    /// should fail to find an anchor rather than resurrect a detached
    /// button.
    private weak var statusItem: NSStatusItem?

    /// The live settings store, not a snapshot of it. Every interactive
    /// control in the walkthrough writes through this, and the theme is
    /// re-resolved from it at present time so a replay months later renders
    /// in whatever theme the user has since chosen.
    private weak var settingsStore: SettingsStore?

    /// See `showIfNeeded(anchoredTo:settingsStore:theme:endpointPublisher:)`.
    private weak var endpointPublisher: MCPEndpointPublisher?

    private init() {}

    // MARK: - Presentation

    /// Attaches to the app's status item and settings store, then shows the
    /// walkthrough if the user has never seen it.
    ///
    /// - Parameters:
    ///   - statusItem: `StatusItemController.statusItem` — the popover
    ///     anchors to its button the same way `AppDelegate.togglePopover`
    ///     anchors the main dropdown to it. Retained weakly and reused by
    ///     `replay()`.
    ///   - settingsStore: source of truth for `hasSeenWelcome`, the backing
    ///     store for every toggle in the flow, and where the theme is
    ///     resolved from on each presentation.
    ///   - theme: the theme to use for *this* presentation. Kept as a
    ///     parameter purely so the existing `AppDelegate` call site stays
    ///     valid; `replay()` ignores it and asks `settingsStore` instead,
    ///     which is the more correct answer and the one this method would
    ///     take if it were being designed today.
    ///   - endpointPublisher: `AppDelegate`'s `mcpEndpointPublisher`, if the
    ///     integrator chooses to pass it.
    ///
    ///     **This is the one capability that needs an `AppDelegate` edit,
    ///     and it degrades honestly without one.** With a publisher, the
    ///     agent-access step offers the same real "Set Up Command-Line
    ///     Access" button `AIAccessPane` has, which calls
    ///     `SMAppService.agent(...).register()` and reports the actual
    ///     `MCPBridgeRegistration` state back. Without one, that step says —
    ///     in words, not as a greyed button — that the setup lives in
    ///     Settings ▸ AI Access, which is true either way. The default is
    ///     `nil` rather than a required parameter for exactly the reason
    ///     `SettingsView` documents for its own optional dependencies:
    ///     "`nil` is a legitimate configuration," rendered as an explicit
    ///     state rather than as a section that quietly isn't there. Adding
    ///     `endpointPublisher: mcpEndpointPublisher` to the existing
    ///     `AppDelegate` call is a one-line, additive change whenever that
    ///     file is free.
    func showIfNeeded(
        anchoredTo statusItem: NSStatusItem,
        settingsStore: SettingsStore,
        theme: Theme,
        endpointPublisher: MCPEndpointPublisher? = nil
    ) {
        // Attach unconditionally, *then* gate. See this type's doc comment
        // for why the replay path depends on this happening even on the
        // launches where nothing is shown.
        self.statusItem = statusItem
        self.settingsStore = settingsStore
        self.endpointPublisher = endpointPublisher
        canReplay = statusItem.button != nil

        guard WalkthroughGate.shouldPresentOnLaunch(
            hasCompletedWalkthrough: settingsStore.settings.hasSeenWelcome
        ) else { return }

        present(.firstRun, theme: theme)
    }

    /// Runs the walkthrough again, from the top, at the user's request.
    ///
    /// A no-op if `canReplay` is false or the walkthrough is already up —
    /// both of which `GeneralPane` renders as a disabled button with a
    /// stated reason, so this guard is a safety net rather than the primary
    /// defence.
    func replay() {
        guard !isShowing, let settingsStore else { return }
        present(.replay, theme: settingsStore.resolvedTheme())
    }

    private func present(_ presentation: WalkthroughPresentation, theme: Theme) {
        guard let settingsStore else { return }
        guard let button = statusItem?.button else { return }

        // Dismiss any previous instance before building a new one. Cannot
        // happen via `replay()` (guarded above), but `showIfNeeded` running
        // twice is cheap to survive and expensive to debug if it isn't.
        dismiss()

        let newPopover = NSPopover()
        // `.applicationDefined`, not `.transient` — and this is the one
        // behavioural regression risk in the whole file, so: a `.transient`
        // popover closes the moment the user clicks anywhere else, which was
        // right for a single "here's your icon" sentence and is wrong for a
        // nine-step flow that spends several of those steps telling the user
        // to look at things. Losing the walkthrough to a stray click on
        // another window, with no way back except a Settings pane they have
        // not been shown yet, is a worse failure than the one
        // `.applicationDefined` risks (a popover that outstays its welcome).
        // The mitigations for that risk are explicit and all present: a Skip
        // button on every step, Escape bound to it via `.cancelAction`, and
        // a Done button on the last step.
        newPopover.behavior = .applicationDefined
        newPopover.animates = true

        var flow = WalkthroughFlow<MacWalkthroughStep>(presentation: presentation)
        flow.restart()

        newPopover.contentViewController = NSHostingController(
            rootView: WalkthroughView(
                flow: flow,
                store: settingsStore,
                theme: theme,
                endpointPublisher: endpointPublisher,
                onFinish: { [weak self] outcome in self?.complete(outcome) }
            )
        )
        popover = newPopover
        isShowing = true

        if WalkthroughGate.shouldMarkCompletedOnPresent(presentation) {
            // Written the instant the walkthrough is shown, not on dismiss:
            // a user who quits (or the app crashes) mid-flow must not see it
            // again claiming to be "first run" a second time. Argued at
            // length in `AppSettings.hasSeenWelcome`'s doc comment and in
            // `WalkthroughGate.shouldMarkCompletedOnPresent`; unchanged from
            // this file's first version.
            settingsStore.settings.hasSeenWelcome = true
        }

        newPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        // Matches `AppDelegate.togglePopover`: an accessory app's popover
        // opens behind other windows without this.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Both Skip and Done land here. `WalkthroughGate.completedFlag(after:)`
    /// is what decides they mean the same thing — see that function for why
    /// the policy is written down rather than implied by two call sites that
    /// happen to do the same thing today.
    private func complete(_ outcome: WalkthroughOutcome) {
        if let settingsStore {
            let completed = WalkthroughGate.completedFlag(after: outcome)
            if settingsStore.settings.hasSeenWelcome != completed {
                settingsStore.settings.hasSeenWelcome = completed
            }
        }
        dismiss()
    }

    private func dismiss() {
        popover?.performClose(nil)
        popover = nil
        isShowing = false
    }
}
