import Cocoa
import Combine
import SwiftUI
import SentryKit
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
    // circular SentryKit<->SystemMetricsKit framework dependency), so this
    // composition root is where the two actually meet.
    private let batteryCollector = BatteryCollector()
    private let cpuCollector = CPUCollector()
    private let memoryCollector = MemoryCollector()
    private let diskCollector = DiskCollector()
    private let networkCollector = NetworkCollector()
    private let thermalCollector = ThermalCollector()
    private let gpuCollector = GPUCollector()
    private let aneCollector = ANECollector()
    // Feeds `coordinator`'s slower, independent process tier — see
    // `StatsCoordinator.Tier.process`'s doc comment. Deliberately a second
    // `ProcessCollector` instance from `Sentry/Dashboard/ProcessMonitor.swift`'s
    // own (which stays untouched): they serve different consumers — this
    // one feeds `SystemSnapshot.topProcesses` for `AlertEngine`'s process-
    // scoped rules, that one feeds the Dashboard's Top Processes card — and
    // per-provider-closure state can't be safely shared between them.
    private let processCollector = ProcessCollector()

    private lazy var coordinator = StatsCoordinator(
        batteryProvider: batteryCollector.collect,
        cpuProvider: cpuCollector.collect,
        memoryProvider: memoryCollector.collect,
        diskProvider: diskCollector.collect,
        networkProvider: networkCollector.collect,
        thermalProvider: thermalCollector.collect,
        gpuProvider: gpuCollector.collect,
        aneProvider: aneCollector.collect,
        processProvider: { [processCollector] in processCollector.collectTopProcesses(limit: 20) },
        // The persisted per-Mac identity (AppSettings.deviceID) — without
        // this argument the coordinator mints a fresh UUID every launch and
        // the phone's reconnect-to-the-last-Mac preference can never match.
        deviceID: settingsStore.settings.deviceID
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

    // MARK: - In-process AppIntents access (Sentry/Intents/SentryMacIntents.swift)
    //
    // `AppIntent`s are instantiated by the system, not by this composition
    // root, so there is no initializer call site to inject `coordinator`/
    // `powerControl`/`settingsStore` into the way `MCPXPCService` and
    // friends receive them. These three internal (not private) accessors are
    // that seam's entire surface — explicit and type-checked, rather than
    // `Mirror`-reflecting this instance's stored properties by type from
    // outside the file (an earlier draft did exactly that; replaced once
    // this file was open for editing anyway, since a compiler-checked
    // property beats a runtime type scan for the same three-line result).
    var intentAccessiblePowerControl: PowerControlService { powerControl }
    var intentAccessibleCoordinator: StatsCoordinator { coordinator }
    var intentAccessibleSettingsStore: SettingsStore { settingsStore }

    /// The "Location Log" feature (plan-external addition; see
    /// `LocationService`'s doc comment for why this is deliberately not
    /// "Find My"). Constructed unconditionally, like `powerControl` above —
    /// it does nothing observable (no permission prompt, no timer, no
    /// `CLLocationManager` activity beyond reading the already-cached
    /// `authorizationStatus`) until `applySettings` sees
    /// `AppSettings.locationLogEnabled == true`, which is also the only
    /// path that ever calls `requestAuthorization()`.
    private let locationService = LocationService()

    /// Backs Settings ▸ Fans.
    ///
    /// `PrivilegedFanControlBackend` **wrapping** the read-only SMC one, not
    /// replacing it: capability detection and every RPM the pane shows come
    /// from `SMCReadOnlyFanControlBackend` exactly as they did in Phase 2,
    /// and only *writes* are routed to the root helper. So a helper that is
    /// missing, unapproved, broken, or removed cannot change a single
    /// number on that screen.
    ///
    /// **Constructing this is inert, and staying inert is the point.** The
    /// privileged backend's `init` performs one `SMAppService.daemon(…)
    /// .status` read — a local lookup that prompts nothing, launches
    /// nothing, and opens no XPC connection — plus the same handful of SMC
    /// reads the read-only backend has always done. Nothing here registers
    /// a daemon; the only caller of `register()` is a button in the Fans
    /// pane. On a machine with no helper installed (every fresh install,
    /// and every build made without signing certificates, where
    /// registration cannot succeed at all) the app behaves precisely as it
    /// did before this change. See `PrivilegedFanControlBackend` and
    /// `docs/fan-control-spike.md`.
    private let fanControlBackend = PrivilegedFanControlBackend(
        reading: SMCReadOnlyFanControlBackend()
    )
    private lazy var fanControlService = FanControlService(backend: fanControlBackend)

    /// Feeds the desktop widget's App Group cache from the same snapshot
    /// stream as every other consumer — see `MacWidgetSnapshotWriter`.
    private let widgetWriter = MacWidgetSnapshotWriter(
        deviceName: Host.current().localizedName ?? String(localized: "This Mac")
    )
    private lazy var alertEngine = AlertEngine(
        rules: settingsStore.settings.alertRules,
        historyStore: historyStore,
        rateCapPerHour: settingsStore.settings.notificationRateCapPerHour,
        doNotDisturb: settingsStore.settings.doNotDisturb,
        persistedState: settingsStore.settings.alertPersistedState
    )

    // MARK: - UI

    private var statusItemController: StatusItemController?
    private let dropdownViewModel = DropdownViewModel()
    private let popover = NSPopover()

    /// Which tab Sentry's one window shows — written by the window's own
    /// glass switcher and by the dropdown's Dashboard/Settings actions.
    private let mainWindowState = MainWindowState()

    /// Mirrors whether `mainWindowController`'s window is currently on
    /// screen — `onShow`/`onHide` are the only two places that flip it.
    /// `MainWindowController` has no publisher of its own for this (it
    /// reports visibility only via those two closures), so this is the
    /// simplest way to let `updateProcessMonitorState()` combine "window
    /// visible" with "Dashboard tab selected" without restructuring the
    /// controller just to expose a `$isVisible` publisher for one caller.
    private var isMainWindowVisible = false

    /// Narrows `ProcessMonitor.start()`/`stop()` (wired to window
    /// visibility via `onShow`/`onHide` above) to the Dashboard tab
    /// specifically. `MainWindowView` keeps all three tabs alive at once
    /// via `.opacity` (so switching tabs never rebuilds a tree — see its
    /// doc comment), which means being window-visible is not the same as
    /// being *Dashboard*-visible: sitting in Settings or Insights kept
    /// paying for `ProcessCollector`'s full per-process enumeration, the
    /// app's most expensive collector, every 5 seconds for a card nobody
    /// was looking at.
    ///
    /// Additive on top of the existing window-visibility gate, not a
    /// replacement for it: `isMainWindowVisible` remains the outer bound
    /// (the monitor is always stopped when the window itself is hidden,
    /// regardless of which tab was last selected), and this just adds "and
    /// also the Dashboard tab" as a second, narrower condition.
    private func updateProcessMonitorState() {
        if processMonitorShouldRun(windowVisible: isMainWindowVisible, selectedTab: mainWindowState.tab) {
            processMonitor.start()
        } else {
            processMonitor.stop()
        }
    }

    /// Sentry's single window: Dashboard and Settings behind the glass nav
    /// switcher (`MainWindowView`), replacing the separate settings and
    /// history windows. Same lazy-singleton pattern those two had.
    private lazy var mainWindowController = MainWindowController(
        rootView: { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(
                MainWindowView(
                    state: self.mainWindowState,
                    dashboard: AnyView(
                        DashboardView(
                            viewModel: self.dashboardViewModel,
                            historyStore: self.historyStore,
                            processMonitor: self.processMonitor,
                            powerControl: self.powerControl
                        )
                    ),
                    insights: AnyView(
                        InsightsView(viewModel: self.insightsViewModel)
                    ),
                    settings: AnyView(
                        SettingsView(
                            store: self.settingsStore,
                            // Same store the engine logs firings to — the
                            // Alerts pane's history view reads `alert_log`
                            // from it. Without it that pane renders an
                            // explicit "history unavailable" state.
                            historyStore: self.historyStore,
                            onShowDebugWindow: { [weak self] in self?.debugWindowController.show() },
                            mcpActivityLog: self.mcpActivityLog,
                            endpointPublisher: self.mcpEndpointPublisher,
                            locationService: self.locationService,
                            fanControlService: self.fanControlService,
                            updateController: self.updateController
                        )
                    )
                )
            )
        },
        navSwitcher: { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(NavSwitcherPill(state: self.mainWindowState))
        },
        onShow: { [weak self] in
            self?.dashboardViewModel.refresh()
            // Keeps every chart below the header live for as long as the
            // window stays open — see `DashboardViewModel.startAutoRefresh`'s
            // doc comment for why the charts were frozen at open-time before
            // this. Started here (window-visibility scope), narrowed to the
            // Dashboard tab specifically by `updateProcessMonitorState`'s
            // sibling gating below — auto-refresh itself isn't tab-gated
            // because unlike `ProcessMonitor`'s per-process enumeration, a
            // `HistoryStore` query is cheap enough that keeping it current
            // while the user is on Insights/Settings (so it's instantly
            // fresh switching back) isn't worth extra bookkeeping.
            self?.dashboardViewModel.startAutoRefresh()
            self?.isMainWindowVisible = true
            self?.updateProcessMonitorState()
        },
        onHide: { [weak self] in
            self?.isMainWindowVisible = false
            self?.updateProcessMonitorState()
            self?.dashboardViewModel.stopAutoRefresh()
            // A refresh in flight for a window the user just closed is pure
            // waste — see `InsightsViewModel.cancelRefresh`'s doc comment.
            self?.insightsViewModel.cancelRefresh()
            // The debounced writer may still hold the user's last edit;
            // closing the window is exactly the moment "eventually" isn't
            // enough — carried over from the old SettingsWindowController.
            self?.settingsStore.save()
        },
        // The window measures its own chrome band and hands the number to
        // the root view, which reserves exactly that much and clips its tab
        // content to what's below it — see `mainWindowChromeInset`.
        onChromeInset: { [weak self] inset in
            self?.mainWindowState.chromeInset = inset
        }
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

    /// Another independent consumer of `coordinator.snapshots()`, same shape
    /// as `dropdownViewModel`/`debugDumpViewModel` above — not a second poll
    /// loop. `lazy`, like `rollupJob` below, only because its initializer
    /// references `historyStore` (a class stored-property initializer can't
    /// reference `self` or sibling properties unless it's `lazy`) — not
    /// because construction should wait for the Dashboard window to open.
    /// It's still fed from the very first snapshot: the snapshot loop
    /// touches `self.dashboardViewModel` on every tick regardless of
    /// whether the Dashboard window has ever been shown, so `ingest(_:)`
    /// keeps its live headlines current the whole time, not just once the
    /// window is opened.
    private lazy var dashboardViewModel: DashboardViewModel = {
        let viewModel = DashboardViewModel(
            historyStore: historyStore,
            enabledModules: settingsStore.settings.enabledModules,
            theme: settingsStore.resolvedTheme()
        )
        // Per-session awake-time attribution for the Dashboard's agent
        // activity card — see `DashboardViewModel.awakeHoldsProvider`. A
        // closure rather than passing `powerControl` itself so the view
        // model stays constructible in tests without a power service.
        viewModel.awakeHoldsProvider = { [weak self] in
            self?.powerControl.awakeHolds ?? []
        }
        return viewModel
    }()

    // MARK: - Protection Insights

    /// The license-backed entitlement check (`LicenseProEntitlementStore`)
    /// — the "change the one line in `AppDelegate`" step that
    /// `ProEntitlementProviding`'s doc comment always promised, done.
    /// `publicKey` is `LicenseKeys.productionPublicKey`, which is nil until
    /// the owner embeds the real key (see `LicenseKeys` for the go-live
    /// step), so today this behaves exactly like the override-only
    /// `ProEntitlementStore` it replaced — while reporting *why* honestly
    /// (`LicenseDenialReason.verificationUnavailableInThisBuild`) if a
    /// license ever shows up anyway. `activationClient` stays nil until the
    /// checkout side exists (`LicenseActivation.swift`), and
    /// `revalidationPolicy` stays `.never` for exactly as long — see that
    /// policy's doc comment for why enforcing a grace window with no
    /// refresher would brick paying users.
    private lazy var proEntitlementStore = LicenseProEntitlementStore(
        settingsStore: settingsStore,
        publicKey: LicenseKeys.productionPublicKey
    )

    /// macOS-only, off-main-thread, TTL-cached — see
    /// `SecurityPostureCollector`'s doc comment. One instance for the app's
    /// lifetime so its five-minute cache is actually useful across repeated
    /// visits to the Insights tab.
    private let securityPostureCollector = SecurityPostureCollector()

    /// Same lazy-singleton reasoning as `dashboardViewModel` immediately
    /// above: cheap to construct, fed from the same `historyStore`, kept
    /// alive for the app's lifetime rather than rebuilt on every tab switch
    /// so its report, suppressions, and refresh state survive navigating
    /// away and back.
    private lazy var insightsViewModel = InsightsViewModel(
        historyStore: historyStore,
        settingsStore: settingsStore,
        entitlements: proEntitlementStore,
        postureProvider: securityPostureCollector,
        theme: settingsStore.resolvedTheme(),
        onOpenAppSettings: { [weak self] in self?.openMainWindow(tab: .settings) },
        // The one-line hook StatsCoordinator.protectionScore's doc comment
        // asked for: each computed score rides the snapshot cadence out to
        // the phone/watch and `GetProtectionScoreIntent`.
        onScoreComputed: { [weak self] score in self?.coordinator.protectionScore = score }
    )

    /// Backs the Dashboard's "Top Processes" card (plan §17 Phase 8). Lazy
    /// for the same reason `dashboardViewModel` is — cheap to construct,
    /// but its `Timer` (started via `mainWindowController`'s `onShow`)
    /// should only run while Sentry's window is actually open.
    private lazy var processMonitor = ProcessMonitor()

    // MARK: - MCP (plan §13)
    //
    // `MCPAccessController`/`MCPActivityLog` are plain (non-lazy) instances —
    // cheap value/ObservableObject holders with no timers or IOKit access of
    // their own, so there's no reason to defer construction the way the
    // window controllers below defer theirs. `mcpXPCService` and
    // `mcpListener` *are* lazy: both close over `self.coordinator` /
    // `self.historyStore` / etc., which — same as `dashboardViewModel` and
    // `rollupJob` above — a stored-property initializer can't reference
    // before `self` fully exists.
    private let mcpAccessController = MCPAccessController()
    private let mcpActivityLog = MCPActivityLog()
    private let pendingAlertPushStore = PendingAlertPushStore()
    private lazy var mcpXPCService = MCPXPCService(
        coordinator: coordinator,
        historyStore: historyStore,
        alertEngine: alertEngine,
        powerControl: powerControl,
        settingsStore: settingsStore,
        accessController: mcpAccessController,
        activityLog: mcpActivityLog
    )
    /// Owns the anonymous `NSXPCListener` that `sentryctl`/`SentryMCP`
    /// eventually connect to, and the `SMAppService` registration of the
    /// LaunchAgent that introduces them. Replaces the `mcpListener` that used
    /// to live here — an `NSXPCListener(machServiceName:)` on a name no
    /// launchd job had ever declared, which is why both tools failed against
    /// a perfectly healthy app. See
    /// `SentryKit/MCPBridge/MCPBridgeContract.swift`.
    ///
    /// `lazy` for the same reason `mcpXPCService` is: it closes over it.
    private lazy var mcpEndpointPublisher = MCPEndpointPublisher(service: mcpXPCService)

    /// Off by default, unlike `mcpListener`/`localSyncServer` below (both
    /// started unconditionally, gated internally) — this one actually
    /// changes the Mac's network posture (LAN-reachable, not just an inert
    /// local listener), so it stays fully stopped, not just silently
    /// denying, until `mcpRemoteAccessEnabled` is on. See
    /// `MCPRemoteServer`'s doc comment.
    private let mcpRemoteServer = MCPRemoteServer()

    // MARK: - Local-network sync (plan §7.1's "v4" fast path)
    //
    // `LocalSyncServer` (`SentryKit/LocalSync/LocalSyncServer.swift`) is the
    // Bonjour/`Network.framework` transport built ahead of CloudKit
    // specifically because it needs no Apple Developer Program enrollment —
    // see that type's doc comment. Named with this Mac's user-facing name
    // (same `Host.current().localizedName` source `DropdownHeader`/
    // `DashboardView` already use) so a multi-Mac household's Bonjour
    // browse results are distinguishable, even though `LocalSyncClient`'s
    // current picker just connects to whichever result arrives first.
    private lazy var localSyncServer = LocalSyncServer(
        serviceName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    )

    /// Turns a `ControlCommand` arriving over `localSyncServer` — from an
    /// iPhone Siri intent, an Apple Watch intent relayed through the phone,
    /// or the iPhone's sleep card — into a real `IOPMAssertion` change. See
    /// `LocalCommandExecutor`'s doc comment
    /// (`SentryKit/Services/LocalCommandExecutor.swift`) for why it shares
    /// `powerControl` with the MCP write-tool path rather than owning a
    /// second `PowerControlService`. Wired into
    /// `localSyncServer.commandHandler` in `applicationDidFinishLaunching`;
    /// `lazy` for the same reason as `mcpXPCService` above (it closes over
    /// `self.powerControl`/`self.coordinator`, so it can't be a plain
    /// stored-property initializer).
    private lazy var localCommandExecutor = LocalCommandExecutor(
        powerControl: powerControl,
        deviceID: coordinator.deviceID
    )

    // MARK: - Updates
    //
    // Sentry's only update channel: it ships outside the Mac App Store
    // (Developer ID + notarization), so there is no StoreKit path and no
    // "check the App Store" fallback. One instance for the app's lifetime,
    // same reasoning `powerControl` gives for its own singleton-ness —
    // Sparkle persists its check schedule in `UserDefaults`, so a second
    // updater would reconcile against the first's record.
    //
    // Non-lazy and unconditional, like `locationService`/`fanControlService`
    // above: construction reads two `Info.plist` keys and, when they don't
    // describe a working channel, deliberately builds no Sparkle object at
    // all. That last part is the whole design — see `UpdateController`'s doc
    // comment for why this service is the one exception to the "start it
    // unconditionally, gate it internally" pattern `mcpListener` and
    // `localSyncServer` follow. In this build it resolves to
    // `.publicKeyPlaceholder`, and Settings ▸ General says so on screen
    // instead of offering a Check for Updates button that could only ever
    // come back empty.
    private let updateController = UpdateController()

    private var snapshotTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Only a theme or enabled-modules change requires rebuilding the
    /// dropdown's SwiftUI tree. Tracked so unrelated settings edits (a
    /// retention slider drag emits a value per frame) don't tear down and
    /// rebuild an `NSHostingController` each time — and can't stomp an open
    /// popover.
    private var lastAppliedTheme: Theme?
    /// The list the dropdown's quick switcher was last built with. Tracked
    /// separately from `lastAppliedTheme` because renaming or deleting a
    /// custom theme the user isn't *currently* using changes the switcher's
    /// menu without changing the active theme at all — without this, a theme
    /// created in Settings wouldn't appear in that menu until something else
    /// happened to force a rebuild.
    private var lastAppliedCustomThemes: [Theme]?
    private var lastAppliedModules: Set<MetricModule>?
    /// The `cardListMaxHeight` baked into the current hosting controller, so
    /// `togglePopover` can tell a genuine display change from a no-op reopen
    /// and skip the state-destroying rebuild in the latter case.
    private var lastAppliedCardListMaxHeight: CGFloat?
    private var lastAppliedDropdownShowsKeepAwake: Bool?
    private var lastAppliedDropdownShowsAgentActivity: Bool?

    /// Kill-switch state last seen by `applySettings`, so a rising edge
    /// (false→true) can release the agent-held keep-awake assertion exactly
    /// once — same transition-detection pattern as `lastEnabledRuleIDs`
    /// below. `nil` until the first emission; a persisted engaged switch at
    /// launch counts as a rising edge, which is harmless (nothing agent-held
    /// exists yet) and self-consistent (paused stays paused, enforced).
    private var lastKillSwitchEngaged: Bool?

    /// Revoked client names last seen by `applySettings`, so a newly stopped
    /// agent's keep-awake hold can be released the moment the user hits
    /// Stop, wherever the setting was written from (AI Access pane, or a
    /// hand-edited file).
    private var lastRevokedClientNames: Set<String> = []

    /// Which rules were enabled last time settings changed, so a
    /// disabled→enabled transition can be detected and reported to
    /// `AlertEngine.ruleWasEnabled` (its lazy-authorization trigger).
    /// Comparing sets rather than trusting the pane to notify us keeps the
    /// authorization prompt correct no matter how a rule got enabled —
    /// including a hand-edited settings file.
    private var lastEnabledRuleIDs: Set<UUID> = []

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = settingsStore.settings
        let theme = settingsStore.resolvedTheme()

        // Persist once at startup: a first launch (or a pre-deviceID
        // settings.json) has just minted this Mac's deviceID in memory, and
        // SettingsStore never writes at load time — without this save the ID
        // would re-mint on every launch until the user happened to change
        // some other setting.
        settingsStore.save()

        let controller = StatusItemController(layout: settings.menuBarLayout, theme: theme)
        controller.onClick = { [weak self] in self?.togglePopover() }
        statusItemController = controller

        configurePopover(theme: theme, enabledModules: settings.enabledModules)

        // First-run welcome popover — see OnboardingCoordinator's doc comment.
        // Anchored to the just-built status item, after the real popover
        // exists so there's something for it to sit beside.
        OnboardingCoordinator.shared.showIfNeeded(
            anchoredTo: controller.statusItem,
            settingsStore: settingsStore,
            theme: theme
        )

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

        // Give the updater the persisted preference before Sparkle's own
        // scheduler has a chance to run its first check, so a user who
        // turned automatic checks off on a previous launch isn't checked on
        // this one. `applySettings` keeps it current after that — the same
        // one-way flow `alertEngine.updateRules` and `fanControlService
        // .settings` use, and the reader `AppSettings.updateCheckDaily` has
        // been missing since it was added.
        updateController.applySettings(settings)

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
        // Activates `AlertAction.runShortcut` (AI-agent-integration pass —
        // see Sentry-AI-Features-Research.md item #8): Shortcuts.app's own
        // URL scheme, no Shortcuts framework linkage needed. A name with
        // spaces/special characters must be percent-encoded for the query
        // item to survive `NSWorkspace.open`; an empty/invalid name after
        // encoding is simply not opened rather than launching a broken URL.
        alertEngine.shortcutRunner = { name in
            guard !name.isEmpty,
                  let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "shortcuts://run-shortcut?name=\(encodedName)")
            else { return }
            NSWorkspace.shared.open(url)
        }
        // Activates `AlertAction.pushToPhone` as far as it can go without
        // real CloudKit infra — see `PendingAlertPushStore`'s doc comment
        // for what "activated" means here vs. what's still blocked on
        // Apple Developer Program enrollment.
        alertEngine.phonePushRecorder = { [weak self] push in
            self?.pendingAlertPushStore.enqueue(push)
        }
        // Persistence pass (verified-bug fix: "cooldowns, sustained timers,
        // and the hourly rate cap all reset on relaunch"): mirrors
        // `alertEngine`'s durable runtime state into `settingsStore.settings`
        // on every change, so the *next* launch's `AlertEngine(persistedState:)`
        // above picks up where this one left off instead of starting every
        // rule's cooldown/rate-cap/battery-health-baseline cold. One-way
        // (engine → settings), matching every other injectable hook on this
        // type — `SettingsStore`'s own debounced-write `didSet` (see that
        // type's doc comment) is what turns this into an actual disk write.
        alertEngine.onPersistedStateChanged = { [weak self] state in
            self?.settingsStore.settings.alertPersistedState = state
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
                self.dashboardViewModel.ingest(snapshot)
                self.insightsViewModel.ingest(snapshot)
                // Settings ▸ Fans reads live RPM from here rather than
                // opening a second SMC connection of its own — two
                // independent reads milliseconds apart would occasionally
                // disagree, and a user shown two numbers for one fan has
                // been lied to by at least one of them.
                if let thermal = snapshot.thermal {
                    self.fanControlService.ingest(thermal)
                }
                // Without these, both Phase 3 services are armed but inert —
                // neither has a data source of its own by design (plan §3.2
                // P3: one poll loop, many consumers). A conditional
                // assertion ("keep awake until battery < 20%") would never
                // release, and no alert rule would ever fire.
                self.powerControl.evaluate(snapshot)
                self.alertEngine.evaluate(snapshot)
                // Guardrail auto-revocation (quiet hours starting, thermal
                // pressure climbing) — checked per tick, but a release
                // clears `agentAssertionOwner`, so each hold is revoked and
                // announced at most once. See `AgentGuardrails`.
                self.enforceAgentGuardrailRevocation(snapshot)
                // Same trigger, a second target: a guardrail condition that
                // would revoke Sentry's own keep-awake should also reach a
                // coding agent's own `caffeinate -i -t 300` (Claude Code
                // respawns this outside Sentry's control entirely — see
                // `CaffeinateArbitrator`'s header comment). Gated by the same
                // `shouldEnforce` check `enforce` runs internally, so this
                // costs a live process-table read only while a guardrail
                // condition is actually active, not on every idle tick.
                self.enforceExternalCaffeinateArbitration(snapshot)
                await self.widgetWriter.record(snapshot)
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

        // Mirrors `powerControl.$state` immediately above, same reasoning:
        // `LocationService` is `@MainActor`-isolated and changes on its own
        // multi-minute capture cadence, not a poll tick, so pushing on
        // change (not polling from `StatsCoordinator`) is both correct and
        // cheap. `sink` (not `AsyncPublisher`) for the same "never drop an
        // emission" reasoning documented on the settings sink below.
        // Seed the fan-control service with the persisted policy block so
        // its resolution preview matches what's on disk from the first
        // sample, not from the second. `applySettings` keeps it current
        // after that.
        fanControlService.settings = settings.fanControl

        locationService.$lastLocation
            .sink { [weak self] location in
                self?.coordinator.location = location
            }
            .store(in: &cancellables)

        // Tab-gates `ProcessMonitor` (see `updateProcessMonitorState`'s doc
        // comment) — the nav switcher writes `mainWindowState.tab` on every
        // click, and that's the only way the Dashboard tab is deselected
        // while the window stays open, so it needs its own subscription
        // alongside the `onShow`/`onHide` window-visibility calls above.
        // `sink`, matching every other subscription in this method, for the
        // same "never drop an emission" reasoning documented on the
        // settings sink below — though here it mainly matters for not
        // missing a rapid double-click between tabs.
        mainWindowState.$tab
            .sink { [weak self] _ in
                self?.updateProcessMonitorState()
            }
            .store(in: &cancellables)

        // If Location Log was already enabled and authorized on a previous
        // run (persisted in settings.json + macOS's own permission
        // bookkeeping), resume capturing on this launch without re-prompting
        // — `start()` itself no-ops unless `permissionState == .authorized`,
        // so this is safe to call unconditionally even if the user never
        // enabled the feature or later revoked permission in System
        // Settings.
        if settings.locationLogEnabled {
            locationService.start()
        }

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

        // MCP (plan §13.2): bring up the anonymous listener and, *if the user
        // has already set up command-line access*, tell the bridge where to
        // find it. Unconditional with respect to `settings.mcpServerEnabled`,
        // for the reason that has always applied here: the permission model
        // lives inside `MCPXPCService`/`MCPAccessController`, which check live
        // settings on every method, rather than in whether a listener exists
        // — a disabled feature should *reject cleanly*, not be unreachable in
        // a way indistinguishable from a broken one. (That distinction used to
        // be theoretical: the listener was unreachable for everybody, always.
        // See `MCPBridgeContract`.)
        //
        // Conditional with respect to the *registration*, which is a different
        // thing: constructing the publisher creates a process-local listener
        // and reads a status, and `publishIfRegistered()` connects to nothing
        // unless launchd already has the agent. On an install that never set
        // this up — the default — this line opens no connection at all.
        mcpEndpointPublisher.publishIfRegistered()

        // Local-network sync (plan §7.1 "v4"): another independent consumer
        // of `coordinator.snapshots()`, same shape as `historyStore`/
        // `dropdownViewModel`/etc. above — not a second poll loop. Started
        // unconditionally, same reasoning the MCP listener above uses for its
        // own unconditional construction: a disabled/unused
        // feature should be an inert, harmless listener (nobody on the LAN
        // is browsing for `_sentry._tcp` if no phone app is installed),
        // not something that has to be reached through a settings gate to
        // exist at all.
        // Assigned before `start(feedingFrom:)` so there's no window where a
        // connection could be accepted with no handler installed. Commands
        // arriving over the remote (TLS-PSK) listener are trusted on the
        // same terms as LAN ones — a remote client authenticated during the
        // TLS handshake, which is a strictly stronger check than the LAN
        // path applies. See `LocalCommandExecutor`'s doc comment.
        localSyncServer.commandHandler = { [localCommandExecutor] command in
            await localCommandExecutor.execute(command)
        }
        // The Watch's agent-page kill switch (`setAgentAccessPaused`,
        // relayed through the iPhone) lands in `LocalCommandExecutor`, which
        // deliberately owns no settings reference — this handler is the one
        // line that connects it to the same `killSwitchEngaged` flag every
        // other surface writes, so the release/notice logic in
        // `applySettings` below runs identically no matter who flipped it.
        localCommandExecutor.agentAccessPauseHandler = { [weak self] paused in
            self?.settingsStore.settings.agentGuardrails.killSwitchEngaged = paused
        }
        localSyncServer.start(feedingFrom: coordinator.snapshots())
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Both stores buffer/debounce writes, so quitting without an explicit
        // flush would drop whatever accumulated since the last interval.
        historyStore.flush()
        settingsStore.save()
        localSyncServer.stop()
        // Ask the fan helper for every fan back before we go. This is a
        // *courtesy*, not the guarantee, and the distinction matters enough
        // to spell out: `applicationWillTerminate` is not called on a crash,
        // on a force-quit, or on `kill -9`, which are precisely the
        // circumstances a fan left spinning at a fixed speed would be worst.
        // The guarantee lives in the daemon — the XPC connection dying fires
        // its `invalidationHandler`, which hands every held fan back to the
        // firmware, and its heartbeat expiry catches the case where the app
        // is alive but wedged. `PowerControlService`'s doc comment makes the
        // same split for IOPM assertions and names the OS-side mechanism as
        // the one that still works when this process doesn't. A no-op when
        // no helper is installed, which is the default.
        fanControlBackend.returnEveryFanToFirmware()
        // Retire our endpoint from the bridge's table so the next `sentryctl`
        // run is told "Sentry isn't running" — which will be true — instead of
        // failing to connect to an endpoint that died with this process. Same
        // courtesy-not-guarantee caveat as the fan revert above: this doesn't
        // run on a crash or a force-quit, and the bridge's own
        // `invalidationHandler` is what covers those. A no-op when command-line
        // access was never set up, which is the default.
        mcpEndpointPublisher.withdraw()
        // Best-effort: NIO's own graceful shutdown, not something worth
        // blocking app termination on if it's slow. See `MCPRemoteServer
        // .stop()`'s doc comment — idempotent either way.
        let remoteServer = mcpRemoteServer
        Task { await remoteServer.stop() }
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
        lastAppliedCustomThemes = settingsStore.settings.customThemes
        lastAppliedModules = enabledModules
        let height = cardListMaxHeight()
        lastAppliedCardListMaxHeight = height
        let hostingController = NSHostingController(
            rootView: DropdownView(
                viewModel: dropdownViewModel,
                powerControl: powerControl,
                activityLog: mcpActivityLog,
                settingsStore: settingsStore,
                theme: theme,
                customThemes: settingsStore.settings.customThemes,
                enabledModules: enabledModules,
                cardListMaxHeight: height,
                showsKeepAwake: settingsStore.settings.dropdownShowsKeepAwake,
                showsAgentActivity: settingsStore.settings.dropdownShowsAgentActivity,
                onOpenSettings: { [weak self] in self?.openSettings() },
                onOpenHistory: { [weak self] in self?.openMainWindow(tab: .dashboard) },
                onQuit: { NSApplication.shared.terminate(nil) },
                onSelectTheme: { [weak self] themeID in self?.selectTheme(id: themeID) }
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
        openMainWindow(tab: .settings)
    }

    /// Opens (or fronts) Sentry's one window onto a specific tab.
    private func openMainWindow(tab: MainTab) {
        popover.performClose(nil)
        mainWindowState.tab = tab
        mainWindowController.show()
    }

    /// Theme picked from the dropdown's quick switcher. `applySettings`
    /// deliberately skips popover rebuilds while it's shown (a background
    /// settings change must not yank state out from under the user) — but
    /// here the user asked for the change *from* the popover, so repainting
    /// it immediately is the whole point.
    private func selectTheme(id: String) {
        settingsStore.settings.themeID = id
        guard popover.isShown else { return }
        let theme = Theme.resolve(id: id, in: settingsStore.settings.customThemes)
        configurePopover(theme: theme, enabledModules: settingsStore.settings.enabledModules)
    }

    // MARK: - NSPopoverDelegate

    // Feed the coordinator's adaptive throttling (plan §8.4): polling slows
    // down while nobody is looking at the charts. These fire for *every*
    // close path, including the outside-click dismissal that a `.transient`
    // popover uses and that never goes through `togglePopover`.

    func popoverDidShow(_ notification: Notification) {
        coordinator.popoverIsClosed = false
        applyPopoverFrameMaterial()
    }

    /// Retints the popover's own frame — the `NSVisualEffectView` AppKit
    /// wraps around the content, including the arrow — to match a material
    /// theme, so "Liquid Glass" is glass edge-to-edge rather than glass
    /// content inside a stock gray frame. Walking to the content view's
    /// superview is the only access AppKit offers to that frame view; the
    /// conditional cast means a future AppKit that restructures the popover
    /// silently degrades to the stock frame instead of crashing.
    private func applyPopoverFrameMaterial() {
        guard let frameView = popover.contentViewController?.view.superview as? NSVisualEffectView else { return }
        if let theme = lastAppliedTheme, theme.useMaterialBackground {
            frameView.material = theme.materialStyle.nsMaterial
        } else {
            frameView.material = .popover
        }
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
        let theme = Theme.resolve(id: settings.themeID, in: settings.customThemes)

        statusItemController?.apply(layout: settings.menuBarLayout)
        statusItemController?.apply(theme: theme)

        // The Watch's copy of the same decision. `theme` above is already
        // resolved through `settings.customThemes`, so a theme the user
        // forked in the editor or imported from a `.sentrytheme` file is
        // carried here exactly like a built-in one — which is the whole
        // point, since a custom theme's *id* resolves to nothing on any
        // other device. Flattened to `RelayedPalette` (see that type) and
        // pushed into the coordinator, which puts it on
        // `SystemSnapshot.themePalette` for the phone to relay onward.
        //
        // The appearance is resolved here, on the Mac, for the same reason
        // the colours are: this is where `NSApp.effectiveAppearance` means
        // something. A theme with a light/dark pair therefore reaches the
        // wrist already showing the half this Mac is showing.
        // The user's Light/Dark pin (if any) beats what this Mac's windows
        // happen to be showing; `.auto` keeps the pre-existing behavior.
        let relayedAppearance = settings.appearanceMode.fixedAppearance
            ?? (NSApp.effectiveAppearance.sentryIsDark ? .dark : .light)
        coordinator.themePalette = RelayedPalette(
            theme: theme,
            appearance: relayedAppearance
        )

        // Dashboard reads both live off the view model rather than a value
        // captured once at window construction — without this, a theme
        // change or a Modules-pane edit would never reach an already-built
        // Dashboard window, since `HistoryWindowController` reuses its
        // `NSHostingController` forever. Plain assignment, not conditional:
        // `@Published`'s own `didSet`/equality check already makes a no-op
        // assignment cheap, and `enabledModules`'s `didSet` is what triggers
        // the re-query a module toggle needs.
        dashboardViewModel.theme = theme
        dashboardViewModel.enabledModules = settings.enabledModules
        dashboardViewModel.detailedCharts = settings.detailedCharts
        // The `.raw` tier's row cadence, which is what the Dashboard's charts
        // derive their gap threshold from — see
        // `DashboardViewModel.samplingInterval`.
        dashboardViewModel.samplingInterval = settings.globalRefreshInterval
        insightsViewModel.theme = theme
        // The window chrome (nav bar, its hairline, the base fill behind
        // the titlebar) themes itself off this — see `MainWindowState`.
        mainWindowState.theme = theme
        mainWindowState.appearanceMode = settings.appearanceMode

        // The dropdown popover is its own window, outside the main window's
        // `.preferredColorScheme` reach — pin its NSAppearance directly.
        // The menu bar *item* is deliberately left alone: it follows the
        // menu bar's own appearance (wallpaper-driven), not the app's.
        switch settings.appearanceMode {
        case .auto: popover.appearance = nil
        case .light: popover.appearance = NSAppearance(named: .aqua)
        case .dark: popover.appearance = NSAppearance(named: .darkAqua)
        }

        // Remote (off-LAN) phone access: open/close the TLS-PSK listener
        // to match settings. `enableRemote` is idempotent per config, so
        // calling on every settings emission is safe.
        if settings.remoteSyncEnabled,
           !settings.remoteSyncPairingCode.isEmpty,
           let port = UInt16(exactly: settings.remoteSyncPort) {
            localSyncServer.enableRemote(port: port, pairingCode: settings.remoteSyncPairingCode)
        } else {
            localSyncServer.disableRemote()
        }

        // Entitlement resolution first: `insightsViewModel.applySettings`
        // reads `proEntitlementStore.isUnlocked` synchronously below, so the
        // override toggle must already reflect the delivered value.
        proEntitlementStore.applySettings(settings)
        insightsViewModel.applySettings(settings)

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

        // Same one-way flow as `alertEngine.updateRules` above: the Fans
        // pane writes to settings and never touches the service directly,
        // so this is the single place a policy edit reaches the resolver.
        // Note what this does *not* do — it does not apply anything to the
        // hardware, because nothing in this build can (see
        // `FanControlService`). It only keeps the computed preview honest.
        fanControlService.settings = settings.fanControl

        // Same one-way flow again: the General pane writes
        // `updateCheckDaily` to settings and never touches the updater, so
        // this is the single place the toggle reaches Sparkle's scheduler.
        // Idempotent, so the per-frame emissions of a slider drag cost
        // nothing — and a no-op when no updater exists, which is honest
        // because the pane disables the toggle in exactly that case.
        updateController.applySettings(settings)

        // MCPRemoteServer start/stop is async (binding/tearing down a real
        // socket); `applySettings` itself isn't, so this hops into a
        // detached `Task` rather than blocking whatever triggered the
        // settings change (a Settings-pane toggle, a hand-edited file
        // reload). `start(port:)` itself no-ops if already listening on the
        // same port, so a settings emission unrelated to these two fields
        // doesn't tear down and rebind a live server.
        let remoteAccessEnabled = settings.mcpRemoteAccessEnabled
        let remotePort = settings.mcpRemotePort
        Task { [mcpRemoteServer, mcpXPCService] in
            if remoteAccessEnabled {
                await mcpRemoteServer.start(port: remotePort, serviceCaller: LocalXPCServiceCaller(service: mcpXPCService))
            } else {
                await mcpRemoteServer.stop()
                // Documented contract on `MCPRemoteAccessKey.clear()` that
                // previously had no production caller: turning Remote Access
                // off invalidates the key, so a later re-enable mints a
                // fresh one instead of resurrecting a possibly-shared one.
                MCPRemoteAccessKey.clear()
            }
        }

        // Location Log: request permission (if not already decided) and
        // start capturing only in direct response to the toggle turning on
        // — never at launch, never as a side effect of any other settings
        // change. `requestAuthorization()` itself no-ops once macOS has
        // already recorded a decision, so a re-toggle after a prior grant
        // just resumes capturing without a second prompt.
        if settings.locationLogEnabled {
            locationService.requestAuthorization()
            locationService.start()
        } else {
            locationService.stop()
        }

        // Agent termination controls (see AgentGuardrails): every surface —
        // dropdown, AI Access pane, Watch relay — writes only the settings
        // flags, and this sink is the single place those flags reach
        // `PowerControlService`. Rising-edge detection (not level) so a
        // slider drag's per-frame emissions can't re-announce a revocation.
        let guardrails = settings.agentGuardrails
        if guardrails.killSwitchEngaged, lastKillSwitchEngaged != true,
           let owner = powerControl.agentAssertionOwner {
            powerControl.releaseAgentAssertion()
            announceAgentRevocation(
                reason: String(localized: "Agent access was paused — Sentry released the keep-awake hold \"\(owner)\" was holding."),
                clientName: owner
            )
        }
        lastKillSwitchEngaged = guardrails.killSwitchEngaged
        // The other direction of the same flag: feeds `SystemSnapshot
        // .agentAccessPaused` (via `StatsCoordinator`) so the Watch relay can
        // show — and, via `WatchResumeAgentsIntent`, resume from — a pause
        // that was engaged anywhere. See `StatsCoordinator.agentAccessPaused`
        // and `WatchRelaySnapshot.agentAccessPaused`'s doc comments for the
        // nil-means-old-build convention this keeps intact end to end.
        coordinator.agentAccessPaused = guardrails.killSwitchEngaged

        for name in guardrails.revokedClientNames.subtracting(lastRevokedClientNames)
        where powerControl.releaseAgentAssertion(ownedBy: name) {
            announceAgentRevocation(
                reason: String(localized: "\"\(name)\" was stopped — Sentry released the keep-awake hold it was holding."),
                clientName: name
            )
        }
        lastRevokedClientNames = guardrails.revokedClientNames

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
        let dropdownOptionsChanged = settings.dropdownShowsKeepAwake != lastAppliedDropdownShowsKeepAwake
            || settings.dropdownShowsAgentActivity != lastAppliedDropdownShowsAgentActivity
        lastAppliedDropdownShowsKeepAwake = settings.dropdownShowsKeepAwake
        lastAppliedDropdownShowsAgentActivity = settings.dropdownShowsAgentActivity
        guard theme != lastAppliedTheme
                || settings.customThemes != lastAppliedCustomThemes
                || settings.enabledModules != lastAppliedModules
                || dropdownOptionsChanged,
              !popover.isShown
        else { return }
        configurePopover(theme: theme, enabledModules: settings.enabledModules)
    }

    // MARK: - Agent guardrail revocation (see AgentGuardrails)

    /// Releases an agent-held keep-awake assertion when a guardrail
    /// condition arises mid-hold (quiet hours starting, thermal pressure
    /// reaching serious/critical, or a kill switch that arrived without a
    /// settings emission). Fed per snapshot tick from the loop in
    /// `applicationDidFinishLaunching`; the decision itself is the pure
    /// `AgentGuardrails.autoRevocationReason`, so this method is only glue.
    private func enforceAgentGuardrailRevocation(_ snapshot: SystemSnapshot) {
        guard let owner = powerControl.agentAssertionOwner,
              let reason = AgentGuardrails.autoRevocationReason(
                  settings: settingsStore.settings.agentGuardrails,
                  context: .from(snapshot: snapshot)
              )
        else { return }
        powerControl.releaseAgentAssertion()
        announceAgentRevocation(reason: reason, clientName: owner)
    }

    /// The integration step `CaffeinateArbitrator`'s own doc comment asks
    /// for — see `SentryKit/Services/CaffeinateArbitrator.swift`'s `enforce`
    /// for why it doesn't announce its own outcomes. `sessions` is left at
    /// its default `[]`: the live `AgentSessionRegistry` is owned by
    /// `MCPXPCService`, not this type, so a terminated caffeinate can't be
    /// attributed to a specific client name here — `EnforcementOutcome
    /// .clientName` is `nil` for every match, and the notice names the
    /// action rather than an agent. Attribution without a plumbed-through
    /// registry reference would mean guessing, which is worse than saying
    /// so plainly.
    private func enforceExternalCaffeinateArbitration(_ snapshot: SystemSnapshot) {
        let outcomes = CaffeinateArbitrator.enforce(
            settings: settingsStore.settings.agentGuardrails,
            context: .from(snapshot: snapshot)
        )
        for outcome in outcomes where outcome.terminated {
            announceAgentRevocation(
                reason: String(
                    localized: "Stopped a coding agent's sleep-prevention process (\"caffeinate\", pid \(outcome.match.pid)) so this guardrail could take effect."
                ),
                clientName: String(localized: "Sentry Guardrails")
            )
        }
    }

    /// An auto-revocation must be visible, twice over: a user notification
    /// through the existing `AlertEngine` delivery pathway (lazy
    /// authorization, DND respected — see `deliverGuardrailNotice`), and a
    /// row in the MCP activity feed (AI Access pane + dropdown agent line).
    /// The activity entry's client is "Sentry Guardrails", not the agent —
    /// the agent didn't call `release_awake`, Sentry released it, and the
    /// feed must not attribute an action to a client that never made it;
    /// whose hold it was is named in the summary text instead.
    private func announceAgentRevocation(reason: String, clientName: String) {
        alertEngine.deliverGuardrailNotice(
            title: String(localized: "Agent keep-awake released"),
            body: reason
        )
        mcpActivityLog.record(
            MCPActivityLogEntry(
                clientName: String(localized: "Sentry Guardrails"),
                tool: .releaseAwake,
                argumentsSummary: reason,
                decision: .allow
            )
        )
    }

    // MARK: - MCP XPC listener (plan §13.2)
    //
    // The listener, its delegate, and the connection gate all moved to
    // `MCPEndpointPublisher`. What used to be here was
    // `NSXPCListener(machServiceName:)` plus an `NSXPCListenerDelegate`
    // conformance that accepted every connection unconditionally, on the
    // stated grounds that "there is no connection-level identity check to
    // perform". Two things changed:
    //
    //   * The listener is now anonymous, because a Mach-service listener in
    //     this process could never have received a connection — nothing had
    //     registered the name with launchd, and only the process launchd
    //     starts as the job may vend it. `MCPBridgeContract` has the
    //     measurement.
    //   * There *is* now a connection-level check, because introducing an
    //     endpoint broker means something other than a spawned `SentryMCP`
    //     could plausibly try. It gates who may connect, and nothing more:
    //     `MCPAccessController` inside `MCPXPCService` remains the only thing
    //     deciding what a connected client may do, per call, from live
    //     settings.
    //
    // Still true and still worth recording: this app ships unsandboxed
    // (`Sentry/Sentry.entitlements` sets `com.apple.security.app-sandbox`
    // to false), so none of this needs an entitlement or a provisioning
    // profile, and hardened runtime is irrelevant to it — hardened runtime
    // constrains what code a process may load, not what XPC it may do.
}
