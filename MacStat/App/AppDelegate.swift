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
        doNotDisturb: settingsStore.settings.doNotDisturb
    )

    // MARK: - UI

    private var statusItemController: StatusItemController?
    private let dropdownViewModel = DropdownViewModel()
    private let popover = NSPopover()

    /// Which tab Sentry's one window shows — written by the window's own
    /// glass switcher and by the dropdown's Dashboard/Settings actions.
    private let mainWindowState = MainWindowState()

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
                            locationService: self.locationService,
                            fanControlService: self.fanControlService,
                            updateController: self.updateController
                        )
                    )
                )
            )
        },
        onShow: { [weak self] in
            self?.dashboardViewModel.refresh()
            self?.processMonitor.start()
        },
        onHide: { [weak self] in
            self?.processMonitor.stop()
            // A refresh in flight for a window the user just closed is pure
            // waste — see `InsightsViewModel.cancelRefresh`'s doc comment.
            self?.insightsViewModel.cancelRefresh()
            // The debounced writer may still hold the user's last edit;
            // closing the window is exactly the moment "eventually" isn't
            // enough — carried over from the old SettingsWindowController.
            self?.settingsStore.save()
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
    private lazy var dashboardViewModel = DashboardViewModel(
        historyStore: historyStore,
        enabledModules: settingsStore.settings.enabledModules,
        theme: settingsStore.resolvedTheme()
    )

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
        onOpenAppSettings: { [weak self] in self?.openMainWindow(tab: .settings) }
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
    private var mcpListener: NSXPCListener?

    /// Off by default, unlike `mcpListener`/`localSyncServer` below (both
    /// started unconditionally, gated internally) — this one actually
    /// changes the Mac's network posture (LAN-reachable, not just an inert
    /// local listener), so it stays fully stopped, not just silently
    /// denying, until `mcpRemoteAccessEnabled` is on. See
    /// `MCPRemoteServer`'s doc comment.
    private let mcpRemoteServer = MCPRemoteServer()

    // MARK: - Local-network sync (plan §7.1's "v4" fast path)
    //
    // `LocalSyncServer` (`MacStatKit/LocalSync/LocalSyncServer.swift`) is the
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
    /// (`MacStatKit/Services/LocalCommandExecutor.swift`) for why it shares
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
        // see MacStat-AI-Features-Research.md item #8): Shortcuts.app's own
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

        // MCP (plan §13.2): register the Mach service unconditionally, not
        // gated behind `settings.mcpServerEnabled`. The permission model
        // lives entirely inside `MCPXPCService`/`MCPAccessController` (every
        // method checks live settings before doing anything real) rather
        // than in whether the listener exists at all — same reasoning
        // `AlertEngine`'s lazy-authorization-request pattern uses elsewhere
        // in this file: a disabled feature should *reject cleanly*, not be
        // unreachable in a way that makes `MacStatMCP` fail with an opaque
        // connection error indistinguishable from "MacStat isn't running."
        startMCPListener()

        // Local-network sync (plan §7.1 "v4"): another independent consumer
        // of `coordinator.snapshots()`, same shape as `historyStore`/
        // `dropdownViewModel`/etc. above — not a second poll loop. Started
        // unconditionally, same reasoning `startMCPListener()`'s doc comment
        // gives for its own unconditional registration: a disabled/unused
        // feature should be an inert, harmless listener (nobody on the LAN
        // is browsing for `_macstat._tcp` if no phone app is installed),
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
        insightsViewModel.theme = theme
        // The window chrome (nav bar, its hairline, the base fill behind
        // the titlebar) themes itself off this — see `MainWindowState`.
        mainWindowState.theme = theme

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

    // MARK: - MCP XPC listener (plan §13.2)

    /// Registers `NSXPCListener(machServiceName:)` under the well-known
    /// service name `MacStatMCP` connects to, with `self` as its delegate
    /// (see the `NSXPCListenerDelegate` conformance below) and starts
    /// listening. This app ships unsandboxed — `MacStat/MacStat.entitlements`
    /// says `com.apple.security.app-sandbox = false` outright — so a plain
    /// Mach-service listener works without any entitlement or provisioning
    /// profile, in a hardened-runtime Developer ID Release build exactly as in
    /// the ad-hoc Debug one (hardened runtime constrains what code a process
    /// may load, not what Mach services it may vend); the
    /// XPC service's own methods, not code-signing, are what gate access
    /// (see `MCPXPCService`'s type doc comment).
    private func startMCPListener() {
        let listener = NSXPCListener(machServiceName: MacStatXPCServiceName.machService)
        listener.delegate = self
        listener.resume()
        mcpListener = listener
    }
}

extension AppDelegate: NSXPCListenerDelegate {
    /// Called once per incoming connection attempt from a spawned
    /// `MacStatMCP` process. `exportedObject`/`exportedInterface` are set
    /// per-connection (the standard `NSXPCListener` pattern) rather than
    /// once globally — cheap, since `mcpXPCService` is a single shared
    /// instance reused across every connection, not constructed per-client.
    /// Returning `true` unconditionally and resuming is deliberate: there is
    /// no connection-level identity check to perform (see
    /// `MacStatXPCServiceProtocol`'s doc comment on why `clientName` is
    /// self-reported, not a security boundary) — every actual authorization
    /// decision happens per-method-call inside `MCPXPCService`, not here.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: MacStatXPCServiceProtocol.self)
        newConnection.exportedObject = mcpXPCService
        newConnection.resume()
        return true
    }
}
