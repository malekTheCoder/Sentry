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
/// `SentryKit/Services/`, and the six concrete collectors
/// (`BatteryCollector`, `CPUCollector`, ...) live in `SystemMetricsKit`.
/// `project.yml` (not to be edited for this task) declares the dependency
/// edge as `SystemMetricsKit → SentryKit_macOS`, not the other way — so
/// `SentryKit` importing `SystemMetricsKit` would make the two frameworks
/// depend on each other, which Xcode cannot build under any `#if` guard.
/// Rather than reach for a concrete collector type, `StatsCoordinator` is
/// initialized with plain `() -> Sample?` provider closures — one per
/// metric — that the composition root (wherever both frameworks are linked,
/// e.g. `SentryApp`) supplies as `someCollector.collect`. This keeps P1
/// intact (each metric still has exactly one collector backing its
/// provider) and arguably sharpens P4 ("transport-agnostic service layer")
/// further: `StatsCoordinator` doesn't even link against IOKit-adjacent
/// code, only `Foundation`/`Dispatch` and `SentryKit`'s own model types.
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
    //
    // FR-2 ("refresh interval user-adjustable per module") is implemented at
    // this tier granularity, not per collector — see `setBaseInterval`'s doc
    // comment below for why that's a deliberate scope call, not a shortcut.
    //
    //   Process (8s default) — top-N processes by CPU
    //                          (`SystemSnapshot.topProcesses`). Deliberately
    //                          its own tier, not folded into `.fast` or even
    //                          `.slow`: `ProcessCollector`'s own doc comment
    //                          (`SystemMetricsKit/Collectors/ProcessCollector.swift`)
    //                          calls per-process enumeration meaningfully
    //                          more expensive than any other single
    //                          collector's per-tick cost, so it needs a
    //                          cadence slower than `.fast`'s 3s — but 30s
    //                          (`.slow`'s default) is too coarse for
    //                          "process X has been pegging CPU for N
    //                          minutes" alerting to notice promptly. 8s
    //                          lands in the same 5–10s neighborhood
    //                          `ProcessMonitor` (the Dashboard's own,
    //                          entirely separate poller for the same
    //                          underlying data) already uses for its "Top
    //                          Processes" card, without literally sharing a
    //                          cadence — these are two independent
    //                          `ProcessCollector` instances, each enumerating
    //                          on its own timer for its own consumer
    //                          (Dashboard UI vs. `AlertEngine`), exactly the
    //                          same "no shared mutable collector state
    //                          across consumers" posture every other
    //                          provider closure on this type already has.
    //                          Reuses the same adaptive-throttling
    //                          multipliers as every other tier
    //                          (`effectiveInterval(for:)`), since a
    //                          comparatively expensive collector is
    //                          precisely the one that should back off
    //                          hardest on battery / with the popover closed.
    public enum Tier: Hashable {
        case fast, medium, slow, process
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

    /// Optional dependency slot: process enumeration
    /// (`SystemSnapshot.topProcesses`) is meaningfully more expensive than
    /// every other collector here (see the `.process` tier's doc comment
    /// above), so it gets the same "optional provider closure, nil on a
    /// composition root that hasn't wired it in" treatment as `gpuProvider`
    /// rather than being a required dependency every caller (including every
    /// existing test that constructs a `StatsCoordinator`) would otherwise
    /// have to supply. `nil` means the `.process` tier never starts a timer
    /// at all (see `startPollingIfNeeded`) — not "starts and yields nothing"
    /// — so a Mac/build without this wired pays literally zero cost for it,
    /// matching P6 ("cheap by default").
    private let processProvider: (() -> [ProcessStats]?)?

    /// Base interval for the `.process` tier — see that tier's doc comment
    /// for why 8s and why it's a separate tier from `.fast`/`.medium`/`.slow`
    /// rather than reusing one of them. `let`, not `var` like
    /// `fastInterval`/`mediumInterval`/`slowInterval`: those three are
    /// user-adjustable via `AppSettings`/`GeneralPane` (FR-2), and wiring a
    /// fourth settings-pane slider for this tier is out of scope for the
    /// alerting feature this exists to support — nothing currently reads or
    /// writes this after construction. `effectiveInterval(for:)`'s adaptive
    /// throttling still applies on top of it exactly as it does for the
    /// other three tiers' base intervals.
    private let processInterval: TimeInterval

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

    /// Sets the fast tier's base interval (plan §8.4's "0.5s...30s" slider;
    /// `AppSettings.globalRefreshInterval`). Takes effect on the fast timer's
    /// next self-reschedule.
    ///
    /// **FR-2 note (per-tier, not per-module, control):** earlier revisions
    /// of this method also rescaled `mediumInterval`/`slowInterval` off of
    /// `fast` by the plan's fixed 1x/1.67x/10x ratios, so there was no way to
    /// move one tier without moving all three. FR-2 asks for user-adjustable
    /// refresh "per module" — but this scheduler is tier-based (one timer per
    /// fast/medium/slow tier, each carrying several collectors; see the enum
    /// doc above), not per-metric, and the plan's own §8.4 table already
    /// groups metrics into exactly those three tiers rather than describing
    /// independent per-metric timers. A true per-module scheduler would mean
    /// one `DispatchSourceTimer` per collector, which is a materially bigger
    /// architectural change than FR-2's one-line requirement implies, and
    /// cuts against §3.2's P1/P3 preference for one simple poll loop. This
    /// method (plus `setMediumInterval`/`setSlowInterval` below) instead
    /// gives the user independent control over each *tier's* base interval —
    /// "make the fast tier (CPU/GPU/memory/network/disk) update quicker" and
    /// "make the slow tier (battery) update less often" are both expressible
    /// now, which is the spirit of FR-2 without overclaiming per-metric
    /// granularity the UI doesn't actually have. See `AppSettings`'s
    /// `mediumTierRefreshInterval`/`slowTierRefreshInterval` doc comments and
    /// `GeneralPane`'s "Tier Intervals" section for where this is surfaced.
    public func setBaseInterval(_ fast: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            self.fastInterval = min(max(fast, 0.5), 30)
        }
    }

    /// Sets the medium tier's base interval independently of `fast`
    /// (`AppSettings.mediumTierRefreshInterval`). See `setBaseInterval`'s doc
    /// comment for why tiers are now independently adjustable rather than
    /// ratio-locked. Clamped to 1...60s: below 1s defeats the plan's own
    /// rationale for this tier ("IOReport needs >=1s windows anyway"); above
    /// 60s a "medium" tier slower than the "slow" tier's 30s default would be
    /// a confusing inversion for a value nobody asked to type in directly.
    public func setMediumInterval(_ medium: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            self.mediumInterval = min(max(medium, 1), 60)
        }
    }

    /// Sets the slow tier's base interval independently of `fast`
    /// (`AppSettings.slowTierRefreshInterval`). See `setBaseInterval`'s doc
    /// comment for why tiers are now independently adjustable rather than
    /// ratio-locked.
    ///
    /// Clamped to 5...60s, not a larger number: `effectiveInterval(for:)`
    /// unconditionally caps every tier's *effective* interval at
    /// `maxInterval` (60s, plan §8.4's own `return min(i, 60)` example) —
    /// that cap is applied after this base value, in both the
    /// throttling-enabled and throttling-disabled branches, with no
    /// per-tier exception. A wider clamp here (this method previously
    /// allowed up to 300s) would let the setter and any UI built on it
    /// advertise a range the coordinator silently truncates 5x smaller the
    /// moment a tick actually runs — exactly the kind of overclaim P5 exists
    /// to prevent. 60s is the true achievable ceiling for every tier alike.
    public func setSlowInterval(_ slow: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            self.slowInterval = min(max(slow, 5), Self.maxInterval)
        }
    }

    /// Read-only view of a tier's *base* interval (pre-adaptive-throttling),
    /// i.e. exactly what `setBaseInterval`/`setMediumInterval`/
    /// `setSlowInterval` last set (post-clamp). Exists mainly so tests can
    /// assert the clamping/independence behavior documented on those setters
    /// without depending on real timer firing or `effectiveInterval`'s
    /// power-state multipliers.
    public func currentBaseInterval(for tier: Tier) -> TimeInterval {
        queue.sync { baseInterval(for: tier) }
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

    /// The Mac's last-captured approximate location, pushed down by the
    /// composition root whenever `LocationService.lastLocation` changes —
    /// same "pushed from the main actor, not a provider closure" shape as
    /// `sleepAssertionState` immediately above, and for the identical
    /// reason: `LocationService` is `@MainActor`-isolated (it wraps
    /// `CLLocationManager`, whose delegate callbacks land there), and every
    /// provider closure here runs off a background queue in `tick(tier:)`.
    /// Unlike the polled collectors, a location fix genuinely doesn't change
    /// on every tick — it's captured on its own multi-minute cadence (see
    /// `LocationService`'s doc comment) — so pushing on change, not polling,
    /// is also the behaviorally correct model here, not just a concurrency
    /// workaround.
    ///
    /// Feeds `SystemSnapshot.location`, which is what `LocalSyncServer`
    /// broadcasts to the iPhone app alongside every other metric.
    public var location: MacLocation? {
        get { queue.sync { locationStorage } }
        set { queue.async { [weak self] in self?.locationStorage = newValue } }
    }
    private var locationStorage: MacLocation?

    /// Whether all AI agent access is currently paused, pushed down by the
    /// composition root — same "pushed from the main actor, not a provider
    /// closure" shape as `sleepAssertionState` above, and for an identical
    /// reason: `SettingsStore.settings` is read from the main actor (it's
    /// an `ObservableObject` driving SwiftUI), and every provider closure
    /// here runs off a background queue in `tick(tier:)`.
    ///
    /// Feeds `SystemSnapshot.agentAccessPaused`, which is what lets the
    /// Watch (`WatchRelaySnapshot.agentAccessPaused`) finally render a
    /// truthful resume control for the kill switch — see that field's doc
    /// comment.
    ///
    /// **This property is wired end-to-end and, as of this branch, never
    /// actually assigned — the same honest, deliberately-incomplete state
    /// `sleepAssertionState` was in before `AppDelegate` was taught to push
    /// it (`Sentry/App/AppDelegate.swift:591-595`,
    /// `powerControl.$state.sink { ... self?.coordinator.sleepAssertionState
    /// = state }`).** The composition root that would do the equivalent for
    /// this property — `SettingsStore`'s `$settings.sink { ...
    /// self?.coordinator.agentAccessPaused = $0.agentGuardrails
    /// .killSwitchEngaged }`, wired next to `applySettings(_:)` — lives in
    /// `Sentry/App/AppDelegate.swift`, which is owned by other agents
    /// working in parallel on this codebase and is explicitly off-limits to
    /// this branch. Until that one-line hook lands, `SystemSnapshot
    /// .agentAccessPaused` stays `nil` for every real Mac, and every
    /// consumer down the chain (the phone's relay, the watch's button,
    /// `GetAgentGuardrailsStatusIntent`) already renders that `nil` as "not
    /// reported" rather than guessing — so nothing downstream lies while
    /// this one line is outstanding.
    public var agentAccessPaused: Bool? {
        get { queue.sync { agentAccessPausedStorage } }
        set { queue.async { [weak self] in self?.agentAccessPausedStorage = newValue } }
    }
    private var agentAccessPausedStorage: Bool?

    /// The most recently computed `ProtectionScore.overall`, pushed down by
    /// the composition root whenever `InsightsViewModel` finishes a
    /// `refresh()` — same shape as `agentAccessPaused` immediately above,
    /// for the same "assign, don't poll" reason `sleepAssertionState`
    /// documents, plus a second one specific to this value: recomputing a
    /// protection score is expensive (`InsightsViewModel`'s own doc comment
    /// — "a security-posture sweep plus fifteen `HistoryStore` reads plus
    /// forty-odd rule evaluations") and deliberately never runs on a timer,
    /// so there is no "current" score to poll for even if this were a
    /// provider closure like the collectors above.
    ///
    /// Feeds `SystemSnapshot.protectionScore`. See that field's doc comment
    /// for why a stale score riding along on the ordinary snapshot cadence
    /// is the correct trade here, not a shortcut.
    ///
    /// **Also wired end-to-end and, as of this branch, never assigned —
    /// same reason as `agentAccessPaused` above.** The composition-root
    /// hook this needs is one line in `InsightsViewModel.apply(_:)`
    /// (`Sentry/Insights/InsightsViewModel.swift`, where `report` is
    /// published) or in whatever observes it from `AppDelegate` —
    /// `coordinator.protectionScore = report.score.overall` — and `AppDelegate`
    /// is off-limits to this branch for the same reason described above.
    public var protectionScore: Int? {
        get { queue.sync { protectionScoreStorage } }
        set { queue.async { [weak self] in self?.protectionScoreStorage = newValue } }
    }
    private var protectionScoreStorage: Int?

    /// A Mac-wide rollup of `AgentSessionRegistry`'s active sessions, pushed
    /// down by the composition root — same "assign, don't poll" shape as
    /// `agentAccessPaused`/`protectionScore` immediately above, and for the
    /// identical actor-mismatch reason: `AgentSessionRegistry` is
    /// `@MainActor`-isolated (owned by `MCPXPCService`), while every provider
    /// closure `tick(tier:)` calls runs off this coordinator's background
    /// queue.
    ///
    /// Feeds `SystemSnapshot.agentActivitySummary`, which is what lets the
    /// Watch (`WatchRelaySnapshot.agentToolCallCount`/`.agentLastActivityAt`/
    /// `.agentRecentToolNames`) finally render real agent-activity numbers
    /// instead of the permanent "not reported" state those fields' doc
    /// comments describe.
    ///
    /// **Wired end-to-end and, as of this branch, never actually assigned —
    /// the same honest, deliberately-incomplete state `agentAccessPaused` and
    /// `protectionScore` are in above.** Unlike those two, the hook this
    /// property needs does not live in `AppDelegate` at all:
    /// `MCPXPCService` (`Sentry/App/MCPXPCService.swift`) already holds both
    /// `coordinator` and `sessionRegistry` as its own instance properties, and
    /// every MCP call already funnels through one method,
    /// `authorize(tool:clientName:argumentsSummary:)`, which already calls
    /// `sessionRegistry.recordCall(clientName:tool:)` right before it returns
    /// a decision (`Sentry/App/MCPXPCService.swift:143`). The one line this
    /// branch cannot add, immediately after that call:
    ///
    /// ```swift
    /// coordinator.agentActivitySummary = sessionRegistry.activitySummary()
    /// ```
    ///
    /// `MCPXPCService.swift` is explicitly read-only to this branch (owned by
    /// other agents working in parallel on this codebase), the same
    /// off-limits reasoning `agentAccessPaused`'s doc comment gives for
    /// `AppDelegate.swift` — so this is documented rather than applied. Until
    /// that one line lands, `SystemSnapshot.agentActivitySummary` stays `nil`
    /// for every real Mac, and every consumer down the chain already renders
    /// that `nil` as "not reported" (see `AgentActivityPage`'s `nil`-vs-`0`
    /// discipline) rather than guessing.
    public var agentActivitySummary: AgentActivitySummary? {
        get { queue.sync { agentActivitySummaryStorage } }
        set { queue.async { [weak self] in self?.agentActivitySummaryStorage = newValue } }
    }
    private var agentActivitySummaryStorage: AgentActivitySummary?

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

    private let queue = DispatchQueue(label: "dev.malekswilam.sentry.statscoordinator", qos: .utility)
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
        /// Only ever assigned from the `.process` tier's tick, and only when
        /// that tick actually produced a non-nil result — see
        /// `SystemSnapshot.topProcesses`'s doc comment for why every other
        /// tier's tick, and even a `.process` tick that itself yields nil,
        /// must leave this exactly as it was rather than clearing it.
        var topProcesses: [ProcessStats]?
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
    ///   - processProvider: optional; nil on a Mac/build where process
    ///     enumeration isn't wired up — see `processProvider`'s own doc
    ///     comment. Expected to close over one persistent `ProcessCollector`
    ///     instance, e.g. `{ processCollector.collectTopProcesses(limit: 20) }`,
    ///     same "one collector instance per provider" contract as every
    ///     other stateful provider here.
    ///   - fastInterval/mediumInterval/slowInterval: base tier intervals
    ///     before adaptive throttling (plan §8.4 defaults: 3s/5s/30s).
    ///   - processInterval: base interval for the `.process` tier (default
    ///     8s) — see that tier's doc comment above for why it's slower than
    ///     `.fast` but faster than `.slow`.
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
        processProvider: (() -> [ProcessStats]?)? = nil,
        fastInterval: TimeInterval = 3,
        mediumInterval: TimeInterval = 5,
        slowInterval: TimeInterval = 30,
        processInterval: TimeInterval = 8,
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
        self.processProvider = processProvider
        self.fastInterval = fastInterval
        self.mediumInterval = mediumInterval
        self.slowInterval = slowInterval
        self.processInterval = processInterval
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

    /// Synchronous point-in-time read of whatever this coordinator currently
    /// knows, without subscribing to the stream. Added for the MCP server
    /// (plan §13.3's `get_system_snapshot` and friends): `MCPXPCService`
    /// answers a request/response XPC call, not a long-lived stream
    /// consumer, so `snapshots()`'s `AsyncStream` — designed for a UI
    /// component that wants to keep observing — is the wrong shape for "give
    /// me the current values right now." `queue.sync` is safe here for the
    /// same reason every other synchronous accessor on this type
    /// (`currentBaseInterval`, `popoverIsClosed`'s getter) is: it's a quick
    /// read of already-computed state, never blocked on a provider call.
    /// Does *not* start polling on its own — if nothing has called
    /// `snapshots()` yet, this returns whatever `buildSnapshot()` produces
    /// from an all-nil `LatestSamples` (every field optional, so that's a
    /// valid, honestly-empty snapshot, not a crash).
    public func latestSnapshot() -> SystemSnapshot {
        queue.sync { buildSnapshot() }
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
        // Sample every tier once RIGHT NOW, then fall into cadence. The
        // timers' first deadlines are `now + interval`, which meant battery
        // (slow tier, 30s) didn't exist for the first half-minute of every
        // launch — the dropdown, Dashboard, and widget all opened looking
        // broken. Already on `queue` (the only caller hops here first), so
        // the synchronous ticks are safe and cost a few milliseconds once.
        for tier in [Tier.fast, .medium, .slow] {
            tick(tier: tier)
            scheduleTimer(for: tier)
        }
        // `.process` only starts its own timer when a provider is actually
        // wired in — see `processProvider`'s doc comment. Unlike the three
        // tiers above, a build/composition-root that hasn't wired process
        // enumeration in must not pay for a timer that would just tick a
        // provider closure that always returns nil.
        if processProvider != nil {
            tick(tier: .process)
            scheduleTimer(for: .process)
        }
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
        case .process: return processInterval
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
        case .process:
            guard let processProvider = self.processProvider else { return }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let processes = processProvider()
                self?.queue.async {
                    guard let self else { return }
                    // Only overwrite on an actual result — see
                    // `LatestSamples.topProcesses`'s doc comment. A nil
                    // result here (provider hiccup, or simply "hasn't run
                    // yet") must never clobber the last-known list, unlike
                    // every other tier's tick, which does overwrite on nil
                    // (nil there legitimately means "this Mac doesn't have
                    // this capability," not "temporarily unavailable").
                    if let processes {
                        self.latest.topProcesses = processes
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
            sleepAssertion: sleepAssertionStateStorage,
            location: locationStorage,
            agentAccessPaused: agentAccessPausedStorage,
            protectionScore: protectionScoreStorage,
            topProcesses: latest.topProcesses,
            agentActivitySummary: agentActivitySummaryStorage
        )
    }
}
#endif
