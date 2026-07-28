import Cocoa
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

    // MARK: - UI

    private var statusItemController: StatusItemController?
    private let dropdownViewModel = DropdownViewModel()
    private let popover = NSPopover()
    private lazy var settingsWindowController = SettingsWindowController(settingsStore: settingsStore)

    private var snapshotTask: Task<Void, Never>?
    private var settingsObservation: Task<Void, Never>?

    /// Only a theme change requires rebuilding the dropdown's SwiftUI tree.
    /// Tracked so unrelated settings edits (a retention slider drag emits a
    /// value per frame) don't tear down and rebuild an `NSHostingController`
    /// each time — and can't stomp an open popover.
    private var lastAppliedTheme: Theme?

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

        configurePopover(theme: theme)

        // Apply persisted settings before anything starts polling, so a saved
        // refresh interval / retention window takes effect on the first tick
        // rather than only after the user next touches a control.
        coordinator.setBaseInterval(settings.globalRefreshInterval)
        coordinator.adaptiveThrottlingEnabled = settings.adaptiveThrottlingEnabled
        rollupJob.setRetention(
            rawHours: settings.rawRetentionHours,
            hourlyDays: settings.hourlyRetentionDays
        )
        rollupJob.start()

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
            }
        }

        // Live-apply theme/layout changes made in Settings without a restart.
        settingsObservation = Task { [weak self] in
            guard let self else { return }
            for await newSettings in self.settingsStore.$settings.values {
                self.applySettings(newSettings)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Both stores buffer/debounce writes, so quitting without an explicit
        // flush would drop whatever accumulated since the last interval.
        historyStore.flush()
        settingsStore.save()
    }

    // MARK: - Popover

    private func configurePopover(theme: Theme) {
        popover.behavior = .transient
        popover.animates = true
        // `.transient` closes on an outside click without ever calling
        // `togglePopover`, so the throttling flag has to come from the
        // delegate callbacks or it latches to "open" after the first
        // dismissal and silently disables §8.4 throttling for the rest of
        // the run.
        popover.delegate = self
        lastAppliedTheme = theme
        popover.contentViewController = NSHostingController(
            rootView: DropdownView(
                viewModel: dropdownViewModel,
                theme: theme,
                onOpenSettings: { [weak self] in self?.openSettings() },
                onOpenHistory: { [weak self] in self?.openSettings() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        )
    }

    private func togglePopover() {
        guard let button = statusItemController?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
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
        coordinator.adaptiveThrottlingEnabled = settings.adaptiveThrottlingEnabled
        rollupJob.setRetention(
            rawHours: settings.rawRetentionHours,
            hourlyDays: settings.hourlyRetentionDays
        )

        // Rebuilding the hosting controller is how a new theme reaches an
        // already-constructed SwiftUI tree, but it's expensive and discards
        // scroll state — so only on an actual theme change, and never while
        // the user is looking at the popover.
        guard theme != lastAppliedTheme, !popover.isShown else { return }
        configurePopover(theme: theme)
    }
}
