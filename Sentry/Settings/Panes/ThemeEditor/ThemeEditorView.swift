import SwiftUI
import SentryKit

/// §9.3's theme editor: per-token color wells grouped into sections, a
/// per-metric color grid, font/size/weight controls, density and chart-style
/// toggles, a live preview, per-token and global reset-to-preset, and export.
///
/// **Edits are a draft until you save.** The editor works on a `@State` copy
/// and writes back through `onSave` when the user commits. The alternative —
/// binding straight into `SettingsStore` — was tried in outline and rejected:
/// `SettingsStore` debounce-writes to disk on every mutation, so dragging an
/// opacity slider would be a settings write per frame; a half-typed hex string
/// would repaint the entire live app grey mid-keystroke if the theme being
/// edited happened to be the active one; and "Cancel" would have nothing to
/// restore. A draft makes all three go away and costs one struct copy.
///
/// **The live preview renders the draft, not the active theme.** See
/// `ThemeEditorPreview`. Everything *else* in this view — every label, well,
/// slider and badge — is drawn from the active theme's palette via
/// `\.themePalette`, so the editor chrome stays legible while the user is
/// halfway through making the draft unreadable. That separation is deliberate
/// and is the reason no color literal appears anywhere in this file.
///
/// **§9.4 is enforced here, not documented here.** `ThemeContrastAudit` is
/// recomputed on every draft mutation — sixty-odd ratio computations, cheap
/// enough not to think about — and every failing pair is flagged inline
/// beside the well that caused it, with the ratio in text and a symbol, never
/// by color alone. Saving a theme that fails is still allowed: the user is
/// told, clearly and permanently (the banner does not dismiss), but a theme
/// editor that refuses to save is a theme editor that can't be used to *fix*
/// an imported theme, and "unknowingly" is the word §9.4 actually uses.
struct ThemeEditorView: View {

    /// The theme as it was when the editor opened, for Revert.
    private let original: Theme
    let layout: MenuBarLayout
    let onSave: (Theme) -> Void
    let onCancel: () -> Void

    @State private var draft: Theme
    /// Which half of every light/dark pair the wells write and the preview
    /// renders. Starts on the appearance the user's Mac is actually in, since
    /// that's the half they'll notice being wrong.
    @State private var appearance: ThemeAppearance
    @State private var errorMessage: String?

    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        theme: Theme,
        layout: MenuBarLayout,
        initialAppearance: ThemeAppearance,
        onSave: @escaping (Theme) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.original = theme
        self.layout = layout
        self.onSave = onSave
        self.onCancel = onCancel
        self._draft = State(initialValue: theme)
        self._appearance = State(initialValue: initialAppearance)
    }

    /// Recomputed on every body evaluation rather than cached in `@State`.
    /// A cached audit would need invalidating on every one of the dozens of
    /// mutation paths below, and the failure mode of missing one is a stale
    /// "passes" badge next to a color that doesn't — precisely the silent
    /// unreadability §9.4 exists to prevent. See `Theme.contrastAudit`.
    private var audit: ThemeContrastAudit { draft.contrastAudit }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                controls
                Rectangle()
                    .fill(palette.separator)
                    .frame(width: 1)
                previewColumn
            }
            Divider()
            footer
        }
        .frame(minWidth: 900, idealWidth: 980, minHeight: 620, idealHeight: 700)
        .background(palette.background)
        .alert(
            "Couldn't export theme",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: palette.spacingBlock) {
            VStack(alignment: .leading, spacing: 4) {
                TextField(
                    String(localized: "Theme name"),
                    text: Binding(get: { draft.name }, set: { draft.name = $0 })
                )
                .textFieldStyle(.plain)
                .font(palette.font(size: 17, weight: .semibold))
                .foregroundStyle(palette.textPrimary)

                Text(ancestryDescription)
                    .font(palette.font(size: 11))
                    .foregroundStyle(palette.textSecondary)
            }

            Spacer(minLength: 0)

            // The appearance switch governs both the wells and the preview,
            // so it sits above both rather than inside either column.
            Picker(String(localized: "Editing appearance"), selection: $appearance) {
                ForEach(ThemeAppearance.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .help(String(localized: "Which half of each color's light/dark pair the wells edit, and which the preview shows."))
        }
        .padding(.horizontal, palette.spacingPage)
        .padding(.vertical, palette.spacingBlock)
    }

    private var ancestryDescription: String {
        switch draft.globalResetAvailability {
        case .available(let presetName), .alreadyMatchesPreset(let presetName):
            return String(localized: "Duplicated from \(presetName).")
        case .noBasePreset:
            return String(localized: "No source preset — reset-to-preset is unavailable for this theme.")
        case .basePresetMissing(let id):
            return String(localized: "Source preset \(id) isn't in this version of Sentry, so reset-to-preset is unavailable.")
        }
    }

    // MARK: - Controls column

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: palette.spacingBlock) {
                contrastBanner
                ForEach(ThemeColorToken.Section.allCases) { section in
                    colorSection(section)
                }
                chartGradientSection
                metricColorSection
                typographySection
                geometrySection
                effectsSection
            }
            .padding(palette.spacingPage)
        }
        .frame(maxWidth: .infinity)
    }

    /// The §9.4 headline. Always present, pass or fail — a banner that only
    /// appears on failure trains the user to read its absence as "not
    /// checked yet."
    private var contrastBanner: some View {
        HStack(alignment: .top, spacing: palette.spacingTight) {
            Image(systemName: audit.passesTextAA ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(audit.passesTextAA ? palette.success : palette.danger)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(audit.headline)
                    .font(palette.font(size: 12, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                Text("Checked in both light and dark, against every surface the app draws text on. Translucent backdrops are approximate — the real backdrop is your desktop.")
                    .font(palette.font(size: 11))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(palette.spacingBlock)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                .fill(palette.surfaceElevated)
        )
        .accessibilityElement(children: .combine)
    }

    private func colorSection(_ section: ThemeColorToken.Section) -> some View {
        ThemeEditorSection(section.title, explanation: section.explanation) {
            VStack(spacing: palette.spacingRow) {
                ForEach(section.tokens) { token in
                    ThemeColorWellRow(
                        title: token.displayName,
                        subtitle: token.usageNote,
                        appearance: appearance,
                        color: Binding<ThemeColor>(
                            get: { self.draft[token] },
                            set: { self.draft[token] = $0 }
                        ),
                        findings: findings(for: .token(token)),
                        resetAvailability: draft.resetAvailability(for: token),
                        onReset: { draft.resetToPreset(token) }
                    )
                }
            }
        }
    }

    // MARK: Chart gradient

    /// `chartFill` is an ordered list of gradient stops, so it gets its own
    /// section rather than a slot in the color grid — see `ThemeColorToken`'s
    /// doc comment for why it isn't addressable as a token.
    private var chartGradientSection: some View {
        ThemeEditorSection(
            String(localized: "Chart Gradient"),
            explanation: String(localized: "Stops filled under an area chart, top to bottom. Two is the useful minimum; the last stop is usually fully transparent.")
        ) {
            VStack(spacing: palette.spacingRow) {
                ForEach(Array(draft.chartFill.indices), id: \.self) { index in
                    ThemeColorWellRow(
                        title: String(localized: "Stop \(index + 1)"),
                        subtitle: nil,
                        appearance: appearance,
                        color: Binding<ThemeColor>(
                            get: { self.draft.chartFill[index] },
                            set: { self.draft.chartFill[index] = $0 }
                        ),
                        // Gradient stops sit under a chart line, not under
                        // text, so no contrast requirement applies and no
                        // badge is shown. An empty array here is how the
                        // badge stays honest rather than inventing a pass.
                        findings: [],
                        resetAvailability: chartFillResetAvailability(at: index),
                        onReset: { resetChartFillStop(at: index) }
                    )
                }

                HStack {
                    Button {
                        // A new stop copies the last one rather than being
                        // invented: a stop of some arbitrary color would jump
                        // the gradient somewhere the user didn't ask for,
                        // whereas a duplicate is visually a no-op they then
                        // edit.
                        draft.chartFill.append(draft.chartFill.last ?? draft.accent)
                    } label: {
                        Label("Add Stop", systemImage: "plus")
                    }
                    .disabled(draft.chartFill.count >= ThemeLimits.chartFillStops.upperBound)
                    .help(draft.chartFill.count >= ThemeLimits.chartFillStops.upperBound
                          ? String(localized: "A theme can have at most \(ThemeLimits.chartFillStops.upperBound) gradient stops.")
                          : String(localized: "Add a gradient stop."))

                    Button {
                        draft.chartFill.removeLast()
                    } label: {
                        Label("Remove Stop", systemImage: "minus")
                    }
                    .disabled(draft.chartFill.isEmpty)
                    .help(draft.chartFill.isEmpty
                          ? String(localized: "There are no stops to remove.")
                          : String(localized: "Remove the last gradient stop. Below two stops, charts fall back to a gradient derived from the accent."))

                    Spacer(minLength: 0)
                }
                .font(palette.font(size: 11))
            }
        }
    }

    private func chartFillResetAvailability(at index: Int) -> ThemeResetAvailability {
        guard let basePresetID = draft.basePresetID else { return .noBasePreset }
        guard let preset = draft.basePreset else { return .basePresetMissing(id: basePresetID) }
        guard index < preset.chartFill.count else {
            // A stop the preset never had can't be "reset" to anything. Not
            // an error — the user added it — but the button must say so
            // rather than silently doing nothing.
            return .basePresetMissing(id: basePresetID)
        }
        return draft.chartFill[index] == preset.chartFill[index]
            ? .alreadyMatchesPreset(presetName: preset.name)
            : .available(presetName: preset.name)
    }

    private func resetChartFillStop(at index: Int) {
        guard let preset = draft.basePreset, index < preset.chartFill.count else { return }
        draft.chartFill[index] = preset.chartFill[index]
    }

    // MARK: Per-metric colors

    /// The metrics the per-metric grid offers.
    ///
    /// The six that `ThemePalette.moduleColor` maps — i.e. the ones that
    /// actually tint something — plus any extra keys the theme already
    /// carries. That second half matters: an imported theme may assign
    /// colors to metrics outside this six, and a grid that only showed the
    /// six would leave those keys in the file, active, and uneditable.
    private var editableMetrics: [MetricID] {
        let canonical: [MetricID] = [
            .cpuTotalPercent, .gpuUtilizationPercent, .memoryUsedBytes,
            .diskReadBytesPerSec, .networkRxBytesPerSec, .thermalSocTempC,
        ]
        let extras = draft.metricColors.keys
            .compactMap(MetricID.init(rawValue:))
            .filter { !canonical.contains($0) }
            .sorted { $0.rawValue < $1.rawValue }
        return canonical + extras
    }

    private var metricColorSection: some View {
        ThemeEditorSection(
            String(localized: "Metric Colors"),
            explanation: String(localized: "Per-metric tints for chart lines, dots and fill bars. These are graphics rather than text, so they're checked against 3:1 — WCAG's non-text threshold — not 4.5:1.")
        ) {
            VStack(spacing: palette.spacingRow) {
                ForEach(editableMetrics, id: \.self) { metric in
                    ThemeColorWellRow(
                        title: metric.shortLabel,
                        // The metric's raw dotted id rather than a prettier
                        // label: it's what the `.sentrytheme` file's
                        // `metricColors` keys actually say, so anyone
                        // hand-editing an export can match the two up.
                        subtitle: metric.rawValue,
                        appearance: appearance,
                        color: metricColorBinding(metric),
                        findings: findings(for: .metric(metric)),
                        resetAvailability: metricResetAvailability(metric),
                        onReset: { draft.resetMetricColorToPreset(metric) }
                    )
                }
            }
        }
    }

    /// Extracted, and explicitly typed, because the same expression written
    /// inline inside the `ForEach` above defeated the type checker outright
    /// (`unable to type-check this expression in reasonable time`) — a
    /// `Binding` whose getter combines a dictionary subscript, a `??` and a
    /// property access is a lot of overload resolution for a closure with no
    /// annotations.
    private func metricColorBinding(_ metric: MetricID) -> Binding<ThemeColor> {
        Binding<ThemeColor>(
            // A metric with no entry falls back to the accent at render time
            // (`ThemePalette.metricColor`), so the well shows the accent —
            // and writing to it creates the entry, which is what the user
            // just asked for by touching the well.
            get: { self.draft.metricColors[metric.rawValue] ?? self.draft.accent },
            set: { self.draft.metricColors[metric.rawValue] = $0 }
        )
    }

    /// Findings for one subject in the appearance currently being edited.
    ///
    /// Filtered by appearance on purpose: switching to Light shouldn't flag a
    /// token because its *dark* half is bad. That's a real problem, but it
    /// belongs to the other tab, and surfacing it here would make every row
    /// look broken while the user fixes one.
    private func findings(for subject: ContrastSubject) -> [ContrastFinding] {
        audit.findings.filter { $0.subject == subject && $0.appearance == appearance }
    }

    private func metricResetAvailability(_ metric: MetricID) -> ThemeResetAvailability {
        guard let basePresetID = draft.basePresetID else { return .noBasePreset }
        guard let preset = draft.basePreset else { return .basePresetMissing(id: basePresetID) }
        return draft.metricColors[metric.rawValue] == preset.metricColors[metric.rawValue]
            ? .alreadyMatchesPreset(presetName: preset.name)
            : .available(presetName: preset.name)
    }

    // MARK: Typography

    private var typographySection: some View {
        ThemeEditorSection(
            String(localized: "Typography"),
            explanation: String(localized: "Applies to the bar item and every readout in the app. The size below is the menu-bar size; the rest of the UI scales from it.")
        ) {
            VStack(alignment: .leading, spacing: palette.spacingRow) {
                Picker(String(localized: "Typeface"), selection: fontFamilyKindBinding) {
                    Text("System").tag(FontFamilyKind.system)
                    Text("Monospaced").tag(FontFamilyKind.systemMono)
                    Text("Rounded").tag(FontFamilyKind.rounded)
                    Text("Custom…").tag(FontFamilyKind.custom)
                }

                if case .custom(let name) = draft.fontFamily {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField(
                            String(localized: "PostScript name"),
                            text: Binding(
                                get: { name },
                                set: { draft.fontFamily = .custom($0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        Text("A font that isn't installed silently falls back to the system font — that's deliberate, so a theme authored on another Mac still renders.")
                            .font(palette.font(size: 10))
                            .foregroundStyle(palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                sliderRow(
                    String(localized: "Bar font size"),
                    value: Binding(get: { Double(draft.barFontSize) }, set: { draft.barFontSize = CGFloat($0) }),
                    range: Double(ThemeLimits.barFontSize.lowerBound)...Double(ThemeLimits.barFontSize.upperBound),
                    step: 0.5,
                    format: { String(format: "%.1f pt", $0) }
                )

                Picker(String(localized: "Weight"), selection: Binding(get: { draft.barFontWeight }, set: { draft.barFontWeight = $0 })) {
                    ForEach(FontWeightToken.allCasesInWeightOrder, id: \.self) { weight in
                        Text(weight.displayName).tag(weight)
                    }
                }

                Picker(String(localized: "Numerals"), selection: Binding(get: { draft.numericStyle }, set: { draft.numericStyle = $0 })) {
                    Text("Monospaced digits").tag(NumericStyle.monospacedDigit)
                    Text("Proportional").tag(NumericStyle.proportional)
                }
                .help(String(localized: "Monospaced digits keep a changing number from shifting the layout under your cursor."))
            }
        }
    }

    /// The picker's tag type. `FontChoice.custom` carries a `String`, so it
    /// can't be a `Picker` tag directly without every keystroke in the name
    /// field changing the selected tag out from under the picker.
    private enum FontFamilyKind: Hashable {
        case system, systemMono, rounded, custom
    }

    private var fontFamilyKindBinding: Binding<FontFamilyKind> {
        Binding(
            get: {
                switch draft.fontFamily {
                case .system: return .system
                case .systemMono: return .systemMono
                case .rounded: return .rounded
                case .custom: return .custom
                }
            },
            set: { kind in
                switch kind {
                case .system: draft.fontFamily = .system
                case .systemMono: draft.fontFamily = .systemMono
                case .rounded: draft.fontFamily = .rounded
                case .custom:
                    // Preserve whatever name is already there when the user
                    // toggles away and back, rather than clearing it.
                    if case .custom = draft.fontFamily { return }
                    draft.fontFamily = .custom("")
                }
            }
        )
    }

    // MARK: Geometry

    private var geometrySection: some View {
        ThemeEditorSection(
            String(localized: "Density & Charts"),
            explanation: String(localized: "Density scales every gap and inset in the app together; the chart controls apply to the dropdown's sparklines and the Dashboard's history charts.")
        ) {
            VStack(alignment: .leading, spacing: palette.spacingRow) {
                Picker(String(localized: "Density"), selection: Binding(get: { draft.density }, set: { draft.density = $0 })) {
                    Text("Compact").tag(Density.compact)
                    Text("Comfortable").tag(Density.comfortable)
                    Text("Spacious").tag(Density.spacious)
                }
                .pickerStyle(.segmented)

                Picker(String(localized: "Chart style"), selection: Binding(get: { draft.chartStyle }, set: { draft.chartStyle = $0 })) {
                    Text("Line").tag(ChartStyle.line)
                    Text("Area").tag(ChartStyle.area)
                    Text("Bars").tag(ChartStyle.bars)
                    Text("Stepped").tag(ChartStyle.stepped)
                }
                .pickerStyle(.segmented)

                sliderRow(
                    String(localized: "Chart line width"),
                    value: Binding(get: { Double(draft.chartLineWidth) }, set: { draft.chartLineWidth = CGFloat($0) }),
                    range: Double(ThemeLimits.chartLineWidth.lowerBound)...Double(ThemeLimits.chartLineWidth.upperBound),
                    step: 0.5,
                    format: { String(format: "%.1f pt", $0) }
                )

                sliderRow(
                    String(localized: "Corner radius"),
                    value: Binding(get: { Double(draft.cornerRadius) }, set: { draft.cornerRadius = CGFloat($0) }),
                    range: Double(ThemeLimits.cornerRadius.lowerBound)...Double(ThemeLimits.cornerRadius.upperBound),
                    step: 1,
                    format: { String(format: "%.0f pt", $0) }
                )

                sliderRow(
                    String(localized: "Menu-bar graph width"),
                    value: Binding(get: { Double(draft.barGraphWidth) }, set: { draft.barGraphWidth = CGFloat($0) }),
                    range: Double(ThemeLimits.barGraphWidth.lowerBound)...Double(ThemeLimits.barGraphWidth.upperBound),
                    step: 2,
                    format: { String(format: "%.0f pt", $0) }
                )

                Toggle(String(localized: "Show chart gridlines"), isOn: Binding(get: { draft.showChartGrid }, set: { draft.showChartGrid = $0 }))
            }
        }
    }

    // MARK: Effects

    private var effectsSection: some View {
        ThemeEditorSection(
            String(localized: "Effects"),
            explanation: String(localized: "Glow and scanlines are suppressed automatically when Increase Contrast is on in System Settings — the preview shows the version you'll actually get.")
        ) {
            VStack(alignment: .leading, spacing: palette.spacingRow) {
                Toggle(
                    String(localized: "Translucent background"),
                    isOn: Binding(get: { draft.useMaterialBackground }, set: { draft.useMaterialBackground = $0 })
                )
                .help(String(localized: "Paints surfaces over a system blur instead of an opaque fill. Contrast findings against a translucent backdrop are approximate."))

                Picker(String(localized: "Material"), selection: Binding(get: { draft.materialStyle }, set: { draft.materialStyle = $0 })) {
                    ForEach(MaterialToken.allCasesInOrder, id: \.self) { material in
                        Text(material.displayName).tag(material)
                    }
                }
                .disabled(!draft.useMaterialBackground)
                .help(draft.useMaterialBackground
                      ? String(localized: "Which system blur sits behind translucent surfaces.")
                      : String(localized: "Only applies when “Translucent background” is on."))

                sliderRow(
                    String(localized: "Glow"),
                    value: Binding(get: { draft.glowIntensity }, set: { draft.glowIntensity = $0 }),
                    range: ThemeLimits.glowIntensity,
                    step: 0.05,
                    format: { "\(Int(($0 * 100).rounded()))%" }
                )

                Toggle(
                    String(localized: "Scanline overlay"),
                    isOn: Binding(get: { draft.scanlineOverlay }, set: { draft.scanlineOverlay = $0 })
                )
            }
        }
    }

    // MARK: - Shared control

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        HStack(spacing: palette.spacingTight) {
            Text(title)
                .font(palette.font(size: 12))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 150, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(format(value.wrappedValue))
                .font(palette.numericFont(size: 11))
                .foregroundStyle(palette.textTertiary)
                .frame(width: 54, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(format(value.wrappedValue))
    }

    // MARK: - Preview column

    private var previewColumn: some View {
        ScrollView {
            ThemeEditorPreview(theme: draft, appearance: appearance, layout: layout)
                .padding(palette.spacingPage)
        }
        .frame(width: 340)
        .background(palette.surface.opacity(palette.theme.useMaterialBackground ? 0.6 : 1))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: palette.spacingRow) {
            Button(role: .destructive) {
                draft.resetAllToPreset()
            } label: {
                Text("Reset All to Preset")
            }
            .disabled(!draft.globalResetAvailability.canReset)
            .help(globalResetHelp)

            Button {
                draft = original
            } label: {
                Text("Revert Changes")
            }
            .disabled(draft == original)
            .help(draft == original
                  ? String(localized: "Nothing has changed since you opened the editor.")
                  : String(localized: "Discard every change made since the editor opened, without closing it."))

            Button {
                ThemeFileIO.exportTheme(
                    draft,
                    in: NSApp.keyWindow,
                    onError: { errorMessage = $0 },
                    onSuccess: { _ in }
                )
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .help(String(localized: "Write this theme to a .sentrytheme file. Exports the draft as it stands, including unsaved changes."))

            Spacer(minLength: 0)

            Button(role: .cancel) { onCancel() } label: { Text("Cancel") }
                .keyboardShortcut(.cancelAction)

            Button { onSave(draft) } label: { Text("Save") }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      ? String(localized: "Give the theme a name first.")
                      : String(localized: "Save this theme and close the editor."))
        }
        .padding(.horizontal, palette.spacingPage)
        .padding(.vertical, palette.spacingBlock)
    }

    private var globalResetHelp: String {
        if case .available(let presetName) = draft.globalResetAvailability {
            return String(localized: "Restore every color, font and geometry token to \(presetName). Keeps this theme's name.")
        }
        return draft.globalResetAvailability.unavailableReason ?? ""
    }
}

// MARK: - Token display names

extension FontWeightToken {
    /// Declaration order in `Theme.swift` happens to be weight order already,
    /// but relying on that would make a future insertion silently reorder a
    /// picker. Spelled out so the list is the list.
    static let allCasesInWeightOrder: [FontWeightToken] = [
        .ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black,
    ]

    var displayName: String {
        switch self {
        case .ultraLight: return String(localized: "Ultra Light")
        case .thin: return String(localized: "Thin")
        case .light: return String(localized: "Light")
        case .regular: return String(localized: "Regular")
        case .medium: return String(localized: "Medium")
        case .semibold: return String(localized: "Semibold")
        case .bold: return String(localized: "Bold")
        case .heavy: return String(localized: "Heavy")
        case .black: return String(localized: "Black")
        }
    }
}

extension MaterialToken {
    static let allCasesInOrder: [MaterialToken] = [
        .menu, .popover, .sidebar, .hudWindow, .underWindowBackground, .contentBackground,
    ]

    var displayName: String {
        switch self {
        case .menu: return String(localized: "Menu")
        case .popover: return String(localized: "Popover")
        case .sidebar: return String(localized: "Sidebar")
        case .hudWindow: return String(localized: "HUD")
        case .underWindowBackground: return String(localized: "Under Window")
        case .contentBackground: return String(localized: "Content")
        }
    }
}
