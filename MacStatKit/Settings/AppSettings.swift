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

    /// Dashboard charts render simplified by default (no axes or gridlines —
    /// a stat sentence carries the numbers, per the redesign handoff). This
    /// opts back into the detailed rendering: gridlines, a y-axis, and
    /// intermediate time labels.
    public var detailedCharts: Bool

    // MARK: - Remote sync (off-LAN phone access)

    /// Opens `LocalSyncServer`'s second, TLS-PSK-secured listener on
    /// `remoteSyncPort` so the iPhone app can connect from outside the
    /// local network (via Tailscale/VPN or a router port-forward — the
    /// user's arrangement; Sentry only opens the port). Off by default:
    /// exposing a listener beyond the LAN is opt-in, always.
    public var remoteSyncEnabled: Bool

    /// TCP port for the remote listener. 8643 by default (one above the
    /// MCP remote port's 8642).
    public var remoteSyncPort: Int

    /// Pairing code the phone must present (as a TLS pre-shared key — see
    /// `SyncSecurity`). Empty until the user enables remote access for the
    /// first time; the Sync pane generates one then.
    public var remoteSyncPairingCode: String

    // MARK: - Dropdown content
    //
    // Which optional sections the menu bar dropdown shows. The vitals rows
    // themselves follow `enabledModules` (one switch for dropdown + Dashboard,
    // deliberately); these cover the sections that aren't per-module.

    /// Show the keep-awake controls section in the dropdown.
    public var dropdownShowsKeepAwake: Bool

    /// Show the transient "agent just did something" line under the headline.
    public var dropdownShowsAgentActivity: Bool

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

    /// Per-tool enable set (plan §13.4: "per-tool toggles, grouped read vs
    /// write, write tools default-off"). Stores `MCPToolID.rawValue`s rather
    /// than `[MCPToolID: Bool]` because `Dictionary` with a non-`String`/`Int`
    /// key round-trips through `Codable` as an array-of-pairs, which is a
    /// worse `settings.json` shape than a plain string set for something a
    /// user might hand-edit. Membership means "enabled" — a tool ID *absent*
    /// from this set (e.g. one added in a later build, present in
    /// `MCPToolID.allCases` but not yet in an existing settings file) is
    /// **not** implicitly enabled; see `init(from:)` below for how a missing
    /// key upgrades safely to "just the shipped defaults," and
    /// `MCPAccessController.evaluate` for why a tool absent from this set
    /// after that upgrade is authoritative denial, not a fallback guess.
    public var mcpEnabledToolIDs: Set<String>

    /// Plan §13.4: "'Require confirmation' checkbox per write tool → the app
    /// shows a native confirmation dialog before executing." Only write
    /// tools are meaningful members — `MCPAccessController.evaluate` only
    /// consults this set for `tool.isWrite`, so a read tool's ID present
    /// here (e.g. from a hand-edited file) is simply never checked, not an
    /// error.
    public var mcpConfirmationRequiredToolIDs: Set<String>

    /// Plan §13.4: "Rate limiting: max N tool calls/minute," enforced by
    /// `MCPAccessController.isRateLimited`. Applies across every tool
    /// combined (one shared window, not one per tool) — a client alternating
    /// between two allowed tools to dodge a per-tool cap would otherwise
    /// defeat the point of having a cap at all.
    public var mcpRateLimitPerMinute: Int

    /// Master switch for `MCPRemoteServer` (`MacStat/App/MCPRemoteServer.swift`)
    /// — an in-app HTTP transport reachable from other devices on the LAN,
    /// distinct from `mcpServerEnabled`'s local-only stdio `MacStatMCP`
    /// binary. Off by default: this is the one MCP-related switch that
    /// actually changes MacStat's network posture (see `AIAccessPane`'s
    /// "Privacy" section, which stops being an unconditional "zero network"
    /// claim once this is `true`), so it doesn't inherit `mcpServerEnabled`'s
    /// gate — a user who already turned on local MCP access hasn't thereby
    /// agreed to a LAN-reachable one.
    public var mcpRemoteAccessEnabled: Bool

    /// Port `MCPRemoteServer` binds on all interfaces when
    /// `mcpRemoteAccessEnabled` is on. No clamping here for the same
    /// no-clamp-at-the-model-layer convention as `globalRefreshInterval` —
    /// `MCPRemoteServer` owns validating this at bind time.
    public var mcpRemotePort: Int

    // MARK: - Location Log

    /// Master switch for `LocationService` (`MacStatKit/Services/LocationService.swift`)
    /// — the honest "Location Log" feature (never "Find My," see that type's
    /// doc comment). Off by default and, critically, **not** what actually
    /// requests macOS location permission: `AppDelegate` only calls
    /// `LocationService.requestAuthorization()` in direct response to this
    /// flipping to `true` from a user tapping the toggle in `LocationPane`,
    /// matching `AlertEngine`'s existing "request authorization lazily, on
    /// explicit user action, never at launch" convention (plan §11.3) for
    /// the same reason: a permission prompt a user didn't ask for, tied to a
    /// setting they didn't know existed, is the opposite of the explicit,
    /// user-initiated permission flow this feature requires.
    public var locationLogEnabled: Bool

    // MARK: - Protection Insights

    /// Per-insight dismissals and snoozes (see `InsightSuppression`).
    ///
    /// Lives here rather than in its own store for the same reason
    /// `alertRules` does: it is a small `Codable` value type, it belongs to
    /// the user rather than to a machine, and carrying it in the one file
    /// everything else round-trips through means a user who copies
    /// `settings.json` to a new Mac keeps their decisions with it.
    ///
    /// Unlike `alertRules`, an absent key here upgrades to `[]` — the
    /// shipped default genuinely is "nothing suppressed", so there is no
    /// missing-key-versus-explicitly-empty distinction to preserve.
    public var protectionInsightSuppressions: [InsightSuppression]

    /// The local developer/testing unlock for Pro features (see
    /// `ProEntitlementStore`). **Not a licence check**: it is a plain
    /// boolean in a user-editable JSON file, deliberately, because it is a
    /// testing affordance and not a purchase. Off by default, and the only
    /// thing that ever sets it is the explicit toggle in Settings ▸
    /// Advanced.
    public var proUnlockOverrideEnabled: Bool

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

    /// Plan §13.4: read tools ship enabled, write tools ship disabled. This
    /// is the single source `mcpEnabledToolIDs`'s default parameter and
    /// `init(from:)`'s upgrade fallback both read from — see
    /// `MCPToolID.enabledByDefault`'s doc comment for the underlying rule.
    public static let defaultMCPEnabledToolIDs: Set<String> = Set(
        MCPToolID.allCases.filter(\.enabledByDefault).map(\.rawValue)
    )

    public init(
        themeID: String = Theme.defaultTheme.id,
        enabledModules: Set<MetricModule> = AppSettings.defaultEnabledModules,
        menuBarLayout: MenuBarLayout = .batteryFocus,
        detailedCharts: Bool = false,
        remoteSyncEnabled: Bool = false,
        remoteSyncPort: Int = 8643,
        remoteSyncPairingCode: String = "",
        dropdownShowsKeepAwake: Bool = true,
        dropdownShowsAgentActivity: Bool = true,
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
        mcpEnabledToolIDs: Set<String> = AppSettings.defaultMCPEnabledToolIDs,
        mcpConfirmationRequiredToolIDs: Set<String> = [],
        mcpRateLimitPerMinute: Int = 20,
        mcpRemoteAccessEnabled: Bool = false,
        mcpRemotePort: Int = 8642,
        locationLogEnabled: Bool = false,
        protectionInsightSuppressions: [InsightSuppression] = [],
        proUnlockOverrideEnabled: Bool = false,
        updateCheckDaily: Bool = true,
        schemaVersion: Int = AppSettings.currentSchemaVersion
    ) {
        self.themeID = themeID
        self.enabledModules = enabledModules
        self.menuBarLayout = menuBarLayout
        self.detailedCharts = detailedCharts
        self.remoteSyncEnabled = remoteSyncEnabled
        self.remoteSyncPort = remoteSyncPort
        self.remoteSyncPairingCode = remoteSyncPairingCode
        self.dropdownShowsKeepAwake = dropdownShowsKeepAwake
        self.dropdownShowsAgentActivity = dropdownShowsAgentActivity
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
        self.mcpEnabledToolIDs = mcpEnabledToolIDs
        self.mcpConfirmationRequiredToolIDs = mcpConfirmationRequiredToolIDs
        self.mcpRateLimitPerMinute = mcpRateLimitPerMinute
        self.mcpRemoteAccessEnabled = mcpRemoteAccessEnabled
        self.mcpRemotePort = mcpRemotePort
        self.locationLogEnabled = locationLogEnabled
        self.protectionInsightSuppressions = protectionInsightSuppressions
        self.proUnlockOverrideEnabled = proUnlockOverrideEnabled
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
        case detailedCharts
        case remoteSyncEnabled
        case remoteSyncPort
        case remoteSyncPairingCode
        case dropdownShowsKeepAwake
        case dropdownShowsAgentActivity
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
        case mcpEnabledToolIDs
        case mcpConfirmationRequiredToolIDs
        case mcpRateLimitPerMinute
        case mcpRemoteAccessEnabled
        case mcpRemotePort
        // Additive, same decodeIfPresent ?? fallback contract as every other
        // field here — a settings file written before Location Log existed
        // must upgrade to `false` (off), never implicitly opt a pre-existing
        // install into a permission-gated feature it never asked for.
        case locationLogEnabled
        // Protection Insights, additive: absent in any settings.json written
        // before this feature existed, so both decode via the same
        // decodeIfPresent ?? fallback pattern as every other field.
        case protectionInsightSuppressions
        case proUnlockOverrideEnabled
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
            detailedCharts: try container.decodeIfPresent(Bool.self, forKey: .detailedCharts)
                ?? fallback.detailedCharts,
            remoteSyncEnabled: try container.decodeIfPresent(Bool.self, forKey: .remoteSyncEnabled)
                ?? fallback.remoteSyncEnabled,
            remoteSyncPort: try container.decodeIfPresent(Int.self, forKey: .remoteSyncPort)
                ?? fallback.remoteSyncPort,
            remoteSyncPairingCode: try container.decodeIfPresent(String.self, forKey: .remoteSyncPairingCode)
                ?? fallback.remoteSyncPairingCode,
            dropdownShowsKeepAwake: try container.decodeIfPresent(Bool.self, forKey: .dropdownShowsKeepAwake)
                ?? fallback.dropdownShowsKeepAwake,
            dropdownShowsAgentActivity: try container.decodeIfPresent(Bool.self, forKey: .dropdownShowsAgentActivity)
                ?? fallback.dropdownShowsAgentActivity,
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
            // Same "missing key upgrades to shipped defaults, explicit value
            // is honored verbatim" contract as `alertRules` above — a
            // settings file written before this key existed must upgrade
            // into "read tools on, write tools off," not into an empty set
            // that would silently disable every read tool too.
            mcpEnabledToolIDs: try container.decodeIfPresent(Set<String>.self, forKey: .mcpEnabledToolIDs)
                ?? fallback.mcpEnabledToolIDs,
            mcpConfirmationRequiredToolIDs: try container.decodeIfPresent(Set<String>.self, forKey: .mcpConfirmationRequiredToolIDs)
                ?? fallback.mcpConfirmationRequiredToolIDs,
            mcpRateLimitPerMinute: try container.decodeIfPresent(Int.self, forKey: .mcpRateLimitPerMinute)
                ?? fallback.mcpRateLimitPerMinute,
            mcpRemoteAccessEnabled: try container.decodeIfPresent(Bool.self, forKey: .mcpRemoteAccessEnabled)
                ?? fallback.mcpRemoteAccessEnabled,
            mcpRemotePort: try container.decodeIfPresent(Int.self, forKey: .mcpRemotePort)
                ?? fallback.mcpRemotePort,
            locationLogEnabled: try container.decodeIfPresent(Bool.self, forKey: .locationLogEnabled)
                ?? fallback.locationLogEnabled,
            // Unlike `alertRules`/`mcpEnabledToolIDs` above, "missing" and
            // "explicitly empty" mean the same thing here — the shipped
            // default is genuinely nothing suppressed — so there is no
            // upgrade distinction to preserve.
            protectionInsightSuppressions: try container.decodeIfPresent([InsightSuppression].self, forKey: .protectionInsightSuppressions)
                ?? fallback.protectionInsightSuppressions,
            // Must upgrade to `false`: a settings file written before Pro
            // gating existed has not been granted anything.
            proUnlockOverrideEnabled: try container.decodeIfPresent(Bool.self, forKey: .proUnlockOverrideEnabled)
                ?? fallback.proUnlockOverrideEnabled,
            updateCheckDaily: try container.decodeIfPresent(Bool.self, forKey: .updateCheckDaily)
                ?? fallback.updateCheckDaily,
            // An absent version means a file written before versioning existed;
            // treat it as v1 rather than as "unknown".
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? fallback.schemaVersion
        )
    }
}
