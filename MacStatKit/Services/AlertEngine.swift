import Foundation
import UserNotifications
import os

/// Evaluates every enabled `AlertRule` against each `SystemSnapshot` and
/// delivers whatever `AlertAction`s fire (plan §11).
///
/// **Not a poller.** Like `PowerControlService.evaluate(_:)`, this engine
/// has no timer of its own — the composition root feeds it snapshots by
/// calling `evaluate(_:)` from the same shared `StatsCoordinator.snapshots()`
/// stream everything else consumes (plan §3.2 P3: one poll loop, many
/// consumers). This keeps alert evaluation cadence identical to whatever
/// the coordinator's tiers are already doing, with no second timer to keep
/// in sync and no extra IOKit/collector traffic.
///
/// **Sustained-duration + cooldown + Do Not Disturb + quiet hours, in that
/// order.** For every enabled, precondition-satisfied rule: the metric
/// comparison must hold *continuously* for `sustainedFor` (tracked per rule
/// as a "condition became true at" timestamp that resets to nil the instant
/// the condition isn't true on some tick — the same flapping-suppression
/// semantics the plan already establishes for `PowerControlService.evaluate`'s
/// `cpuAbovePercent` condition); then `cooldown` must have elapsed since
/// this rule last actually fired; then `doNotDisturb` must be off; then the
/// current hour must fall outside `quietHours`. All four exist for the same
/// reason (plan §11.3: "anti-spam is mandatory") and are independent —
/// meeting one doesn't substitute for another.
///
/// **Do Not Disturb vs. quiet hours vs. the rate cap.** `doNotDisturb` is
/// checked before `quietHours` because it's the coarser, user-facing "mute
/// everything" switch (plan §11.3's master toggle) — there's no reason to
/// evaluate a per-rule quiet-hours window once the global one has already
/// decided nothing is getting through. Both give a firing the same
/// treatment: the rule simply isn't due to run right now, so neither
/// consumes `cooldown` (a rule muted for an hour can still fire promptly
/// the second it's unmuted) and neither writes to `alert_log`. That is a
/// deliberate departure from the global rate cap below, which *does* log a
/// suppressed firing — the rate cap exists to keep a misconfigured rule
/// (one that's firing far more often than anyone wants) visible in History
/// rather than invisible, which is a diagnostic need. DND is not a
/// misconfiguration signal; it is the user explicitly asking, on purpose,
/// to hear nothing until they say otherwise, the same "don't fire, don't
/// log, don't touch the cooldown" contract `quietHours` already has. Making
/// DND behave like the rate cap instead would fill History with a firing
/// for every single tick a muted rule's condition holds — noise that
/// defeats the point of muting in the first place.
///
/// **The two ID-special-cased rules.** `chargingPausedRuleID` and
/// `slowChargingRuleID` (see `AlertRule`'s doc comment) don't reduce to a
/// single metric-vs-threshold compare: "charging paused" needs the decoded
/// `BatteryStats.notChargingReasonText`, and "slow charging" compares
/// actual charging watts against the *current* adapter's rated watts, not
/// a fixed number (a 30W adapter and a 96W adapter both charging at 20W
/// mean very different things). Both live fields already exist on
/// `BatteryStats` (populated by `BatteryCollector` in `SystemMetricsKit`),
/// so `AlertEngine` reads them directly for these two rule IDs instead of
/// going through `SystemSnapshot.value(for:)`.
///
/// **Delivery.** `.notification` goes out via `UNUserNotificationCenter`,
/// with authorization requested lazily — the first time *any* rule
/// transitions from disabled to enabled (plan §11.3: "not at launch"), via
/// `ruleWasEnabled(_:)`, which the composition root/settings UI should call
/// whenever the user flips a rule on. `.releaseSleepAssertion` and
/// `.menuBarHighlight` go through injectable closures (`sleepAssertionReleaser`,
/// `menuBarHighlighter`) rather than importing `PowerControlService` or a
/// concrete menu-bar type — see `AlertAction`'s doc comment for the full
/// reasoning. `.pushToPhone` and `.runShortcut` go through their own
/// injectable closures (`phonePushRecorder`, `shortcutRunner`) —
/// `.runShortcut` launches Shortcuts.app for real; `.pushToPhone` records an
/// `AlertPush` locally pending a CloudKit upload path that doesn't exist yet
/// (blocked on Apple Developer Program enrollment — see
/// `PendingAlertPushStore`'s doc comment), so it's a real local effect today
/// even though the phone never actually receives anything yet.
/// `.logOnly` writes to `alert_log` and delivers nothing else.
///
/// **Global rate cap (plan §11.3).** Independent of any single rule's
/// cooldown, at most `rateCapPerHour` notifications are actually delivered
/// across *all* rules combined in any trailing 60-minute window. A firing
/// that exceeds the cap still gets evaluated, still resets that rule's
/// cooldown, and is still written to `alert_log` (with `suppressed: true`)
/// — only the actual `UNUserNotificationCenter` delivery (and the
/// `menuBarHighlight`/`releaseSleepAssertion` side effects) are held back.
/// Silently dropping a firing instead would make a misbehaving rule
/// invisible in the very history pane meant to help diagnose it.
@MainActor
public final class AlertEngine {

    private static let logger = Logger(subsystem: "com.sentry.macstat.kit", category: "AlertEngine")

    // MARK: - Special-cased rule IDs

    /// "Charging paused" (plan §11.2). Fixed, not derived from any rule's
    /// content, so `defaultRules(cooldown:)` and this engine's evaluation
    /// path always agree on which rule gets the special-cased treatment
    /// even if a user later renames/edits the rule via a settings UI.
    ///
    /// These three IDs are `nonisolated` (they're immutable `UUID`s, so
    /// there's nothing for the main actor to protect) because their whole
    /// purpose is to be compared against outside this class: `defaultRules`
    /// below, and the settings UI, which has to know that a rule with one of
    /// these IDs is evaluated by content this engine reads directly rather
    /// than by the rule's own metric/comparison/threshold fields.
    nonisolated public static let chargingPausedRuleID = UUID(uuidString: "5B1A0001-0000-4000-8000-000000000001")!

    /// "Slow charging" (plan §11.2). See `chargingPausedRuleID`.
    nonisolated public static let slowChargingRuleID = UUID(uuidString: "5B1A0001-0000-4000-8000-000000000002")!

    /// "Battery health drop" (plan §11.2). Special-cased for the same reason
    /// as the two IDs above: plan §11.2 wants this to fire only on a
    /// *decrease* ("health decreased ≥ 1% vs baseline"), but the generic
    /// `.changedBy` comparison (`abs(value - baseline) >= threshold`) is
    /// deliberately bidirectional per its own doc comment — a health value
    /// that *increases* (e.g. a recalibration blip) shouldn't trip a "drop"
    /// alert. Rather than making `.changedBy` itself directional (which
    /// would narrow it for any future rule that legitimately wants
    /// bidirectional change detection), this one rule gets its own
    /// decrease-only evaluation, same pattern as charging-paused/slow-charging.
    nonisolated public static let batteryHealthDropRuleID = UUID(uuidString: "5B1A0001-0000-4000-8000-000000000003")!

    // MARK: - Injectable delivery hooks

    /// Delivers `.releaseSleepAssertion`. See `AlertAction`'s doc comment
    /// for why this is a closure rather than a `PowerControlService`
    /// dependency. `nil` means the action is silently skipped (logged, not
    /// crashed on) — expected on any composition root that hasn't wired
    /// power control in yet, e.g. in unit tests.
    public var sleepAssertionReleaser: (() -> Void)?

    /// Delivers `.menuBarHighlight(token)`. See `AlertAction`'s doc
    /// comment. `nil` is a silent no-op, same as `sleepAssertionReleaser`.
    public var menuBarHighlighter: ((String) -> Void)?

    /// Delivers `.runShortcut(name:)` — runs `AppDelegate`'s composition
    /// root wires this to `NSWorkspace.shared.open(shortcuts://run-shortcut...)`
    /// rather than `AlertEngine` importing AppKit itself, since this file
    /// also compiles for the iOS target (`MacStatKit_iOS`), which has no
    /// `NSWorkspace`. Same "closure, not a concrete dependency" reasoning as
    /// `sleepAssertionReleaser`/`menuBarHighlighter`; `nil` is a silent
    /// no-op.
    public var shortcutRunner: ((String) -> Void)?

    /// Delivers `.pushToPhone`. Called with a locally-built `AlertPush`
    /// record; `AppDelegate`'s composition root queues it for the next
    /// `SyncService` upload once CloudKit is actually wired (blocked on
    /// Apple Developer Program enrollment — see `SyncRecords.swift`'s
    /// top-level doc comment). `nil` is a silent no-op, same as the other
    /// injectable delivery hooks — expected in any composition root that
    /// hasn't wired sync in yet, e.g. in unit tests.
    public var phonePushRecorder: ((AlertPush) -> Void)?

    // MARK: - Dependencies

    private let historyStore: HistoryStore?
    private let notificationCenter: UNUserNotificationCenter
    private let clock: () -> Date

    /// Plan §11.3 default: 6. Mirrors `AppSettings.notificationRateCapPerHour`
    /// — the composition root is expected to pass that setting's live value
    /// in at construction (and reconstruct/update this engine if the user
    /// changes it), matching the same "read from `AppSettings`, don't
    /// hardcode" guidance `AlertRule` gives for `cooldown`.
    /// `var`, not `let`: `AdvancedPane` exposes this as a live slider, so a
    /// value captured once at construction would leave the control wired to
    /// nothing until the next relaunch. The composition root assigns it from
    /// `applySettings`.
    public var rateCapPerHour: Int

    /// Plan §11.3's global "Do Not Disturb" master toggle. Mirrors
    /// `AppSettings.doNotDisturb` — the composition root is expected to
    /// assign this from `applySettings`, same convention as
    /// `rateCapPerHour` immediately above. `var`, not `let`, for the same
    /// reason: it's exposed as a live toggle (in `AdvancedPane`), so a value
    /// captured once at construction would freeze until the next relaunch.
    /// See the type doc comment for exactly where this sits in the firing
    /// pipeline and why a DND-suppressed firing isn't logged.
    public var doNotDisturb: Bool

    // MARK: - Rules

    public private(set) var rules: [AlertRule]

    // MARK: - Per-rule runtime state (not persisted — resets on relaunch)

    /// When the current tick first observed each rule's condition as true.
    /// Removed (not just left stale) the instant a tick observes the
    /// condition as false, which is what makes this "continuously true"
    /// rather than "true at some point in the last `sustainedFor`."
    private var conditionTrueSince: [UUID: Date] = [:]

    /// When each rule last actually fired (i.e. passed `sustainedFor` and
    /// was not itself held back by cooldown/quiet-hours). Used for that
    /// same rule's next cooldown check.
    private var lastFired: [UUID: Date] = [:]

    /// First-observed value per `.changedBy` rule — see
    /// `AlertRule.Comparison.changedBy`'s doc comment for why this is an
    /// in-memory baseline rather than a real 30-day historical lookup.
    private var changedByBaseline: [UUID: Double] = [:]

    /// Timestamps of notifications actually delivered (not suppressed) in
    /// roughly the last hour, across all rules, for the global rate cap.
    /// Pruned lazily on each `evaluate(_:)` call rather than by a separate
    /// timer — this engine has no timer of its own by design (see type
    /// doc comment).
    private var recentDeliveryTimestamps: [Date] = []

    private var authorizationRequested = false

    // MARK: - Init

    /// - Parameters:
    ///   - rules: initial rule set, typically `AlertEngine.defaultRules(cooldown:)`
    ///     plus any user edits loaded from `SettingsStore`.
    ///   - historyStore: where firings are logged (`alert_log`, plan
    ///     §11.3). `nil` is a legitimate configuration (e.g. a unit test
    ///     that only cares about evaluation logic) — logging is simply
    ///     skipped, matching `HistoryStore`'s own "no dbQueue, no-op"
    ///     failure handling.
    ///   - rateCapPerHour: plan §11.3 default 6; pass
    ///     `AppSettings.notificationRateCapPerHour` in production.
    ///   - doNotDisturb: plan §11.3 default off; pass
    ///     `AppSettings.doNotDisturb` in production.
    ///   - notificationCenter: injectable for tests, defaults to the real
    ///     shared center.
    ///   - clock: injectable `Date` source so tests can drive
    ///     sustained-duration/cooldown/rate-cap logic without real
    ///     `sleep()` calls.
    public init(
        rules: [AlertRule],
        historyStore: HistoryStore? = nil,
        rateCapPerHour: Int = 6,
        doNotDisturb: Bool = false,
        notificationCenter: UNUserNotificationCenter = .current(),
        clock: @escaping () -> Date = Date.init
    ) {
        self.rules = rules
        self.historyStore = historyStore
        self.rateCapPerHour = rateCapPerHour
        self.doNotDisturb = doNotDisturb
        self.notificationCenter = notificationCenter
        self.clock = clock
    }

    // MARK: - Rule management

    /// Replaces the whole rule set (e.g. after a settings-pane edit).
    /// Runtime state for rules that no longer exist is dropped; state for
    /// rules whose `id` is unchanged (edits, not replacements) is kept, so
    /// editing a rule's `name` mid-cooldown doesn't reset that cooldown.
    public func updateRules(_ newRules: [AlertRule]) {
        let newIDs = Set(newRules.map(\.id))
        conditionTrueSince = conditionTrueSince.filter { newIDs.contains($0.key) }
        lastFired = lastFired.filter { newIDs.contains($0.key) }
        changedByBaseline = changedByBaseline.filter { newIDs.contains($0.key) }
        rules = newRules
    }

    /// Call whenever a rule transitions from disabled to enabled (settings
    /// UI, or `defaultRules` being enabled for the first time). Requests
    /// notification authorization on the *first* such call only — plan
    /// §11.3 explicitly wants this lazy, not requested at app launch, so a
    /// user who never turns on any alert never sees the system permission
    /// prompt at all.
    public func ruleWasEnabled(_ rule: AlertRule) {
        requestAuthorizationIfNeeded()
    }

    /// Requests notification authorization exactly once per engine lifetime.
    /// Called from `ruleWasEnabled` (user explicitly switched a rule on) and
    /// from the first actual delivery attempt (covers the shipped-enabled
    /// default rules) — see `deliverNotification` for why both entry points
    /// are needed to satisfy §11.3 without prompting at launch.
    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            // Authorization outcome isn't *actionable* here — this engine
            // has no UI to surface a "notifications disabled" banner from,
            // and must not retry/re-prompt on every firing — but a denial
            // means every `.notification` action from here on is silently
            // dropped by the system, so at minimum the log has to say so
            // once, honestly, rather than the loss being invisible even to
            // someone reading Console. (Firings themselves are still
            // recorded in `alert_log` regardless.)
            if let error {
                Self.logger.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                Self.logger.notice("Notification authorization denied — .notification alert actions will not be shown until it is enabled in System Settings. Firings are still recorded in alert_log.")
            }
        }
    }

    // MARK: - Evaluation

    /// Evaluates every enabled rule against `snapshot`. `@MainActor`-isolated
    /// like `PowerControlService` rather than queue-confined like
    /// `StatsCoordinator` — this type has no hot polling loop of its own, is
    /// driven by the same main-actor snapshot-consumption point everything
    /// else in `AppDelegate` already uses, and (per `PowerControlService`'s
    /// own doc comment on the same tradeoff) there's no contention here that
    /// a private serial queue would be protecting against.
    public func evaluate(_ snapshot: SystemSnapshot) {
        let now = clock()
        pruneRateCapWindow(now: now)
        for rule in rules {
            evaluate(rule: rule, snapshot: snapshot, now: now)
        }
    }

    private func evaluate(rule: AlertRule, snapshot: SystemSnapshot, now: Date) {
        guard rule.isEnabled else {
            conditionTrueSince[rule.id] = nil
            return
        }
        guard preconditionsMet(rule.onlyWhen, snapshot: snapshot) else {
            conditionTrueSince[rule.id] = nil
            return
        }

        let (conditionTrue, observedValue) = currentCondition(for: rule, snapshot: snapshot, now: now)
        guard conditionTrue else {
            conditionTrueSince[rule.id] = nil
            return
        }

        let since = conditionTrueSince[rule.id] ?? now
        if conditionTrueSince[rule.id] == nil {
            conditionTrueSince[rule.id] = now
        }
        guard now.timeIntervalSince(since) >= rule.sustainedFor else { return }

        if let last = lastFired[rule.id], now.timeIntervalSince(last) < rule.cooldown {
            return
        }

        if doNotDisturb {
            // The global master mute (plan §11.3), checked before the
            // per-rule quiet-hours window because it's the coarser gate —
            // see the type doc comment for why this is a silent, unlogged
            // return (same contract as `quietHours` below) rather than the
            // rate cap's "fire but log as suppressed" treatment.
            // `lastFired` is intentionally left untouched so the rule can
            // fire promptly once DND is turned off.
            return
        }

        if let quietHours = rule.quietHours {
            let hour = Calendar.current.component(.hour, from: now)
            if quietHours.contains(hour: hour) {
                // Quiet hours are a deliberate "don't fire at all" mute,
                // distinct from the rate cap's "fired but held back" —
                // nothing to log, this rule simply isn't due to run right
                // now. `lastFired`/cooldown are untouched so the rule can
                // still fire promptly once quiet hours end, rather than
                // being penalized by a cooldown it never actually used.
                return
            }
        }

        lastFired[rule.id] = now
        fire(rule: rule, value: observedValue ?? rule.threshold, snapshot: snapshot, now: now)
    }

    /// Preconditions are AND'd — every listed precondition must hold.
    private func preconditionsMet(_ preconditions: [AlertRule.Precondition], snapshot: SystemSnapshot) -> Bool {
        for precondition in preconditions {
            switch precondition {
            case .onBattery:
                // `nil` battery (no sample yet, or a desktop Mac) fails
                // this precondition rather than guessing either way — see
                // `AlertRule.Precondition.onBattery`'s doc comment.
                guard snapshot.battery?.isCharging == false else { return false }
            case .charging:
                guard snapshot.battery?.isCharging == true else { return false }
            case .pluggedIn:
                guard snapshot.battery?.isPluggedIn == true else { return false }
            case .displayAsleep:
                // No display-sleep signal exists anywhere in this codebase
                // yet — always false. See the doc comment on this case.
                return false
            }
        }
        return true
    }

    /// Returns whether `rule`'s condition is true on this tick, and the
    /// value to record/log for it. `observedValue` is `nil` only when the
    /// needed data simply isn't available (missing module, IOKit read
    /// failure) — that always pairs with `conditionTrue == false`, per P5:
    /// missing data must never be read as "condition met."
    private func currentCondition(for rule: AlertRule, snapshot: SystemSnapshot, now: Date) -> (Bool, Double?) {
        if rule.id == Self.chargingPausedRuleID {
            return evaluateChargingPaused(snapshot)
        }
        if rule.id == Self.slowChargingRuleID {
            return evaluateSlowCharging(snapshot)
        }
        if rule.id == Self.batteryHealthDropRuleID {
            return evaluateBatteryHealthDrop(snapshot, threshold: rule.threshold)
        }

        guard let value = snapshot.value(for: rule.metric) else { return (false, nil) }

        switch rule.comparison {
        case .above:
            return (value >= rule.threshold, value)
        case .below:
            return (value <= rule.threshold, value)
        case .equals:
            return (abs(value - rule.threshold) < 0.0001, value)
        case .changedBy:
            if let baseline = changedByBaseline[rule.id] {
                return (abs(value - baseline) >= rule.threshold, value)
            } else {
                // First observation establishes the baseline; nothing has
                // "changed" relative to itself yet.
                changedByBaseline[rule.id] = value
                return (false, value)
            }
        }
    }

    /// "Battery health drop": fires only on a *decrease* of at least
    /// `rule.threshold` from the first-observed baseline, unlike the
    /// generic bidirectional `.changedBy` comparison — see
    /// `batteryHealthDropRuleID`'s doc comment for why this needs its own
    /// evaluator. Baseline bookkeeping reuses `changedByBaseline`, keyed by
    /// this rule's own `id`, so it behaves identically to `.changedBy` in
    /// every other respect (first-seen baseline, never reset, in-memory only).
    private func evaluateBatteryHealthDrop(_ snapshot: SystemSnapshot, threshold: Double) -> (Bool, Double?) {
        guard let value = snapshot.value(for: .batteryHealthPercent) else { return (false, nil) }
        guard let baseline = changedByBaseline[Self.batteryHealthDropRuleID] else {
            changedByBaseline[Self.batteryHealthDropRuleID] = value
            return (false, value)
        }
        return (baseline - value >= threshold, value)
    }

    /// "Charging paused": `BatteryStats.notChargingReason` non-zero while
    /// plugged in. `notChargingReason == 0` (or `nil`, meaning the
    /// IORegistry key wasn't present) means "no reason reported" — treated
    /// as "not paused," which is the honest default (P5: absence of a
    /// reason is not evidence of a paused charge).
    private func evaluateChargingPaused(_ snapshot: SystemSnapshot) -> (Bool, Double?) {
        guard let battery = snapshot.battery, battery.isPluggedIn else { return (false, nil) }
        guard let reason = battery.notChargingReason, reason != 0 else { return (false, nil) }
        return (true, Double(reason))
    }

    /// "Slow charging": actual charging watts under 50% of the *current*
    /// adapter's rated watts. Both `chargingWatts` and `adapterRatedWatts`
    /// must be present and the adapter rating must be positive — a Mac
    /// mid-negotiation (adapter rating not yet reported) or running on
    /// battery reports "not slow charging" rather than a false positive
    /// built on a missing denominator.
    private func evaluateSlowCharging(_ snapshot: SystemSnapshot) -> (Bool, Double?) {
        guard let battery = snapshot.battery, battery.isCharging else { return (false, nil) }
        guard let actualWatts = battery.chargingWatts,
              let adapterWatts = battery.adapterRatedWatts,
              adapterWatts > 0 else { return (false, nil) }
        let ratio = actualWatts / Double(adapterWatts)
        return (ratio < 0.5, actualWatts)
    }

    // MARK: - Firing / delivery

    private func fire(rule: AlertRule, value: Double, snapshot: SystemSnapshot, now: Date) {
        let withinRateCap = recentDeliveryTimestamps.count < rateCapPerHour
        // Counts once per *rule firing* that had at least one
        // user-perceptible action, not once per action — a rule with both
        // a `.notification` and a `.menuBarHighlight` shouldn't cost twice
        // against the cap. `.logOnly` is silent by design, so it never
        // counts. `.pushToPhone` and `.runShortcut` both count (a queued
        // phone push and an external automation launch are each just as
        // capable of being "intolerable" from a misconfigured, rapidly
        // refiring rule as a notification would be), same as
        // `.releaseSleepAssertion`.
        //
        // Closure-delivered actions only count when their closure is
        // actually wired: a `nil` `menuBarHighlighter` (or `shortcutRunner`,
        // `sleepAssertionReleaser`, `phonePushRecorder`) delivers nothing to
        // anyone, so treating it as a delivery would both lie in `alert_log`
        // ("Delivered" for something no one could have seen — the log's own
        // doc comment below says it must distinguish "we showed you
        // something" from "nothing stopped us") and burn one of the
        // `rateCapPerHour` slots on a no-op, potentially suppressing a real
        // notification later in the same hour.
        var didDeliver = false

        for action in rule.actions {
            switch action {
            case .notification(let title, let body, let sound):
                guard withinRateCap else { continue }
                deliverNotification(
                    title: title,
                    body: dynamicBody(for: rule, fallback: body, snapshot: snapshot),
                    sound: sound,
                    ruleID: rule.id
                )
                didDeliver = true

            case .menuBarHighlight(let token):
                guard withinRateCap, let menuBarHighlighter else { continue }
                menuBarHighlighter(token)
                didDeliver = true

            case .pushToPhone:
                // Recorded locally, not yet actually pushed — see
                // `phonePushRecorder`'s doc comment. Gated by
                // `withinRateCap` and counts toward `didDeliver` like every
                // other user-perceptible action (`.notification`,
                // `.menuBarHighlight`, `.runShortcut`,
                // `.releaseSleepAssertion`): once CloudKit upload is wired
                // up, an unguarded push here would let a misconfigured,
                // rapidly-refiring rule queue an unbounded stream of phone
                // notifications even though its on-Mac `.notification`
                // action was itself being suppressed by the same cap — an
                // inconsistency worth closing off now rather than after
                // the transport exists to make it user-visible.
                guard withinRateCap, let phonePushRecorder else { continue }
                if let (title, body) = notificationText(in: rule.actions) {
                    phonePushRecorder(AlertPush(
                        deviceID: snapshot.deviceID,
                        ruleName: rule.name,
                        title: title,
                        body: dynamicBody(for: rule, fallback: body, snapshot: snapshot),
                        firedAt: now
                    ))
                    didDeliver = true
                }

            case .runShortcut(let name):
                guard withinRateCap, let shortcutRunner else { continue }
                shortcutRunner(name)
                didDeliver = true

            case .releaseSleepAssertion:
                guard withinRateCap, let sleepAssertionReleaser else { continue }
                sleepAssertionReleaser()
                didDeliver = true

            case .logOnly:
                break
            }
        }

        if didDeliver {
            recentDeliveryTimestamps.append(now)
        }

        historyStore?.logAlertFiring(
            ruleID: rule.id,
            ruleName: rule.name,
            metric: rule.metric.rawValue,
            value: value,
            at: now,
            // `didDeliver`, not `withinRateCap`: the latter only says the cap
            // *allowed* a delivery, so a rule whose only action is `.logOnly`
            // (which by definition shows the user nothing) would be recorded
            // as delivered and render in the history pane with a bell icon
            // reading "Delivered". The log is the one place a user checks to
            // find out what actually reached them, so it has to distinguish
            // "we showed you something" from "nothing stopped us."
            delivered: didDeliver,
            suppressed: !withinRateCap
        )
    }

    /// The two ID-special-cased rules ship with a static placeholder body
    /// (plan §11.2's table gives them fixed copy), but both are much more
    /// useful with the live reason/wattage folded in. Every other rule's
    /// body is used verbatim — most already read fine as static copy
    /// ("Consider unplugging for battery longevity" doesn't need a number
    /// in it).
    /// `.pushToPhone` piggybacks on the same rule's `.notification` text
    /// where one exists, rather than defining a second, parallel
    /// title/body on `AlertAction.pushToPhone` itself — a rule author
    /// already wrote the human-readable text once; the phone shouldn't need
    /// a second copy that can drift from it. `nil` if the rule has no
    /// `.notification` action at all (a `.pushToPhone`-only rule has no
    /// text to send yet — rare, and better to skip than to fabricate one).
    private func notificationText(in actions: [AlertAction]) -> (title: String, body: String)? {
        for action in actions {
            if case .notification(let title, let body, _) = action {
                return (title, body)
            }
        }
        return nil
    }

    private func dynamicBody(for rule: AlertRule, fallback: String, snapshot: SystemSnapshot) -> String {
        if rule.id == Self.chargingPausedRuleID {
            let reasonText = snapshot.battery?.notChargingReasonText ?? "unknown reason"
            return "Charging paused: \(reasonText)"
        }
        if rule.id == Self.slowChargingRuleID,
           let actual = snapshot.battery?.chargingWatts,
           let rated = snapshot.battery?.adapterRatedWatts {
            return "Charging at \(Int(actual))W of \(rated)W rated — \(fallback)"
        }
        return fallback
    }

    private func deliverNotification(title: String, body: String, sound: Bool, ruleID: UUID) {
        // The other half of §11.3's lazy authorization. `ruleWasEnabled`
        // covers the user explicitly switching a rule on; this covers the
        // shipped-enabled default rules, which would otherwise force the
        // composition root to prompt at launch (defeating the point) or
        // never prompt at all (so notifications silently never appear).
        // Requesting here means the prompt arrives at the first moment
        // there is genuinely something to show the user. Idempotent via the
        // same `authorizationRequested` flag.
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound {
            content.sound = .default
        }
        // Fires as soon as possible; `nil` trigger means "now" per
        // `UNUserNotificationCenter` semantics.
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        notificationCenter.add(request) { error in
            // Delivery errors (e.g. authorization not yet granted) aren't
            // *actionable* here — see `ruleWasEnabled(_:)`'s doc comment —
            // but they are the only signal that an alert the log recorded
            // as delivered never actually appeared, so they must at least
            // be visible in Console rather than swallowed.
            if let error {
                Self.logger.error("Notification delivery failed for rule \(ruleID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func pruneRateCapWindow(now: Date) {
        let cutoff = now.addingTimeInterval(-3600)
        recentDeliveryTimestamps.removeAll { $0 < cutoff }
    }
}

// MARK: - Default rules (plan §11.2)

extension AlertEngine {
    /// Builds the 11 shipped default rules, all user-editable afterward.
    /// Thresholds/durations/actions transcribed from plan §11.2's table.
    ///
    /// - Parameter cooldown: applied to every rule uniformly. Per
    ///   `AlertRule`'s own doc comment, callers should pass
    ///   `TimeInterval(AppSettings.alertCooldownMinutes * 60)` — this
    ///   function takes it as a parameter rather than reading `AppSettings`
    ///   itself so `MacStatKit/Services` doesn't need a dependency on
    ///   `MacStatKit/Settings` (or a hidden default that silently diverges
    ///   from the user's actual setting).
    ///
    /// `nonisolated` because this is a pure factory for value types with no
    /// access to any engine state, and its natural callers aren't on the
    /// main actor: `AppSettings.defaultAlertRules` (a `static let`) and
    /// `AppSettings.init(from:)` (a nonisolated `Decodable` requirement)
    /// both need it, and both are exactly the callers this function's own
    /// `cooldown` parameter was designed for. Without `nonisolated` the
    /// enclosing `@MainActor` class silently makes this unreachable from
    /// them — a compile error, not a runtime hazard, and one that would
    /// otherwise force `AppSettings` to hardcode a duplicate rule list.
    nonisolated public static func defaultRules(cooldown: TimeInterval) -> [AlertRule] {
        [
            AlertRule(
                name: "Low battery",
                metric: .batteryChargePercent,
                comparison: .below,
                threshold: 20,
                sustainedFor: 30,
                cooldown: cooldown,
                onlyWhen: [.onBattery],
                actions: [
                    .notification(title: "Low Battery", body: "Battery is below 20%.", sound: false),
                    .pushToPhone
                ]
            ),
            AlertRule(
                name: "Critical battery",
                metric: .batteryChargePercent,
                comparison: .below,
                threshold: 10,
                sustainedFor: 10,
                cooldown: cooldown,
                onlyWhen: [.onBattery],
                actions: [
                    .notification(title: "Critical Battery", body: "Battery is below 10%.", sound: true),
                    .pushToPhone
                ]
            ),
            AlertRule(
                name: "Fully charged",
                metric: .batteryChargePercent,
                comparison: .above,
                threshold: 100,
                sustainedFor: 60,
                cooldown: cooldown,
                // NOT `[.charging]`, which is the intuitive reading of plan
                // §11.2's "charge ≥ 100%, charging" but makes the rule
                // unfireable in practice: macOS stops reporting
                // `isCharging` once the battery reaches full, so the two
                // conditions are never simultaneously true and the
                // sustained 60s window can never complete. `.pluggedIn`
                // expresses the actual intent — "you're on power and topped
                // up" — and, unlike `.onBattery`, doesn't also fire at 100%
                // while running unplugged.
                onlyWhen: [.pluggedIn],
                actions: [
                    .notification(title: "Fully Charged", body: "Battery is fully charged.", sound: false)
                ]
            ),
            AlertRule(
                name: "Charge limit reminder",
                metric: .batteryChargePercent,
                comparison: .above,
                threshold: 80,
                sustainedFor: 60,
                cooldown: cooldown,
                onlyWhen: [.charging],
                actions: [
                    .notification(
                        title: "Charge Limit Reminder",
                        body: "Consider unplugging for battery longevity.",
                        sound: false
                    )
                ]
            ),
            AlertRule(
                // ID-special-cased (see `batteryHealthDropRuleID`'s doc
                // comment) so this fires on a *decrease* only, not the
                // generic `.changedBy` comparison's bidirectional delta.
                // `metric`/`comparison` below are informational placeholders,
                // same convention as the charging-paused/slow-charging rules.
                id: batteryHealthDropRuleID,
                name: "Battery health drop",
                metric: .batteryHealthPercent,
                comparison: .changedBy,
                threshold: 1,
                sustainedFor: 0,
                cooldown: cooldown,
                actions: [
                    .notification(title: "Battery Health Drop", body: "Battery health has decreased.", sound: false),
                    .logOnly
                ]
            ),
            AlertRule(
                name: "High temperature",
                // Plan §11.2: "SoC temp > 95°C" — `.thermalSocTempC`, not
                // battery temperature. These are two different sensors on
                // `SystemSnapshot` (`thermal?.socTemperatureCelsius` vs
                // `battery?.temperatureCelsius`); using the wrong one would
                // silently monitor the wrong hardware.
                metric: .thermalSocTempC,
                comparison: .above,
                threshold: 95,
                sustainedFor: 60,
                cooldown: cooldown,
                actions: [
                    .notification(title: "High Temperature", body: "SoC temperature is above 95°C.", sound: false)
                ]
            ),
            AlertRule(
                name: "Thermal throttling",
                metric: .thermalPressureLevel,
                comparison: .above,
                // `ThermalStats.PressureLevel.serious` encodes to 2 (see
                // `HistoryStore.pressureLevelCode` / `SystemSnapshot+MetricValue`'s
                // `thermalPressureLevel` mapping: nominal=0, fair=1,
                // serious=2, critical=3).
                threshold: 2,
                sustainedFor: 60,
                cooldown: cooldown,
                actions: [
                    .menuBarHighlight("warning"),
                    .notification(title: "Thermal Throttling", body: "The system is thermally throttling.", sound: false)
                ]
            ),
            AlertRule(
                name: "Sustained high CPU",
                metric: .cpuTotalPercent,
                comparison: .above,
                threshold: 90,
                sustainedFor: 300,
                cooldown: cooldown,
                actions: [
                    .notification(title: "Sustained High CPU", body: "CPU usage has been above 90% for 5 minutes.", sound: false)
                ]
            ),
            AlertRule(
                name: "Low disk",
                metric: .diskFreeBytes,
                comparison: .below,
                // 10 GiB (1024-based), not 10 decimal-billion bytes: every
                // byte-scale display in this app (`MetricFormatter`'s
                // `ByteCountFormatter` uses `.memory` count style, and
                // `AlertsPane`'s threshold editor for this same field) is
                // 1024-based, so a decimal-GB threshold here would show as
                // an odd "9.31 GB" everywhere a person actually reads it
                // instead of the clean "10 GB" plan §11.2 asks for.
                threshold: 10 * 1024 * 1024 * 1024,
                sustainedFor: 0,
                cooldown: cooldown,
                actions: [
                    .notification(title: "Low Disk Space", body: "Free disk space is below 10 GB.", sound: false)
                ]
            ),
            AlertRule(
                id: chargingPausedRuleID,
                name: "Charging paused",
                // Placeholder metric/comparison — see `AlertRule`'s and
                // this engine's doc comments. `AlertEngine` special-cases
                // evaluation for `chargingPausedRuleID` and never reads
                // these three fields.
                metric: .batteryChargePercent,
                comparison: .above,
                threshold: 0,
                sustainedFor: 120,
                cooldown: cooldown,
                actions: [
                    .notification(title: "Charging Paused", body: "Charging has paused.", sound: false)
                ]
            ),
            AlertRule(
                id: slowChargingRuleID,
                name: "Slow charging",
                // Placeholder — see `chargingPausedRuleID` above.
                metric: .batteryChargingWatts,
                comparison: .below,
                threshold: 0,
                sustainedFor: 300,
                cooldown: cooldown,
                actions: [
                    .notification(title: "Slow Charging", body: "check cable/adapter", sound: false)
                ]
            )
        ]
    }
}
