import SwiftUI
import MacStatKit

/// The §8.2 menu bar composer: live preview on top, drag-to-reorder module list
/// on the left, per-module inspector on the right, layout-level controls below.
struct MenuBarPane: View {

    @ObservedObject var store: SettingsStore

    /// Purely transient UI state — which row the inspector is editing. Not
    /// persisted, so it deliberately lives here and not in `AppSettings`.
    @State private var selectedModuleID: BarModule.ID?

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
        }
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

        Section("Color") {
            Picker("Rule", selection: colorRuleKindBinding(module)) {
                ForEach(ColorRuleKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .accessibilityLabel("Color rule")

            switch module.wrappedValue.colorRule {
            case .fixed:
                ColorPicker("Color", selection: fixedColorBinding(module), supportsOpacity: false)
                    .accessibilityLabel("Fixed color")
            case .thresholdGradient:
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
                Text("Green below the low value, amber between, red above the high value. Set low above high to invert — useful for metrics where a small number is the bad one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .matchSystemAccent, .themeMetricColor:
                EmptyView()
            }
        }
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

    /// `ColorRule` carries associated values, which a `Picker` can't select
    /// over; this projects it onto a plain case tag and rebuilds the rule with
    /// sensible defaults when the kind changes.
    private func colorRuleKindBinding(_ module: Binding<BarModule>) -> Binding<ColorRuleKind> {
        Binding(
            get: { ColorRuleKind(rule: module.wrappedValue.colorRule) },
            set: { kind in
                guard kind != ColorRuleKind(rule: module.wrappedValue.colorRule) else { return }
                module.wrappedValue.colorRule = kind.defaultRule()
            }
        )
    }

    private func fixedColorBinding(_ module: Binding<BarModule>) -> Binding<Color> {
        Binding(
            get: {
                guard case .fixed(let hex) = module.wrappedValue.colorRule else {
                    return .accentColor
                }
                return ThemeColor(hex: hex).color(for: .dark)
            },
            set: { newColor in
                module.wrappedValue.colorRule = .fixed(hex: Self.hexString(from: newColor))
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

    /// `Color` has no public component accessor on macOS 14, so this goes
    /// through `NSColor` and returns a neutral gray if the conversion to sRGB
    /// fails (a catalog color with no RGB representation) rather than trapping.
    private static func hexString(from color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "#808080" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
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
