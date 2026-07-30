import CloudKit
import Foundation
import MacStatKit

// MARK: - MockDataSource: the only data source this build actually has

/// A `StatsTransport` conformer that fabricates plausible-looking snapshots
/// locally instead of talking to CloudKit — because there is nothing to talk
/// to yet.
///
/// **Why this exists.** Same constraint as `MacStat/Settings/Panes/SyncPane.swift`
/// on the Mac side and `StatsTransport.swift`'s own doc comment: there is no
/// enrolled Apple Developer Program account for this project, so there is no
/// `iCloud.dev.malekswilam.macstat` container, no `CKContainer`, and no real
/// `CloudKitTransport` conformer anywhere in the tree. The iPhone app still
/// needs *something* behind `StatsTransport` to build its screens against —
/// Dashboard/History/Alerts all need a Mac's worth of `SystemSnapshot` data
/// to render, and building those screens against a live protocol type (never
/// against ad hoc view-local fake structs) is what makes swapping this out
/// for a real `CloudKitTransport` later a one-line change at the call site
/// that constructs it, not a UI rewrite.
///
/// **Why it conforms to `StatsTransport` itself, not a new mobile-only
/// protocol.** `StatsTransport` (`MacStatKit/Sync/StatsTransport.swift`) is
/// already "the seam a real CloudKit implementation slots into," per that
/// file's own heading — introducing a second, UI-shaped protocol here would
/// just be a parallel abstraction the real `CloudKitTransport` would also
/// have to satisfy, doubling the seam for no benefit. Conforming directly
/// means the Dashboard/History/Alerts view models can be written against
/// `any StatsTransport` from day one, and `MockDataSource()` today becomes
/// `CloudKitTransport()` later with zero other code changes.
///
/// **What "realistic-looking" means here and why it matters.** The plan's
/// entire iPhone chapter (§12.2) is built around `Freshness` making stale
/// data honest rather than confusing. A mock that always reports "just now"
/// would defeat the ability to see that discipline actually work — every
/// screen would look identically fresh forever, and a developer/reviewer
/// could never tell whether the freshness banner is wired up correctly. So
/// `mockDevice` deliberately reports `lastSeen` a few minutes in the past
/// (see its doc comment below) rather than `Date()`, and the periodic
/// snapshots this type emits keep that gap roughly constant rather than
/// collapsing to zero — the mock is honest about being a snapshot of
/// "recently, not right now," the same category of truth a real
/// CloudKit-backed transport would actually deliver.
///
/// **The one thing this type cannot fake responsibly: `Device.lastSeen` as
/// "live."** Every screen that reads `mockDevice` must still run it through
/// `Freshness` and `FreshnessBadge` exactly as it would a real `Device` —
/// this type does not special-case itself out of that discipline, because
/// the whole point is that the UI layer can't tell (and shouldn't be able to
/// tell) it isn't talking to a real transport.
public actor MockDataSource: StatsTransport {

    /// The one fake Mac this build pretends to sync with. `deviceID` is
    /// stable across calls (not re-randomized per snapshot) so a device
    /// picker built against `[Device]` shows one consistent row rather than
    /// flickering identities.
    public let mockDevice: Device

    /// How often a new synthetic snapshot is produced. 15s keeps the mock
    /// dashboard visibly "moving" (Freshness cycling through `.live` shortly
    /// after each tick) without spinning the simulator's CPU for no reason —
    /// this is demo data, not a stress test.
    private let tickInterval: TimeInterval = 15

    public init(deviceID: String = "mock-mbp-14-2024") {
        // `lastSeen` starts a few minutes in the past rather than "now" —
        // see this type's top-level doc comment on why an always-fresh mock
        // would hide bugs in the freshness UI rather than exercise it.
        let startingLastSeen = Date().addingTimeInterval(-192)
        self.mockDevice = Device(
            deviceID: deviceID,
            deviceName: "Malek's MacBook Pro",
            model: "MacBook Pro (14-inch, 2024)",
            chip: "Apple M3 Pro",
            osVersion: "macOS 15.1",
            appVersion: "0.1.0",
            lastSeen: startingLastSeen,
            capabilitiesJSON: #"{"battery":true,"gpu":true,"ane":true,"thermal":true}"#,
            lastViewedAt: nil
        )
    }

    /// The device catalog this mock pretends to know about. Not part of
    /// `StatsTransport` — the plan doesn't yet specify how the iPhone app
    /// discovers *which* `Device` records exist (that's presumably a plain
    /// CloudKit query against the `Device` record type, made once at
    /// launch/refresh, not a `StatsTransport` responsibility, since
    /// `StatsTransport` is scoped to snapshot/command flow for an
    /// already-known device). Exposed here as a pragmatic concrete-type
    /// extra so `DashboardViewModel`'s device-picker stub (plan §12.1) has
    /// something to populate from today; a real device-catalog fetch is
    /// separate, later work, gated on the same CloudKit enrollment as
    /// everything else in this file's doc comment.
    public func devices() async -> [Device] {
        [mockDevice]
    }

    /// Fabricates a `DailyHealth` series for the History tab's battery
    /// health/cycle-count charts (plan §12.1). Not part of `StatsTransport`
    /// for the same reason `devices()` above isn't: the plan never
    /// specifies how the iPhone app is meant to fetch `DailyHealth` records
    /// — `CKMapper` (`MacStatKit/Sync/CKMapper.swift`) can round-trip one
    /// to/from a `CKRecord`, but no `CKQuery` for the record type exists
    /// anywhere in this tree, and designing that fetch API is separate,
    /// later work this task doesn't own.
    ///
    /// The actual fabrication math lives in `SyntheticDailyHealth`
    /// (`MacStatKit/History/SyntheticDailyHealth.swift`), not here — see
    /// that type's doc comment for why (short version: `MacStatTests` can't
    /// see anything defined inside `MacStatMobile`, so the testable part has
    /// to live in `MacStatKit`). This method is just the actor-isolated
    /// call site that exposes it as part of the mock transport, matching
    /// `devices()`'s own shape immediately above.
    public func dailyHealthHistory(deviceID: String, dayCount: Int) async -> [DailyHealth] {
        SyntheticDailyHealth.series(deviceID: deviceID, dayCount: dayCount)
    }

    // MARK: - StatsTransport

    /// Emits one synthetic `SystemSnapshot` immediately, then one every
    /// `tickInterval` for as long as the returned stream is alive. Each call
    /// gets its own stream/`Task`, matching `StatsTransport.snapshots()`'s
    /// documented "fresh stream per call" contract — a `CloudKitTransport`
    /// fans a single underlying subscription out to each caller; this mock
    /// just runs one independent timer loop per caller, which is simpler and
    /// behaviorally equivalent for a value nobody actually observes over the
    /// network.
    /// `nonisolated` because `StatsTransport.snapshots()` is a synchronous,
    /// non-`async` protocol requirement — callers get the stream back
    /// immediately and consume it with `for await`, they don't `await` the
    /// call that vends it (matching `StatsTransport.swift`'s own doc
    /// comment on why this method isn't `async`). `mockDevice`/`tickInterval`
    /// are safe to read here despite the surrounding `actor`: both are
    /// `let`-bound `Sendable` values, and Swift permits synchronous,
    /// unisolated access to an actor's immutable `Sendable` stored
    /// properties (SE-0313) — no `await` needed to read them.
    public nonisolated func snapshots() -> AsyncStream<SystemSnapshot> {
        let device = mockDevice
        let interval = tickInterval
        return AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    continuation.yield(Self.syntheticSnapshot(deviceID: device.deviceID))
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A fixed, honest-about-itself staleness. `0` would read as "just
    /// synced," which is false — this transport has never synced anything.
    /// `TimeInterval.infinity` is closer to the truth (there is no upstream
    /// to be fresh *relative to*) without risking a caller doing arithmetic
    /// that produces `NaN`/`Inf` propagating into a rendered string; callers
    /// that want an honest age for *display* should read `mockDevice
    /// .lastSeen` through `Freshness` instead, which is what every screen in
    /// this app is required to do anyway (see this type's top-level doc
    /// comment).
    public func freshness() async -> TimeInterval {
        .infinity
    }

    /// No-op: there is no Mac on the other end of this transport to receive
    /// a command. Intentionally does not throw — a thrown error here would
    /// read as "the send failed," implying a send was attempted, when
    /// actually nothing happened at all. Logged instead so the omission is
    /// visible in debug builds without misrepresenting itself to callers
    /// that only check for a thrown error.
    public func send(command: ControlCommand) async throws {
        #if DEBUG
        print("[MockDataSource] ignoring command \(command.commandType) — no real Mac to send it to")
        #endif
    }

    /// No-op for the same reason as `send(command:)` — nothing to upload to.
    public func upload(_ batch: UploadBatch) async throws {
        #if DEBUG
        print("[MockDataSource] ignoring upload of \(batch.recordsToSave.count) record(s) — no real container to upload to")
        #endif
    }

    // MARK: - Synthetic snapshot generation

    /// Builds one plausible `SystemSnapshot` with light jitter so a
    /// dashboard bound to this doesn't render bit-for-identical numbers on
    /// every tick (which would itself look like a hung UI). Ranges are
    /// picked to look like "a MacBook Pro doing ordinary background work,"
    /// not stress-test extremes — this is demo data for laying out a UI, not
    /// a battery-drain simulator.
    private static func syntheticSnapshot(deviceID: String) -> SystemSnapshot {
        let cpuTotal = Double.random(in: 8...34)
        let memTotal: UInt64 = 36_000_000_000
        let memUsed = UInt64(Double(memTotal) * Double.random(in: 0.45...0.68))

        return SystemSnapshot(
            timestamp: Date(),
            deviceID: deviceID,
            battery: BatteryStats(
                chargePercent: Double.random(in: 60...78),
                isCharging: true,
                isPluggedIn: true,
                chargingWatts: Double.random(in: 25...45),
                systemPowerInWatts: Double.random(in: 12...22),
                adapterRatedWatts: 96,
                adapterDescription: "96W USB-C Power Adapter",
                adapterCount: 1,
                cycleCount: 142,
                designCapacityMAh: 6800,
                fullChargeCapacityMAh: 6390,
                healthPercent: 94,
                temperatureCelsius: Double.random(in: 28...34),
                timeToFullMinutes: 46,
                isThermallyLimited: false
            ),
            cpu: CPUStats(
                totalPercent: cpuTotal,
                ecorePercent: cpuTotal * 0.4,
                pcorePercent: cpuTotal * 0.6,
                effectiveFrequencyMHz: 3200,
                packagePowerWatts: Double.random(in: 3...9),
                loadAverage1m: Double.random(in: 1.2...3.1),
                processCount: 421
            ),
            gpu: GPUStats(
                utilizationPercent: Double.random(in: 2...18),
                vramUsedBytes: 2_400_000_000,
                frequencyMHz: 1278,
                powerWatts: Double.random(in: 1...4)
            ),
            ane: ANEStats(powerWatts: 0.1, isActive: false),
            memory: MemoryStats(
                usedBytes: memUsed,
                appMemoryBytes: UInt64(Double(memUsed) * 0.7),
                wiredBytes: UInt64(Double(memTotal) * 0.08),
                compressedBytes: UInt64(Double(memTotal) * 0.05),
                cachedBytes: UInt64(Double(memTotal) * 0.1),
                totalBytes: memTotal,
                pressureLevel: .normal
            ),
            disk: DiskStats(
                freeBytes: 412_000_000_000,
                totalBytes: 1_000_000_000_000,
                readBytesPerSec: Double.random(in: 0...4_000_000),
                writeBytesPerSec: Double.random(in: 0...2_000_000)
            ),
            network: NetworkStats(
                rxBytesPerSec: Double.random(in: 10_000...800_000),
                txBytesPerSec: Double.random(in: 5_000...200_000),
                rxSessionTotalBytes: 4_200_000_000,
                txSessionTotalBytes: 890_000_000,
                activeInterface: "en0",
                isWiFi: true,
                wifiSSID: "Demo Network",
                wifiRSSIdBm: -52,
                wifiTxRateMbps: 866
            ),
            thermal: ThermalStats(
                socTemperatureCelsius: Double.random(in: 42...58),
                fanRPMs: [0, 0],
                pressureLevel: .nominal,
                isThrottling: false
            ),
            sleepAssertion: .inactive
        )
    }
}
