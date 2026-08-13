import Foundation

/// The canonical payload that flows through the whole system — UI, storage,
/// device sync, and MCP. Every sub-struct is optional so a Mac missing a
/// capability produces a valid, smaller snapshot rather than fake zeros.
public struct SystemSnapshot: Codable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let deviceID: String
    public let schemaVersion: Int

    public var battery: BatteryStats?
    public var cpu: CPUStats?
    public var gpu: GPUStats?
    public var ane: ANEStats?
    public var memory: MemoryStats?
    public var disk: DiskStats?
    public var network: NetworkStats?
    public var thermal: ThermalStats?
    public var sleepAssertion: SleepAssertionState?

    /// Whether all AI agent access is currently paused — mirrors
    /// `AppSettings.agentGuardrails.killSwitchEngaged`
    /// (`SentryKit/Services/AgentGuardrails.swift`), pushed in the same
    /// "composition root assigns `StatsCoordinator`'s property whenever the
    /// source changes" style as `sleepAssertion` above (see
    /// `StatsCoordinator.agentAccessPaused`'s doc comment for the one-line
    /// hook this still needs at the composition root, and for why this
    /// branch does not add it itself).
    ///
    /// `nil` means "this Mac hasn't reported a pause state" — either
    /// because that hook isn't wired yet, or (once it is) because the very
    /// first snapshot of a run predates the settings store's first read.
    /// Never defaulted to `false`: a consumer as far away as the Watch
    /// (`WatchRelaySnapshot.agentAccessPaused`) renders a resume *button*
    /// off this value, and a fabricated "not paused" would draw a control
    /// that could be wrong about whether the Mac is currently declining
    /// every agent tool call.
    public var agentAccessPaused: Bool?

    /// The colours of whichever `Theme` the Mac is currently rendering,
    /// already resolved for its appearance.
    ///
    /// Rides along for the Watch's benefit, on the same "app state, not a
    /// metric" precedent as `agentAccessPaused` directly above. It is what
    /// lets the wrist render a theme the user *forked or imported on this
    /// Mac* — `AppSettings.customThemes` exists nowhere else, so an id would
    /// resolve to nothing downstream. See `RelayedPalette`.
    ///
    /// `nil` means the composition root has not pushed one (or this Mac
    /// predates the field), and the phone falls back to relaying its own
    /// theme rather than guessing.
    public var themePalette: RelayedPalette?

    /// The most recent `ProtectionScore.value` this Mac has computed
    /// (`SentryKit/Insights/ProtectionScore.swift`), 0...100.
    ///
    /// **Deliberately not kept current the way `battery`/`cpu`/`thermal`
    /// are.** A protection score comes out of `ProtectionInsightsEngine
    /// .evaluate(_:)`, which `InsightsViewModel`'s own doc comment describes
    /// as "a security-posture sweep plus fifteen `HistoryStore` reads plus
    /// forty-odd rule evaluations" — expensive by design, and deliberately
    /// run only when the Insights tab is opened or explicitly refreshed,
    /// never on a timer (see that type's "Nothing is left running" note).
    /// `SystemSnapshot` is rebuilt on every collector tick
    /// (`StatsCoordinator.buildSnapshot()`), so this field is filled from
    /// whatever score was last computed — possibly minutes or hours old —
    /// rather than one computed fresh for this snapshot. That is the
    /// correct trade for a field that rides along on an existing message
    /// instead of justifying a new one, not an oversight; a client that
    /// cares how old the number is has `SystemSnapshot.timestamp` (or,
    /// better, should not rely on this field to mean "right now").
    ///
    /// `nil` when no score has been computed yet this run (Insights tab
    /// never opened) or the composition-root hook described on
    /// `StatsCoordinator.protectionScore` isn't wired. Not `0` — a score of
    /// zero is a real, alarming claim ("everything checked failed"), and an
    /// absent reading must not be spelled the same way.
    public var protectionScore: Int?

    /// The busiest processes on the Mac by CPU, as of the last time
    /// `StatsCoordinator` ran its (deliberately slower, separate) process
    /// tier — see that type's doc comment for the cadence and why process
    /// enumeration doesn't ride along with the fast/medium/slow tiers every
    /// other field here does. This is what lets `AlertEngine` build a rule
    /// against "process X is pegging CPU/memory" (`SentryKit/Services/AlertRule.swift`'s
    /// `processNameMatch`) without `AlertEngine` reaching into the Dashboard
    /// layer, which already owns its own independent, UI-driven collection
    /// of the same underlying data (`Sentry/Dashboard/ProcessMonitor.swift`,
    /// `SystemMetricsKit/Collectors/ProcessCollector.swift`) for the "Top
    /// Processes" card.
    ///
    /// **Honest-nil, with a twist versus every other field on this type.**
    /// `nil` here means "no process tier has ticked yet this session" (e.g.
    /// the composition root never wired a process provider in, or the app
    /// only just launched) — the same "not yet measured" meaning every other
    /// optional field on `SystemSnapshot` already carries. The twist:
    /// once non-nil, this field is **not** reset to nil between process-tier
    /// ticks the way, say, `battery` conceptually could be if its provider
    /// ever returned nil — `StatsCoordinator` deliberately leaves the
    /// previous value in place on every *other* tier's tick (and even on a
    /// process tick that itself produced no data), so a rule referencing a
    /// named process always sees the last-known ranked list rather than
    /// flickering to "unavailable" between the (comparatively rare)
    /// full re-enumerations. A caller that wants to know how fresh this
    /// specific slice is has nothing to check it against on this type alone
    /// (there is no per-field timestamp) — same limitation `timestamp`
    /// already has for every other field, just more visible here because
    /// this field updates far less often than the rest.
    ///
    /// Ranked by CPU percent, top-N only (not every running process) — see
    /// `ProcessCollector.collect(limit:matching:now:)`'s doc comment for why
    /// a full enumeration's *result* still can't be a database row per
    /// process. A rule matching a process that never cracks the top-N (e.g.
    /// a memory hog that stays CPU-quiet) will not find it here — documented
    /// as a known limitation on `AlertRule.processNameMatch` rather than
    /// silently guessed around.
    public var topProcesses: [ProcessStats]?

    /// A Mac-wide rollup of what `AgentSessionRegistry`
    /// (`SentryKit/Services/AgentSessionRegistry.swift`) is currently
    /// tracking — how many tool calls, from whom, and when — computed across
    /// every active session, not just one. This is what finally lets
    /// `WatchRelaySnapshot.agentToolCallCount`/`.agentLastActivityAt`/
    /// `.agentRecentToolNames` (`SentryKit/Watch/WatchRelaySnapshot.swift`)
    /// carry a real reading instead of the permanent `nil` their doc comment
    /// describes: this field is the piece of `SystemSnapshot` that was
    /// missing to close that gap.
    ///
    /// **Pushed in, not computed here — same "composition root assigns
    /// `StatsCoordinator`'s property whenever the source changes" shape as
    /// `agentAccessPaused` and `protectionScore` above.** `AgentSessionRegistry`
    /// is `@MainActor`-isolated and owned by `MCPXPCService`
    /// (`Sentry/App/MCPXPCService.swift`), while `StatsCoordinator.buildSnapshot()`
    /// runs off a background queue — the same actor/queue mismatch those two
    /// fields' doc comments describe, solved the same way: whoever observes
    /// the registry assigns `StatsCoordinator.agentActivitySummary` on the
    /// main actor, and the coordinator just reads back whatever was last
    /// assigned when it builds a snapshot. See `StatsCoordinator
    /// .agentActivitySummary`'s doc comment for the one-line composition-root
    /// hook this still needs — not added by this branch, for the identical
    /// reason `agentAccessPaused`'s hook wasn't: it lives in
    /// `Sentry/App/AppDelegate.swift`, off-limits here.
    ///
    /// `nil` means "not measured this run" — the same honest-nil convention
    /// `agentAccessPaused` establishes immediately above (predates the hook,
    /// or the hook hasn't fired yet because no MCP call has landed since
    /// launch). Never a fabricated zero-valued summary: a Mac that has not
    /// wired the hook yet must not claim "no agent activity" any more than
    /// `protectionScore` may claim "0" for a score never computed.
    public var agentActivitySummary: AgentActivitySummary?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        deviceID: String,
        schemaVersion: Int = 1,
        battery: BatteryStats? = nil,
        cpu: CPUStats? = nil,
        gpu: GPUStats? = nil,
        ane: ANEStats? = nil,
        memory: MemoryStats? = nil,
        disk: DiskStats? = nil,
        network: NetworkStats? = nil,
        thermal: ThermalStats? = nil,
        sleepAssertion: SleepAssertionState? = nil,
        agentAccessPaused: Bool? = nil,
        themePalette: RelayedPalette? = nil,
        protectionScore: Int? = nil,
        topProcesses: [ProcessStats]? = nil,
        agentActivitySummary: AgentActivitySummary? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.deviceID = deviceID
        self.schemaVersion = schemaVersion
        self.battery = battery
        self.cpu = cpu
        self.gpu = gpu
        self.ane = ane
        self.memory = memory
        self.disk = disk
        self.network = network
        self.thermal = thermal
        self.sleepAssertion = sleepAssertion
        self.agentAccessPaused = agentAccessPaused
        self.themePalette = themePalette
        self.protectionScore = protectionScore
        self.topProcesses = topProcesses
        self.agentActivitySummary = agentActivitySummary
    }
}

/// A Mac-wide aggregate over every session `AgentSessionRegistry` currently
/// considers active — see `SystemSnapshot.agentActivitySummary`'s doc
/// comment for why this rides along on the snapshot rather than being
/// queried directly, and `AgentSessionRegistry.activeSessions(asOf:)` for
/// what "active" means (pruned lazily, `staleAfter`-windowed).
///
/// **Genuinely Mac-wide, not one session's view.** The Watch page this feeds
/// (`SentryWatch/Pages/AgentActivityPage.swift`) asks "has anything talked to
/// my Mac," not "what is client X doing" — the same framing
/// `AgentSessionRegistry`'s own doc comment uses for `otherActiveSessions`
/// existing beside `activeSessions`. A summary scoped to one arbitrarily
/// chosen session would silently under-report the moment a second agent
/// connects, which is exactly the scenario (two agents active at once) this
/// registry exists to make visible.
public struct AgentActivitySummary: Codable, Sendable, Equatable {
    /// Sum of every active session's tool-call activity, not a single
    /// session's count. `AgentSessionRegistry.Session` doesn't itself carry a
    /// per-session call count (only the deduplicated `recentTools` list), so
    /// this is populated by whoever builds the summary counting calls as they
    /// arrive — see `StatsCoordinator.agentActivitySummary`'s doc comment for
    /// where that counting happens. Monotonically non-decreasing within a
    /// run; never reset just because a session went stale, since "50 calls
    /// happened this session" stays true after the calling agent goes idle.
    public var toolCallCount: Int

    /// The latest `lastCallAt` across every active session — i.e. `max(over:
    /// activeSessions.map(\.lastCallAt))`. `nil` only when there are no
    /// active sessions to take a max over, which is the ordinary, healthy
    /// state for a Mac nobody's agent is currently using.
    public var lastActivityAt: Date?

    /// Tool names, most recent first, merged and deduplicated across every
    /// active session rather than one session's `recentTools` — two agents
    /// calling different tools at the same moment should both show up here,
    /// not just whichever session happened to be enumerated first. Capped at
    /// `AgentSessionRegistry.recentToolsLimit` for the same reason a single
    /// session's list is: this rides a size-constrained `WCSession` payload
    /// by the time it reaches the Watch
    /// (`WatchRelaySnapshot.agentRecentToolNames`'s doc comment).
    public var recentToolNames: [String]

    public init(toolCallCount: Int, lastActivityAt: Date?, recentToolNames: [String]) {
        self.toolCallCount = toolCallCount
        self.lastActivityAt = lastActivityAt
        self.recentToolNames = recentToolNames
    }
}
