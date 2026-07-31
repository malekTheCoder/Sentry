import SwiftUI
import MacStatKit

/// The §8.2 menu bar composer: live preview on top, drag-to-reorder module list
/// on the left, per-module inspector on the right, layout-level controls below.
struct MenuBarPane: View {

    @ObservedObject var store: SettingsStore

    /// Purely transient UI state — which row the inspector is editing. Not
    /// persisted, so it deliberately lives here and not in `AppSettings`.
    @State private var selectedModuleID: BarModule.ID?

    /// Thresholds parked when the user switches the visibility rule *away*
    /// from `.whenAboveThreshold`. `VisibilityRule` has nowhere to store the
    /// number for the other four cases, so without this, tapping through the
    /// picker to read the options silently resets a threshold the user tuned.
    /// Deliberately session-only and not persisted: it is undo affordance for
    /// one editing session, not state worth surviving a relaunch, and the
    /// per-unit default it falls back to is a fine answer after that.
    @State private var parkedThresholds: [BarModule.ID: Double] = [:]

    var body: some View {
        VStack(spacing: 0) {
            MenuBarPreviewStrip(layout: layout, theme: store.resolvedTheme())
                .padding(12)

            Divider()

            HSplitView {
                moduleListColumn
                    .frame(minWidth: 240)
                inspectorColumn
                    .frame(minWidth: 280)
            }

            Divider()

            dropdownContentBar
        }
    }

    /// What the menu bar *dropdown* shows, as opposed to the bar item the
    /// rest of this pane composes. One compact row rather than a separate
    /// pane: two switches don't justify a ninth sidebar entry. The vitals
    /// rows themselves follow the Modules pane — said here so nobody hunts
    /// for a third place.
    private var dropdownContentBar: some View {
        HStack(spacing: 16) {
            Text("Dropdown shows:")
                .foregroundStyle(.secondary)
            Toggle("Keep-awake controls", isOn: $store.settings.dropdownShowsKeepAwake)
            Toggle("Agent activity", isOn: $store.settings.dropdownShowsAgentActivity)
            Spacer()
            Text("Vitals rows follow Modules")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var layout: MenuBarLayout {
        store.settings.menuBarLayout
    }

    // MARK: - Left column: presets + reorderable module list

    private var moduleListColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    ForEach(MenuBarLayout.presets, id: \.name) { preset in
                        Button(preset.name) {
                            store.settings.menuBarLayout = preset.layout
                            selectedModuleID = preset.layout.modules.first?.id
                        }
                    }
                } label: {
                    Label("Preset", systemImage: "square.stack.3d.up")
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Apply a menu bar preset")

                Spacer()

                addModuleMenu
            }
            .padding(8)

            Divider()

            List(selection: $selectedModuleID) {
                ForEach(layout.modules) { module in
                    moduleRow(module)
                        .tag(module.id)
                }
                .onMove { indices, destination in
                    store.settings.menuBarLayout.modules.move(
                        fromOffsets: indices,
                        toOffset: destination
                    )
                }
                .onDelete { offsets in
                    let removed = offsets.map { layout.modules[$0].id }
                    store.settings.menuBarLayout.modules.remove(atOffsets: offsets)
                    if let selected = selectedModuleID, removed.contains(selected) {
                        selectedModuleID = nil
                    }
                }
            }
            .accessibilityLabel("Menu bar modules, drag to reorder")
            // `.onDelete` alone gives no affordance on macOS — no swipe, no
            // edit mode — so without these a module could be added but never
            // removed (and ModulesPane tells the user to remove them here).
            .onDeleteCommand { removeSelectedModule() }
            .contextMenu(forSelectionType: BarModule.ID.self) { ids in
                Button("Remove", role: .destructive) { removeModules(ids: ids) }
            }

            HStack {
                Button(role: .destructive) {
                    removeSelectedModule()
                } label: {
                    Label("Remove Module", systemImage: "minus.circle")
                }
                .disabled(selectedModuleID == nil)
                .accessibilityLabel("Remove selected module from the menu bar")
                Spacer()
            }
            .padding(.horizontal, 4)

            if layout.modules.isEmpty {
                Text("Your menu bar is empty. Use “Add Module” to start composing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
    }

    private func removeSelectedModule() {
        guard let selected = selectedModuleID else { return }
        removeModules(ids: [selected])
    }

    private func removeModules(ids: Set<BarModule.ID>) {
        guard !ids.isEmpty else { return }
        store.settings.menuBarLayout.modules.removeAll { ids.contains($0.id) }
        if let selected = selectedModuleID, ids.contains(selected) {
            selectedModuleID = nil
        }
    }

    private func moduleRow(_ module: BarModule) -> some View {
        HStack(spacing: 8) {
            Image(systemName: MenuBarPreviewStrip.symbolName(for: module.metric))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(module.metric.shortLabel)
                Text(module.displayMode.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(module.metric.shortLabel), \(module.displayMode.displayName)")
    }

    /// Grouped by module so a 50-entry flat list of metrics never appears.
    private var addModuleMenu: some View {
        Menu {
            ForEach(MetricModule.allCases, id: \.self) { module in
                let metrics = MetricID.allCases.filter { $0.module == module }
                if !metrics.isEmpty {
                    Menu(module.displayName) {
                        ForEach(metrics, id: \.self) { metric in
                            Button(metric.shortLabel) { append(metric) }
                        }
                    }
                }
            }
        } label: {
            Label("Add Module", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Add a module to the menu bar")
    }

    private func append(_ metric: MetricID) {
        let module = BarModule(metric: metric)
        store.settings.menuBarLayout.modules.append(module)
        selectedModuleID = module.id
    }

    // MARK: - Right column: inspector + layout controls

    private var inspectorColumn: some View {
        Form {
            if let binding = selectedModuleBinding() {
                // Keyed on the selected id so switching rows gives SwiftUI a
                // *new* view identity. Without this it reuses the same
                // TextFields and rebinds them, so text typed into module A
                // but not yet committed (these commit on blur/Enter, not per
                // keystroke) lands on module B when the user clicks B. The
                // id-based binding below can't prevent that — the binding
                // itself was swapped underneath the editor.
                moduleInspector(binding)
                    .id(binding.wrappedValue.id)
            } else {
                Section("Module") {
                    Text("Select a module on the left to configure how it draws.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            layoutSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func moduleInspector(_ module: Binding<BarModule>) -> some View {
        Section(module.wrappedValue.metric.shortLabel) {
            Picker("Display", selection: module.displayMode) {
                ForEach(DisplayMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .accessibilityLabel("Display mode")

            Toggle("Show label", isOn: module.showLabel)
                .accessibilityLabel("Show metric label")
            Toggle("Show unit", isOn: module.showUnit)
                .accessibilityLabel("Show metric unit")
        }

        // The bar renders strictly monochrome (white/black with the menu
        // bar's own appearance — see `MenuBarPalette`), so this section no
        // longer picks colors: what the threshold rule still controls is the
        // severity machinery — the "!" critical cue and the VoiceOver
        // announcement. The old fixed/accent color rules remain in the data
        // model for imported layouts, but there's nothing left for them to
        // change, so the UI stops offering them.
        Section("Thresholds") {
            Toggle("Warn at thresholds", isOn: thresholdEnabledBinding(module))
                .accessibilityLabel("Warn at thresholds")

            if case .thresholdGradient = module.wrappedValue.colorRule {
                // Low > high is legal and inverts the ramp (see ColorRule's
                // doc comment), so neither field constrains the other.
                LabeledContent("Low threshold") {
                    TextField(
                        "Low",
                        value: thresholdBinding(module, isLow: true),
                        format: .number
                    )
                    .labelsHidden()
                    .frame(width: 80)
                    .accessibilityLabel("Low threshold value")
                }
                LabeledContent("High threshold") {
                    TextField(
                        "High",
                        value: thresholdBinding(module, isLow: false),
                        format: .number
                    )
                    .labelsHidden()
                    .frame(width: 80)
                    .accessibilityLabel("High threshold value")
                }
                Text("The bar always draws in plain white or black so it stays readable on any wallpaper. Near the high threshold a value counts as critical: it gets a “!” beside it and VoiceOver says so. Set low above high to invert — useful for metrics where a small number is the bad one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        visibilitySection(module)
    }

    /// Plan §10.5's missing control. Every `VisibilityRule` case has always
    /// been honored by `StatusItemView.isVisible`, but nothing wrote the
    /// property, so four of the five were unreachable except by loading the
    /// Battery Focus preset.
    @ViewBuilder
    private func visibilitySection(_ module: Binding<BarModule>) -> some View {
        let unit = module.wrappedValue.metric.unit

        Section("Visibility") {
            Picker("Show", selection: visibilityRuleKindBinding(module)) {
                ForEach(VisibilityRuleKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .accessibilityLabel("Visibility rule")

            if case .whenAboveThreshold = module.wrappedValue.visibilityRule {
                // The threshold is compared against the raw metric value in
                // that metric's own unit (StatusItemView.isVisible), so the
                // control has to be unit-aware: a slider is only honest where
                // the unit has a real domain to slide across. Bytes/sec, MHz
                // and counts have no upper bound worth inventing, so those get
                // free numeric entry instead of a fake 0–100 track.
                if let bounds = VisibilityThreshold.sliderBounds(for: unit) {
                    VStack(alignment: .leading, spacing: 2) {
                        Slider(
                            value: visibilityThresholdBinding(module),
                            in: bounds.range,
                            step: bounds.step
                        ) {
                            Text("Threshold")
                        } minimumValueLabel: {
                            Text(MetricFormatter.compact(bounds.range.lowerBound, unit: unit))
                        } maximumValueLabel: {
                            Text(MetricFormatter.compact(bounds.range.upperBound, unit: unit))
                        }
                        .accessibilityLabel("Visibility threshold")
                        .accessibilityValue(
                            MetricFormatter.compact(
                                visibilityThresholdBinding(module).wrappedValue,
                                unit: unit
                            )
                        )
                        thresholdExplanation(module)
                    }
                } else {
                    LabeledContent("Threshold") {
                        TextField(
                            "Threshold",
                            value: visibilityThresholdBinding(module),
                            format: .number
                        )
                        .labelsHidden()
                        .frame(width: 110)
                        .accessibilityLabel("Visibility threshold value")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Measured in \(VisibilityThreshold.unitDescription(for: unit)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        thresholdExplanation(module)
                    }
                }
            }

            // Worth saying out loud because the obvious guess is wrong:
            // `StatsCoordinator` runs a fixed tiered poll loop that never
            // consults the layout, and `isVisible` is applied in
            // `StatusItemView.rebuildLayout` after the value has already been
            // read out of the snapshot. Hiding a module is a render filter, so
            // the number is current the instant the rule flips back on — and
            // it is not a way to save battery.
            Text("Hiding a module only stops it drawing. Sentry keeps sampling the metric on its normal schedule, so the reading is already current when the rule turns the module back on.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func thresholdExplanation(_ module: Binding<BarModule>) -> some View {
        let metric = module.wrappedValue.metric
        let value = visibilityThresholdBinding(module).wrappedValue
        // Strictly above, matching `isVisible`'s `value > threshold`; a module
        // sitting exactly on its threshold stays hidden.
        return Text("Shown only while \(metric.shortLabel) reads above \(MetricFormatter.compact(value, unit: metric.unit)). A metric with no reading counts as not above it.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var layoutSection: some View {
        Section("Bar Layout") {
            VStack(alignment: .leading, spacing: 2) {
                Slider(value: $store.settings.menuBarLayout.spacing, in: 2...12, step: 1) {
                    Text("Spacing")
                } minimumValueLabel: {
                    Text("2")
                } maximumValueLabel: {
                    Text("12")
                }
                .accessibilityLabel("Spacing between modules")
                .accessibilityValue("\(Int(layout.spacing)) points")
                Text("\(Int(layout.spacing)) pt between modules")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Separator", selection: $store.settings.menuBarLayout.separatorStyle) {
                ForEach(SeparatorStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .accessibilityLabel("Separator style")

            Toggle("Collapse inactive modules", isOn: $store.settings.menuBarLayout.collapseWhenInactive)
                .accessibilityLabel("Collapse inactive modules")

            Toggle("Limit maximum width", isOn: maxWidthEnabledBinding)
                .accessibilityLabel("Limit maximum width")

            if layout.maxWidth != nil {
                VStack(alignment: .leading, spacing: 2) {
                    Slider(value: maxWidthValueBinding, in: 120...600, step: 10) {
                        Text("Maximum width")
                    } minimumValueLabel: {
                        Text("120")
                    } maximumValueLabel: {
                        Text("600")
                    }
                    .accessibilityLabel("Maximum menu bar width")
                    .accessibilityValue("\(Int(maxWidthValueBinding.wrappedValue)) points")
                    Text("Truncates at \(Int(maxWidthValueBinding.wrappedValue)) pt instead of pushing other status items off a crowded bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Bindings

    /// Resolves the selection by id on every access rather than caching an
    /// index, so a reorder or delete under the inspector can't write into the
    /// wrong row.
    private func selectedModuleBinding() -> Binding<BarModule>? {
        guard
            let id = selectedModuleID,
            let current = store.settings.menuBarLayout.modules.first(where: { $0.id == id })
        else { return nil }

        return Binding(
            get: {
                store.settings.menuBarLayout.modules.first(where: { $0.id == id }) ?? current
            },
            set: { newValue in
                guard let index = store.settings.menuBarLayout.modules
                    .firstIndex(where: { $0.id == id }) else { return }
                store.settings.menuBarLayout.modules[index] = newValue
            }
        )
    }

    /// On = `.thresholdGradient` (the rule that feeds `severity(for:)`'s
    /// "!" cue), off = `.themeMetricColor` (the monochrome bar's inert
    /// default). Turning the toggle off and on again restores the default
    /// 20/90 band rather than remembering the old one — matching how
    /// `maxWidthEnabledBinding` below deliberately forgets on disable.
    private func thresholdEnabledBinding(_ module: Binding<BarModule>) -> Binding<Bool> {
        Binding(
            get: {
                if case .thresholdGradient = module.wrappedValue.colorRule { return true }
                return false
            },
            set: { isOn in
                module.wrappedValue.colorRule = isOn
                    ? ColorRuleKind.thresholdGradient.defaultRule()
                    : .themeMetricColor
            }
        )
    }

    private func thresholdBinding(_ module: Binding<BarModule>, isLow: Bool) -> Binding<Double> {
        Binding(
            get: {
                guard case .thresholdGradient(let low, let high) = module.wrappedValue.colorRule else {
                    return isLow ? 20 : 90
                }
                return isLow ? low : high
            },
            set: { newValue in
                guard case .thresholdGradient(let low, let high) = module.wrappedValue.colorRule else { return }
                module.wrappedValue.colorRule = .thresholdGradient(
                    low: isLow ? newValue : low,
                    high: isLow ? high : newValue
                )
            }
        )
    }

    /// Same shape as `colorRuleKindBinding`: `VisibilityRule` carries an
    /// associated value on one case, so the `Picker` selects over a plain tag
    /// and the rule is rebuilt on change. Unlike the color rule, the discarded
    /// associated value is parked rather than dropped — see `parkedThresholds`.
    private func visibilityRuleKindBinding(_ module: Binding<BarModule>) -> Binding<VisibilityRuleKind> {
        Binding(
            get: { VisibilityRuleKind(rule: module.wrappedValue.visibilityRule) },
            set: { kind in
                let current = module.wrappedValue.visibilityRule
                guard kind != VisibilityRuleKind(rule: current) else { return }
                if case .whenAboveThreshold(let parked) = current {
                    parkedThresholds[module.wrappedValue.id] = parked
                }
                module.wrappedValue.visibilityRule = kind.rule(
                    threshold: threshold(for: module.wrappedValue)
                )
            }
        )
    }

    private func visibilityThresholdBinding(_ module: Binding<BarModule>) -> Binding<Double> {
        Binding(
            get: {
                guard case .whenAboveThreshold(let value) = module.wrappedValue.visibilityRule else {
                    return threshold(for: module.wrappedValue)
                }
                return value
            },
            set: { newValue in
                // Guarded so a stale editor (the TextField commits on blur,
                // which can land after the picker moved off this case) can't
                // resurrect `.whenAboveThreshold` over the user's new choice.
                guard case .whenAboveThreshold = module.wrappedValue.visibilityRule else { return }
                parkedThresholds[module.wrappedValue.id] = newValue
                module.wrappedValue.visibilityRule = .whenAboveThreshold(newValue)
            }
        )
    }

    /// The value to offer when `.whenAboveThreshold` is (re)selected: whatever
    /// this module last used in this session, else a per-unit default.
    private func threshold(for module: BarModule) -> Double {
        parkedThresholds[module.id] ?? VisibilityThreshold.defaultValue(for: module.metric.unit)
    }

    private var maxWidthEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.menuBarLayout.maxWidth != nil },
            set: { isOn in
                // Remember nothing on disable — re-enabling restores the
                // model's own default rather than a stale value.
                store.settings.menuBarLayout.maxWidth = isOn ? 320 : nil
            }
        )
    }

    private var maxWidthValueBinding: Binding<Double> {
        Binding(
            get: { store.settings.menuBarLayout.maxWidth ?? 320 },
            set: { store.settings.menuBarLayout.maxWidth = $0 }
        )
    }

}

// MARK: - ColorRule case tags

/// A `Picker`-friendly stand-in for `ColorRule`'s cases.
private enum ColorRuleKind: String, CaseIterable, Hashable {
    case fixed
    case thresholdGradient
    case matchSystemAccent
    case themeMetricColor

    init(rule: ColorRule) {
        switch rule {
        case .fixed: self = .fixed
        case .thresholdGradient: self = .thresholdGradient
        case .matchSystemAccent: self = .matchSystemAccent
        case .themeMetricColor: self = .themeMetricColor
        }
    }

    var displayName: String {
        switch self {
        case .fixed: return "Fixed color"
        case .thresholdGradient: return "Threshold gradient"
        case .matchSystemAccent: return "System accent"
        case .themeMetricColor: return "Theme metric color"
        }
    }

    /// Defaults match the plan's own §8.2 preset examples.
    func defaultRule() -> ColorRule {
        switch self {
        case .fixed: return .fixed(hex: "#33FF66")
        case .thresholdGradient: return .thresholdGradient(low: 20, high: 90)
        case .matchSystemAccent: return .matchSystemAccent
        case .themeMetricColor: return .themeMetricColor
        }
    }
}

// MARK: - VisibilityRule case tags

/// A `Picker`-friendly stand-in for `VisibilityRule`'s cases, mirroring
/// `ColorRuleKind`.
///
/// Internal rather than `private` (which is what `ColorRuleKind` gets away
/// with) because the tag↔rule mapping is the one piece of real logic here:
/// getting it wrong silently rewrites a user's rule, which no compiler check
/// catches. `AlertsPane.RuleKind` is internal for the same reason.
enum VisibilityRuleKind: String, CaseIterable, Hashable {
    case always
    case whenAboveThreshold
    case whenOnBattery
    case whenCharging
    case whenAssertionActive

    init(rule: VisibilityRule) {
        switch rule {
        case .always: self = .always
        case .whenAboveThreshold: self = .whenAboveThreshold
        case .whenOnBattery: self = .whenOnBattery
        case .whenCharging: self = .whenCharging
        case .whenAssertionActive: self = .whenAssertionActive
        }
    }

    var displayName: String {
        switch self {
        case .always: return "Always"
        case .whenAboveThreshold: return "When above a threshold"
        case .whenOnBattery: return "When on battery"
        case .whenCharging: return "When charging"
        // Named for what the user did ("keep my Mac awake"), not for the
        // IOPMAssertion underneath it — plan §10.5's own framing.
        case .whenAssertionActive: return "While keeping the Mac awake"
        }
    }

    /// Rebuilds the real rule. `threshold` is only consumed by one case; the
    /// caller supplies it unconditionally so the mapping stays total and the
    /// number survives a round trip through the other four.
    func rule(threshold: Double) -> VisibilityRule {
        switch self {
        case .always: return .always
        case .whenAboveThreshold: return .whenAboveThreshold(threshold)
        case .whenOnBattery: return .whenOnBattery
        case .whenCharging: return .whenCharging
        case .whenAssertionActive: return .whenAssertionActive
        }
    }
}

extension VisibilityRule {
    /// Plain-language "when is this module actually on the bar", for surfaces
    /// that must describe a rule they cannot evaluate — the settings window has
    /// no snapshot stream, so the preview can say *what the condition is* but
    /// never *whether it currently holds*.
    ///
    /// `nil` for `.always`, because "always shown" is the absence of a
    /// condition and annotating it would make the unconditional case look
    /// conditional.
    func previewSummary(unit: MetricUnit) -> String? {
        switch self {
        case .always:
            return nil
        case .whenAboveThreshold(let value):
            return "Only shown when above \(MetricFormatter.compact(value, unit: unit))"
        case .whenOnBattery:
            return "Only shown when on battery"
        case .whenCharging:
            return "Only shown when charging"
        case .whenAssertionActive:
            return "Only shown while Sentry is keeping the Mac awake"
        }
    }
}

/// Per-unit shaping for the `.whenAboveThreshold` control.
///
/// The threshold is compared against the metric's raw value in its own unit
/// (`StatusItemView.isVisible`), so there is no single sensible range: 50 means
/// half for a percent, a warm chip for °C, and half a *byte* per second for a
/// network metric. Rather than pick one and be wrong four times out of five,
/// units with a genuine domain get a bounded slider and the rest get free
/// numeric entry.
enum VisibilityThreshold {

    /// Where a module "starts being interesting" for each unit — the point of
    /// the rule is to surface a metric only when it's worth a glance.
    static func defaultValue(for unit: MetricUnit) -> Double {
        switch unit {
        case .percent: return 50
        case .celsius: return 70
        case .watts: return 5
        case .thermalLevel: return 1          // above nominal
        case .megahertz: return 2000
        case .bytes: return 1_073_741_824     // 1 GB
        case .bytesPerSecond: return 1_048_576 // 1 MB/s
        case .megabitsPerSecond: return 10
        case .operationsPerSecond: return 100
        case .minutes: return 30
        case .seconds: return 60
        case .millivolts: return 12_000
        case .milliamps: return 1_000
        case .decibelMilliwatts: return -60
        case .boolean: return 0               // "> 0" is "true"
        case .decimal: return 1
        case .count: return 1
        }
    }

    /// `nil` means "no defensible upper bound" — use a text field.
    ///
    /// Note `.decibelMilliwatts` is bounded but *negative*, and `.boolean` is
    /// bounded but only has two meaningful positions; both still read better as
    /// a slider than as a number a user has to guess the scale of.
    static func sliderBounds(for unit: MetricUnit) -> (range: ClosedRange<Double>, step: Double)? {
        switch unit {
        case .percent: return (0...100, 1)
        case .celsius: return (0...110, 1)
        case .watts: return (0...150, 0.5)
        case .thermalLevel: return (0...3, 1)
        case .decibelMilliwatts: return ((-100)...(0), 1)
        case .boolean: return (0...1, 1)
        case .bytes, .bytesPerSecond, .megahertz, .megabitsPerSecond,
             .operationsPerSecond, .minutes, .seconds, .millivolts,
             .milliamps, .decimal, .count:
            return nil
        }
    }

    /// Spelled out for the free-entry case, where the field shows a bare
    /// number and `MetricUnit.suffix` is empty for exactly the byte-scale
    /// units that need the explanation most.
    static func unitDescription(for unit: MetricUnit) -> String {
        switch unit {
        case .percent: return "percent"
        case .watts: return "watts"
        case .celsius: return "degrees Celsius"
        case .megahertz: return "megahertz"
        case .bytes: return "bytes"
        case .bytesPerSecond: return "bytes per second"
        case .operationsPerSecond: return "operations per second"
        case .megabitsPerSecond: return "megabits per second"
        case .minutes: return "minutes"
        case .seconds: return "seconds"
        case .millivolts: return "millivolts"
        case .milliamps: return "milliamps"
        case .decibelMilliwatts: return "dBm"
        case .boolean: return "0 or 1"
        case .decimal: return "a plain number"
        case .thermalLevel: return "a thermal level from 0 to 3"
        case .count: return "a count"
        }
    }
}
