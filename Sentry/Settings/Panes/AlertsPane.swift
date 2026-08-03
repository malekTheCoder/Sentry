import SwiftUI
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
/// launches Shortcuts.app for real and `.pushToPhone` is recorded to
/// `PendingAlertPushStore` (see `AppDelegate`'s wiring), but phone *delivery*
/// is still blocked on device sync — the summary text says exactly which
/// half of that works. Showing the shipped actions honestly is the smaller
/// lie than none at all.
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

    init(store: SettingsStore, historyStore: HistoryStore? = nil) {
        self.store = store
        self.historyStore = historyStore
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
            Toggle(isOn: enabledBinding(for: rule.id)) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.checkbox)
            .accessibilityLabel("Enable \(rule.name)")

            VStack(alignment: .leading, spacing: 1) {
                Text(rule.name)
                    .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                Text(Self.conditionSummary(for: rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        // Without this the row's accessibility label would splice the
        // toggle's label into the condition sentence.
        .accessibilityElement(children: .contain)
    }

    /// Removal (`Remove Rule`, the row's Delete key, its context menu) has
    /// always been one-way in this pane — the only recovery was `Restore
    /// Defaults`, which rebuilds all 11 shipped rules with fresh UUIDs and
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
        let kind = RuleKind(id: rule.wrappedValue.id)

        Section("Rule") {
            TextField("Name", text: rule.name)
                .accessibilityLabel("Rule name")
            Toggle("Enabled", isOn: rule.isEnabled)
                .accessibilityLabel("Rule enabled")
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
            if let note = kind.notApplicableNote {
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
        Section {
            if rule.wrappedValue.actions.isEmpty {
                Text("This rule has no actions and will only be recorded in history.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(rule.wrappedValue.actions.enumerated()), id: \.offset) { _, action in
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
            Text("Actions aren't editable yet. “Push to iPhone” is queued on this Mac but can't reach a phone until device sync ships. Every firing is still written to history regardless.")
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
                store.settings.alertRules[index].isEnabled = isOn
            }
        )
    }

    private func comparisonKindBinding(_ rule: Binding<AlertRule>) -> Binding<ComparisonKind> {
        Binding(
            get: { ComparisonKind(comparison: rule.wrappedValue.comparison) },
            set: { rule.wrappedValue.comparison = $0.comparison }
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
        switch RuleKind(id: rule.id) {
        case .chargingPaused, .slowCharging:
            return RuleKind(id: rule.id).fixedConditionSummary ?? ""
        case .batteryHealthDrop:
            return String(localized: "Health drops by \(MetricFormatter.detailed(rule.threshold, unit: .percent)) or more")
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

    /// The detail column doubles as the honesty column: the two unimplemented
    /// cases say so here rather than looking like working features.
    static func actionDetail(_ action: AlertAction) -> String {
        switch action {
        case .notification(let title, _, let sound):
            return sound
                ? String(localized: "“\(title)”, with sound")
                : String(localized: "“\(title)”")
        case .menuBarHighlight(let token):
            return String(localized: "Token “\(token)”")
        case .pushToPhone:
            return String(localized: "Queued on this Mac — reaches a phone only once device sync ships")
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

    init(id: AlertRule.ID) {
        switch id {
        case AlertEngine.chargingPausedRuleID: self = .chargingPaused
        case AlertEngine.slowChargingRuleID: self = .slowCharging
        case AlertEngine.batteryHealthDropRuleID: self = .batteryHealthDrop
        default: self = .generic
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
        case .generic, .batteryHealthDrop:
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
        case .generic:
            return nil
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
