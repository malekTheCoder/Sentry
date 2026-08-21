import SwiftUI
import AppKit
import UserNotifications
import SentryKit

/// The plan §11 alert surface: a rule list with an inspector for the selected
/// rule, plus the `alert_log` history §11.3 asks for.
///
/// **Why history is a mode of this pane and not its own sidebar entry.**
/// `SettingsView`'s sidebar already carries nine panes, and a tenth row for a
/// read-only list would stretch it for no gain. More importantly the two
/// views are one workflow, not two subjects — you
/// read the history *in order to* decide which rule to retune (that's the
/// entire reason the rate cap logs suppressed firings instead of dropping
/// them), so putting them a segmented-control click apart keeps the edit and
/// the evidence together. History is read-only and needs no inspector, so it
/// doesn't fight the rules mode for the split-view layout.
///
/// **Bindings write straight into `store.settings`**, like every other pane —
/// there is deliberately no draft/apply copy (see `SettingsView`'s doc
/// comment). `SettingsStore` debounces the resulting save.
///
/// **What this pane deliberately does not do:** it does not hold an
/// `AlertEngine`. Pushing edits into the live engine
/// (`AlertEngine.updateRules(_:)`) and requesting notification authorization
/// on the first enable (`AlertEngine.ruleWasEnabled(_:)`, which plan §11.3
/// requires to be lazy) are composition-root jobs — `AppDelegate` already
/// owns both objects and can observe `store.$settings.map(\.alertRules)`
/// without this view growing a second dependency it would have to keep in
/// sync with the settings it's already writing to.
///
/// **Actions are shown but not edited.** A rule's `[AlertAction]` is
/// summarized read-only. Editing it well means a UI for composing
/// notification title/body copy plus per-action pickers. `.runShortcut` now
/// launches Shortcuts.app for real. `.pushToPhone` is a deleted feature's
/// decode-compatibility remnant (see `AlertAction.pushToPhone`'s doc
/// comment) that delivers nothing, so its row is filtered out of
/// `actionsSection` entirely — an action the user can neither edit nor
/// receive isn't worth a row that needs a disclaimer.
///
/// **Process-match rules are part of Sentry Pro**
/// (`ProFeature.processMatchAlerts`), gated twice on purpose:
/// `AlertEngine.processRulesUnlocked` refuses the *evaluation* (covering
/// rules that never came through this editor — a hand-edited settings
/// file, an MCP re-enable), while this pane withholds the create/enable
/// affordances and discloses, on the rule itself, that an existing process
/// rule isn't being evaluated. A lapse deletes nothing, and everything
/// that reverts — disabling a rule, converting it back to generic — stays
/// available regardless of entitlement.
struct AlertsPane: View {

    @ObservedObject var store: SettingsStore

    /// Read-only source for the history mode. Optional because the settings
    /// window is constructible without one (previews, and any composition
    /// root that hasn't wired history yet) — history then shows an explicit
    /// "unavailable" message rather than an empty list that would read as
    /// "nothing has ever fired."
    ///
    /// `AppDelegate` (via `MainWindowController`'s root view) passes the same
    /// `HistoryStore` instance `AlertEngine` was constructed with; nothing
    /// here writes to it.
    let historyStore: HistoryStore?

    /// Answers `ProFeature.processMatchAlerts` for the process-match gate —
    /// the UI half of the entitlement `AlertEngine.processRulesUnlocked`
    /// enforces at evaluation time (defense in depth: this pane withholds
    /// the affordance, the engine refuses the evaluation either way).
    ///
    /// The live provider, deliberately not a captured `Bool`:
    /// `MainWindowController` reuses this pane's view tree forever, so a
    /// value snapshotted at construction would freeze until relaunch. Body
    /// re-evaluation is safe because every entitlement flip originates as a
    /// `settingsStore.settings` mutation (the developer override, or
    /// `LicenseProEntitlementStore.installLicense` writing the license),
    /// which re-renders this `@ObservedObject`-store pane after the
    /// composition root's synchronous sink has already updated the provider.
    ///
    /// Optional, defaulting to nil, for the same fail-toward-locked reason
    /// `AlertEngine.processRulesUnlocked` defaults to false: a construction
    /// site that forgets to wire it (a preview, a future settings host)
    /// withholds the paid feature rather than silently granting it.
    let entitlements: (any ProEntitlementProviding)?

    init(
        store: SettingsStore,
        historyStore: HistoryStore? = nil,
        entitlements: (any ProEntitlementProviding)? = nil
    ) {
        self.store = store
        self.historyStore = historyStore
        self.entitlements = entitlements
    }

    /// The resolved gate every locked-state branch below reads. Computed,
    /// not stored, so each body evaluation asks the live provider — see
    /// `entitlements`'s doc comment.
    private var processMatchUnlocked: Bool {
        entitlements?.isUnlocked(.processMatchAlerts) ?? false
    }

    private enum Mode: String, CaseIterable, Hashable {
        case rules, history

        var displayName: String {
            switch self {
            case .rules: return String(localized: "Rules")
            case .history: return String(localized: "History")
            }
        }
    }

    /// Transient UI state, not persisted — same reasoning as `MenuBarPane`'s
    /// `selectedModuleID`.
    @State private var mode: Mode = .rules
    @State private var selectedRuleID: AlertRule.ID?
    @State private var isConfirmingRestore = false
    @State private var historyEntries: [AlertLogEntry] = []

    /// Verified-bug fix ("a denied notification permission is invisible"):
    /// `nil` until the one-time `.task` check below completes, so the
    /// banner never flashes on and back off during the very first frame.
    /// `AlertEngine` itself has no notion of this — it only ever *requests*
    /// authorization lazily (`ruleWasEnabled`/`deliverNotification`'s
    /// `requestAuthorizationIfNeeded`) and has no UI to surface a denial
    /// from, which is exactly the gap this pane closes: without it,
    /// `alert_log` keeps recording `delivered: true` for a notification the
    /// system silently dropped, and nothing on screen ever says why.
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus?

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            .accessibilityLabel("Alerts view")

            Divider()

            // Honest-UI requirement for plan §11.3's DND master toggle: a
            // user staring at an enabled, correctly-configured rule that
            // just isn't firing needs to know *why* without having to guess
            // that Advanced has a switch flipped. Shown regardless of
            // `mode` since it's equally true of History (nothing fired
            // because nothing was allowed to, not because nothing happened
            // to be true).
            if store.settings.doNotDisturb {
                Label(
                    "Do Not Disturb is on — no alerts will be delivered until you turn it off in the Advanced pane.",
                    systemImage: "moon.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                Divider()
            }

            // Verified-bug fix: same "why isn't this firing" honesty
            // requirement as the DND banner immediately above, for a
            // different silent cause — macOS notification permission denied
            // (or later revoked in System Settings) rather than the user's
            // own DND toggle. `.red`, not `.orange`, to read as more urgent
            // than DND: DND is the user's own on-purpose choice, this is an
            // OS-level block the user may not know exists at all.
            if notificationAuthorizationStatus == .denied {
                HStack(alignment: .firstTextBaseline) {
                    Label(
                        "Notifications are turned off for Sentry — open System Settings to allow them.",
                        systemImage: "bell.slash.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.red)

                    Spacer()

                    Button("Open System Settings") {
                        openNotificationSettings()
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)

                Divider()
            }

            switch mode {
            case .rules:
                HSplitView {
                    ruleListColumn
                        .frame(minWidth: 240)
                    inspectorColumn
                        .frame(minWidth: 300)
                }
            case .history:
                historyColumn
            }
        }
        .task {
            // One-time check, not a poller: `UNUserNotificationCenter` has
            // no "authorization status changed" notification to observe, so
            // this only catches a denial that was already in effect when
            // this pane last appeared (fresh app launch, or switching back
            // to Settings from another tab) — good enough for the honesty
            // requirement this banner exists for, without inventing a
            // polling timer nothing else in this pane needs.
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationAuthorizationStatus = settings.authorizationStatus
        }
        .confirmationDialog(
            "Restore the default alert rules?",
            isPresented: $isConfirmingRestore
        ) {
            Button("Restore Defaults", role: .destructive) { restoreDefaultRules() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // The count fragment is localized on its own first: inside a
            // `Text` interpolation a bare literal ternary is a plain
            // `String`, so "1 rule"/"N rules" would otherwise stay English
            // in every locale even though the surrounding sentence is a
            // proper `LocalizedStringKey`.
            let ruleCountText = rules.count == 1
                ? String(localized: "1 rule")
                : String(localized: "\(String(rules.count)) rules")
            let defaultCountText = String(AppSettings.defaultAlertRules.count)
            Text("Your \(ruleCountText) will be replaced by the \(defaultCountText) rules Sentry ships with, including any you edited or removed. Alert history is not deleted.")
        }
    }

    private var rules: [AlertRule] {
        store.settings.alertRules
    }

    // MARK: - Left column: rule list

    private var ruleListColumn: some View {
        VStack(spacing: 0) {
            List(selection: $selectedRuleID) {
                ForEach(rules) { rule in
                    ruleRow(rule)
                        .tag(rule.id)
                }
            }
            .accessibilityLabel("Alert rules")
            // `.onDelete` gives no affordance at all on macOS — no swipe, no
            // edit mode — so `MenuBarPane` established this trio (explicit
            // button + context menu + Delete key) as the way a list row gets
            // removed in this app. Same pattern here rather than a second
            // discovery of the same gap.
            .onDeleteCommand { removeSelectedRule() }
            .contextMenu(forSelectionType: AlertRule.ID.self) { ids in
                Button("Remove", role: .destructive) { removeRules(ids: ids) }
            }

            if rules.isEmpty {
                Text("You have no alert rules. Nothing will ever notify you until you add one or restore the defaults below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding()
            }

            HStack {
                Button {
                    addRule()
                } label: {
                    Label("Add Rule", systemImage: "plus.circle")
                }
                .accessibilityLabel("Add a new alert rule")

                Button(role: .destructive) {
                    removeSelectedRule()
                } label: {
                    Label("Remove Rule", systemImage: "minus.circle")
                }
                .disabled(selectedRuleID == nil)
                .accessibilityLabel("Remove the selected alert rule")

                Spacer()

                Button {
                    isConfirmingRestore = true
                } label: {
                    Label("Restore Defaults", systemImage: "arrow.counterclockwise")
                }
                .accessibilityLabel("Restore the default alert rules")
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
    }

    private func ruleRow(_ rule: AlertRule) -> some View {
        HStack(spacing: 8) {
            if Self.enableAffordanceWithheld(for: rule, processMatchUnlocked: processMatchUnlocked) {
                // A checkbox here could only *enable* the rule, and enabling
                // a process rule is part of Sentry Pro — so the affordance is
                // withheld, not constructed-and-dead (the inert-control shape
                // this pane refuses; see `actionsSection`'s `.pushToPhone`
                // reasoning). The moment the rule is enabled — or the copy is
                // unlocked — the checkbox returns, because *disabling* is an
                // escape hatch and is never gated.
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Enabling \(rule.name) requires Sentry Pro")
            } else {
                Toggle(isOn: enabledBinding(for: rule.id)) {
                    EmptyView()
                }
                .labelsHidden()
                // Deliberately no `.toggleStyle(.checkbox)`: that explicit
                // override was the one place in the Mac app that would have
                // stayed stock. A system checkbox's bezel grey measures
                // roughly 2.2:1 on Ivory's grouped rows — under the 3:1 the
                // themed-controls pass enforces everywhere else — so the
                // rule list inherits `ThemedToggleStyle` with the rest of
                // the pane, which also makes the genuinely-disabled rules
                // here the thing the disabled floor is graded on.
                .accessibilityLabel("Enable \(rule.name)")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(rule.name)
                    .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                Text(Self.conditionSummary(for: rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // The honest disclosure lives on the rule itself, not only
                // in the inspector — same "why isn't this firing" duty as
                // the DND banner above, for a rule the engine is skipping
                // because of the entitlement rather than a mute.
                if RuleKind(rule: rule) == .processMatch && !processMatchUnlocked {
                    Label("Part of Sentry Pro — not being evaluated", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()
        }
        // Without this the row's accessibility label would splice the
        // toggle's label into the condition sentence.
        .accessibilityElement(children: .contain)
    }

    /// Removal (`Remove Rule`, the row's Delete key, its context menu) has
    /// always been one-way in this pane — the only recovery was `Restore
    /// Defaults`, which rebuilds all 14 shipped rules with fresh UUIDs and
    /// discards every other edit along with it. `Add Rule` is the actual
    /// undo path: selecting the new rule immediately afterward means the
    /// user lands straight in the inspector to retune it, the same flow
    /// `restoreDefaultRules` uses for consistency (it clears the selection
    /// instead, since there's no single new rule to focus there).
    private func addRule() {
        let newRule = Self.makeNewRule(
            cooldown: TimeInterval(store.settings.alertCooldownMinutes * 60)
        )
        store.settings.alertRules.append(newRule)
        selectedRuleID = newRule.id
        mode = .rules
    }

    /// Builds a fresh, meaningfully-configured rule for `addRule()`.
    ///
    /// **Why these particular defaults.** A rule needs a metric, a
    /// comparison, a threshold, `sustainedFor`, a `cooldown`, and at least
    /// one action to be worth anything at all — an all-zero/empty-actions
    /// rule would evaluate some placeholder condition immediately and then
    /// visibly do nothing, which is a worse starting point than no rule.
    /// CPU above 90%, sustained a minute, with a plain notification, mirrors
    /// the shipped "Sustained high CPU" default (plan §11.2): a real,
    /// already-meaningful condition the user can retune from the inspector
    /// rather than a blank template they have to fully construct themselves.
    /// `cooldown` is threaded through from the current
    /// `alertCooldownMinutes` setting for the same reason
    /// `restoreDefaultRules` does — a hardcoded literal here would drift
    /// from what the rest of this pane calls "the default cooldown for new
    /// rules."
    ///
    /// **Fresh, non-colliding UUID.** `AlertRule.init`'s default `UUID()` is
    /// astronomically unlikely to land on one of `AlertEngine`'s three fixed
    /// special-cased IDs, but "astronomically unlikely" isn't "provably
    /// can't" — and a user-created rule that happened to carry one of those
    /// IDs would be silently evaluated by the engine's hardcoded logic
    /// (reading `BatteryStats` fields directly) instead of the
    /// metric/comparison/threshold this editor shows and the user actually
    /// set, with no error and no indication anything was wrong. The loop
    /// below makes the exclusion explicit rather than leaving it to chance.
    static func makeNewRule(cooldown: TimeInterval) -> AlertRule {
        var id = UUID()
        while reservedRuleIDs.contains(id) {
            id = UUID()
        }
        // Localized at creation time, like a document called "Untitled":
        // the name and notification copy become the user's data the moment
        // the rule is saved, so they should be born in the user's language.
        return AlertRule(
            id: id,
            name: String(localized: "New Rule"),
            metric: .cpuTotalPercent,
            comparison: .above,
            threshold: 90,
            sustainedFor: 60,
            cooldown: cooldown,
            actions: [
                .notification(
                    title: String(localized: "New Rule"),
                    body: String(localized: "Custom alert condition met."),
                    sound: false
                )
            ]
        )
    }

    /// The three IDs `AlertEngine` special-cases (see `RuleKind`), pulled
    /// into one set so `makeNewRule(cooldown:)` doesn't have to spell out
    /// three separate comparisons.
    private static let reservedRuleIDs: Set<AlertRule.ID> = [
        AlertEngine.chargingPausedRuleID,
        AlertEngine.slowChargingRuleID,
        AlertEngine.batteryHealthDropRuleID,
    ]

    private func removeSelectedRule() {
        guard let selected = selectedRuleID else { return }
        removeRules(ids: [selected])
    }

    private func removeRules(ids: Set<AlertRule.ID>) {
        guard !ids.isEmpty else { return }
        store.settings.alertRules.removeAll { ids.contains($0.id) }
        if let selected = selectedRuleID, ids.contains(selected) {
            selectedRuleID = nil
        }
    }

    /// Replaces the rule set wholesale, rebuilt at the user's *current*
    /// cooldown setting rather than `AppSettings.defaultAlertRules`' baked-in
    /// 30 minutes — `AlertRule`'s doc comment asks for exactly this: the
    /// cooldown setting takes effect the next time defaults are rebuilt.
    private func restoreDefaultRules() {
        store.settings.alertRules = AlertEngine.defaultRules(
            cooldown: TimeInterval(store.settings.alertCooldownMinutes * 60)
        )
        selectedRuleID = nil
    }

    /// Deep-links to Sentry's own Notifications settings screen. This file
    /// doesn't reuse `SentryKit/Insights`' `SystemSettingsLink` (an
    /// Insights-owned type this task's brief marks out of scope) — the URL
    /// lives here instead, same "own the constant you need rather than reach
    /// into a file you're not supposed to touch" call the rest of this pane
    /// already makes for its own concerns. `x-apple.systempreferences:`
    /// URLs are an undocumented, Apple-can-change-them-anytime scheme, so a
    /// failed `open(_:)` is swallowed rather than surfaced with a second
    /// banner — the banner itself, and its System-Settings-app-launches
    /// System-Settings intent, already communicate the actionable part
    /// ("go turn this on"); a broken deep link degrading to "the button did
    /// nothing" is a worse failure mode than a partially-useful one, but not
    /// one worth a second layer of error UI for a single button.
    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Right column: rule inspector

    private var inspectorColumn: some View {
        Form {
            if let binding = selectedRuleBinding() {
                // Keyed on the selected id for the same reason `MenuBarPane`
                // does it: the `TextField`s below commit on blur, so reusing
                // one editor across a selection change would land text typed
                // for rule A onto rule B.
                ruleInspector(binding)
                    .id(binding.wrappedValue.id)
            } else {
                Section("Rule") {
                    Text("Select a rule on the left to edit when it fires.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            globalLimitsSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func ruleInspector(_ rule: Binding<AlertRule>) -> some View {
        let kind = RuleKind(rule: rule.wrappedValue)

        Section("Rule") {
            TextField("Name", text: rule.name)
                .accessibilityLabel("Rule name")
            if Self.enableAffordanceWithheld(for: rule.wrappedValue, processMatchUnlocked: processMatchUnlocked) {
                // Same withheld-enable treatment as the rule list's checkbox
                // — see `ruleRow`. The row stays (the rule is the user's own
                // data) but the one thing a toggle here could do is part of
                // Sentry Pro.
                LabeledContent {
                    Text("Part of Sentry Pro")
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Enabled", systemImage: "lock.fill")
                }
                .accessibilityLabel("Enabling this rule requires Sentry Pro")
            } else {
                Toggle("Enabled", isOn: inspectorEnabledBinding(rule))
                    .accessibilityLabel("Rule enabled")
            }
        }

        conditionSection(rule, kind: kind)

        Section {
            durationField(
                title: "Must hold for",
                seconds: rule.sustainedFor,
                accessibilityLabel: "Seconds the condition must hold before firing"
            )
            durationField(
                title: "Cooldown",
                seconds: rule.cooldown,
                accessibilityLabel: "Seconds between repeat firings of this rule"
            )
        } header: {
            Text("Timing")
        } footer: {
            Text("“Must hold for” suppresses flapping — a metric bouncing across the threshold resets the timer instead of firing. “Cooldown” is the minimum gap between two firings of this rule once it has fired. They are independent: satisfying one does not substitute for the other.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        quietHoursSection(rule)
        preconditionSection(rule)
        actionsSection(rule)
    }

    /// The condition half of the editor. Three of the shipped rules are
    /// evaluated by `AlertEngine` from IDs it special-cases, not from the
    /// metric/comparison/threshold stored on the rule — see `RuleKind`. For
    /// those, showing editable fields the engine will never read would be a
    /// straightforward lie about what the app does, so the fields that don't
    /// apply are replaced by an explanation of what the rule actually
    /// measures.
    @ViewBuilder
    private func conditionSection(_ rule: Binding<AlertRule>, kind: RuleKind) -> some View {
        Section {
            // Honest lock disclosure for a pre-existing process rule while
            // the entitlement is locked (typically a lapse, or a hand-edited
            // settings file) — same why-isn't-this-firing duty as the DND
            // and denied-notifications banners at the top of the pane.
            if kind == .processMatch && !processMatchUnlocked {
                Label {
                    Text("Part of Sentry Pro — not being evaluated")
                        .font(.callout)
                } icon: {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                }
            }

            // Only offered for the two rule kinds that reduce to an
            // editable metric/comparison/threshold in the first place — the
            // three ID-special-cased kinds have nothing this toggle could
            // meaningfully apply to (see their `notApplicableNote`s below).
            //
            // Entitlement split: converting a generic rule *into* a process
            // rule is part of Sentry Pro, so on a locked copy the generic
            // kind gets a locked row rather than the toggle — withheld, not
            // constructed-and-dead. An existing process rule keeps the
            // toggle even while locked, because its one reachable direction
            // is *off* — converting back to an ordinary free rule is an
            // escape hatch, and those are never gated.
            if kind == .processMatch || (kind == .generic && processMatchUnlocked) {
                Toggle("Watch a specific process", isOn: processMatchEnabledBinding(rule))
                    .accessibilityLabel("Limit this rule to a specific process by name, rather than a system-wide metric")
            } else if kind == .generic {
                LabeledContent {
                    Text("Part of Sentry Pro")
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Watch a specific process", systemImage: "lock.fill")
                }
                .accessibilityLabel("Watching a specific process requires Sentry Pro")
            }

            switch kind {
            case .generic:
                Picker("Metric", selection: rule.metric) {
                    ForEach(MetricID.allCases, id: \.self) { metric in
                        Text(metric.shortLabel).tag(metric)
                    }
                }
                .accessibilityLabel("Metric this rule watches")

                // Bound through `ComparisonKind` rather than directly:
                // `AlertRule.Comparison` is `Equatable` but not `Hashable`,
                // and a `Picker` tag has to be `Hashable`. Adding the
                // conformance to a SentryKit type this pane doesn't own,
                // purely to satisfy one picker, is the wrong direction.
                Picker("Comparison", selection: comparisonKindBinding(rule)) {
                    ForEach(ComparisonKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .accessibilityLabel("Comparison")

                thresholdField(rule, label: "Threshold")

            case .processMatch:
                // The whole editor, disabled as a group while locked: the
                // stored values stay visible (they're the user's own data,
                // never withheld), but a field that edits a rule the engine
                // is refusing to evaluate would be a control whose change
                // appears to take and can't matter — the same reasoning
                // `GeneralPane` gives for disabling the automatic-update
                // toggle while the signing key is a placeholder. The
                // toggle above stays live so the rule can still be converted
                // back to a free generic rule.
                Group {
                    TextField("Process name", text: processNameBinding(rule))
                        .accessibilityLabel("Process name to match, case-insensitive")

                    // Deliberately not the full `MetricID.allCases` picker
                    // `.generic` shows above — `AlertEngine.evaluateProcessRule`
                    // only ever reads `.cpuTotalPercent`/`.memoryUsedBytes` for
                    // a process rule, so offering the other ~40 values would
                    // let a user "select" a metric that silently has no effect.
                    Picker("Metric", selection: processMetricBinding(rule)) {
                        ForEach(ProcessMetricKind.allCases, id: \.self) { processMetric in
                            Text(processMetric.displayName).tag(processMetric)
                        }
                    }
                    .accessibilityLabel("Which of this process's metrics to watch")

                    // `.changedBy` has no meaningful baseline for a process rule
                    // (see `AlertEngine.evaluateProcessRule`'s doc comment) —
                    // excluded here rather than offered and silently evaluating
                    // to always-false.
                    Picker("Comparison", selection: comparisonKindBinding(rule)) {
                        ForEach(ComparisonKind.allCases.filter { $0 != .changedBy }, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .accessibilityLabel("Comparison")

                    thresholdField(rule, label: "Threshold")
                }
                .disabled(!processMatchUnlocked)

            case .batteryHealthDrop:
                // The one special-cased rule whose `threshold` *is* read
                // (as a percentage-point drop from the observed baseline);
                // only its metric and comparison are ignored.
                thresholdField(rule, label: "Drop of at least")

            case .chargingPaused, .slowCharging:
                LabeledContent("Condition") {
                    Text(kind.fixedConditionSummary ?? "")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Text("Condition")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if kind == .processMatch,
                   let lockedNote = Self.lockedConditionFooter(kind: kind, processMatchUnlocked: processMatchUnlocked) {
                    // For a locked process rule the paywall sentence
                    // *replaces* `notApplicableNote`'s matching-semantics
                    // explanation: describing how a rule matches, without
                    // first saying it isn't being evaluated at all, buries
                    // the one fact the user came here for.
                    Text(lockedNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let note = kind.notApplicableNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Fires when \(rule.wrappedValue.metric.shortLabel) is \(ComparisonKind(comparison: rule.wrappedValue.comparison).phrase) \(Self.detailedThreshold(rule.wrappedValue.threshold, unit: rule.wrappedValue.metric.unit)). “Above” and “below” are inclusive (≥ and ≤).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // A locked *generic* rule is different: the rule itself
                // stays free and evaluated, so its real firing sentence
                // above must survive — the paywall sentence for the
                // withheld toggle is appended, not substituted.
                if kind == .generic,
                   let lockedNote = Self.lockedConditionFooter(kind: kind, processMatchUnlocked: processMatchUnlocked) {
                    Text(lockedNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// **Why byte-scale thresholds don't edit in raw bytes.** They used to:
    /// the field showed the stored value verbatim (e.g. `10000000000`
    /// alongside a "bytes" unit label), while every prose description of
    /// the same threshold — this section's footer, the row's condition
    /// summary — ran it through `MetricFormatter.detailed`, which divides
    /// by 1024³ and prints "9.31 GB". Both numbers were defensible on their
    /// own; showing both for the same stored value was not. Byte-scale
    /// units edit in GB here (`Self.gbValue`/`Self.bytes(fromGB:)`) and the
    /// prose helpers (`detailedThreshold`) use that exact same conversion,
    /// so the editor and the sentence describing it always agree.
    private func thresholdField(_ rule: Binding<AlertRule>, label: String) -> some View {
        let unit = rule.wrappedValue.metric.unit
        let isByteScale = unit == .bytes || unit == .bytesPerSecond

        return LabeledContent(label) {
            HStack(spacing: 4) {
                if isByteScale {
                    TextField(label, value: byteScaleThresholdBinding(rule), format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden()
                        .frame(width: 110)
                        .accessibilityLabel("\(label) value in gigabytes")
                } else if unit == .celsius {
                    TextField(label, value: temperatureThresholdBinding(rule), format: .number)
                        .labelsHidden()
                        .frame(width: 110)
                        .accessibilityLabel("\(label) value in \(TemperatureUnit.display.spokenSuffix)")
                } else {
                    TextField(label, value: rule.threshold, format: .number)
                        .labelsHidden()
                        .frame(width: 110)
                        .accessibilityLabel("\(label) value")
                }
                Text(Self.thresholdUnitLabel(unit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Bridges the stored Celsius threshold to whatever unit the user reads
    /// in — exactly the same arrangement, and for exactly the same reason,
    /// as `byteScaleThresholdBinding` below.
    ///
    /// **This one is not optional the way the byte case was.** The unit
    /// label beside the field, this section's footer sentence, and the
    /// rule row's condition summary all render through
    /// `MetricFormatter.detailed`, which follows the display preference; a
    /// field left editing raw Celsius would sit under a label reading "°F"
    /// showing "95" — and typing the 203 that label invites would store a
    /// 203 °C threshold no Mac will ever reach, silently disabling the
    /// alert. Converting on the way in and back out is what keeps the
    /// number the user types and the number the engine compares the same
    /// physical temperature.
    ///
    /// `AlertRule.threshold` itself is never stored in Fahrenheit. The
    /// engine, `alert_log`, and every `AlertRule` on the sync wire keep
    /// working in Celsius unchanged.
    private func temperatureThresholdBinding(_ rule: Binding<AlertRule>) -> Binding<Double> {
        Binding(
            get: {
                let unit = TemperatureUnit.display
                // Rounded to a tenth on the way out: 95 °C is 203.00000000000003 °F
                // in binary floating point, and a threshold field is not the
                // place to show that. The stored Celsius value is untouched
                // unless the user actually edits the field.
                return (unit.value(fromCelsius: rule.wrappedValue.threshold) * 10).rounded() / 10
            },
            set: { rule.wrappedValue.threshold = TemperatureUnit.display.celsiusValue(from: $0) }
        )
    }

    /// Bridges the stored byte threshold to the GB number the field above
    /// actually shows and edits. `AlertRule.threshold` itself is never
    /// stored in GB — only this editor's *presentation* of a byte-scale
    /// threshold is — so every other reader of `threshold` (the engine,
    /// history) keeps working in raw bytes unchanged.
    private func byteScaleThresholdBinding(_ rule: Binding<AlertRule>) -> Binding<Double> {
        Binding(
            get: { Self.gbValue(fromBytes: rule.wrappedValue.threshold) },
            set: { rule.wrappedValue.threshold = Self.bytes(fromGB: $0) }
        )
    }

    /// Durations are stored as `TimeInterval` seconds. Edited in seconds
    /// rather than a minutes/seconds pair because the shipped rules span 0 s
    /// to 300 s and a minutes control would either round "30 seconds" away or
    /// need a unit picker for no gain; the caption spells out long values in
    /// minutes so a 300 doesn't have to be divided in the user's head.
    private func durationField(
        title: String,
        seconds: Binding<TimeInterval>,
        accessibilityLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title) {
                HStack(spacing: 4) {
                    TextField(title, value: seconds, format: .number)
                        .labelsHidden()
                        .frame(width: 110)
                        .accessibilityLabel(accessibilityLabel)
                    Text("s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(Self.humanDuration(seconds.wrappedValue))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func quietHoursSection(_ rule: Binding<AlertRule>) -> some View {
        Section {
            Toggle("Mute during quiet hours", isOn: quietHoursEnabledBinding(rule))
                .accessibilityLabel("Mute this rule during quiet hours")

            if let quietHours = rule.wrappedValue.quietHours {
                Picker("From", selection: quietHourBinding(rule, isStart: true)) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(Self.hourLabel(hour)).tag(hour)
                    }
                }
                .accessibilityLabel("Quiet hours start")

                Picker("Until", selection: quietHourBinding(rule, isStart: false)) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(Self.hourLabel(hour)).tag(hour)
                    }
                }
                .accessibilityLabel("Quiet hours end")

                if quietHours.startHour == quietHours.endHour {
                    // `QuietHours.contains(hour:)` treats an equal start/end
                    // as a zero-width window, i.e. no muting at all. That is
                    // the safer reading of an ambiguous value, but it is not
                    // what a user setting both to 23 expects, so say so.
                    Label(
                        "A matching start and end mutes nothing. Pick different hours, or turn quiet hours off.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Quiet Hours")
        } footer: {
            Text("Inside the window this rule does not fire at all — and its cooldown is not consumed, so it can fire promptly once the window ends. An end hour earlier than the start wraps past midnight.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func preconditionSection(_ rule: Binding<AlertRule>) -> some View {
        let selected = rule.wrappedValue.onlyWhen

        Section {
            ForEach(PreconditionKind.allCases, id: \.self) { kind in
                Toggle(kind.displayName, isOn: preconditionBinding(rule, kind.precondition))
                    .accessibilityLabel("Only when \(kind.displayName)")
            }

            if selected.contains(.onBattery) && selected.contains(.charging) {
                // Preconditions are AND'd, and these two are mutually
                // exclusive by construction, so this combination is a rule
                // that provably never fires.
                Label(
                    "“On battery” and “Charging” can't both be true, so this rule will never fire.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if selected.contains(.displayAsleep) {
                Label(
                    "Sentry has no display-sleep signal yet, so this condition is always false and this rule will never fire.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Only When")
        } footer: {
            Text("All checked conditions must hold at once. With none checked the rule is always eligible.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func actionsSection(_ rule: Binding<AlertRule>) -> some View {
        // `.pushToPhone` is filtered from display: the feature was cut
        // before any delivery path existed, and a rule editor row for an
        // action that can't act is the inert-control shape this pane
        // refuses. Rules persisted by earlier builds may still carry the
        // action (see `AlertAction.pushToPhone`'s doc comment for why the
        // case survives decode) — only the row is hidden.
        let visibleActions = rule.wrappedValue.actions.filter { $0 != .pushToPhone }
        Section {
            if visibleActions.isEmpty {
                Text("This rule has no actions and will only be recorded in history.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(visibleActions.enumerated()), id: \.offset) { _, action in
                    LabeledContent(Self.actionTitle(action)) {
                        Text(Self.actionDetail(action))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        } header: {
            Text("Actions")
        } footer: {
            Text("Actions aren't editable yet. Every firing is still written to history regardless.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Points at the Advanced pane instead of duplicating the two
    /// anti-spam controls (plan §11.3). `AdvancedPane` already owns
    /// `notificationRateCapPerHour` and `alertCooldownMinutes`, and two live
    /// editors for the same stored value in one window is how a user ends up
    /// unsure which one won.
    private var globalLimitsSection: some View {
        Section {
            LabeledContent("Do Not Disturb", value: store.settings.doNotDisturb ? String(localized: "On") : String(localized: "Off"))
            LabeledContent("Notification cap", value: String(localized: "\(String(store.settings.notificationRateCapPerHour)) per hour"))
            LabeledContent("Default cooldown for new rules", value: String(localized: "\(String(store.settings.alertCooldownMinutes)) min"))
        } header: {
            Text("Global Limits")
        } footer: {
            Text("Change these in the Advanced pane. The cap applies across every rule combined: once it's reached, further firings are still recorded in History and marked Suppressed rather than silently dropped. Do Not Disturb is a full mute instead of a cap — while it's on, nothing fires and nothing is recorded, the same as a rule's own quiet hours.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - History (plan §11.3)

    /// Whether history can actually be read — which is *not* the same as
    /// "a `HistoryStore` was injected."
    ///
    /// `HistoryStore` is deliberately failure-tolerant: if the database can't
    /// be opened it keeps working with a nil `databaseQueue` and every read
    /// returns `[]` rather than throwing. So checking `historyStore == nil`
    /// alone (the app always injects one) meant a genuinely broken database
    /// rendered as "No alerts have fired yet." — a confident claim that
    /// nothing happened, which is precisely the misreading the unavailable
    /// state exists to prevent.
    private var historyIsAvailable: Bool {
        historyStore?.databaseQueue != nil
    }

    private var historyColumn: some View {
        VStack(spacing: 0) {
            if !historyIsAvailable {
                message("Alert history isn't available — Sentry couldn't open its history database. Alerts still fire; they just aren't being recorded.")
            } else if historyEntries.isEmpty {
                message("No alerts have fired yet.")
            } else {
                // Keyed by position, not by content: `AlertLogEntry` has no
                // row id and is only `Equatable`, and two firings of the
                // same rule in the same second are legitimately identical
                // values that must still render as two rows.
                List(Array(historyEntries.enumerated()), id: \.offset) { _, entry in
                    historyRow(entry)
                }
                .accessibilityLabel("Alert history, most recent first")
            }

            Divider()

            HStack {
                Text(historySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    loadHistory()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!historyIsAvailable)
                .accessibilityLabel("Reload alert history")
            }
            .padding(8)
        }
        // Loaded on every appearance and on demand, rather than observed
        // live: `HistoryStore` publishes no change notification, and polling
        // SQLite from a settings window that's usually closed would burn
        // exactly the battery this app exists to measure. Re-reading on each
        // switch into this mode is one bounded `LIMIT 200` query and keeps
        // the pane from showing a snapshot from whenever the window was last
        // opened — which, since `MainWindowController` deliberately reuses
        // its window (and this pane's view tree) forever, could be days ago.
        .onAppear { loadHistory() }
    }

    private func message(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var historySummary: String {
        guard historyStore != nil else { return String(localized: "History unavailable") }
        let suppressed = historyEntries.filter(\.suppressed).count
        // Counts are pre-formatted to `String` so the catalog keys carry
        // plain `%@` placeholders — the shape every other interpolated key
        // in this catalog already uses (see `ProUpsellCard`'s `totalText`).
        let countText = String(historyEntries.count)
        if suppressed == 0 {
            return String(localized: "\(countText) recent firings")
        }
        let suppressedText = String(suppressed)
        return String(localized: "\(countText) recent firings, \(suppressedText) suppressed by the hourly cap")
    }

    private func historyRow(_ entry: AlertLogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.ruleName.isEmpty ? String(localized: "(unnamed rule)") : entry.ruleName)
                Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(Self.historyValueText(entry))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            // Suppressed rows are the whole point of logging a capped
            // firing (see `AlertEngine`'s rate-cap doc comment), so they get
            // a label rather than being dimmed or filtered out. §9.4: the
            // word carries the meaning, not the color.
            if entry.suppressed {
                Label("Suppressed", systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
            } else if entry.delivered {
                Label("Delivered", systemImage: "bell")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            // The delivery fragment is localized on its own: inside a string
            // interpolation a bare literal is a plain `String`, so the
            // ternary would otherwise splice untranslated English into an
            // otherwise localized VoiceOver sentence.
            "\(entry.ruleName), \(entry.timestamp.formatted(date: .abbreviated, time: .standard)), \(Self.historyValueText(entry)), \(entry.suppressed ? String(localized: "suppressed by the hourly cap") : String(localized: "delivered"))"
        )
    }

    private func loadHistory() {
        historyEntries = historyStore?.recentAlertFirings(limit: 200) ?? []
    }

    /// Renders the logged value in its metric's own unit. The
    /// charging-paused rule is the one row where the stored `metric` is a
    /// placeholder `AlertEngine` never reads (`AlertRule`'s doc comment
    /// calls this out): its logged value is the decoded `NotChargingReason`
    /// code, so formatting it as a battery percentage would print a
    /// confident, wrong "1%".
    static func historyValueText(_ entry: AlertLogEntry) -> String {
        if entry.ruleID == AlertEngine.chargingPausedRuleID {
            let codeText = String(Int(entry.value))
            return String(localized: "reason code \(codeText)")
        }
        guard let metric = MetricID(rawValue: entry.metric) else {
            // A rule whose metric this build doesn't recognize (older or
            // newer settings file) — show the raw number rather than
            // dropping the row.
            return String(format: "%g", entry.value)
        }
        return MetricFormatter.detailed(entry.value, unit: metric.unit)
    }

    // MARK: - Bindings

    /// Resolved by id on every access rather than by cached index, so a
    /// removal underneath the inspector can't write into the wrong rule.
    private func selectedRuleBinding() -> Binding<AlertRule>? {
        guard
            let id = selectedRuleID,
            let current = store.settings.alertRules.first(where: { $0.id == id })
        else { return nil }

        return Binding(
            get: {
                store.settings.alertRules.first(where: { $0.id == id }) ?? current
            },
            set: { newValue in
                guard let index = store.settings.alertRules.firstIndex(where: { $0.id == id }) else { return }
                store.settings.alertRules[index] = newValue
            }
        )
    }

    private func enabledBinding(for id: AlertRule.ID) -> Binding<Bool> {
        Binding(
            get: { store.settings.alertRules.first(where: { $0.id == id })?.isEnabled ?? false },
            set: { isOn in
                guard let index = store.settings.alertRules.firstIndex(where: { $0.id == id }) else { return }
                // Stale-frame guard behind the withheld checkbox (`ruleRow`):
                // enabling a process rule is part of Sentry Pro. Disabling
                // is never gated — it's the escape hatch. Routed through
                // `RuleKind` (not a raw `processNameMatch` check) so the
                // gate covers exactly the rules the engine's own gate
                // covers — a reserved-ID rule is evaluated by ID, ungated,
                // and must stay enableable.
                if isOn,
                   RuleKind(rule: store.settings.alertRules[index]) == .processMatch,
                   !processMatchUnlocked {
                    return
                }
                store.settings.alertRules[index].isEnabled = isOn
            }
        )
    }

    /// The inspector's "Enabled" toggle — same entitlement guard as
    /// `enabledBinding(for:)`, expressed against the already-resolved rule
    /// binding the inspector holds.
    private func inspectorEnabledBinding(_ rule: Binding<AlertRule>) -> Binding<Bool> {
        Binding(
            get: { rule.wrappedValue.isEnabled },
            set: { isOn in
                if isOn,
                   RuleKind(rule: rule.wrappedValue) == .processMatch,
                   !processMatchUnlocked {
                    return
                }
                rule.wrappedValue.isEnabled = isOn
            }
        )
    }

    private func comparisonKindBinding(_ rule: Binding<AlertRule>) -> Binding<ComparisonKind> {
        Binding(
            get: { ComparisonKind(comparison: rule.wrappedValue.comparison) },
            set: { rule.wrappedValue.comparison = $0.comparison }
        )
    }

    /// Drives the "Watch a specific process" toggle: turning it on switches
    /// `RuleKind(rule:)`'s derivation from `.generic` to `.processMatch` by
    /// setting `processNameMatch` to a (still-empty, user fills it in next)
    /// string; turning it off clears it back to nil. Also snaps `metric` to
    /// `.cpuTotalPercent` and `comparison` off of `.changedBy` when turning
    /// on — a metric like `.batteryChargePercent` or a `.changedBy`
    /// comparison carried over from a generic rule would be meaningless
    /// (and, for `.changedBy`, silently always-false — see
    /// `AlertEngine.evaluateProcessRule`'s doc comment) the instant this
    /// rule becomes process-scoped, so the switch lands on values that are
    /// actually valid for the new kind rather than a technically-decodable
    /// but nonsensical combination.
    private func processMatchEnabledBinding(_ rule: Binding<AlertRule>) -> Binding<Bool> {
        Binding(
            get: { rule.wrappedValue.processNameMatch != nil },
            set: { isOn in
                if isOn {
                    // The single generic→process conversion site in the app,
                    // so the entitlement is re-checked here even though the
                    // toggle isn't constructed for a locked generic rule —
                    // a stale frame must not be able to convert. The `else`
                    // branch (converting back to generic) is deliberately
                    // unguarded: it's the escape hatch.
                    guard processMatchUnlocked else { return }
                    rule.wrappedValue.processNameMatch = rule.wrappedValue.processNameMatch ?? ""
                    if ProcessMetricKind.allCases.map(\.metricID).contains(rule.wrappedValue.metric) == false {
                        rule.wrappedValue.metric = .cpuTotalPercent
                    }
                    if rule.wrappedValue.comparison == .changedBy {
                        rule.wrappedValue.comparison = .above
                    }
                } else {
                    rule.wrappedValue.processNameMatch = nil
                }
            }
        )
    }

    private func processNameBinding(_ rule: Binding<AlertRule>) -> Binding<String> {
        Binding(
            get: { rule.wrappedValue.processNameMatch ?? "" },
            set: { rule.wrappedValue.processNameMatch = $0 }
        )
    }

    private func processMetricBinding(_ rule: Binding<AlertRule>) -> Binding<ProcessMetricKind> {
        Binding(
            get: { ProcessMetricKind(metric: rule.wrappedValue.metric) },
            set: { rule.wrappedValue.metric = $0.metricID }
        )
    }

    private func quietHoursEnabledBinding(_ rule: Binding<AlertRule>) -> Binding<Bool> {
        Binding(
            get: { rule.wrappedValue.quietHours != nil },
            set: { isOn in
                // Nothing is remembered on disable: re-enabling restores the
                // plan's own 23:00–08:00 example rather than a stale window
                // the user can no longer see. Same choice `MenuBarPane`
                // makes for its max-width toggle.
                rule.wrappedValue.quietHours = isOn
                    ? AlertRule.QuietHours(startHour: 23, endHour: 8)
                    : nil
            }
        )
    }

    private func quietHourBinding(_ rule: Binding<AlertRule>, isStart: Bool) -> Binding<Int> {
        Binding(
            get: {
                guard let quietHours = rule.wrappedValue.quietHours else { return isStart ? 23 : 8 }
                return isStart ? quietHours.startHour : quietHours.endHour
            },
            set: { newValue in
                guard let quietHours = rule.wrappedValue.quietHours else { return }
                rule.wrappedValue.quietHours = AlertRule.QuietHours(
                    startHour: isStart ? newValue : quietHours.startHour,
                    endHour: isStart ? quietHours.endHour : newValue
                )
            }
        )
    }

    private func preconditionBinding(
        _ rule: Binding<AlertRule>,
        _ precondition: AlertRule.Precondition
    ) -> Binding<Bool> {
        Binding(
            get: { rule.wrappedValue.onlyWhen.contains(precondition) },
            set: { isOn in
                var preconditions = rule.wrappedValue.onlyWhen
                if isOn {
                    guard !preconditions.contains(precondition) else { return }
                    preconditions.append(precondition)
                } else {
                    preconditions.removeAll { $0 == precondition }
                }
                rule.wrappedValue.onlyWhen = preconditions
            }
        )
    }

    // MARK: - Display helpers

    static func conditionSummary(for rule: AlertRule) -> String {
        let kind = RuleKind(rule: rule)
        switch kind {
        case .chargingPaused, .slowCharging:
            return kind.fixedConditionSummary ?? ""
        case .batteryHealthDrop:
            return String(localized: "Health drops by \(MetricFormatter.detailed(rule.threshold, unit: .percent)) or more")
        case .processMatch:
            let name = (rule.processNameMatch?.isEmpty == false) ? rule.processNameMatch! : String(localized: "(no process set)")
            let comparison = ComparisonKind(comparison: rule.comparison).phrase
            // Same "not `String(localized:)`" reasoning as `.generic` below
            // — every segment is already independently localized at its
            // source (the process name is user data, not UI copy).
            return "\(name) \(rule.metric.shortLabel) \(comparison) \(Self.detailedThreshold(rule.threshold, unit: rule.metric.unit))"
        case .generic:
            let comparison = ComparisonKind(comparison: rule.comparison).phrase
            // Deliberately NOT `String(localized:)` (l10n audit): every
            // segment is an interpolation, so the extracted key would be the
            // meaningless "%@ %@ %@" — nothing for a translator to work
            // with. The pieces are localized at their sources instead
            // (`shortLabel`, `phrase`), matching `AlertRuleDisplay
            // .conditionSummary`'s documented reasoning on the iOS side.
            return "\(rule.metric.shortLabel) \(comparison) \(Self.detailedThreshold(rule.threshold, unit: rule.metric.unit))"
        }
    }

    // MARK: - Process-match lock state (ProFeature.processMatchAlerts)

    /// True when a row's enable control would be an inert affordance: the
    /// rule is process-scoped, this copy isn't entitled, and the rule is
    /// currently disabled — so the only thing the control could do (enable)
    /// is part of Sentry Pro. While the rule is still *enabled* the control
    /// stays, because disabling must always work: escape hatches survive a
    /// lapsed license. Static and view-state-free so
    /// `AlertsPaneFormattingTests` can pin the truth table.
    static func enableAffordanceWithheld(for rule: AlertRule, processMatchUnlocked: Bool) -> Bool {
        guard !processMatchUnlocked else { return false }
        guard RuleKind(rule: rule) == .processMatch else { return false }
        return !rule.isEnabled
    }

    /// The condition section's footer while the process-match entitlement
    /// is locked, or nil when the standard footers apply. Two different
    /// sentences for the same reason `ThemeEditingGate` keeps
    /// `lockedAffordanceLabel` and `lockedExistingThemesNote` apart: "you
    /// can't create one" and "the one you have isn't running" are different
    /// facts. Both follow the honest-copy
    /// rules `ProUpsellCard` set: Sentry Pro is named plainly, no Buy
    /// button exists anywhere (checkout hasn't opened), and the
    /// existing-rule sentence spells out the lapse semantics
    /// (`AlertEngine.processRulesUnlocked`'s contract) and the ungated way
    /// out.
    static func lockedConditionFooter(kind: RuleKind, processMatchUnlocked: Bool) -> String? {
        guard !processMatchUnlocked else { return nil }
        switch kind {
        case .generic:
            return String(localized: "Watching a specific process — alerting on what a named app is doing rather than on a system-wide metric — is part of Sentry Pro. It's shown rather than hidden so you can see what the feature offers. Everything else about this rule stays free; purchasing isn't available yet because Sentry's license checkout hasn't opened.")
        case .processMatch:
            return String(localized: "This rule isn't being evaluated: watching a specific process is part of Sentry Pro. Nothing fires, nothing is recorded, and its cooldown isn't consumed — but the rule and every setting on it are kept exactly as they are, and it starts evaluating again, with a fresh “must hold for” window, the moment this copy is unlocked. Turning “Watch a specific process” off converts it back to an ordinary rule, which stays free.")
        case .chargingPaused, .slowCharging, .batteryHealthDrop:
            // The three ID-special-cased kinds have no process dimension —
            // their `notApplicableNote`s keep the footer.
            return nil
        }
    }

    /// Spells a raw second count out in the units a person would say it in.
    /// Kept `static` and free of view state so the pane's arithmetic is
    /// testable without a view hierarchy.
    static func humanDuration(_ seconds: TimeInterval) -> String {
        // A hand-edited settings file can hold a negative interval; treat it
        // as "immediately" rather than printing "-30 seconds".
        guard seconds > 0 else { return String(localized: "Fires immediately") }
        // Whole localized sentences per plural branch, not a spliced "s"
        // suffix — suffix-gluing is untranslatable in languages whose
        // plurals don't work that way, and explicit branches are the plural
        // style this codebase already uses (see `InsightsView`'s hidden-
        // findings caption).
        if seconds < 60 {
            let valueText = Self.trimmed(seconds)
            return seconds == 1
                ? String(localized: "1 second")
                : String(localized: "\(valueText) seconds")
        }
        let minutes = seconds / 60
        if minutes < 60 {
            let valueText = Self.trimmed(minutes)
            return minutes == 1
                ? String(localized: "1 minute")
                : String(localized: "\(valueText) minutes")
        }
        let hours = minutes / 60
        let valueText = Self.trimmed(hours)
        return hours == 1
            ? String(localized: "1 hour")
            : String(localized: "\(valueText) hours")
    }

    /// "1.5" but "30", not "30.0".
    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// Unit suffix for a bare numeric entry field. `MetricUnit.suffix` is
    /// deliberately empty for byte-scale units (its formatter emits "1.2 GB"
    /// itself, and "1.2 GB B" would be nonsense) — but a raw `TextField`
    /// holding `10000000000` has no formatter and desperately needs the word.
    static func unitLabel(_ unit: MetricUnit) -> String {
        switch unit {
        case .bytes: return String(localized: "bytes")
        case .bytesPerSecond: return String(localized: "bytes/s")
        case .boolean: return String(localized: "0 or 1")
        case .thermalLevel: return String(localized: "0–3")
        case .count, .decimal: return ""
        // `MetricUnit.suffix` is a hard "°C" and stays that way — it
        // describes the unit a *stored* value is in. This label sits beside
        // a field the user reads and types in, so it follows the display
        // preference instead. See `TemperatureUnit.suffix`.
        case .celsius: return TemperatureUnit.display.suffix
        default: return unit.suffix
        }
    }

    /// The 1024-based bytes-per-GB conversion the threshold editor and its
    /// prose descriptions share — see `thresholdField`'s doc comment.
    /// Matches `ByteCountFormatter`'s `.memory` count style (what
    /// `MetricFormatter` uses for byte-scale live readings), not the
    /// decimal-1000 `.file` style, so a rule edited here and a live reading
    /// of the same metric elsewhere in the app scale the same way.
    private static let bytesPerGB: Double = 1024 * 1024 * 1024

    /// Raw bytes → the GB number the threshold editor shows.
    static func gbValue(fromBytes bytes: Double) -> Double {
        bytes / bytesPerGB
    }

    /// The GB number typed into the threshold editor → raw bytes to store.
    static func bytes(fromGB value: Double) -> Double {
        value * bytesPerGB
    }

    /// Unit suffix for the threshold editor specifically — distinct from
    /// `unitLabel(_:)`, which still describes the *stored* unit (used by
    /// history rows, which render an actually-observed value, not a
    /// threshold a user is editing). Byte-scale units are edited in GB
    /// (`gbValue`/`bytes(fromGB:)`), so this reads "GB"/"GB/s" here instead
    /// of `unitLabel`'s "bytes"/"bytes/s".
    static func thresholdUnitLabel(_ unit: MetricUnit) -> String {
        switch unit {
        case .bytes: return "GB"
        case .bytesPerSecond: return "GB/s"
        default: return unitLabel(unit)
        }
    }

    /// Formats a threshold for prose (the condition footer, a row's
    /// condition summary) so it always agrees with what `thresholdField`
    /// shows for the same stored value. Byte-scale units can't delegate to
    /// `MetricFormatter.detailed` here: its `ByteCountFormatter` picks
    /// KB/MB/GB/TB adaptively based on magnitude, which is correct for a
    /// live reading but would silently disagree with the threshold editor's
    /// fixed GB field the moment a stored value crossed one of those
    /// adaptive boundaries.
    static func detailedThreshold(_ value: Double, unit: MetricUnit) -> String {
        switch unit {
        case .bytes, .bytesPerSecond:
            return "\(trimmedDecimal(gbValue(fromBytes: value))) \(thresholdUnitLabel(unit))"
        default:
            return MetricFormatter.detailed(value, unit: unit)
        }
    }

    /// "9.31" but "10", not "10.00" — same trimming idea as `trimmed(_:)`
    /// above, with two fraction digits instead of one since a GB-scale
    /// threshold needs finer precision than a duration spelled out in
    /// minutes/hours does.
    private static func trimmedDecimal(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.2f", rounded)
    }

    static func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    static func actionTitle(_ action: AlertAction) -> String {
        switch action {
        case .notification: return String(localized: "Notification")
        case .menuBarHighlight: return String(localized: "Menu bar highlight")
        case .pushToPhone: return String(localized: "Push to iPhone")
        case .runShortcut: return String(localized: "Run Shortcut")
        case .releaseSleepAssertion: return String(localized: "Allow sleep")
        case .logOnly: return String(localized: "Record only")
        }
    }

    /// The detail column doubles as the honesty column. `.pushToPhone`'s
    /// detail is unreachable while `actionsSection` filters that action out,
    /// but its case stays — the switch is exhaustive over a case that
    /// survives only for decode compatibility (see `AlertAction.pushToPhone`),
    /// and the text is honest should the filter ever be removed.
    static func actionDetail(_ action: AlertAction) -> String {
        switch action {
        case .notification(let title, _, let sound):
            return sound
                ? String(localized: "“\(title)”, with sound")
                : String(localized: "“\(title)”")
        case .menuBarHighlight(let token):
            return String(localized: "Token “\(token)”")
        case .pushToPhone:
            return String(localized: "Not delivered — this action remains from an earlier build")
        case .runShortcut(let name):
            return String(localized: "Runs “\(name)” in Shortcuts")
        case .releaseSleepAssertion:
            return String(localized: "Releases the keep-awake assertion")
        case .logOnly:
            return String(localized: "History only, no notification")
        }
    }
}

// MARK: - Rule kinds

/// Which of `AlertEngine`'s evaluation paths a rule takes, derived from its
/// `id` exactly the way the engine derives it.
///
/// This exists so the editor can't offer a field the engine will ignore. Three
/// shipped rules don't reduce to a metric-vs-threshold compare, and their
/// stored `metric`/`comparison` (and, for two of them, `threshold`) are
/// documented placeholders `AlertEngine` never reads. Leaving those fields
/// editable would let a user "fix" a rule by changing a number that has no
/// effect — the worst kind of settings UI, because the change appears to
/// take and the behavior never moves.
///
/// Derived from `id` rather than matched on rule *content* for the same
/// reason `AlertEngine` uses fixed UUIDs: renaming or retuning one of these
/// rules must not silently change which evaluator it gets.
enum RuleKind: Hashable {
    case generic
    case chargingPaused
    case slowCharging
    case batteryHealthDrop
    /// `AlertRule.processNameMatch` is set — a "watch this process" rule.
    /// Unlike the three cases above, this is never derived from a fixed
    /// `id` (there is no shipped default process rule to special-case — see
    /// `AlertEngine.defaultRules(cooldown:)`'s doc comment) and, unlike
    /// `.generic`, its `metric` field is meaningful but deliberately
    /// restricted to two values (`ProcessMetricKind`) rather than the full
    /// `MetricID.allCases` picker `.generic` shows.
    case processMatch

    /// Derived from the *whole rule*, not just `id`, because `.processMatch`
    /// can't be told apart from `.generic` any other way — it's a
    /// user-created rule with an ordinary (non-special-cased) `id` whose
    /// `processNameMatch` happens to be set. The three ID-special-cased
    /// kinds still take priority over content, same as before.
    init(rule: AlertRule) {
        switch rule.id {
        case AlertEngine.chargingPausedRuleID: self = .chargingPaused
        case AlertEngine.slowChargingRuleID: self = .slowCharging
        case AlertEngine.batteryHealthDropRuleID: self = .batteryHealthDrop
        default: self = rule.processNameMatch != nil ? .processMatch : .generic
        }
    }

    /// A plain-language description of what the engine actually measures, for
    /// the rules whose stored condition fields are placeholders.
    var fixedConditionSummary: String? {
        switch self {
        case .chargingPaused:
            return String(localized: "Plugged in but not charging, with a reason reported")
        case .slowCharging:
            return String(localized: "Charging below half the adapter's rated wattage")
        case .generic, .batteryHealthDrop, .processMatch:
            return nil
        }
    }

    var notApplicableNote: String? {
        switch self {
        case .chargingPaused:
            return String(localized: "This rule has no editable metric or threshold. It reads the reason macOS gives for pausing the charge (too hot, on-hold by Optimized Charging, and so on) and reports that text verbatim — there is no single number to compare against. Only its timing, quiet hours, and conditions below are editable.")
        case .slowCharging:
            return String(localized: "This rule has no editable metric or threshold. It compares the wattage actually reaching the battery against the connected adapter's rated wattage, which changes with whatever adapter is plugged in — a fixed number couldn't express it. Only its timing, quiet hours, and conditions below are editable.")
        case .batteryHealthDrop:
            return String(localized: "Fires when battery health falls by at least this many percentage points below the highest value seen since Sentry last launched. The metric and comparison aren't editable — this rule deliberately ignores health *increases*, which a generic comparison can't express. The baseline resets on relaunch, so this won't catch a drop that happened while Sentry was closed.")
        case .processMatch:
            return String(localized: "Matches by process name (case-insensitive) against the busiest processes seen in the last several seconds. A process using very little CPU may not appear in that list even while using a lot of memory, and a process that hasn't run yet this session won't match until Sentry has observed it at least once.")
        case .generic:
            return nil
        }
    }
}

/// Which of `ProcessStats`'s two attributions a `.processMatch` rule
/// compares against — the picker-friendly mirror of the two `MetricID`
/// values `AlertRule.processNameMatch`'s doc comment documents as
/// meaningful once a rule is process-scoped (`.cpuTotalPercent`/
/// `.memoryUsedBytes`). A dedicated type rather than reusing the full
/// `MetricID` picker `.generic` rules use, because every other `MetricID`
/// case is meaningless for a process rule — `AlertEngine.evaluateProcessRule`
/// only ever reads these two.
private enum ProcessMetricKind: String, CaseIterable, Hashable {
    case cpuPercent
    case memoryBytes

    init(metric: MetricID) {
        self = metric == .memoryUsedBytes ? .memoryBytes : .cpuPercent
    }

    var metricID: MetricID {
        self == .memoryBytes ? .memoryUsedBytes : .cpuTotalPercent
    }

    var displayName: String {
        switch self {
        case .cpuPercent: return String(localized: "CPU")
        case .memoryBytes: return String(localized: "Memory")
        }
    }
}

// MARK: - Picker-friendly enum tags

/// `AlertRule.Comparison` has no `CaseIterable` conformance (it lives in
/// SentryKit and gains nothing from one there), so the picker enumerates
/// this local mirror instead of this pane reaching in to add a conformance to
/// a type it doesn't own.
private enum ComparisonKind: String, CaseIterable, Hashable {
    case above
    case below
    case equals
    case changedBy

    init(comparison: AlertRule.Comparison) {
        switch comparison {
        case .above: self = .above
        case .below: self = .below
        case .equals: self = .equals
        case .changedBy: self = .changedBy
        }
    }

    var comparison: AlertRule.Comparison {
        switch self {
        case .above: return .above
        case .below: return .below
        case .equals: return .equals
        case .changedBy: return .changedBy
        }
    }

    var displayName: String {
        switch self {
        case .above: return String(localized: "At or above")
        case .below: return String(localized: "At or below")
        case .equals: return String(localized: "Equals")
        case .changedBy: return String(localized: "Changed by")
        }
    }

    /// Sentence-fragment form, for the summary lines.
    var phrase: String {
        switch self {
        case .above: return "≥"
        case .below: return "≤"
        case .equals: return "="
        case .changedBy: return String(localized: "changed by")
        }
    }
}

private enum PreconditionKind: String, CaseIterable, Hashable {
    case onBattery
    case charging
    case pluggedIn
    case displayAsleep

    var precondition: AlertRule.Precondition {
        switch self {
        case .onBattery: return .onBattery
        case .charging: return .charging
        case .pluggedIn: return .pluggedIn
        case .displayAsleep: return .displayAsleep
        }
    }

    var displayName: String {
        switch self {
        case .onBattery: return String(localized: "On battery")
        case .charging: return String(localized: "Charging")
        case .pluggedIn: return String(localized: "Plugged in")
        case .displayAsleep: return String(localized: "Display asleep")
        }
    }
}
