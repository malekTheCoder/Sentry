import Foundation

/// The Codable root of everything the user can configure (plan §4.2), persisted
/// as a single `settings.json` by `SettingsStore`. Defaults match the plan's
/// Appendix B table exactly.
///
/// **Why every property has a default:** `SettingsStore` decodes with a manual
/// `init(from:)` that treats *every* key as optional, so a settings file written
/// by an older build (missing keys added later) still decodes rather than
/// throwing and resetting the user's entire configuration. The defaults below
/// are the single source of truth for that fallback — see `schemaVersion`.
public struct AppSettings: Codable, Equatable, Sendable {

    // MARK: - Appearance

    /// References a `Theme` by `Theme.id` rather than embedding the whole value:
    /// switching presets is then a cheap id swap, and user-authored themes can
    /// live in their own store later without bloating this file.
    public var themeID: String

    /// Which metric modules are surfaced in the UI.
    public var enabledModules: Set<MetricModule>

    /// The user's composed menu bar (plan §8.2). Defaults to the Battery Focus
    /// preset per Appendix B.
    public var menuBarLayout: MenuBarLayout

    // MARK: - Lifecycle

    public var launchAtLogin: Bool

    // MARK: - Sampling (plan §8.4)

    /// Seconds between "fast class" samples. Plan §8.4 exposes this as a
    /// 0.5…30 s slider; no clamping happens here because a data model shouldn't
    /// silently rewrite what the user typed — the settings pane owns validation.
    public var globalRefreshInterval: TimeInterval

    /// Master switch for §8.4's multipliers (on battery, popover closed, low
    /// power mode, display asleep). Off means `globalRefreshInterval` is used
    /// verbatim, which is what a user staring at a benchmark wants.
    public var adaptiveThrottlingEnabled: Bool

    // MARK: - Retention (plan §6.3)

    /// `sample_raw` window. Daily rollups are kept forever, so there is
    /// deliberately no daily-retention setting.
    public var rawRetentionHours: Int
    public var hourlyRetentionDays: Int

    // MARK: - Alerts

    public var notificationRateCapPerHour: Int
    public var alertCooldownMinutes: Int

    // MARK: - Sync

    public var cloudKitSyncEnabled: Bool

    // MARK: - MCP (plan §13)

    public var mcpServerEnabled: Bool
    /// Separate from `mcpServerEnabled` on purpose: read-only tooling is a much
    /// smaller trust decision than letting an agent change power state.
    public var mcpWriteToolsEnabled: Bool

    // MARK: - Updates

    public var updateCheckDaily: Bool

    // MARK: - Versioning

    /// Bumped whenever a stored field changes meaning (not merely when one is
    /// added — additions are already tolerated by the decoder). Present from day
    /// one so a future migration has something to branch on instead of guessing.
    public var schemaVersion: Int

    /// Modules shown out of the box: the metrics every Mac can report, and the
    /// ones plan §3 calls the app's reason for existing.
    public static let defaultEnabledModules: Set<MetricModule> = [
        .battery, .cpu, .memory, .gpu,
    ]

    public static let currentSchemaVersion: Int = 1

    public init(
        themeID: String = Theme.terminal.id,
        enabledModules: Set<MetricModule> = AppSettings.defaultEnabledModules,
        menuBarLayout: MenuBarLayout = .batteryFocus,
        launchAtLogin: Bool = false,
        globalRefreshInterval: TimeInterval = 3,
        adaptiveThrottlingEnabled: Bool = true,
        rawRetentionHours: Int = 48,
        hourlyRetentionDays: Int = 90,
        notificationRateCapPerHour: Int = 6,
        alertCooldownMinutes: Int = 30,
        cloudKitSyncEnabled: Bool = false,
        mcpServerEnabled: Bool = false,
        mcpWriteToolsEnabled: Bool = false,
        updateCheckDaily: Bool = true,
        schemaVersion: Int = AppSettings.currentSchemaVersion
    ) {
        self.themeID = themeID
        self.enabledModules = enabledModules
        self.menuBarLayout = menuBarLayout
        self.launchAtLogin = launchAtLogin
        self.globalRefreshInterval = globalRefreshInterval
        self.adaptiveThrottlingEnabled = adaptiveThrottlingEnabled
        self.rawRetentionHours = rawRetentionHours
        self.hourlyRetentionDays = hourlyRetentionDays
        self.notificationRateCapPerHour = notificationRateCapPerHour
        self.alertCooldownMinutes = alertCooldownMinutes
        self.cloudKitSyncEnabled = cloudKitSyncEnabled
        self.mcpServerEnabled = mcpServerEnabled
        self.mcpWriteToolsEnabled = mcpWriteToolsEnabled
        self.updateCheckDaily = updateCheckDaily
        self.schemaVersion = schemaVersion
    }

    /// Appendix B, verbatim.
    public static let `default` = AppSettings()
}

// MARK: - Forward-compatible decoding

extension AppSettings {

    private enum CodingKeys: String, CodingKey {
        case themeID
        case enabledModules
        case menuBarLayout
        case launchAtLogin
        case globalRefreshInterval
        case adaptiveThrottlingEnabled
        case rawRetentionHours
        case hourlyRetentionDays
        case notificationRateCapPerHour
        case alertCooldownMinutes
        case cloudKitSyncEnabled
        case mcpServerEnabled
        case mcpWriteToolsEnabled
        case updateCheckDaily
        case schemaVersion
    }

    /// Hand-written because Swift's synthesized `init(from:)` **ignores** property
    /// default values and throws `keyNotFound` for any missing key. That would
    /// make every new field a breaking change for existing installs — the exact
    /// thing `schemaVersion` promises not to be. `decodeIfPresent ?? default`
    /// for every field is what actually keeps that promise.
    ///
    /// Note this is only additive-tolerant. A field whose *type* or *meaning*
    /// changes still needs a real migration keyed off `schemaVersion`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings()

        // A present-but-wrong-typed value (hand-edited JSON) throws here rather
        // than being silently coerced; SettingsStore catches that and falls back
        // to defaults wholesale, which is the honest outcome for a corrupt file.
        self.init(
            themeID: try container.decodeIfPresent(String.self, forKey: .themeID)
                ?? fallback.themeID,
            enabledModules: try container.decodeIfPresent(Set<MetricModule>.self, forKey: .enabledModules)
                ?? fallback.enabledModules,
            menuBarLayout: try container.decodeIfPresent(MenuBarLayout.self, forKey: .menuBarLayout)
                ?? fallback.menuBarLayout,
            launchAtLogin: try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
                ?? fallback.launchAtLogin,
            globalRefreshInterval: try container.decodeIfPresent(TimeInterval.self, forKey: .globalRefreshInterval)
                ?? fallback.globalRefreshInterval,
            adaptiveThrottlingEnabled: try container.decodeIfPresent(Bool.self, forKey: .adaptiveThrottlingEnabled)
                ?? fallback.adaptiveThrottlingEnabled,
            rawRetentionHours: try container.decodeIfPresent(Int.self, forKey: .rawRetentionHours)
                ?? fallback.rawRetentionHours,
            hourlyRetentionDays: try container.decodeIfPresent(Int.self, forKey: .hourlyRetentionDays)
                ?? fallback.hourlyRetentionDays,
            notificationRateCapPerHour: try container.decodeIfPresent(Int.self, forKey: .notificationRateCapPerHour)
                ?? fallback.notificationRateCapPerHour,
            alertCooldownMinutes: try container.decodeIfPresent(Int.self, forKey: .alertCooldownMinutes)
                ?? fallback.alertCooldownMinutes,
            cloudKitSyncEnabled: try container.decodeIfPresent(Bool.self, forKey: .cloudKitSyncEnabled)
                ?? fallback.cloudKitSyncEnabled,
            mcpServerEnabled: try container.decodeIfPresent(Bool.self, forKey: .mcpServerEnabled)
                ?? fallback.mcpServerEnabled,
            mcpWriteToolsEnabled: try container.decodeIfPresent(Bool.self, forKey: .mcpWriteToolsEnabled)
                ?? fallback.mcpWriteToolsEnabled,
            updateCheckDaily: try container.decodeIfPresent(Bool.self, forKey: .updateCheckDaily)
                ?? fallback.updateCheckDaily,
            // An absent version means a file written before versioning existed;
            // treat it as v1 rather than as "unknown".
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? fallback.schemaVersion
        )
    }
}
