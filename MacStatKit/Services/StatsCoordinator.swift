import Foundation

#if os(macOS)
import Dispatch

/// Central polling/fan-out service (plan §3.2 P1/P3, §8.4). Runs a tiered
/// `DispatchSourceTimer` scheduler and publishes each assembled
/// `SystemSnapshot` to every subscriber via `AsyncStream`. Every consumer —
/// the menu bar, a future dropdown, the sync service, eventually the MCP
/// server — reads the same stream, so adding a consumer never changes
/// polling behavior (P3).
///
/// **Dependency inversion, and why:** per plan §4.2 this type lives in
/// `MacStatKit/Services/`, and the six concrete collectors
/// (`BatteryCollector`, `CPUCollector`, ...) live in `SystemMetricsKit`.
/// `project.yml` (not to be edited for this task) declares the dependency
/// edge as `SystemMetricsKit → MacStatKit_macOS`, not the other way — so
/// `MacStatKit` importing `SystemMetricsKit` would make the two frameworks
/// depend on each other, which Xcode cannot build under any `#if` guard.
/// Rather than reach for a concrete collector type, `StatsCoordinator` is
/// initialized with plain `() -> Sample?` provider closures — one per
/// metric — that the composition root (wherever both frameworks are linked,
/// e.g. `MacStatApp`) supplies as `someCollector.collect`. This keeps P1
/// intact (each metric still has exactly one collector backing its
/// provider) and arguably sharpens P4 ("transport-agnostic service layer")
/// further: `StatsCoordinator` doesn't even link against IOKit-adjacent
/// code, only `Foundation`/`Dispatch` and `MacStatKit`'s own model types.
/// Stateful collectors (CPU/Disk/Network delta tracking) work correctly
/// because the caller is expected to close over one persistent collector
/// instance per provider (`cpuCollector.collect`, not
/// `{ CPUCollector().collect() }`), not construct a fresh collector inside
/// the closure.
///
/// **Concurrency model:** this class is `@unchecked Sendable` and guards
/// every piece of mutable state (latest-known samples, subscriber
/// continuations, the adaptive-throttling inputs) behind a private serial
/// `DispatchQueue` rather than `@MainActor`. Timers fire on that queue, but
/// **provider calls themselves run off of it** (dispatched to a global
/// concurrent queue) precisely so a provider that blocks — GPU/ANE power via
/// `SharedEnergySampler`, ~1s — can never delay another tier's scheduled
/// tick or a `queue.sync` property read; only the actual mutation of
/// `latest`/`continuations` hops back onto `queue` to stay serialized. This
/// was a real bug in an earlier revision (all provider calls ran directly on
/// `queue`, so any tier's slow provider stalled every other tier — caught by
/// independent review, not by the original design). Consumers get immutable
/// `SystemSnapshot` values off `AsyncStream`; it's on them (typically a
/// SwiftUI view) to hop to `@MainActor` when they render.
public final class StatsCoordinator: @unchecked Sendable {

    // MARK: - Tiers (plan §8.4)
    //
    // The plan's tier table splits sub-metrics of a single collector across
    // tiers (e.g. Battery's "charging watts" is listed under Medium while
    // "cycle count" is Slow, even though both come out of one
    // `BatteryCollector`). Phase 1 simplifies to one collector == one tier,
    // chosen by picking each collector's dominant/defining metric:
    //
    //   Fast   (3s default)  — CPU, Memory, Network, Disk throughput, GPU.
    //                          The plan's own words: "genuinely dynamic," and
    //                          the plan's §8.4 table places GPU here
    //                          explicitly, alongside CPU/memory/network/disk.
    //   Medium (5s default)  — Thermal (pressure, SoC temperature, fan RPM),
    //                          ANE. The plan groups "temperatures, fan RPM"
    //                          here and notes IOReport-backed readings "need
    //                          >=1s windows anyway."
    //   Slow   (30s default) — Battery (%, health, cycle count, capacity).
    //                          The plan explicitly calls battery "a
    //                          reasonable slow-tier fit" — it barely changes
    //                          tick to tick.
    //
    // GPU and ANE both read power via the same blocking (~1s)
    // `IOReportBridge.sampleDelta` call (through `SharedEnergySampler`).
    // Earlier revisions of this file moved GPU into the medium tier to keep
    // that blocking work away from the fast tier's cadence — but the real
    // problem wasn't which tier GPU sat in, it was that every tier's timer
    // shared one serial `queue`, so *any* tier's blocking provider call
    // stalled every other tier's scheduled ticks regardless of placement
    // (confirmed by independent review). `tick(tier:)` below now dispatches
    // provider calls off `queue` entirely and only hops back to mutate
    // state, which fixes the real problem generically — so GPU moves back
    // to the fast tier to match the plan's explicit table, and blocking is
    // no longer a factor in tier placement at all.
    //
    // The Event tier (plug/unplug, sleep/wake, thermal-state transitions via
    // IOPSNotification/NSWorkspace) is out of scope for this pass — nothing
    // here currently pushes ad hoc updates between ticks.
    public enum Tier: Hashable {
        case fast, medium, slow
    }

    // MARK: - Dependencies (provider closures — see type doc for why)

    private let batteryProvider: () -> BatteryStats?
    private let cpuProvider: () -> CPUStats?
    private let memoryProvider: () -> MemoryStats?
    private let diskProvider: () -> DiskStats?
    private let networkProvider: () -> NetworkStats?
    private let thermalProvider: () -> ThermalStats?

    /// Optional dependency slot: a `GPUCollector` already exists in
    /// `SystemMetricsKit`, but the coordinator itself only ever sees the
    /// provider closure, so wiring it in (or leaving it nil on a Mac where
    /// it's unavailable) is the composition root's call.
    private let gpuProvider: (() -> GPUStats?)?

    /// Optional dependency slot for ANE stats. No `ANECollector` type exists
    /// yet anywhere in the codebase. Settable post-init (unlike the other
    /// providers, which are fixed at construction) so wiring in the real
    /// thing later is just `coordinator.aneCollectorProvider = { ANECollector().collect() }`
    /// once it exists, with no signature changes anywhere in
    /// `StatsCoordinator`.
    public var aneCollectorProvider: (() -> ANEStats?)? {
        get { queue.sync { aneCollectorProviderStorage } }
        set { queue.async { [weak self] in self?.aneCollectorProviderStorage = newValue } }
    }
    private var aneCollectorProviderStorage: (() -> ANEStats?)?

    // MARK: - Identity

    /// Stable per-Mac identifier (plan §6.1: "stable per-Mac UUID"). Phase 1
    /// keeps this in memory only — the plan wants it persisted under the app
    /// support directory, but `SettingsStore`/persistence doesn't exist yet
    /// (out of scope here). TODO(later phase): persist and reload this
    /// instead of minting a fresh UUID every launch.
    public let deviceID: String

    // MARK: - Scheduling configuration

    // Live-adjustable so the §8.4 settings slider actually takes effect
    // without an app restart. Queue-confined like all other mutable state.
    private var fastInterval: TimeInterval
    private var mediumInterval: TimeInterval
    private var slowInterval: TimeInterval
    private var adaptiveThrottlingEnabledStorage = true

    /// Master switch for the §8.4 throttling multipliers. Off means every
    /// tier polls at its configured base interval regardless of power state.
    public var adaptiveThrottlingEnabled: Bool {
        get { queue.sync { adaptiveThrottlingEnabledStorage } }
        set { queue.async { [weak self] in self?.adaptiveThrottlingEnabledStorage = newValue } }
    }

    /// Rescales all three tiers from a single user-facing "fast" interval,
    /// keeping the plan's 1x/1.67x/10x tier ratios. Takes effect on each
    /// tier's next self-reschedule.
    public func setBaseInterval(_ fast: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            let clamped = min(max(fast, 0.5), 30)
            self.fastInterval = clamped
            self.mediumInterval = clamped * (5.0 / 3.0)
            self.slowInterval = clamped * 10
        }
    }

    /// Hard ceiling from the plan's `effectiveInterval` example (§8.4).
    private static let maxInterval: TimeInterval = 60

    /// Nobody's looking at the popover yet — there's no UI wired to this
    /// coordinator. Defaulting to "closed" means the throttle is applied by
    /// default rather than assuming a window is always open, which matches
    /// P6 ("cheap by default"). The menu bar / dropdown layer should flip
    /// this as the popover opens and closes once it exists.
    public var popoverIsClosed: Bool {
        get { queue.sync { popoverIsClosedStorage } }
        set { queue.async { [weak self] in self?.popoverIsClosedStorage = newValue } }
    }
    private var popoverIsClosedStorage = true

    /// Current sleep-prevention state, pushed down by the composition root
    /// whenever `PowerControlService.state` changes — deliberately *not* a
    /// provider closure like the collectors above.
    ///
    /// `PowerControlService` is `@MainActor`-isolated, and every provider
    /// closure here is invoked from a global background queue in
    /// `tick(tier:)`; reading a main-actor `@Published` property from there
    /// would be exactly the kind of unsynchronized cross-domain access this
    /// file's own history (the `ChannelResolver` crash) argues against.
    /// Pushing from the main actor instead keeps the isolation boundary
    /// intact in the direction it already runs, and costs nothing — the
    /// state changes on user action, not on a poll tick.
    ///
    /// Feeds `SystemSnapshot.sleepAssertion`, which is what makes the
    /// `.whenAssertionActive` menu bar visibility rule (already implemented
    /// in `StatusItemView.isVisible`) able to ever evaluate true.
    public var sleepAssertionState: SleepAssertionState? {
        get { queue.sync { sleepAssertionStateStorage } }
        set { queue.async { [weak self] in self?.sleepAssertionStateStorage = newValue } }
    }
    private var sleepAssertionStateStorage: SleepAssertionState?

    /// Derived from the most recent `BatteryStats.isPluggedIn`, per the
    /// task's guidance to read our own last-known snapshot rather than
    /// re-deriving power-source state elsewhere (that would violate P1 —
    /// one source of truth per metric; the battery collector behind
    /// `batteryProvider` already owns the IOPowerSources read). `nil` until
    /// the first battery sample lands (or forever, on a desktop Mac with no
    /// battery), which resolves to "not on battery" — correct in both the
    /// "unknown yet" and "no battery" cases.
    private var lastKnownIsPluggedIn: Bool?
    private var isOnBattery: Bool { lastKnownIsPluggedIn == false }

    // MARK: - Internal state (queue-confined)

    private let queue = DispatchQueue(label: "dev.malekswilam.macstat.statscoordinator", qos: .utility)
    private var timers: [Tier: DispatchSourceTimer] = [:]
    private var isPolling = false
    private var continuations: [UUID: AsyncStream<SystemSnapshot>.Continuation] = [:]

    private struct LatestSamples {
        var battery: BatteryStats?
        var cpu: CPUStats?
        var gpu: GPUStats?
        var ane: ANEStats?
        var memory: MemoryStats?
        var disk: DiskStats?
        var network: NetworkStats?
        var thermal: ThermalStats?
    }
    private var latest = LatestSamples()

    // MARK: - Init

    /// - Parameters:
    ///   - batteryProvider...thermalProvider: one closure per metric, each
    ///     expected to close over a single persistent collector instance
    ///     (e.g. `cpuCollector.collect`) rather than constructing a fresh
    ///     collector per call — several of these are stateful delta
    ///     trackers (plan §3.2 P2) that only produce correct rates when
    ///     called repeatedly on the same instance.
    ///   - gpuProvider: optional; nil on a Mac/build where GPU stats aren't
    ///     wired up.
    ///   - fastInterval/mediumInterval/slowInterval: base tier intervals
    ///     before adaptive throttling (plan §8.4 defaults: 3s/5s/30s).
    ///   - deviceID: see the `deviceID` property doc — in-memory only for
    ///     Phase 1.
    public init(
        batteryProvider: @escaping () -> BatteryStats?,
        cpuProvider: @escaping () -> CPUStats?,
        memoryProvider: @escaping () -> MemoryStats?,
        diskProvider: @escaping () -> DiskStats?,
        networkProvider: @escaping () -> NetworkStats?,
        thermalProvider: @escaping () -> ThermalStats?,
        gpuProvider: (() -> GPUStats?)? = nil,
        aneProvider: (() -> ANEStats?)? = nil,
        fastInterval: TimeInterval = 3,
        mediumInterval: TimeInterval = 5,
        slowInterval: TimeInterval = 30,
        deviceID: String = UUID().uuidString
    ) {
        self.batteryProvider = batteryProvider
        self.cpuProvider = cpuProvider
        self.memoryProvider = memoryProvider
        self.diskProvider = diskProvider
        self.networkProvider = networkProvider
        self.thermalProvider = thermalProvider
        self.gpuProvider = gpuProvider
        self.aneCollectorProviderStorage = aneProvider
        self.fastInterval = fastInterval
        self.mediumInterval = mediumInterval
        self.slowInterval = slowInterval
        self.deviceID = deviceID
    }

    // MARK: - Public API

    /// Returns a fresh `AsyncStream` of snapshots and (lazily, on first call
    /// from any subscriber) starts the tiered poll loop. Plain `AsyncStream`
    /// only supports one consumer per stream, so "multi-subscriber" here
    /// means: every call to `snapshots()` returns its own stream, and every
    /// live stream's continuation is fanned out to on every tick from the
    /// single shared underlying poll loop — the menu bar, a future dropdown,
    /// and the sync service can each hold their own stream without causing
    /// three independent sets of timers/IOKit calls. A brand-new subscriber
    /// is handed whatever is already known immediately, rather than waiting
    /// up to a full slow-tier interval for its first value.
    public func snapshots() -> AsyncStream<SystemSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            queue.async { [weak self] in
                guard let self else { return }
                self.continuations[id] = continuation
                self.startPollingIfNeeded()
                continuation.yield(self.buildSnapshot())
            }
            continuation.onTermination = { [weak self] _ in
                self?.queue.async {
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Stops all timers and drops every subscriber's continuation. Mainly
    /// for app-teardown / test cleanup; polling restarts automatically the
    /// next time `snapshots()` is called.
    public func stopPolling() {
        queue.async { [weak self] in
            guard let self else { return }
            for timer in self.timers.values { timer.cancel() }
            self.timers.removeAll()
            self.isPolling = false
            for continuation in self.continuations.values { continuation.finish() }
            self.continuations.removeAll()
        }
    }

    /// `stopPolling()` dispatches `async` with `[weak self]`, which is
    /// exactly wrong during teardown: by the time that block would run,
    /// `self` is already gone, so it would silently no-op — every open
    /// `AsyncStream` continuation would never get `.finish()`ed, and a
    /// consumer's `for await snapshot in coordinator.snapshots() { ... }`
    /// loop would hang forever instead of terminating when the coordinator
    /// itself is dropped without an explicit `stopPolling()` call (caught by
    /// independent review). Safe to touch `timers`/`continuations` directly
    /// here with no `queue.sync`: `deinit` only runs once every strong
    /// reference is gone, and every closure that captures `self` elsewhere
    /// in this class does so `[weak self]`, so nothing still in flight can
    /// be concurrently mutating this state by the time we get here.
    deinit {
        for timer in timers.values { timer.cancel() }
        for continuation in continuations.values { continuation.finish() }
    }

    // MARK: - Polling (queue-confined)

    private func startPollingIfNeeded() {
        guard !isPolling else { return }
        isPolling = true
        scheduleTimer(for: .fast)
        scheduleTimer(for: .medium)
        scheduleTimer(for: .slow)
    }

    /// Self-rescheduling rather than a fixed `repeating:` interval, so a
    /// change in adaptive-throttling inputs (plug/unplug, popover state,
    /// Low Power Mode) takes effect on the very next tick instead of only
    /// after the timer is torn down and recreated some other way.
    private func scheduleTimer(for tier: Tier) {
        timers[tier]?.cancel()

        let interval = effectiveInterval(for: tier)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Leeway ~10% of the interval (plan §8.4) lets macOS coalesce this
        // wakeup with other timers instead of waking the CPU precisely on
        // schedule — a real, measurable battery win for a background app.
        timer.schedule(deadline: .now() + interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.tick(tier: tier)
            self.scheduleTimer(for: tier)
        }
        timers[tier] = timer
        timer.resume()
    }

    private func baseInterval(for tier: Tier) -> TimeInterval {
        switch tier {
        case .fast: return fastInterval
        case .medium: return mediumInterval
        case .slow: return slowInterval
        }
    }

    /// Adaptive throttling per the plan's §8.4 example. This Phase 1
    /// coordinator only has real signal for three of the five multipliers
    /// the plan lists: on-battery, popover visibility (injectable above
    /// since no UI exists yet to drive it), and Low Power Mode.
    /// `barItemIsHidden(inNotch:)` and `displayIsAsleep` need menu-bar
    /// geometry and display-sleep notifications this coordinator doesn't
    /// wire up yet — left as a later-phase TODO rather than guessed at.
    private func effectiveInterval(for tier: Tier) -> TimeInterval {
        var interval = baseInterval(for: tier)
        guard adaptiveThrottlingEnabledStorage else { return min(interval, Self.maxInterval) }
        if isOnBattery { interval *= 2 }
        if popoverIsClosedStorage { interval *= 2 }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { interval *= 3 }
        return min(interval, Self.maxInterval)
    }

    /// Called on `queue` (from the timer event handler), but the actual
    /// provider invocations run on a separate global queue — see the
    /// concurrency-model doc comment at the top of this file for why. Only
    /// the final mutation of `latest`/`continuations` hops back onto
    /// `queue`. Providers are read here (already on `queue`) and captured
    /// into locals before the hop, since `aneCollectorProviderStorage` is
    /// itself queue-confined state.
    private func tick(tier: Tier) {
        switch tier {
        case .fast:
            let cpuProvider = self.cpuProvider
            let memoryProvider = self.memoryProvider
            let networkProvider = self.networkProvider
            let diskProvider = self.diskProvider
            let gpuProvider = self.gpuProvider
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let cpu = cpuProvider()
                let memory = memoryProvider()
                let network = networkProvider()
                let disk = diskProvider()
                let gpu = gpuProvider?()
                self?.queue.async {
                    guard let self else { return }
                    self.latest.cpu = cpu
                    self.latest.memory = memory
                    self.latest.network = network
                    self.latest.disk = disk
                    self.latest.gpu = gpu
                    self.publishSnapshot()
                }
            }
        case .medium:
            let thermalProvider = self.thermalProvider
            let aneProvider = self.aneCollectorProviderStorage
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let thermal = thermalProvider()
                let ane = aneProvider?()
                self?.queue.async {
                    guard let self else { return }
                    self.latest.thermal = thermal
                    self.latest.ane = ane
                    self.publishSnapshot()
                }
            }
        case .slow:
            let batteryProvider = self.batteryProvider
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let battery = batteryProvider()
                self?.queue.async {
                    guard let self else { return }
                    if let battery {
                        self.latest.battery = battery
                        self.lastKnownIsPluggedIn = battery.isPluggedIn
                    }
                    self.publishSnapshot()
                }
            }
        }
    }

    private func publishSnapshot() {
        let snapshot = buildSnapshot()
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    /// Every sub-struct on `SystemSnapshot` is optional (plan §6.1) so a Mac
    /// missing a capability — or a tier that just hasn't ticked yet —
    /// produces a valid, smaller snapshot rather than fake zeros.
    /// `sleepAssertion` is pushed in from the main actor rather than polled
    /// — see `sleepAssertionState`'s doc comment for why.
    private func buildSnapshot() -> SystemSnapshot {
        SystemSnapshot(
            deviceID: deviceID,
            battery: latest.battery,
            cpu: latest.cpu,
            gpu: latest.gpu,
            ane: latest.ane,
            memory: latest.memory,
            disk: latest.disk,
            network: latest.network,
            thermal: latest.thermal,
            sleepAssertion: sleepAssertionStateStorage
        )
    }
}
#endif
