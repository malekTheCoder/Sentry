import Foundation

/// The canonical payload that flows through the whole system — UI, storage,
/// CloudKit, and MCP. Every sub-struct is optional so a Mac missing a
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

    /// The Mac's last-captured approximate location (plan §3.2 P5's honesty
    /// discipline applies here same as everywhere else — see
    /// `MacLocation`'s and `LocationService`'s doc comments). `nil` covers
    /// every one of: location permission not granted, the feature toggled
    /// off, or no fix captured yet — `SystemSnapshot`'s consumers can't tell
    /// those apart from this field alone, which is fine, since none of them
    /// change what the UI should show ("no known location," worded
    /// specifically, not a blank/fake map pin).
    public var location: MacLocation?

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
        location: MacLocation? = nil,
        agentAccessPaused: Bool? = nil,
        protectionScore: Int? = nil
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
        self.location = location
        self.agentAccessPaused = agentAccessPaused
        self.protectionScore = protectionScore
    }
}
