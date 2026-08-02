import SwiftUI
import MacStatKit

// MARK: - ThemeColor -> Color

extension ColorScheme {
    /// SwiftUI's appearance as the model layer's. Not exhaustive by choice:
    /// `ColorScheme` is a non-frozen enum, and a future third case is far
    /// more likely to resemble light than dark on a Mac whose default is
    /// light — a `@unknown default` mapping to `.light` beats a crash and
    /// beats an `Optional` every call site would have to unwrap.
    var themeAppearance: ThemeAppearance {
        self == .dark ? .dark : .light
    }
}

extension ThemeColor {
    /// Resolves this token against a color scheme.
    ///
    /// The *parsing* moved to `MacStatKit` (see
    /// `ThemeColor.components(fromHex:)` there) so the contrast auditor and
    /// the `.sentrytheme` validator agree with the renderer byte for byte;
    /// what stays here is the part that is genuinely a rendering concern —
    /// turning numbers into a SwiftUI `Color`, and deciding what to draw when
    /// the numbers don't exist. The data model still deliberately stores
    /// unvalidated strings so a bad import can round-trip through the theme
    /// editor instead of failing to decode (see `ThemeColor.light`'s doc
    /// comment).
    func color(for scheme: ColorScheme) -> Color {
        guard let rgba = rgba(for: scheme.themeAppearance) else {
            // P5: a malformed theme must not take the UI down or render an
            // invisible view. Neutral gray is obviously "wrong" to the eye
            // without being unreadable.
            return Color(.sRGB, red: 0.5, green: 0.5, blue: 0.5, opacity: clampedOpacity)
        }
        return Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }

    /// The token as a `Color` for a `ColorPicker` to bind to, with `opacity`
    /// deliberately **excluded**.
    ///
    /// The editor gives opacity its own slider rather than folding it into
    /// the well. `ColorPicker(supportsOpacity: true)` looks like the obvious
    /// answer and is the wrong one here: `ThemeColor` stores opacity as a
    /// separate multiplier on top of a hex string that may *itself* carry an
    /// alpha byte (`#RRGGBBAA`), so a round-trip through a single alpha
    /// channel would silently collapse the two into one and rewrite hex the
    /// user hadn't touched. A well that edits the hue and a slider that edits
    /// the multiplier map one-to-one onto what is actually stored.
    func pickerColor(for scheme: ColorScheme) -> Color {
        guard let rgba = rgba(for: scheme.themeAppearance) else {
            return Color(.sRGB, red: 0.5, green: 0.5, blue: 0.5, opacity: 1)
        }
        return Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: 1)
    }
}

// MARK: - Color -> hex (the theme editor's write path)

extension Color {
    /// `#RRGGBB` for this color, or `nil` if it can't be expressed in sRGB.
    ///
    /// Goes through `NSColor.usingColorSpace(.sRGB)` rather than reading
    /// components off the `Color` directly: macOS color wells can hand back a
    /// value in Display P3 or a named catalog color, and reading those
    /// channels raw would store numbers that mean something different when
    /// the theme is drawn. Conversion can fail (a pattern color, a color
    /// space with no sRGB path), and `nil` is the honest answer — the editor
    /// leaves the token unchanged and says so rather than writing `#000000`.
    ///
    /// Alpha is dropped, not encoded as `#RRGGBBAA`: the editor's wells never
    /// produce a transparent color (see `pickerColor(for:)`), so an alpha
    /// byte here could only come from rounding noise, and writing one would
    /// double up with `ThemeColor.opacity`.
    func themeHex() -> String? {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> Int {
            Int((min(max(component, 0), 1) * 255).rounded())
        }
        return String(
            format: "#%02X%02X%02X",
            byte(srgb.redComponent),
            byte(srgb.greenComponent),
            byte(srgb.blueComponent)
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

    /// Module-level color for surfaces keyed by module rather than metric
    /// (the dropdown's vitals rows): each module resolves through its
    /// representative metric so it matches the Dashboard's chart tints.
    func moduleColor(_ module: MetricModule) -> Color {
        switch module {
        case .cpu: return metricColor(.cpuTotalPercent)
        case .gpu: return metricColor(.gpuUtilizationPercent)
        case .memory: return metricColor(.memoryUsedBytes)
        case .disk: return metricColor(.diskReadBytesPerSec)
        case .network: return metricColor(.networkRxBytesPerSec)
        case .thermal: return metricColor(.thermalSocTempC)
        case .battery, .ane, .system: return success
        }
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

    /// The main window's page gutter (and its column gap between side-by-side
    /// cards). `SectionRule` un-pads by exactly this to run full-bleed, so
    /// pages must use the token, not `spacing * 3` arithmetic.
    var spacingPage: CGFloat { spacing * 3 }

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

// MARK: - Themed backdrop

extension View {
    /// The one card chrome every Dashboard card wears. Material themes get
    /// Apple's real Liquid Glass on macOS 26+ (`glassEffect`, the same
    /// treatment system surfaces use — refraction and rim lighting, not a
    /// gray wash), an ultra-thin-material tile on older systems; opaque
    /// themes keep the flat elevated-surface fill. One modifier instead of
    /// six hand-copied chrome stacks is also what keeps "randomly placed"
    /// impossible: geometry lives here or nowhere.
    @ViewBuilder
    func dashboardCard(_ palette: ThemePalette) -> some View {
        let shape = RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
        if palette.theme.useMaterialBackground {
            if #available(macOS 26.0, *) {
                self
                    .padding(palette.spacingBlock)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: shape)
            } else {
                self
                    .padding(palette.spacingBlock)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(shape.fill(palette.surfaceElevated))
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.strokeBorder(palette.separator, lineWidth: 1))
            }
        } else {
            self
                .padding(palette.spacingBlock)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.surfaceElevated)
                .clipShape(shape)
                .overlay(shape.stroke(palette.separator, lineWidth: 1))
        }
    }

    /// The one way any themed surface paints its backdrop: for material
    /// themes, a real behind-window `NSVisualEffectView` (see `VisualEffect`
    /// — SwiftUI's `Material` renders flat gray inside an opaque window)
    /// under the theme's low-opacity background wash; for opaque themes,
    /// exactly the old solid fill.
    @ViewBuilder
    func themedBackdrop(_ palette: ThemePalette) -> some View {
        if palette.theme.useMaterialBackground {
            self
                .background(palette.background)
                .background(VisualEffect(material: palette.theme.materialStyle.nsMaterial))
        } else {
            self.background(palette.background)
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
