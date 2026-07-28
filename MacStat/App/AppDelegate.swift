import Cocoa
import MacStatKit
import SystemMetricsKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var snapshotTask: Task<Void, Never>?

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

    // Opens (or creates) ~/Library/Application Support/MacStat/history.sqlite
    // at construction (plan §14.3) — never fails loudly, degrades to a no-op
    // store if the disk write fails (P5).
    private let historyStore = HistoryStore()
    private lazy var rollupJob = RollupJob(dbQueue: historyStore.databaseQueue)

    private var batteryItem: NSMenuItem?
    private var cpuItem: NSMenuItem?
    private var memoryItem: NSMenuItem?
    private var gpuItem: NSMenuItem?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "bolt.fill",
            accessibilityDescription: "MacStat"
        )

        let menu = NSMenu()
        let battery = NSMenuItem(title: "Battery: —", action: nil, keyEquivalent: "")
        let cpu = NSMenuItem(title: "CPU: —", action: nil, keyEquivalent: "")
        let memory = NSMenuItem(title: "Memory: —", action: nil, keyEquivalent: "")
        let gpu = NSMenuItem(title: "GPU: —", action: nil, keyEquivalent: "")
        for menuItem in [battery, cpu, memory, gpu] {
            menuItem.isEnabled = false
            menu.addItem(menuItem)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MacStat", action: #selector(quit), keyEquivalent: "q")
        item.menu = menu

        statusItem = item
        batteryItem = battery
        cpuItem = cpu
        memoryItem = memory
        gpuItem = gpu

        rollupJob.start()

        // StatsCoordinator's AsyncStream is the single source every consumer
        // reads (plan §3.2 P3) — the menu bar and the history store are two
        // independent consumers of the exact same stream, neither aware of
        // the other, per P3's whole point.
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in self.coordinator.snapshots() {
                self.historyStore.record(snapshot)
                await MainActor.run { self.update(with: snapshot) }
            }
        }
    }

    @MainActor
    private func update(with snapshot: SystemSnapshot) {
        if let battery = snapshot.battery {
            let chargingSuffix = battery.isCharging ? " (charging)" : ""
            batteryItem?.title = "Battery: \(Int(battery.chargePercent))%\(chargingSuffix)"
            statusItem?.button?.title = " \(Int(battery.chargePercent))%"
        }
        if let cpu = snapshot.cpu {
            cpuItem?.title = "CPU: \(String(format: "%.0f", cpu.totalPercent))%"
        }
        if let memory = snapshot.memory {
            let usedGB = Double(memory.usedBytes) / 1_073_741_824
            let totalGB = Double(memory.totalBytes) / 1_073_741_824
            memoryItem?.title = "Memory: \(String(format: "%.1f", usedGB))/\(String(format: "%.0f", totalGB)) GB"
        }
        if let gpu = snapshot.gpu {
            let util = gpu.utilizationPercent.map { String(format: "%.0f%%", $0) } ?? "—"
            let power = gpu.powerWatts.map { " · \(String(format: "%.2f", $0))W" } ?? ""
            gpuItem?.title = "GPU: \(util)\(power)"
        }
    }

    @objc private func quit() {
        // HistoryStore's own doc comment calls this out explicitly: app
        // quit is one of the cases that needs a guaranteed write rather
        // than waiting for the next 30s auto-flush. Called from the main
        // thread (menu action), never from HistoryStore's own private
        // queue, so no deadlock risk (see flush()'s doc comment).
        historyStore.flush()
        NSApplication.shared.terminate(nil)
    }
}
