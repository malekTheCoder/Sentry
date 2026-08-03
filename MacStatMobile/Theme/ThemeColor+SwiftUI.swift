import SwiftUI
import MacStatKit

// MARK: - ThemeColor -> Color (iOS)

/// iOS counterpart of `MacStat/Dropdown/ThemeColor+SwiftUI.swift` (the Mac
/// app target's `ThemeColor`/`ThemePalette` SwiftUI bridge).
///
/// **Why this is a separate file instead of sharing the Mac one.** The Mac
/// file's actual code — hex parsing, `Color(.sRGB, ...)` construction,
/// `ColorScheme` branching — has no AppKit dependency; it's pure
/// SwiftUI/Foundation and genuinely could run unmodified on iOS. The
/// reason it isn't simply imported here is where it *lives*: it's a member
/// of the `MacStat` app target, not `MacStatKit`, and Xcode/SwiftPM app
/// targets cannot import each other — only frameworks are shareable that
/// way. Moving it into `MacStatKit` instead of duplicating it was
/// considered and rejected for this task specifically: `ThemePalette` there
/// is `internal` (not `public`), so promoting it would mean auditing and
/// re-exporting the whole theming surface through a framework boundary for
/// the first time — real, valuable work, but a materially larger and
/// riskier change than this task's scope (three other agents are touching
/// History/Alerts/Settings in parallel against today's `MacStat` target
/// shape). Duplicating this one small, stable file keeps that refactor
/// possible later without blocking this one on it now — see this file's
/// contents diffing near-identically against the Mac original as the
/// intended state, not an accident to "fix" casually.
///
/// If/when someone does promote this to `MacStatKit`, this file and its Mac
/// counterpart both get deleted in favor of the shared one; until then, a
/// change to either should be mirrored in the other by hand.

extension ColorScheme {
    /// Mirrors the Mac file's mapping exactly — see its doc comment for why
    /// this isn't exhaustive.
    var themeAppearance: ThemeAppearance {
        self == .dark ? .dark : .light
    }
}

extension ThemeColor {
    /// Resolves this token against a color scheme. See the Mac counterpart's
    /// doc comment for why the *parsing* now lives in `MacStatKit` while the
    /// `Color` construction and the malformed-value fallback stay here.
    ///
    /// The hex parser this used to carry privately was deleted rather than
    /// updated: it and the Mac copy were the two halves of the duplication
    /// this file's header describes, and the theme editor's contrast checker
    /// needs one parser that model code can call. That is a *partial*
    /// resolution of the promotion described above — `ThemePalette` below is
    /// still duplicated, and a change to it still has to be mirrored by hand.
    func color(for scheme: ColorScheme) -> Color {
        guard let rgba = rgba(for: scheme.themeAppearance) else {
            // P5: a malformed theme must not take the UI down or render an
            // invisible view. Neutral gray is obviously "wrong" to the eye
            // without being unreadable.
            return Color(.sRGB, red: 0.5, green: 0.5, blue: 0.5, opacity: clampedOpacity)
        }
        return Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

// MARK: - ThemePalette

/// A `Theme` with a color scheme already applied — see the Mac counterpart
/// for the full rationale. Kept `internal`, matching the Mac file, since
/// nothing outside this app target needs to reference it directly.
struct ThemePalette: Equatable {
    let theme: Theme
    let scheme: ColorScheme

    init(theme: Theme, scheme: ColorScheme) {
        self.theme = theme
        self.scheme = scheme
    }

    var background: Color { theme.background.color(for: scheme) }
    var surface: Color { theme.surface.color(for: scheme) }
    var surfaceElevated: Color { theme.surfaceElevated.color(for: scheme) }
    var textPrimary: Color { theme.textPrimary.color(for: scheme) }
    var textSecondary: Color { theme.textSecondary.color(for: scheme) }
    var textTertiary: Color { theme.textTertiary.color(for: scheme) }
    var accent: Color { theme.accent.color(for: scheme) }
    var success: Color { theme.success.color(for: scheme) }
    var warning: Color { theme.warning.color(for: scheme) }
    var danger: Color { theme.danger.color(for: scheme) }
    var chartGrid: Color { theme.chartGrid.color(for: scheme) }
    var separator: Color { theme.separator.color(for: scheme) }

    var chartFill: [Color] {
        // A single-stop gradient is degenerate in SwiftUI, and an empty
        // `chartFill` is legal in the data model — fall back to the accent.
        let stops = theme.chartFill.map { $0.color(for: scheme) }
        return stops.count >= 2 ? stops : [accent.opacity(0.35), accent.opacity(0)]
    }

    /// Per-metric color with an accent fallback, so a user-authored theme
    /// missing a key still renders. Goes through `Theme.metricColor(for:)`
    /// rather than subscripting `metricColors` with a raw string.
    func metricColor(_ metric: MetricID) -> Color {
        theme.metricColor(for: metric)?.color(for: scheme) ?? accent
    }

    // MARK: Typography

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch theme.fontFamily {
        case .system:
            return .system(size: size, weight: weight)
        case .systemMono:
            return .system(size: size, weight: weight, design: .monospaced)
        case .rounded:
            return .system(size: size, weight: weight, design: .rounded)
        case .custom(let name):
            // `.custom(_:size:)` silently falls back to the system font when
            // the PostScript name isn't installed, which is the degradation
            // we want for imported themes.
            return .custom(name, size: size)
        }
    }

    // MARK: Geometry

    var cornerRadius: CGFloat { theme.cornerRadius }

    /// Base spacing unit derived from the density token; every card uses
    /// multiples of it so density changes scale the whole layout coherently.
    var spacing: CGFloat {
        switch theme.density {
        case .compact: return 6
        case .comfortable: return 9
        case .spacious: return 13
        }
    }

    // MARK: Spacing scale — named steps, mirroring the Mac palette exactly.

    /// Gap inside a tightly coupled pair (dot → its sentence, value → unit).
    var spacingTight: CGFloat { (spacing * 0.5).rounded() }

    /// Padding inside a grouped block, and the gap between sibling rows.
    var spacingRow: CGFloat { spacing }

    /// Padding around grouped surfaces; gap between related blocks.
    var spacingBlock: CGFloat { (spacing * 1.5).rounded() }

    /// Gap between major sections.
    var spacingSection: CGFloat { spacing * 2 }

    /// Screen edge padding.
    var spacingPage: CGFloat { spacing * 2 }

    var glow: Double { min(max(theme.glowIntensity, 0), 1) }

    /// Standard transition per the handoff: ≤180ms ease-out, nothing under
    /// Reduce Motion (the setting asks for no movement, not less).
    static func motion(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.14)
    }
}

// MARK: - Card chrome

extension View {
    /// The one card chrome every grouped block in the iPhone app wears —
    /// the iOS sibling of the Mac's `quietCard`, per the redesign handoff:
    /// fill only, no border, no shadow, no glass. Material themes keep a
    /// touch of translucency so the wash behind still reads; opaque themes
    /// get the flat quiet fill.
    @ViewBuilder
    func glassCard(_ palette: ThemePalette) -> some View {
        let shape = RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
        self
            .background(shape.fill(palette.surface.opacity(palette.theme.useMaterialBackground ? 0.5 : 0.6)))
    }

    /// Screen backdrop: material themes get the theme's translucent wash
    /// over the system background, opaque themes their solid background.
    @ViewBuilder
    func themedScreenBackground(_ palette: ThemePalette) -> some View {
        if palette.theme.useMaterialBackground {
            self.background(palette.background.opacity(0.6)).background(.regularMaterial)
        } else {
            self.background(palette.background)
        }
    }

    /// The ledger hairline between borderless rows.
    func ledgerDivider(_ palette: ThemePalette) -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.separator)
                .frame(height: 1)
        }
    }
}

// MARK: - Environment

private struct ThemePaletteKey: EnvironmentKey {
    static let defaultValue = ThemePalette(theme: .defaultTheme, scheme: .dark)
}

extension EnvironmentValues {
    var themePalette: ThemePalette {
        get { self[ThemePaletteKey.self] }
        set { self[ThemePaletteKey.self] = newValue }
    }
}
