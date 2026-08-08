import SwiftUI
import SentryKit

/// Preset picker and custom-theme list for §9.3. Each card renders itself with
/// its *own* tokens, not the active theme's — the grid is a set of live
/// thumbnails, which is the whole point of §9.3's first bullet, and it is the
/// same rule `ThemeEditorPreview` follows for the theme being edited.
struct ThemePane: View {

    @ObservedObject var store: SettingsStore

    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var systemColorScheme

    /// The theme currently open in the editor sheet. `nil` means no sheet.
    ///
    /// Holds a whole `Theme` rather than an index or an id into
    /// `store.settings.customThemes` deliberately: an index would be
    /// invalidated by anything that reordered or removed a theme while the
    /// sheet was up, and an id would need re-resolving on every body pass to
    /// answer "does this still exist." The value is a draft either way — the
    /// editor works on a copy and hands one back on save (see
    /// `ThemeEditorView`) — so carrying the value is both simpler and the
    /// thing that actually matches how the sheet behaves.
    @State private var editing: Theme?

    @State private var errorMessage: String?
    @State private var confirmingDeletion: Theme?

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 14)]

    private var customThemes: [Theme] { store.settings.customThemes }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                presetsSection
                customSection
            }
            .padding(16)
        }
        .sheet(item: $editing) { theme in
            ThemeEditorView(
                theme: theme,
                layout: store.settings.menuBarLayout,
                initialAppearance: systemColorScheme.themeAppearance,
                onSave: { save($0) },
                onCancel: { editing = nil }
            )
            // The sheet is app chrome, so it themes off the *active* theme,
            // exactly like the pane behind it. Its preview column overrides
            // this for its own subtree with the draft's palette.
            .environment(\.themePalette, palette)
        }
        .alert(
            "Theme problem",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(
            "Delete theme?",
            isPresented: Binding(get: { confirmingDeletion != nil }, set: { if !$0 { confirmingDeletion = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let theme = confirmingDeletion { delete(theme) }
                confirmingDeletion = nil
            }
            Button("Cancel", role: .cancel) { confirmingDeletion = nil }
        } message: {
            // Deleting is the one destructive action here and it isn't
            // undoable — the theme lives only in settings.json. Naming the
            // theme, and saying what happens to the app if it was the active
            // one, is the difference between a confirmation and a speed bump.
            Text(deletionWarning)
        }
    }

    // MARK: - Presets

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                String(localized: "Presets"),
                String(localized: "Six built-in themes, each with a light and a dark variant. Presets can't be edited in place — duplicate one to make it yours.")
            )

            appearancePicker

            presetContrastNote

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Theme.builtInPresets) { theme in
                    ThemeCard(
                        theme: theme,
                        isSelected: theme.id == store.settings.themeID
                    ) {
                        store.settings.themeID = theme.id
                    }
                    .contextMenu {
                        Button("Duplicate & Edit") { duplicate(theme) }
                        Button("Export…") { export(theme) }
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    duplicate(store.resolvedTheme())
                } label: {
                    Label("Duplicate & Edit", systemImage: "plus.square.on.square")
                }
                .help(String(localized: "Fork “\(store.resolvedTheme().name)” into an editable copy."))

                Button {
                    importTheme()
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                .help(String(localized: "Open a .sentrytheme file. It's checked before anything is applied — a malformed file is rejected with the reason, not partly loaded."))

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Custom themes

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                String(localized: "Your Themes"),
                String(localized: "Themes you've duplicated or imported. Stored in settings.json, so they travel with the rest of your configuration.")
            )

            if customThemes.isEmpty {
                Text("None yet. “Duplicate & Edit” above forks whichever theme is currently selected; “Import…” opens a .sentrytheme file.")
                    .font(palette.font(size: 12))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(palette.spacingBlock)
                    .background(
                        RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                            .fill(palette.surface)
                    )
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(customThemes) { theme in
                        VStack(alignment: .leading, spacing: 6) {
                            ThemeCard(
                                theme: theme,
                                isSelected: theme.id == store.settings.themeID
                            ) {
                                store.settings.themeID = theme.id
                            }
                            .contextMenu {
                                Button("Edit…") { edit(theme) }
                                Button("Duplicate") { duplicate(theme) }
                                Button("Export…") { export(theme) }
                                Divider()
                                Button("Delete", role: .destructive) { confirmingDeletion = theme }
                            }

                            HStack(spacing: 10) {
                                Button("Edit") { edit(theme) }
                                Button("Export") { export(theme) }
                                Button("Delete", role: .destructive) { confirmingDeletion = theme }
                                Spacer(minLength: 0)
                            }
                            .buttonStyle(.link)
                            .font(palette.font(size: 11))

                            // §9.4 again, on the list rather than only in the
                            // editor: a theme that fails contrast must be
                            // identifiable *before* you open it, or the only
                            // way to find the bad one is to open all of them.
                            contrastSummary(for: theme)
                        }
                    }
                }
            }
        }
    }

    /// Auto / Light / Dark. Auto follows macOS; Light and Dark pin every
    /// theme to that half of its pair, app-wide (window, dropdown, and the
    /// palette relayed to the watch — the menu bar readout keeps following
    /// the menu bar itself).
    private var appearancePicker: some View {
        HStack(spacing: 10) {
            Text("Appearance")
                .font(palette.font(size: 12, weight: .medium))
                .foregroundStyle(palette.textPrimary)
            Picker("Appearance", selection: $store.settings.appearanceMode) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            Spacer(minLength: 0)
        }
    }

    /// **Why the presets carry one shared note instead of per-card warnings.**
    ///
    /// The contrast checker built for §9.4 reports that the shipped presets
    /// still have text pairs below 4.5:1 — chiefly the deliberately-faint
    /// tertiary ramp, and (in the halves that shipped before the light/dark
    /// pairing) semantic colors sitting on the elevated surface. That is
    /// measured, not suspected (`SentryTests/ThemeContrastTests.swift`
    /// asserts the exact shape of it).
    ///
    /// Stamping a red warning on every card was the first thing tried and is
    /// the wrong answer twice over: a warning that appears on every option
    /// is not information, and these palettes are a shipped design decision
    /// the user didn't make and can't fix from here. So the presets get one
    /// honest sentence, and the full per-token breakdown appears the moment
    /// a preset is duplicated and the user is somewhere they can actually
    /// act on it.
    ///
    /// Custom themes below *are* flagged individually, because those a user
    /// authored and can change.
    private var presetContrastNote: some View {
        Label(
            "Some presets use faint tertiary text and semantic colors that fall below WCAG AA's 4.5:1. Duplicate one to see the full per-token contrast report and fix it.",
            systemImage: "info.circle"
        )
        .font(palette.font(size: 11))
        .foregroundStyle(palette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func contrastSummary(for theme: Theme) -> some View {
        let audit = theme.contrastAudit
        if !audit.passesTextAA {
            Label(audit.headline, systemImage: "exclamationmark.triangle.fill")
                .font(palette.font(size: 10))
                .foregroundStyle(palette.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(palette.font(size: 14, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text(subtitle)
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func duplicate(_ theme: Theme) {
        // A duplicate isn't in settings until the user saves it, which is
        // what makes Cancel on a duplicate leave nothing behind — `save`
        // below appends or replaces by id, so no "is this new?" flag is
        // needed to tell the two apart.
        editing = theme.duplicated()
    }

    private func edit(_ theme: Theme) {
        editing = theme
    }

    /// Commits the editor's draft.
    ///
    /// Selecting the saved theme is deliberate and applies to edits as well as
    /// to new themes: someone who just spent time in a color editor wants to
    /// see the result on the app, and the alternative (save, then hunt for the
    /// card and click it) is a step with no purpose. It also means a theme is
    /// never saved into a state the user can't immediately see.
    private func save(_ theme: Theme) {
        if let index = store.settings.customThemes.firstIndex(where: { $0.id == theme.id }) {
            store.settings.customThemes[index] = theme
        } else {
            store.settings.customThemes.append(theme)
        }
        store.settings.themeID = theme.id
        editing = nil
    }

    private func delete(_ theme: Theme) {
        store.settings.customThemes.removeAll { $0.id == theme.id }
        // Leaving `themeID` pointing at a deleted theme would resolve to the
        // default preset anyway (`Theme.resolve(id:in:)`), but silently: the
        // grid would show nothing selected and the app would look like it had
        // lost its setting. Writing the fallback in makes the state visible.
        if store.settings.themeID == theme.id {
            store.settings.themeID = Theme.defaultTheme.id
        }
    }

    private var deletionWarning: String {
        guard let theme = confirmingDeletion else { return "" }
        let base = String(localized: "“\(theme.name)” will be removed from settings.json. This can't be undone — export it first if you want to keep a copy.")
        return store.settings.themeID == theme.id
            ? base + " " + String(localized: "It's the theme currently in use, so Sentry will fall back to \(Theme.defaultTheme.name).")
            : base
    }

    private func export(_ theme: Theme) {
        ThemeFileIO.exportTheme(
            theme,
            in: NSApp.keyWindow,
            onError: { errorMessage = $0 },
            onSuccess: { _ in }
        )
    }

    /// An imported theme opens in the editor rather than being applied
    /// straight away. Two reasons: it arrives as untrusted input that has
    /// passed structural validation but not a human's judgement, and §9.4's
    /// contrast findings are worth reading *before* the theme repaints the
    /// whole app. Cancel therefore discards it entirely, which is the right
    /// answer for a file that turns out to be unusable.
    private func importTheme() {
        ThemeFileIO.importTheme(
            in: NSApp.keyWindow,
            onError: { errorMessage = $0 },
            completion: { theme in
                editing = theme
            }
        )
    }
}

/// One selectable theme thumbnail.
private struct ThemeCard: View {

    let theme: Theme
    let isSelected: Bool
    let onSelect: () -> Void

    // Every preset now carries a real light/dark pair, so the honest preview
    // is the half the app is actually showing — which the pane's environment
    // already resolves (the user's Auto/Light/Dark pin feeds the window's
    // color scheme via `MainWindowView.forcedScheme`).
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                swatch
                HStack(spacing: 6) {
                    // §9.4: selection is never signalled by the border alone.
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                    Text(theme.name)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.name) theme")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// A miniature of what the theme actually produces: background, a text
    /// line, and a few metric-colored bars.
    private var swatch: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("72%")
                    .font(font(size: theme.barFontSize, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.metricColor(for: .batteryChargePercent)?.color(for: scheme)
                                     ?? theme.accent.color(for: scheme))
                Text("·")
                    .foregroundStyle(theme.textTertiary.color(for: scheme))
                Text("CPU 14%")
                    .font(font(size: theme.barFontSize))
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary.color(for: scheme))
            }

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(barHeights.enumerated()), id: \.offset) { index, height in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(barColor(index: index))
                        .frame(width: 7, height: height)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 26, alignment: .bottom)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: max(theme.cornerRadius, 4), style: .continuous)
                .fill(theme.background.color(for: scheme))
        )
        .accessibilityHidden(true)
    }

    private let barHeights: [CGFloat] = [10, 18, 13, 24, 16, 21]

    private func barColor(index: Int) -> Color {
        let metrics: [MetricID] = [
            .cpuTotalPercent, .gpuUtilizationPercent, .memoryUsedBytes,
            .networkRxBytesPerSec, .diskReadBytesPerSec, .batteryChargePercent,
        ]
        guard index < metrics.count else { return theme.accent.color(for: scheme) }
        return theme.metricColor(for: metrics[index])?.color(for: scheme)
            ?? theme.accent.color(for: scheme)
    }

    private func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch theme.fontFamily {
        case .system: return .system(size: size, weight: weight)
        case .systemMono: return .system(size: size, weight: weight, design: .monospaced)
        case .rounded: return .system(size: size, weight: weight, design: .rounded)
        case .custom(let name): return .custom(name, size: size)
        }
    }
}
