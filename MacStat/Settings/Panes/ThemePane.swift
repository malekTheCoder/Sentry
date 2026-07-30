import SwiftUI
import MacStatKit

/// Preset picker for §9.3. Each card renders itself with its *own* tokens, not
/// the active theme's — the grid is a set of live thumbnails, which is the
/// whole point of §9.3's first bullet.
struct ThemePane: View {

    @ObservedObject var store: SettingsStore

    /// Simplest persistence path consistent with the iOS side's
    /// `SettingsTabView.selectedThemeID` (`@AppStorage`, no store round-trip)
    /// — see that file for the precedent. This toggle is wired to read/write
    /// a persisted preference; it does not yet drive live switching between
    /// presets when the OS appearance changes, since doing that for real
    /// means resolving "system light/dark -> which preset" somewhere both
    /// the dropdown and dashboard read from, which lives outside
    /// `MacStat/Settings/` (this slice's scope) and is left as a follow-up.
    @AppStorage("matchSystemAppearance") private var matchSystemAppearance: Bool = false

    @Environment(\.themePalette) private var palette

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(Theme.builtInPresets) { theme in
                        ThemeCard(
                            theme: theme,
                            isSelected: theme.id == store.settings.themeID
                        ) {
                            store.settings.themeID = theme.id
                        }
                    }
                }

                Rectangle()
                    .fill(palette.separator)
                    .frame(height: 1)

                HStack {
                    Text("Match system appearance")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                    Spacer()
                    Toggle("", isOn: $matchSystemAppearance)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                GroupBox {
                    Label(
                        "Custom theme editing coming soon — duplicating a preset, per-token color wells, the per-metric color grid, and .macstattheme import/export are not in this build.",
                        systemImage: "paintbrush.pointed"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
            .padding(16)
        }
    }
}

/// One selectable preset thumbnail.
private struct ThemeCard: View {

    let theme: Theme
    let isSelected: Bool
    let onSelect: () -> Void

    // The card previews the theme, so it resolves tokens against the theme's
    // own intent rather than the settings window's appearance. Dark is the
    // right default for the appearance-fixed presets; `.system` and `.paper`
    // are handled by their own light/dark pairs either way.
    private var scheme: ColorScheme { .dark }

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
