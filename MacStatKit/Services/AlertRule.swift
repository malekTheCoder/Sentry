import Foundation

/// One user-configurable (or shipped-default) alerting rule, evaluated by
/// `AlertEngine` against every `SystemSnapshot` the composition root feeds it
/// (plan §11.1). A rule is pure, `Codable`/`Equatable` data on purpose — all
/// the runtime state a rule needs to be evaluated correctly (per-rule
/// "sustained since" timestamps, last-fired dates, the in-memory baseline
/// `Comparison.changedBy` needs) lives on `AlertEngine` itself, not here, so
/// a rule stays trivially safe to persist in `SettingsStore` and to hand to
/// a future rule-editor UI without smuggling engine internals into the
/// user's settings file.
///
/// `AlertEngine.defaultRules(cooldown:)` builds the 11 rules from plan
/// §11.2. Two of those — identified by `AlertEngine.chargingPausedRuleID`
/// and `AlertEngine.slowChargingRuleID` — are special-cased by `AlertEngine`
/// at evaluation time (see those rules' shipped `metric`/`comparison`
/// wiring below and `AlertEngine`'s doc comment for why).
///
/// `Sendable` for the same reason every other persisted model in this module
/// (`MetricID`, `MenuBarLayout`, `AppSettings`) is: `AppSettings` stores
/// `[AlertRule]` and is itself `Sendable`, and `SettingsStore` hands a
/// settings snapshot across to its private IO queue to write. Without the
/// conformance that hop is a Swift 6 error and, today, a warning that would
/// sit in the build forever. Nothing here is reference-typed, so the
/// conformance is a statement of fact rather than a promise being made.
public struct AlertRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool

    /// Which live metric this rule reads via `SystemSnapshot.value(for:)`.
    /// For the two ID-special-cased rules (charging paused / slow charging)
    /// this is an informational placeholder — `AlertEngine` ignores it and
    /// reads the relevant `BatteryStats` fields directly instead, because
    /// neither condition reduces to a single metric-vs-threshold compare.
    public var metric: MetricID
    public var comparison: Comparison
    public var threshold: Double

    /// How long `comparison` must hold *continuously* before the rule fires.
    /// Resets to "not sustained" on any tick where the condition isn't true
    /// — the same flap-suppression semantics the plan already establishes
    /// for `PowerControlService.evaluate`'s `cpuAbovePercent` condition, so
    /// a metric bouncing across the threshold every other sample doesn't
    /// fire repeatedly.
    public var sustainedFor: TimeInterval

    /// Minimum gap between two firings of this same rule, independent of
    /// `sustainedFor` — e.g. a battery sitting at 15% for hours should not
    /// notify again every time `sustainedFor` re-elapses after a cooldown.
    /// Per this file's own guidance (echoed in `AlertEngine`'s doc comment),
    /// the *default* value used by `AlertEngine.defaultRules(cooldown:)`
    /// should come from `AppSettings.alertCooldownMinutes` at construction
    /// time — not a hardcoded literal baked into this struct — so changing
    /// the setting later takes effect the next time defaults are rebuilt.
    public var cooldown: TimeInterval

    public var quietHours: QuietHours?

    /// All preconditions must hold for the rule to be eligible to fire on a
    /// given snapshot (AND, not OR) — empty means "always eligible."
    public var onlyWhen: [Precondition]

    public var actions: [AlertAction]

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        metric: MetricID,
        comparison: Comparison,
        threshold: Double,
        sustainedFor: TimeInterval,
        cooldown: TimeInterval,
        quietHours: QuietHours? = nil,
        onlyWhen: [Precondition] = [],
        actions: [AlertAction]
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.metric = metric
        self.comparison = comparison
        self.threshold = threshold
        self.sustainedFor = sustainedFor
        self.cooldown = cooldown
        self.quietHours = quietHours
        self.onlyWhen = onlyWhen
        self.actions = actions
    }
}

extension AlertRule {
    public enum Comparison: Codable, Equatable, Sendable {
        /// `value >= threshold`. Inclusive rather than a strict `>`, so a
        /// single case can express both the plan's "≥" rules (charge limit
        /// reminder, fully charged) and its ">" rules (high temperature,
        /// sustained high CPU) without a fifth comparison case — at the
        /// sampling granularity this engine works at (seconds, not exact
        /// instants), the difference between "at 90.0% exactly" and
        /// "just above 90.0%" firing on the same tick isn't a
        /// correctness question worth doubling the enum's surface area
        /// over.
        case above
        /// `value <= threshold`. Same inclusive reasoning as `.above`.
        case below
        /// `abs(value - threshold) < 0.0001`, for the rare rule that wants
        /// an exact/near-exact match rather than a directional threshold.
        /// None of the 11 shipped default rules use this today.
        case equals

        /// "Changed by `threshold` since a baseline." Plan §11.2 defines
        /// this for "Battery health drop" as "vs 30-day baseline," which
        /// would mean querying `HistoryStore`'s `sample_daily` tier for a
        /// value from ~30 days ago. This pass deliberately does **not** do
        /// that — `AlertEngine` instead records the *first value it ever
        /// observes* for a `.changedBy` rule (in memory, lost on relaunch)
        /// and compares subsequent values against that baseline. That is
        /// honest-but-weaker than the plan's wording: a Mac that's been
        /// running for an hour will compare against "an hour ago," not 30
        /// days ago, and the baseline resets every relaunch rather than
        /// rolling. Implemented this way because building a real 30-day
        /// rolling baseline needs `HistoryStore` wired into `AlertEngine`
        /// as a read dependency (not just a write target for `alert_log`),
        /// plus a decision about what happens when 30 days of history
        /// don't exist yet (new install) — both real design questions
        /// deferred rather than guessed at here. TODO(later phase): back
        /// this with an actual `sample_daily` lookup once that's decided.
        case changedBy
    }

    /// A wall-clock quiet window, e.g. 23:00–08:00. `startHour == endHour`
    /// is treated as "no quiet window" (zero-width) rather than "24 hours
    /// of quiet" — an equal start/end is far more likely to be an
    /// unconfigured/default value than a deliberate all-day mute.
    public struct QuietHours: Codable, Equatable, Sendable {
        /// 0...23, inclusive start of the quiet window.
        public var startHour: Int
        /// 0...23, exclusive end of the quiet window. May be less than
        /// `startHour`, meaning the window wraps past midnight (e.g. 23–8).
        public var endHour: Int

        public init(startHour: Int, endHour: Int) {
            self.startHour = startHour
            self.endHour = endHour
        }

        /// - Parameter hour: 0...23, typically `Calendar.current.component(.hour, from: Date())`.
        public func contains(hour: Int) -> Bool {
            guard startHour != endHour else { return false }
            if startHour < endHour {
                return hour >= startHour && hour < endHour
            } else {
                // Wraps midnight: quiet from startHour through 23, and again
                // from 0 through endHour.
                return hour >= startHour || hour < endHour
            }
        }
    }

    public enum Precondition: Codable, Equatable, Sendable {
        /// True when the most recent snapshot's `BatteryStats.isCharging`
        /// is `false`. Deliberately keyed off `isCharging` rather than
        /// `isPluggedIn` — a Mac can be plugged into a low-power/data-only
        /// source and still be discharging, and "on battery" for alerting
        /// purposes means "actually drawing down," matching how
        /// `StatsCoordinator.isOnBattery` reasons about the same signal.
        /// `nil` battery (no snapshot yet, or a desktop Mac with no
        /// battery) fails this precondition rather than defaulting either
        /// way — an alert whose precondition can't be evaluated shouldn't
        /// fire.
        case onBattery
        /// True when `BatteryStats.isCharging` is `true`.
        case charging
        /// True when `BatteryStats.isPluggedIn` is `true`, regardless of
        /// whether current is actually flowing into the battery.
        ///
        /// Distinct from `charging` for a reason that is easy to get wrong:
        /// macOS stops reporting `isCharging` once the battery reaches
        /// 100%, so a rule about a *full* battery gated on `charging` can
        /// never fire — the two conditions are never simultaneously true.
        /// It's also the honest precondition for "plugged in but not taking
        /// charge" situations (thermal pause, Optimized Battery Charging,
        /// a low-power/data-only source). `nil` battery fails it, same as
        /// the other cases.
        case pluggedIn
        /// Always evaluates `false` — there is no display-sleep signal
        /// anywhere in this codebase yet (`StatsCoordinator`'s own doc
        /// comment calls out the same gap for adaptive-throttling
        /// purposes). A rule that lists this precondition simply never
        /// fires until a real display-sleep notification path exists,
        /// rather than this engine guessing at display state from other
        /// signals.
        case displayAsleep
    }
}

/// What happens when a rule fires. Plan §11.1's pseudocode types this case
/// as `menuBarHighlight(ThemeColorToken)`, but no `ThemeColorToken` type
/// exists anywhere in this codebase (`Theme.swift` has `ThemeColor` and
/// several other tokens, but nothing named or shaped like that) — inventing
/// a whole new theming type as a side effect of the alerts task isn't this
/// task's call to make, so this case carries a plain semantic `String`
/// token (e.g. `"warning"`, `"critical"`) instead. `AlertEngine` never
/// interprets the token itself; it's handed verbatim to the injectable
/// `AlertEngine.menuBarHighlighter` closure, whose owner (the menu bar
/// rendering layer, once it exists) is free to map tokens to real
/// `ThemeColor`s.
public enum AlertAction: Codable, Equatable, Sendable {
    /// Delivered via `UNUserNotificationCenter` by `AlertEngine`.
    case notification(title: String, body: String, sound: Bool)

    /// No `MenuBarHighlighting` protocol exists yet, so this is delivered
    /// through the injectable `AlertEngine.menuBarHighlighter: ((String) -> Void)?`
    /// closure rather than a concrete dependency — same reasoning as
    /// `releaseSleepAssertion` below.
    case menuBarHighlight(String)

    /// Remote push via CloudKit subscription (plan §11.3/§12). Delivered as
    /// far as possible without real CloudKit infra: `AlertEngine.phonePushRecorder`
    /// turns a fired action into a locally-queued `AlertPush`
    /// (`PendingAlertPushStore`) rather than a true push — actual CloudKit
    /// upload is blocked on Apple Developer Program enrollment (see that
    /// store's doc comment), not silently dropped or guessed at.
    case pushToPhone

    /// Shortcuts.app integration (plan §11.1). Delivered via
    /// `AlertEngine.shortcutRunner`, which `AppDelegate`'s composition root
    /// wires to `NSWorkspace.shared.open("shortcuts://run-shortcut?name=...")` —
    /// see that closure's doc comment for why it's injected rather than a
    /// direct `NSWorkspace` call inside `AlertEngine` itself.
    case runShortcut(name: String)

    /// Powers "keep awake until battery <20%" (plan §10.3). `AlertEngine`
    /// intentionally does not import `PowerControlService` to deliver this
    /// — `PowerControlService` already owns the sleep-assertion lifecycle
    /// (plan §4.2's dependency graph has alerts and power control as
    /// siblings under `MacStatKit/Services/`, not one importing the
    /// other), so wiring this case directly to a concrete type would
    /// create a two-way coupling between services that otherwise don't
    /// need to know about each other. Delivered instead via the
    /// injectable `AlertEngine.sleepAssertionReleaser: (() -> Void)?`
    /// closure, which the composition root wires to
    /// `powerControlService.releaseAssertion` (or equivalent) once both
    /// services are constructed.
    case releaseSleepAssertion

    /// Writes to `alert_log` only — no user-visible delivery of any kind.
    /// Useful for rules a user wants tracked in history without being
    /// interrupted (or for `AlertEngine`'s own rate-cap suppression path,
    /// which always logs even when it downgrades a notification).
    case logOnly
}
