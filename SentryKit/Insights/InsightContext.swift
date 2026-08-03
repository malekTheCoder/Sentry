import Foundation

/// The slice of `AppSettings` that Protection Insights rules are allowed to
/// read.
///
/// A projection rather than the whole `AppSettings` value, for two reasons.
/// First, it keeps the rules honest about their inputs — a rule can't
/// quietly start depending on the user's theme. Second, `AppSettings`
/// carries `[AlertRule]`, which is a large value to copy into a context
/// that gets rebuilt on every refresh.
public struct InsightSettingsSnapshot: Sendable, Equatable {

    /// `AppSettings.mcpRemoteAccessEnabled` — the one Sentry setting that
    /// genuinely changes this Mac's network posture (see that property's doc
    /// comment), and therefore the one this feature has any business
    /// commenting on.
    public var mcpRemoteAccessEnabled: Bool
    public var mcpRemotePort: Int

    /// `AppSettings.mcpWriteToolsEnabled` — whether an AI agent can change
    /// power state, not merely read stats.
    public var mcpWriteToolsEnabled: Bool

    public var locationLogEnabled: Bool

    /// `AppSettings.rawRetentionHours` / `hourlyRetentionDays`. Used only by
    /// the "not enough history yet" honesty path, so it can say *why* a
    /// window is short when the reason is a retention setting rather than a
    /// young install.
    public var rawRetentionHours: Int
    public var hourlyRetentionDays: Int

    public init(
        mcpRemoteAccessEnabled: Bool = false,
        mcpRemotePort: Int = 8642,
        mcpWriteToolsEnabled: Bool = false,
        locationLogEnabled: Bool = false,
        rawRetentionHours: Int = 48,
        hourlyRetentionDays: Int = 90
    ) {
        self.mcpRemoteAccessEnabled = mcpRemoteAccessEnabled
        self.mcpRemotePort = mcpRemotePort
        self.mcpWriteToolsEnabled = mcpWriteToolsEnabled
        self.locationLogEnabled = locationLogEnabled
        self.rawRetentionHours = rawRetentionHours
        self.hourlyRetentionDays = hourlyRetentionDays
    }

    public init(_ settings: AppSettings) {
        self.init(
            mcpRemoteAccessEnabled: settings.mcpRemoteAccessEnabled,
            mcpRemotePort: settings.mcpRemotePort,
            mcpWriteToolsEnabled: settings.mcpWriteToolsEnabled,
            locationLogEnabled: settings.locationLogEnabled,
            rawRetentionHours: settings.rawRetentionHours,
            hourlyRetentionDays: settings.hourlyRetentionDays
        )
    }
}

/// Everything a `ProtectionInsightRule` may read, and nothing it may not.
///
/// **All of it is a value.** No store, no service, no closure that could
/// reach back out to disk — so `ProtectionInsightsEngine.evaluate(_:)` is a
/// pure function, every rule is testable by constructing a literal, and the
/// whole evaluation can run off the main actor without anything being
/// `@MainActor`-isolated. `InsightContextBuilder` is the one place that does
/// I/O, and it produces exactly this.
///
/// **Every history field is optional.** A fresh install has no history at
/// all; a Mac without a fan sensor has no thermal series; an iMac has no
/// battery. Rules that need a summary that isn't there return `nil` and say
/// nothing, which is the correct behaviour — the UI's "needs N more days of
/// history" state comes from `historyCoverageDays`, not from rules inventing
/// findings out of thin data.
public struct InsightContext: Sendable {

    /// The moment the evaluation is for. Injected so tests are deterministic
    /// and so every "N days ago" string in one report agrees with the others.
    public var now: Date

    /// The most recent live snapshot. `nil` before the first tick reaches
    /// the view model.
    public var snapshot: SystemSnapshot?

    public var device: DeviceFacts

    /// Never `nil` — a posture that couldn't be collected is
    /// `SecurityPosture.unknownPosture()`, which is a different and more
    /// honest thing than absence. See `PostureState`'s doc comment.
    public var posture: SecurityPosture

    public var battery: BatteryHistorySummary?
    public var thermal: ThermalHistorySummary?
    public var load: LoadHistorySummary?
    public var memory: MemoryHistorySummary?
    public var storage: StorageHistorySummary?
    public var powerHabits: PowerHabitsSummary?

    public var settings: InsightSettingsSnapshot

    /// The window the builder asked `HistoryStore` for, in days.
    public var requestedWindowDays: Int

    /// How many distinct calendar days of data actually came back — the
    /// number the UI's "needs N more days" copy is computed from, and the
    /// number every rule's `confidence` scales with. Distinct from
    /// `requestedWindowDays`: asking for 30 days on a 4-day-old install
    /// yields 4.
    public var historyCoverageDays: Int

    /// Below this, the hardware rules stay silent rather than extrapolating
    /// from a long weekend. Mirrors `AnomalyDetector.minimumBaselineDays`'s
    /// reasoning (a baseline a couple of days old is mostly noise) but sits
    /// higher, because these rules make stronger claims than "this is
    /// unusual" — they make claims about wear that accumulates over months.
    public static let minimumHistoryDays = 5

    /// Full confidence needs a full window of this many days; below it,
    /// `confidenceForCoverage` scales down linearly.
    public static let fullConfidenceDays = 21

    public var hasEnoughHistory: Bool { historyCoverageDays >= Self.minimumHistoryDays }

    /// How many more days of history the hardware rules need before they'll
    /// speak. `0` once there are enough.
    public var additionalDaysNeeded: Int {
        Swift.max(0, Self.minimumHistoryDays - historyCoverageDays)
    }

    /// A rule's confidence given how much history backed it: 0 below the
    /// minimum, ramping linearly to 1.0 at `fullConfidenceDays`.
    ///
    /// This is why a finding from 6 days doesn't sort above one from 30 at
    /// the same severity — and why the UI can honestly say "based on 6 days"
    /// instead of presenting both as equally settled.
    public var confidenceForCoverage: Double {
        guard historyCoverageDays >= Self.minimumHistoryDays else { return 0 }
        let span = Double(Self.fullConfidenceDays - Self.minimumHistoryDays)
        guard span > 0 else { return 1 }
        let progress = Double(historyCoverageDays - Self.minimumHistoryDays) / span
        return Swift.min(1, Swift.max(0, progress)) * 0.5 + 0.5
    }

    public init(
        now: Date = Date(),
        snapshot: SystemSnapshot? = nil,
        device: DeviceFacts = DeviceFacts(),
        posture: SecurityPosture = .unknownPosture(),
        battery: BatteryHistorySummary? = nil,
        thermal: ThermalHistorySummary? = nil,
        load: LoadHistorySummary? = nil,
        memory: MemoryHistorySummary? = nil,
        storage: StorageHistorySummary? = nil,
        powerHabits: PowerHabitsSummary? = nil,
        settings: InsightSettingsSnapshot = InsightSettingsSnapshot(),
        requestedWindowDays: Int = 30,
        historyCoverageDays: Int = 0
    ) {
        self.now = now
        self.snapshot = snapshot
        self.device = device
        self.posture = posture
        self.battery = battery
        self.thermal = thermal
        self.load = load
        self.memory = memory
        self.storage = storage
        self.powerHabits = powerHabits
        self.settings = settings
        self.requestedWindowDays = requestedWindowDays
        self.historyCoverageDays = historyCoverageDays
    }
}
