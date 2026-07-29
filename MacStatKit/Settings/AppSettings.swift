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

    // MARK: - Sampling: per-tier overrides (FR-2, additive)
    //
    // FR-2 asks for refresh interval "user-adjustable per module." The
    // underlying `StatsCoordinator` scheduler is tier-based (fast/medium/slow
    // timers, each carrying several collectors), not per-metric, so these two
    // fields expose per-*tier* control rather than true per-module control —
    // see `StatsCoordinator.setBaseInterval`'s doc comment for the full
    // reasoning. `globalRefreshInterval` above remains the fast tier's
    // interval (plan §8.4 default 3s); these two cover the other tiers, which
    // previously could only move by a fixed ratio of the fast interval.

    /// Seconds between "medium class" samples (ANE power, temperatures, fan
    /// RPM). Plan §8.4 default 5s. No clamping here for the same reason as
    /// `globalRefreshInterval` — the settings pane owns validation;
    /// `StatsCoordinator.setMediumInterval` clamps defensively for a
    /// hand-edited settings file.
    public var mediumTierRefreshInterval: TimeInterval

    /// Seconds between "slow class" samples (battery %, health, cycle count,
    /// capacity). Plan §8.4 default 30s. Same no-clamp-here convention as
    /// `mediumTierRefreshInterval`.
    public var slowTierRefreshInterval: TimeInterval

    // MARK: - Retention (plan §6.3)

    /// `sample_raw` window. Daily rollups are kept forever, so there is
    /// deliberately no daily-retention setting.
    public var rawRetentionHours: Int
    public var hourlyRetentionDays: Int

    // MARK: - Alerts

    public var notificationRateCapPerHour: Int
    public var alertCooldownMinutes: Int

    /// Plan §11.3's global "Do Not Disturb" master toggle: when `true`, no
    /// rule fires anything a user can perceive, full stop — a coarser mute
    /// than any per-rule `AlertRule.quietHours` window, and independent of
    /// them (a rule with no quiet hours of its own is still silenced while
    /// this is on). Lives here rather than on `AlertRule` because it's one
    /// setting for the whole engine, not a per-rule concern, matching
    /// `notificationRateCapPerHour`/`alertCooldownMinutes` immediately
    /// above. See `AlertEngine`'s doc comment for exactly where this sits in
    /// the firing pipeline and why a DND-suppressed firing is not written to
    /// `alert_log`.
    public var doNotDisturb: Bool

    /// The user's alert rules (plan §11.1/§11.2), edited in `AlertsPane` and
    /// handed to `AlertEngine.updateRules(_:)` by the composition root.
    ///
    /// **Why the whole rule set lives in settings rather than in its own
    /// store:** rules are small, plain `Codable` value types by deliberate
    /// design (see `AlertRule`'s doc comment — all engine runtime state is
    /// kept *off* the rule), so they cost nothing to carry in the same
    /// `settings.json` everything else already round-trips, and a user who
    /// copies that one file to a new Mac gets their alerts with it.
    ///
    /// **Empty is a legal, deliberate state — but not a fallback.** See
    /// `init(from:)` below: a settings file that *omits* this key (written by
    /// a build from before alert rules existed) decodes to the shipped
    /// defaults, whereas a file with an explicit `"alertRules": []` decodes
    /// to no rules. Those are different situations and must not collapse
    /// into one: the first is an upgrade, where silently ending up with zero
    /// alerts would be an invisible regression; the second is a user who
    /// removed every rule in `AlertsPane`, which that pane shows an explicit
    /// empty-state message for.
    public var alertRules: [AlertRule]

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

    /// Appendix B's alert cooldown default, hoisted into a named constant
    /// because `defaultAlertRules` below has to derive from the exact same
    /// number — `AlertRule`'s doc comment is explicit that a rule's cooldown
    /// should come from this setting rather than a literal baked in
    /// somewhere else, and two independent `30`s is precisely how that
    /// promise quietly breaks.
    public static let defaultAlertCooldownMinutes: Int = 30

    /// The 11 shipped rules from plan §11.2, built once.
    ///
    /// A `static let` rather than a computed property on purpose:
    /// `AlertEngine.defaultRules(cooldown:)` mints a fresh `UUID` for every
    /// non-special-cased rule on each call, so a computed version would make
    /// two `AppSettings()` values compare unequal for no user-visible reason
    /// — and `SettingsStore` writes to disk on exactly that inequality
    /// (`settings != oldValue`), which would turn every incidental
    /// re-assignment of defaults into a disk write with a churned rule set.
    public static let defaultAlertRules: [AlertRule] = AlertEngine.defaultRules(
        cooldown: TimeInterval(AppSettings.defaultAlertCooldownMinutes * 60)
    )

    public init(
        themeID: String = Theme.terminal.id,
        enabledModules: Set<MetricModule> = AppSettings.defaultEnabledModules,
        menuBarLayout: MenuBarLayout = .batteryFocus,
        launchAtLogin: Bool = false,
        globalRefreshInterval: TimeInterval = 3,
        adaptiveThrottlingEnabled: Bool = true,
        mediumTierRefreshInterval: TimeInterval = 5,
        slowTierRefreshInterval: TimeInterval = 30,
        rawRetentionHours: Int = 48,
        hourlyRetentionDays: Int = 90,
        notificationRateCapPerHour: Int = 6,
        alertCooldownMinutes: Int = AppSettings.defaultAlertCooldownMinutes,
        doNotDisturb: Bool = false,
        alertRules: [AlertRule] = AppSettings.defaultAlertRules,
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
        self.mediumTierRefreshInterval = mediumTierRefreshInterval
        self.slowTierRefreshInterval = slowTierRefreshInterval
        self.rawRetentionHours = rawRetentionHours
        self.hourlyRetentionDays = hourlyRetentionDays
        self.notificationRateCapPerHour = notificationRateCapPerHour
        self.alertCooldownMinutes = alertCooldownMinutes
        self.doNotDisturb = doNotDisturb
        self.alertRules = alertRules
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
        // FR-2, additive: absent in any settings.json written before this
        // pair existed, so both decode via the same decodeIfPresent ?? fallback
        // pattern as every other field below.
        case mediumTierRefreshInterval
        case slowTierRefreshInterval
        case rawRetentionHours
        case hourlyRetentionDays
        case notificationRateCapPerHour
        case alertCooldownMinutes
        case doNotDisturb
        case alertRules
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
            mediumTierRefreshInterval: try container.decodeIfPresent(TimeInterval.self, forKey: .mediumTierRefreshInterval)
                ?? fallback.mediumTierRefreshInterval,
            slowTierRefreshInterval: try container.decodeIfPresent(TimeInterval.self, forKey: .slowTierRefreshInterval)
                ?? fallback.slowTierRefreshInterval,
            rawRetentionHours: try container.decodeIfPresent(Int.self, forKey: .rawRetentionHours)
                ?? fallback.rawRetentionHours,
            hourlyRetentionDays: try container.decodeIfPresent(Int.self, forKey: .hourlyRetentionDays)
                ?? fallback.hourlyRetentionDays,
            notificationRateCapPerHour: try container.decodeIfPresent(Int.self, forKey: .notificationRateCapPerHour)
                ?? fallback.notificationRateCapPerHour,
            alertCooldownMinutes: try container.decodeIfPresent(Int.self, forKey: .alertCooldownMinutes)
                ?? fallback.alertCooldownMinutes,
            doNotDisturb: try container.decodeIfPresent(Bool.self, forKey: .doNotDisturb)
                ?? fallback.doNotDisturb,
            // Same `decodeIfPresent ?? fallback` shape as every other field,
            // and it matters more here than anywhere else: the fallback is
            // the shipped 11-rule default set, *not* `[]`. A file written by
            // a build from before this key existed must upgrade into working
            // alerts — decoding it into an empty list would leave the user
            // with no alerts and nothing on screen explaining why. An
            // explicitly-stored empty array still decodes as empty, because
            // that one really is a user who removed every rule.
            alertRules: try container.decodeIfPresent([AlertRule].self, forKey: .alertRules)
                ?? fallback.alertRules,
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
