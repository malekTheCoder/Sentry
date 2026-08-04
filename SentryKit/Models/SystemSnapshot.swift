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
        topProcesses: [ProcessStats]? = nil
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
        self.topProcesses = topProcesses
    }
}
