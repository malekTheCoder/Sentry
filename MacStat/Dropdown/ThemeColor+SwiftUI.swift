import SwiftUI
import MacStatKit

// MARK: - ThemeColor -> Color

extension ThemeColor {
    /// Resolves this token against a color scheme. Parsing lives here rather
    /// than in `Theme.swift` because hex-string -> `Color` is a rendering
    /// concern; the data model deliberately stores unvalidated strings so a
    /// bad import can round-trip through the theme editor instead of failing
    /// to decode (see `ThemeColor.light`'s doc comment).
    func color(for scheme: ColorScheme) -> Color {
        let hex = (scheme == .dark) ? dark : light
        guard let rgba = Self.components(fromHex: hex) else {
            // P5: a malformed theme must not take the UI down or render an
            // invisible view. Neutral gray is obviously "wrong" to the eye
            // without being unreadable.
            return Color(.sRGB, red: 0.5, green: 0.5, blue: 0.5, opacity: clampedOpacity)
        }
        return Color(
            .sRGB,
            red: rgba.r,
            green: rgba.g,
            blue: rgba.b,
            opacity: rgba.a * clampedOpacity
        )
    }

    private var clampedOpacity: Double { min(max(opacity, 0), 1) }

    /// Accepts `RGB`, `RRGGBB`, and `RRGGBBAA`, with or without a leading `#`.
    /// Returns nil (never a force-unwrap or a crash) for anything else.
    static func components(fromHex raw: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }

        let expanded: String
        switch hex.count {
        case 3: expanded = hex.map { "\($0)\($0)" }.joined()
        case 6, 8: expanded = hex
        default: return nil
        }

        guard let value = UInt64(expanded, radix: 16) else { return nil }
        if expanded.count == 8 {
            return (
                Double((value >> 24) & 0xFF) / 255,
                Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255
            )
        }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255,
            1.0
        )
    }
}

// MARK: - ThemePalette

/// A `Theme` with a color scheme already applied, so views ask for
/// `palette.textPrimary` instead of repeating `.color(for: scheme)` at every
/// call site. Holds the raw theme too — geometry/typography tokens don't
/// depend on appearance.
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

    /// Typography for any number that changes while the user is looking at it.
    ///
    /// Honours `Theme.numericStyle` instead of hard-coding `.monospacedDigit()`
    /// at every call site: with `.monospacedDigit` (what every built-in preset
    /// picks, including the Notion default) a CPU readout stepping 9% → 10% →
    /// 100% keeps a fixed glyph advance, so a right-aligned value column and a
    /// 1 Hz countdown never shift the layout underneath the cursor. A theme
    /// that explicitly opts into `.proportional` gets proportional figures —
    /// that token exists to be obeyed, and the dropdown is the only surface
    /// besides `BarModuleRenderer` that was ignoring it.
    func numericFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let base = font(size: size, weight: weight)
        return theme.numericStyle == .monospacedDigit ? base.monospacedDigit() : base
    }

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
    /// multiples of it so density changes scale the whole dropdown coherently.
    var spacing: CGFloat {
        switch theme.density {
        case .compact: return 6
        case .comfortable: return 9
        case .spacious: return 13
        }
    }

    // MARK: Spacing scale
    //
    // Named steps off `spacing` rather than `palette.spacing * 1.4`-style
    // arithmetic scattered through the views. Three reasons: the multipliers
    // in the old dropdown had drifted (1.4 here, 1.5 there, 1.6 in the
    // battery card) so nothing lined up across cards; every step stays a
    // whole-point value at all three densities, which keeps hairline
    // separators from landing on half-pixels; and a reader can see the
    // rhythm — 0.5 / 1 / 1.5 / 2 / 3 — in one place.

    /// Gap inside a tightly coupled pair (icon → its label, value → its unit).
    var spacingTight: CGFloat { (spacing * 0.5).rounded() }

    /// Padding inside a grouped block, and the gap between sibling rows.
    var spacingRow: CGFloat { spacing }

    /// Padding around the dropdown's own edges and inside grouped surfaces.
    var spacingBlock: CGFloat { (spacing * 1.5).rounded() }

    /// Gap between major sections (header / vitals / keep-awake / actions).
    var spacingSection: CGFloat { spacing * 2 }

    // MARK: Motion
    //
    // "Subtle and fast": 140ms ease-out, nothing bouncy. Returning an
    // Optional lets a call site pass the result straight to `withAnimation`
    // and get *no* animation under Reduce Motion, rather than a shorter one —
    // the accessibility setting asks for no movement, not less movement.

    /// Standard disclosure/hover transition. `nil` under Reduce Motion.
    static func motion(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.14)
    }

    /// Slightly slower step for content that changes size (a row expanding),
    /// still inside the 120–180ms band.
    static func disclosureMotion(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
    }

    var glow: Double { min(max(theme.glowIntensity, 0), 1) }
}

// MARK: - Environment

private struct ThemePaletteKey: EnvironmentKey {
    static let defaultValue = ThemePalette(theme: .slate, scheme: .dark)
}

extension EnvironmentValues {
    var themePalette: ThemePalette {
        get { self[ThemePaletteKey.self] }
        set { self[ThemePaletteKey.self] = newValue }
    }
}
