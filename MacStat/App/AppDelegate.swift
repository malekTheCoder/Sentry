import Cocoa
import Combine
import SwiftUI
import MacStatKit
import SystemMetricsKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    // MARK: - Collection layer
    //
    // Collectors must be persistent instances, not constructed fresh per
    // call — several are stateful delta trackers (CPU, Disk, Network) that
    // only produce correct rates when the same instance is called
    // repeatedly (plan §3.2 P2). `StatsCoordinator` takes provider closures
    // rather than concrete collector types (dependency inversion — avoids a
    // circular MacStatKit<->SystemMetricsKit framework dependency), so this
    // composition root is where the two actually meet.
    private let batteryCollector = BatteryCollector()
    private let cpuCollector = CPUCollector()
    private let memoryCollector = MemoryCollector()
    private let diskCollector = DiskCollector()
    private let networkCollector = NetworkCollector()
    private let thermalCollector = ThermalCollector()
    private let gpuCollector = GPUCollector()
    private let aneCollector = ANECollector()

    private lazy var coordinator = StatsCoordinator(
        batteryProvider: batteryCollector.collect,
        cpuProvider: cpuCollector.collect,
        memoryProvider: memoryCollector.collect,
        diskProvider: diskCollector.collect,
        networkProvider: networkCollector.collect,
        thermalProvider: thermalCollector.collect,
        gpuProvider: gpuCollector.collect,
        aneProvider: aneCollector.collect
    )

    // MARK: - Storage

    private let settingsStore = SettingsStore()
    private let historyStore = HistoryStore()
    private lazy var rollupJob = RollupJob(dbQueue: historyStore.databaseQueue)

    // MARK: - Phase 3 services
    //
    // Both are fed from the same snapshot stream as everything else (plan
    // §3.2 P3) rather than owning timers of their own. Exactly one
    // `PowerControlService` exists app-wide: it persists the live assertion
    // to `UserDefaults` and re-creates it on wake, so a second instance
    // would reconcile against — and fight over — the first's record.
    private let powerControl = PowerControlService()
    private lazy var alertEngine = AlertEngine(
        rules: settingsStore.settings.alertRules,
        historyStore: historyStore,
        rateCapPerHour: settingsStore.settings.notificationRateCapPerHour,
        doNotDisturb: settingsStore.settings.doNotDisturb
    )

    // MARK: - UI

    private var statusItemController: StatusItemController?
    private let dropdownViewModel = DropdownViewModel()
    private let popover = NSPopover()
    private lazy var settingsWindowController = SettingsWindowController(
        settingsStore: settingsStore,
        // Same store the engine logs firings to — the Alerts pane's history
        // view reads `alert_log` from it. Without this it renders an
        // explicit "history unavailable" state rather than a misleading
        // empty list.
        historyStore: historyStore,
        onShowDebugWindow: { [weak self] in self?.debugWindowController.show() }
    )

    // MARK: - Debug window (plan Phase 1 exit criterion)
    //
    // Another independent consumer of `coordinator.snapshots()` — same shape
    // as `historyStore`/`statusItemController`/`dropdownViewModel` below —
    // not a second poll loop. `DebugWindowController` builds its window
    // lazily on first `show()`, so this costs nothing until the developer
    // actually opens it from the Advanced settings pane.
    private let debugDumpViewModel = DebugDumpViewModel()
    private lazy var debugWindowController = DebugWindowController(viewModel: debugDumpViewModel)

    // MARK: - Dashboard window
    //
    // Same lazy-singleton pattern as `settingsWindowController`/
    // `debugWindowController` above — costs nothing until the dropdown's
    // "History" button is actually clicked. `DashboardView` (the real root
    // view) is being built concurrently elsewhere, so this is wired to a
    // placeholder for now; see `HistoryWindowController`'s doc comment for
    // why that's a one-line swap once `DashboardView` lands.
    private lazy var historyWindowController = HistoryWindowController(
        rootView: { AnyView(Text("Dashboard coming soon")) }
    )

    private var snapshotTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Only a theme or enabled-modules change requires rebuilding the
    /// dropdown's SwiftUI tree. Tracked so unrelated settings edits (a
    /// retention slider drag emits a value per frame) don't tear down and
    /// rebuild an `NSHostingController` each time — and can't stomp an open
    /// popover.
    private var lastAppliedTheme: Theme?
    private var lastAppliedModules: Set<MetricModule>?
    /// The `cardListMaxHeight` baked into the current hosting controller, so
    /// `togglePopover` can tell a genuine display change from a no-op reopen
    /// and skip the state-destroying rebuild in the latter case.
    private var lastAppliedCardListMaxHeight: CGFloat?

    /// Which rules were enabled last time settings changed, so a
    /// disabled→enabled transition can be detected and reported to
    /// `AlertEngine.ruleWasEnabled` (its lazy-authorization trigger).
    /// Comparing sets rather than trusting the pane to notify us keeps the
    /// authorization prompt correct no matter how a rule got enabled —
    /// including a hand-edited settings file.
    private var lastEnabledRuleIDs: Set<UUID> = []

    nonisolated static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = settingsStore.settings
        let theme = settingsStore.resolvedTheme()

        let controller = StatusItemController(layout: settings.menuBarLayout, theme: theme)
        controller.onClick = { [weak self] in self?.togglePopover() }
        statusItemController = controller

        configurePopover(theme: theme, enabledModules: settings.enabledModules)

        // Apply persisted settings before anything starts polling, so a saved
        // refresh interval / retention window takes effect on the first tick
        // rather than only after the user next touches a control.
        coordinator.setBaseInterval(settings.globalRefreshInterval)
        // FR-2, additive: medium/slow tiers are now independently
        // user-adjustable (see StatsCoordinator.setBaseInterval's doc
        // comment) rather than ratio-derived from the fast interval above.
        coordinator.setMediumInterval(settings.mediumTierRefreshInterval)
        coordinator.setSlowInterval(settings.slowTierRefreshInterval)
        coordinator.adaptiveThrottlingEnabled = settings.adaptiveThrottlingEnabled
        rollupJob.setRetention(
            rawHours: settings.rawRetentionHours,
            hourlyDays: settings.hourlyRetentionDays
        )
        rollupJob.start()

        // Closes the loop between the two Phase 3 services without either
        // importing the other (see `AlertAction.releaseSleepAssertion`) —
        // this is what makes a rule like "keep awake until battery < 20%"
        // able to actually drop the hold. Unwired, the action was a no-op
        // on both ends.
        alertEngine.sleepAssertionReleaser = { [weak self] in
            self?.powerControl.releaseAssertion()
        }
        // The shipped "Thermal throttling" rule carries `.menuBarHighlight`
        // and is enabled by default, so leaving this unassigned meant a
        // default rule advertising an action that silently did nothing.
        alertEngine.menuBarHighlighter = { [weak self] token in
            self?.statusItemController?.highlight(token: token)
        }
        // Seed the enabled set so `applySettings` can spot a genuine
        // disabled→enabled transition later. Deliberately *without* calling
        // `ruleWasEnabled` here: rules ship enabled, so doing so would
        // request notification authorization at launch on every fresh
        // install — precisely what plan §11.3 forbids ("request
        // authorization lazily — on first alert rule enable, not at
        // launch"). `AlertEngine` instead requests on its first actual
        // delivery attempt, so a user who never trips a rule, or who turns
        // alerts off before one fires, is never prompted at all.
        lastEnabledRuleIDs = Set(settings.alertRules.filter(\.isEnabled).map(\.id))

        // StatsCoordinator's AsyncStream is the single source every consumer
        // reads (plan §3.2 P3) — the menu bar, the dropdown, and the history
        // store are three independent consumers of the same stream, none of
        // them aware of the others.
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in self.coordinator.snapshots() {
                self.historyStore.record(snapshot)
                self.statusItemController?.update(snapshot)
                self.dropdownViewModel.ingest(snapshot)
                self.debugDumpViewModel.ingest(snapshot)
                // Without these, both Phase 3 services are armed but inert —
                // neither has a data source of its own by design (plan §3.2
                // P3: one poll loop, many consumers). A conditional
                // assertion ("keep awake until battery < 20%") would never
                // release, and no alert rule would ever fire.
                self.powerControl.evaluate(snapshot)
                self.alertEngine.evaluate(snapshot)
            }
        }

        // Mirror assertion state into the coordinator so it lands on the next
        // `SystemSnapshot` — that's what lets the `.whenAssertionActive`
        // menu bar visibility rule (plan §10.5) ever evaluate true. Pushed
        // from here rather than polled by the coordinator: the state is
        // main-actor isolated and changes on user action, not on a tick.
        //
        // Combine `sink`, not `for await ... in $state.values`: `AsyncPublisher`
        // requests demand one value at a time and *drops* anything emitted
        // while demand is zero. `startAssertionInternal` sets `state` twice
        // back-to-back synchronously (`releaseAssertion()` → `.inactive`,
        // then `.active`), so the second emission lands in exactly that
        // window — the coordinator would latch `.inactive` while an
        // assertion is genuinely live, and every snapshot would then carry
        // that lie (P5). `sink` requests unlimited demand, so no emission is
        // dropped.
        powerControl.$state
            .sink { [weak self] state in
                self?.coordinator.sleepAssertionState = state
            }
            .store(in: &cancellables)

        // Live-apply theme/layout changes made in Settings without a restart.
        //
        // `sink` for the same reason as `$state` above, and it matters more
        // here: this channel now carries `updateRules` and the
        // disabled→enabled detection that drives notification
        // authorization. `AsyncPublisher` would drop emissions during a
        // rapid burst — and a slider drag emits per frame — which could
        // leave the engine running stale rules. (The set-difference check
        // means a missed transition self-heals on the next emission, but
        // fixing one instance of a bug class and leaving its sibling is how
        // it comes back.)
        settingsStore.$settings
            .sink { [weak self] newSettings in
                self?.applySettings(newSettings)
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Both stores buffer/debounce writes, so quitting without an explicit
        // flush would drop whatever accumulated since the last interval.
        historyStore.flush()
        settingsStore.save()
    }

    // MARK: - Popover

    private func configurePopover(theme: Theme, enabledModules: Set<MetricModule>) {
        popover.behavior = .transient
        popover.animates = true
        // `.transient` closes on an outside click without ever calling
        // `togglePopover`, so the throttling flag has to come from the
        // delegate callbacks or it latches to "open" after the first
        // dismissal and silently disables §8.4 throttling for the rest of
        // the run.
        popover.delegate = self
        lastAppliedTheme = theme
        lastAppliedModules = enabledModules
        let height = cardListMaxHeight()
        lastAppliedCardListMaxHeight = height
        let hostingController = NSHostingController(
            rootView: DropdownView(
                viewModel: dropdownViewModel,
                powerControl: powerControl,
                theme: theme,
                enabledModules: enabledModules,
                cardListMaxHeight: height,
                onOpenSettings: { [weak self] in self?.openSettings() },
                onOpenHistory: { [weak self] in self?.historyWindowController.show() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        )
        // Without this, NSHostingController's `preferredContentSize` never
        // updates to match what SwiftUI actually renders, so the popover's
        // frame drifts from its real content — cards get clipped and the
        // mismatched region shows the desktop behind it instead of the
        // theme background. `.preferredContentSize` keeps it in sync as the
        // dropdown's content changes (more/fewer cards, expand/collapse).
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
    }

    /// Sized against the screen the status item button actually lives on —
    /// this Mac's status item can end up on any of several displays (menu
    /// bar management tools, "displays have separate menu bars"), so
    /// `NSScreen.main` isn't reliable here. Falls back to a sane constant
    /// if the button has no window/screen yet (first launch, before the
    /// popover has ever been shown).
    private func cardListMaxHeight() -> CGFloat {
        guard let screenHeight = statusItemController?.button?.window?.screen?.visibleFrame.height else {
            return 480
        }
        return max(360, screenHeight * 0.55)
    }

    private func togglePopover() {
        guard let button = statusItemController?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // The button's `.window?.screen` usually isn't resolvable until
            // the status item has actually appeared once, so the height
            // computed at launch-time `configurePopover` can be stale (the
            // generic 480pt fallback rather than this display's real one) —
            // and the user can move the status item to a different display
            // mid-run.
            //
            // But only rebuild when the height *actually changed*. Assigning
            // `contentViewController` builds a fresh SwiftUI tree, which
            // resets every `@State` in the dropdown — the sleep control
            // card's pending trigger/mode/threshold selections would revert
            // to defaults every single time the popover reopened. (An
            // earlier comment here claimed this was "no SwiftUI tree
            // rebuild"; that was simply wrong, and harmless only for as
            // long as the dropdown held no state worth keeping.)
            let height = cardListMaxHeight()
            if height != lastAppliedCardListMaxHeight,
               let theme = lastAppliedTheme,
               let modules = lastAppliedModules {
                configurePopover(theme: theme, enabledModules: modules)
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            // An accessory app's popover opens behind other windows otherwise.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func openSettings() {
        popover.performClose(nil)
        settingsWindowController.show()
    }

    // MARK: - NSPopoverDelegate

    // Feed the coordinator's adaptive throttling (plan §8.4): polling slows
    // down while nobody is looking at the charts. These fire for *every*
    // close path, including the outside-click dismissal that a `.transient`
    // popover uses and that never goes through `togglePopover`.

    func popoverDidShow(_ notification: Notification) {
        coordinator.popoverIsClosed = false
    }

    func popoverDidClose(_ notification: Notification) {
        coordinator.popoverIsClosed = true
    }

    // MARK: - Settings changes

    private func applySettings(_ settings: AppSettings) {
        // Resolve from the delivered value rather than re-reading the store:
        // `@Published` emits in `willSet`, so `settingsStore.settings` is
        // still the *old* value at emission time. It happens to work today
        // only because the async hop lands after the assignment — not
        // something a theme switch should depend on.
        let theme = Theme.builtInPresets.first { $0.id == settings.themeID } ?? .terminal

        statusItemController?.apply(layout: settings.menuBarLayout)
        statusItemController?.apply(theme: theme)

        // Settings that must actually reach the services behind them —
        // these sliders/toggles were previously wired to nothing.
        coordinator.setBaseInterval(settings.globalRefreshInterval)
        // FR-2, additive: medium/slow tiers are now independently
        // user-adjustable (see StatsCoordinator.setBaseInterval's doc
        // comment) rather than ratio-derived from the fast interval above.
        coordinator.setMediumInterval(settings.mediumTierRefreshInterval)
        coordinator.setSlowInterval(settings.slowTierRefreshInterval)
        coordinator.adaptiveThrottlingEnabled = settings.adaptiveThrottlingEnabled
        rollupJob.setRetention(
            rawHours: settings.rawRetentionHours,
            hourlyDays: settings.hourlyRetentionDays
        )

        // Rule edits in the Alerts pane only reach the engine through here —
        // the pane deliberately holds no `AlertEngine` reference, it just
        // writes to settings. `updateRules` preserves per-rule runtime state
        // (cooldown timers, sustained-since) for rules whose `id` is
        // unchanged, so editing a rule's name mid-cooldown doesn't reset it.
        alertEngine.updateRules(settings.alertRules)
        // Advanced pane exposes this as a live slider; captured once at
        // construction it would do nothing until relaunch.
        alertEngine.rateCapPerHour = settings.notificationRateCapPerHour
        alertEngine.doNotDisturb = settings.doNotDisturb

        // Then report any disabled→enabled transition, which is what drives
        // §11.3's lazy notification authorization.
        let enabledNow = Set(settings.alertRules.filter(\.isEnabled).map(\.id))
        if let newlyEnabledID = enabledNow.subtracting(lastEnabledRuleIDs).first,
           let rule = settings.alertRules.first(where: { $0.id == newlyEnabledID }) {
            alertEngine.ruleWasEnabled(rule)
        }
        lastEnabledRuleIDs = enabledNow

        // Rebuilding the hosting controller is how a new theme or module
        // selection reaches an already-constructed SwiftUI tree, but it's
        // expensive and discards scroll state — so only on an actual
        // change, and never while the user is looking at the popover.
        guard theme != lastAppliedTheme || settings.enabledModules != lastAppliedModules,
              !popover.isShown
        else { return }
        configurePopover(theme: theme, enabledModules: settings.enabledModules)
    }
}
