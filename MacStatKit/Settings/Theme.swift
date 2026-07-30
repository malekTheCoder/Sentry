import Foundation
import CoreGraphics

// MARK: - Supporting tokens

/// Typeface choice for bar-item and dropdown text. `.custom` carries a PostScript
/// font name so a user-imported `.macstattheme` can request an installed font
/// without the enum needing a case per font.
public enum FontChoice: Codable, Equatable, Sendable {
    case system
    case systemMono
    case rounded
    case custom(String)
}

/// Mirrors SwiftUI's `Font.Weight` cases as a `Codable` token — `Font.Weight`
/// itself is not `Codable`, so theme JSON round-tripping needs its own copy.
public enum FontWeightToken: String, Codable, Equatable, Sendable {
    case ultraLight
    case thin
    case light
    case regular
    case medium
    case semibold
    case bold
    case heavy
    case black
}

/// Digit rendering for numeric readouts (percentages, wattages, etc).
/// `.monospacedDigit` keeps fast-changing numbers from jittering the layout.
public enum NumericStyle: String, Codable, Equatable, Sendable {
    case proportional
    case monospacedDigit
}

/// Overall spacing/sizing scale for dropdown rows and bar-item padding.
public enum Density: String, Codable, Equatable, Sendable {
    case compact
    case comfortable
    case spacious
}

/// Rendering style for per-metric history sparklines/charts.
public enum ChartStyle: String, Codable, Equatable, Sendable {
    case line
    case area
    case bars
    case stepped
}

/// A `Codable` stand-in for `NSVisualEffectView.Material` — the AppKit enum isn't
/// `Codable`, and only a subset of materials make sense as a menu-bar dropdown
/// backdrop, so this is a deliberately small, named set rather than a 1:1 mirror.
public enum MaterialToken: String, Codable, Equatable, Sendable {
    case menu
    case popover
    case sidebar
    case hudWindow
    case underWindowBackground
    case contentBackground
}

// MARK: - ThemeColor

/// A color token expressed as a light/dark hex pair plus opacity, so a single
/// token can answer `NSApp.effectiveAppearance` without the rendering layer
/// needing per-appearance branching at every call site.
public struct ThemeColor: Codable, Equatable, Sendable {
    /// Hex string, e.g. "#0A0D0A". No leading validation here — malformed
    /// values are a theme-editor/import concern, not a data-model concern.
    public var light: String
    public var dark: String
    /// 0...1, applied on top of the resolved hex color.
    public var opacity: Double

    public init(light: String, dark: String, opacity: Double = 1.0) {
        self.light = light
        self.dark = dark
        self.opacity = opacity
    }

    /// Convenience for tokens that don't vary by appearance (most non-"System"
    /// presets are appearance-fixed by design — Terminal stays dark even if
    /// macOS is in light mode).
    public init(hex: String, opacity: Double = 1.0) {
        self.light = hex
        self.dark = hex
        self.opacity = opacity
    }
}

// MARK: - Theme

public struct Theme: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var isBuiltIn: Bool

    // Color tokens — every UI surface references a token, never a literal
    public var background: ThemeColor
    public var surface: ThemeColor
    public var surfaceElevated: ThemeColor
    public var textPrimary: ThemeColor
    public var textSecondary: ThemeColor
    public var textTertiary: ThemeColor
    public var accent: ThemeColor
    public var success: ThemeColor          // e.g. charging, healthy
    public var warning: ThemeColor
    public var danger: ThemeColor
    public var chartGrid: ThemeColor
    public var chartFill: [ThemeColor]      // gradient stops
    public var separator: ThemeColor

    // Per-metric colors so users can make CPU cyan and GPU magenta
    public var metricColors: [String: ThemeColor]

    // Typography
    public var fontFamily: FontChoice       // .system / .systemMono / .rounded / custom
    public var barFontSize: CGFloat         // 9...14
    public var barFontWeight: FontWeightToken
    public var numericStyle: NumericStyle   // .proportional / .monospacedDigit

    // Geometry
    public var cornerRadius: CGFloat
    public var density: Density             // .compact / .comfortable / .spacious
    public var chartStyle: ChartStyle       // .line / .area / .bars / .stepped
    public var chartLineWidth: CGFloat
    public var showChartGrid: Bool
    public var barGraphWidth: CGFloat       // width of menu-bar sparklines

    // Effects
    public var useMaterialBackground: Bool  // NSVisualEffectView blur
    public var materialStyle: MaterialToken
    public var glowIntensity: Double        // 0...1, for the "hacker" aesthetic
    public var scanlineOverlay: Bool        // optional CRT vibe

    public init(
        id: String,
        name: String,
        isBuiltIn: Bool,
        background: ThemeColor,
        surface: ThemeColor,
        surfaceElevated: ThemeColor,
        textPrimary: ThemeColor,
        textSecondary: ThemeColor,
        textTertiary: ThemeColor,
        accent: ThemeColor,
        success: ThemeColor,
        warning: ThemeColor,
        danger: ThemeColor,
        chartGrid: ThemeColor,
        chartFill: [ThemeColor],
        separator: ThemeColor,
        metricColors: [String: ThemeColor],
        fontFamily: FontChoice,
        barFontSize: CGFloat,
        barFontWeight: FontWeightToken,
        numericStyle: NumericStyle,
        cornerRadius: CGFloat,
        density: Density,
        chartStyle: ChartStyle,
        chartLineWidth: CGFloat,
        showChartGrid: Bool,
        barGraphWidth: CGFloat,
        useMaterialBackground: Bool,
        materialStyle: MaterialToken,
        glowIntensity: Double,
        scanlineOverlay: Bool
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.background = background
        self.surface = surface
        self.surfaceElevated = surfaceElevated
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.accent = accent
        self.success = success
        self.warning = warning
        self.danger = danger
        self.chartGrid = chartGrid
        self.chartFill = chartFill
        self.separator = separator
        self.metricColors = metricColors
        self.fontFamily = fontFamily
        self.barFontSize = barFontSize
        self.barFontWeight = barFontWeight
        self.numericStyle = numericStyle
        self.cornerRadius = cornerRadius
        self.density = density
        self.chartStyle = chartStyle
        self.chartLineWidth = chartLineWidth
        self.showChartGrid = showChartGrid
        self.barGraphWidth = barGraphWidth
        self.useMaterialBackground = useMaterialBackground
        self.materialStyle = materialStyle
        self.glowIntensity = glowIntensity
        self.scanlineOverlay = scanlineOverlay
    }
}

// MARK: - Built-in presets (Nocturne redesign — 2 minimal defaults + 5 IDE-inspired)

extension Theme {
    /// Shared per-theme metric→role mapping: CPU/Disk track accent, GPU/Network
    /// track success, Memory tracks warning, Thermal tracks danger — the same
    /// semantic pattern the Dashboard mock uses for its 6-module grid, so every
    /// theme reuses its own 4 semantic tokens rather than carrying a 5th/6th
    /// bespoke hue nobody asked for.
    fileprivate static func nocturneMetricColors(
        accent: ThemeColor, success: ThemeColor, warning: ThemeColor, danger: ThemeColor
    ) -> [String: ThemeColor] {
        [
            "cpu.total_percent": accent,
            "gpu.utilization_percent": success,
            "memory.used_bytes": warning,
            "disk.read_bytes_per_sec": accent,
            "network.rx_bytes_per_sec": success,
            "thermal.soc_temp_c": danger,
        ]
    }

    /// Notion — the app's default theme, and the only built-in that tracks the
    /// system appearance rather than committing to one. Every token is a
    /// light/dark pair, so `ThemePalette` resolves it against
    /// `NSApp.effectiveAppearance` (macOS) / `colorScheme` (iOS) instead of
    /// forcing a single look the way the IDE-inspired presets below do.
    ///
    /// The palette is deliberately near-monochrome: a warm-neutral text ramp on
    /// an untinted background, with a single blue accent. Semantic colors are
    /// reserved for state that actually needs attention (warning/danger), which
    /// is what keeps a dense metrics UI from reading as confetti — see
    /// `nocturneMetricColors` for how the six metric modules reuse those four
    /// semantic tokens rather than carrying six bespoke hues.
    public static let notion = Theme(
        id: "builtin.notion",
        name: "Notion",
        isBuiltIn: true,
        background: ThemeColor(light: "#FFFFFF", dark: "#191919"),
        surface: ThemeColor(light: "#F7F6F3", dark: "#202020"),
        surfaceElevated: ThemeColor(light: "#EFEEE9", dark: "#2C2C2C"),
        textPrimary: ThemeColor(light: "#37352F", dark: "#D4D4D4"),
        textSecondary: ThemeColor(light: "#787774", dark: "#9B9B9B"),
        textTertiary: ThemeColor(light: "#9B9A97", dark: "#6F6F6F"),
        accent: ThemeColor(light: "#2383E2", dark: "#529CCA"),
        success: ThemeColor(light: "#0F7B6C", dark: "#4DAB9A"),
        warning: ThemeColor(light: "#D9730D", dark: "#FFA344"),
        danger: ThemeColor(light: "#E03E3E", dark: "#FF7369"),
        chartGrid: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.06),
        chartFill: [
            ThemeColor(light: "#2383E2", dark: "#529CCA", opacity: 0.18),
            ThemeColor(light: "#2383E2", dark: "#529CCA", opacity: 0.0),
        ],
        separator: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.09),
        metricColors: nocturneMetricColors(
            accent: ThemeColor(light: "#2383E2", dark: "#529CCA"),
            success: ThemeColor(light: "#0F7B6C", dark: "#4DAB9A"),
            warning: ThemeColor(light: "#D9730D", dark: "#FFA344"),
            danger: ThemeColor(light: "#E03E3E", dark: "#FF7369")
        ),
        fontFamily: .system,
        barFontSize: 11,
        barFontWeight: .medium,
        numericStyle: .monospacedDigit,
        cornerRadius: 8,
        density: .comfortable,
        chartStyle: .area,
        chartLineWidth: 1.5,
        showChartGrid: false,
        barGraphWidth: 36,
        useMaterialBackground: true,
        materialStyle: .popover,
        glowIntensity: 0.0,
        scanlineOverlay: false
    )

    /// Slate — minimal, dark.
    public static let slate = Theme(
        id: "builtin.slate",
        name: "Slate",
        isBuiltIn: true,
        background: ThemeColor(hex: "#0D0E12"),
        surface: ThemeColor(hex: "#181A21"),
        surfaceElevated: ThemeColor(hex: "#1F212B"),
        textPrimary: ThemeColor(hex: "#E7E7EA"),
        textSecondary: ThemeColor(hex: "#9A9CA8"),
        textTertiary: ThemeColor(hex: "#6B6D78"),
        accent: ThemeColor(hex: "#7C8CF0"),
        success: ThemeColor(hex: "#5FCE8F"),
        warning: ThemeColor(hex: "#E0A851"),
        danger: ThemeColor(hex: "#E0616B"),
        chartGrid: ThemeColor(hex: "#FFFFFF", opacity: 0.08),
        chartFill: [ThemeColor(hex: "#7C8CF0", opacity: 0.35), ThemeColor(hex: "#7C8CF0", opacity: 0.0)],
        separator: ThemeColor(hex: "#FFFFFF", opacity: 0.08),
        metricColors: nocturneMetricColors(
            accent: ThemeColor(hex: "#7C8CF0"), success: ThemeColor(hex: "#5FCE8F"),
            warning: ThemeColor(hex: "#E0A851"), danger: ThemeColor(hex: "#E0616B")
        ),
        fontFamily: .system,
        barFontSize: 11,
        barFontWeight: .medium,
        numericStyle: .monospacedDigit,
        cornerRadius: 6,
        density: .compact,
        chartStyle: .area,
        chartLineWidth: 1.0,
        showChartGrid: false,
        barGraphWidth: 40,
        useMaterialBackground: false,
        materialStyle: .menu,
        glowIntensity: 0.0,
        scanlineOverlay: false
    )

    /// Paper — minimal default, light.
    public static let paper = Theme(
        id: "builtin.paper",
        name: "Paper",
        isBuiltIn: true,
        background: ThemeColor(hex: "#F7F6F3"),
        surface: ThemeColor(hex: "#ECE9E3"),
        surfaceElevated: ThemeColor(hex: "#E3DED4"),
        textPrimary: ThemeColor(hex: "#232220"),
        textSecondary: ThemeColor(hex: "#5A584F"),
        textTertiary: ThemeColor(hex: "#86837A"),
        accent: ThemeColor(hex: "#5B57C9"),
        success: ThemeColor(hex: "#2F9E5C"),
        warning: ThemeColor(hex: "#B5791C"),
        danger: ThemeColor(hex: "#C4404B"),
        chartGrid: ThemeColor(hex: "#000000", opacity: 0.07),
        chartFill: [ThemeColor(hex: "#5B57C9", opacity: 0.27), ThemeColor(hex: "#5B57C9", opacity: 0.0)],
        separator: ThemeColor(hex: "#000000", opacity: 0.07),
        metricColors: nocturneMetricColors(
            accent: ThemeColor(hex: "#5B57C9"), success: ThemeColor(hex: "#2F9E5C"),
            warning: ThemeColor(hex: "#B5791C"), danger: ThemeColor(hex: "#C4404B")
        ),
        fontFamily: .system,
        barFontSize: 11,
        barFontWeight: .medium,
        numericStyle: .monospacedDigit,
        cornerRadius: 6,
        density: .compact,
        chartStyle: .area,
        chartLineWidth: 1.0,
        showChartGrid: false,
        barGraphWidth: 36,
        useMaterialBackground: false,
        materialStyle: .contentBackground,
        glowIntensity: 0.0,
        scanlineOverlay: false
    )

    /// Nord — IDE-inspired.
    public static let nord = Theme(
        id: "builtin.nord",
        name: "Nord",
        isBuiltIn: true,
        background: ThemeColor(hex: "#2E3440"),
        surface: ThemeColor(hex: "#3B4252"),
        surfaceElevated: ThemeColor(hex: "#434C5E"),
        textPrimary: ThemeColor(hex: "#ECEFF4"),
        textSecondary: ThemeColor(hex: "#D8DEE9"),
        textTertiary: ThemeColor(hex: "#7B88A1"),
        accent: ThemeColor(hex: "#88C0D0"),
        success: ThemeColor(hex: "#A3BE8C"),
        warning: ThemeColor(hex: "#EBCB8B"),
        danger: ThemeColor(hex: "#BF616A"),
        chartGrid: ThemeColor(hex: "#FFFFFF", opacity: 0.08),
        chartFill: [ThemeColor(hex: "#88C0D0", opacity: 0.35), ThemeColor(hex: "#88C0D0", opacity: 0.0)],
        separator: ThemeColor(hex: "#FFFFFF", opacity: 0.08),
        metricColors: nocturneMetricColors(
            accent: ThemeColor(hex: "#88C0D0"), success: ThemeColor(hex: "#A3BE8C"),
            warning: ThemeColor(hex: "#EBCB8B"), danger: ThemeColor(hex: "#BF616A")
        ),
        fontFamily: .system,
        barFontSize: 11,
        barFontWeight: .medium,
        numericStyle: .monospacedDigit,
        cornerRadius: 6,
        density: .compact,
        chartStyle: .area,
        chartLineWidth: 1.0,
        showChartGrid: false,
        barGraphWidth: 40,
        useMaterialBackground: false,
        materialStyle: .menu,
        glowIntensity: 0.0,
        scanlineOverlay: false
    )

    /// Dracula — IDE-inspired.
    public static let dracula = Theme(
        id: "builtin.dracula",
        name: "Dracula",
        isBuiltIn: true,
        background: ThemeColor(hex: "#282A36"),
        surface: ThemeColor(hex: "#343746"),
        surfaceElevated: ThemeColor(hex: "#3D4052"),
        textPrimary: ThemeColor(hex: "#F8F8F2"),
        textSecondary: ThemeColor(hex: "#C7C9D1"),
        textTertiary: ThemeColor(hex: "#6272A4"),
        accent: ThemeColor(hex: "#BD93F9"),
        success: ThemeColor(hex: "#50FA7B"),
        warning: ThemeColor(hex: "#F1FA8C"),
        danger: ThemeColor(hex: "#FF5555"),
        chartGrid: ThemeColor(hex: "#FFFFFF", opacity: 0.08),
        chartFill: [ThemeColor(hex: "#BD93F9", opacity: 0.35), ThemeColor(hex: "#BD93F9", opacity: 0.0)],
        separator: ThemeColor(hex: "#FFFFFF", opacity: 0.08),
        metricColors: nocturneMetricColors(
            accent: ThemeColor(hex: "#BD93F9"), success: ThemeColor(hex: "#50FA7B"),
            warning: ThemeColor(hex: "#F1FA8C"), danger: ThemeColor(hex: "#FF5555")
        ),
        fontFamily: .system,
        barFontSize: 11,
        barFontWeight: .medium,
        numericStyle: .monospacedDigit,
        cornerRadius: 6,
        density: .compact,
        chartStyle: .area,
        chartLineWidth: 1.0,
        showChartGrid: false,
        barGraphWidth: 40,
        useMaterialBackground: false,
        materialStyle: .menu,
        glowIntensity: 0.0,
        scanlineOverlay: false
    )

    /// Solarized Dark — IDE-inspired.
    public static let solarizedDark = Theme(
        id: "builtin.solarizedDark",
        name: "Solarized Dark",
        isBuiltIn: true,
        background: ThemeColor(hex: "#002B36"),
        surface: ThemeColor(hex: "#073642"),
        surfaceElevated: ThemeColor(hex: "#0A4A58"),
        textPrimary: ThemeColor(hex: "#EEE8D5"),
        textSecondary: ThemeColor(hex: "#93A1A1"),
        textTertiary: ThemeColor(hex: "#586E75"),
        accent: ThemeColor(hex: "#2AA198"),
        success: ThemeColor(hex: "#859900"),
        warning: ThemeColor(hex: "#B58900"),
        danger: ThemeColor(hex: "#DC322F"),
        chartGrid: ThemeColor(hex: "#FFFFFF", opacity: 0.08),
        chartFill: [ThemeColor(hex: "#2AA198", opacity: 0.35), ThemeColor(hex: "#2AA198", opacity: 0.0)],
        separator: ThemeColor(hex: "#FFFFFF", opacity: 0.08),
        metricColors: nocturneMetricColors(
            accent: ThemeColor(hex: "#2AA198"), success: ThemeColor(hex: "#859900"),
            warning: ThemeColor(hex: "#B58900"), danger: ThemeColor(hex: "#DC322F")
        ),
        fontFamily: .system,
        barFontSize: 11,
        barFontWeight: .medium,
        numericStyle: .monospacedDigit,
        cornerRadius: 6,
        density: .compact,
        chartStyle: .area,
        chartLineWidth: 1.0,
        showChartGrid: false,
        barGraphWidth: 40,
        useMaterialBackground: false,
        materialStyle: .menu,
        glowIntensity: 0.0,
        scanlineOverlay: false
    )

    /// Tokyo Night — IDE-inspired.
    public static let tokyoNight = Theme(
        id: "builtin.tokyoNight",
        name: "Tokyo Night",
        isBuiltIn: true,
        background: ThemeColor(hex: "#1A1B26"),
        surface: ThemeColor(hex: "#24283B"),
        surfaceElevated: ThemeColor(hex: "#2C3149"),
        textPrimary: ThemeColor(hex: "#C0CAF5"),
        textSecondary: ThemeColor(hex: "#A9B1D6"),
        textTertiary: ThemeColor(hex: "#565F89"),
        accent: ThemeColor(hex: "#7AA2F7"),
        success: ThemeColor(hex: "#9ECE6A"),
        warning: ThemeColor(hex: "#E0AF68"),
        danger: ThemeColor(hex: "#F7768E"),
        chartGrid: ThemeColor(hex: "#FFFFFF", opacity: 0.08),
        chartFill: [ThemeColor(hex: "#7AA2F7", opacity: 0.35), ThemeColor(hex: "#7AA2F7", opacity: 0.0)],
        separator: ThemeColor(hex: "#FFFFFF", opacity: 0.08),
        metricColors: nocturneMetricColors(
            accent: ThemeColor(hex: "#7AA2F7"), success: ThemeColor(hex: "#9ECE6A"),
            warning: ThemeColor(hex: "#E0AF68"), danger: ThemeColor(hex: "#F7768E")
        ),
        fontFamily: .system,
        barFontSize: 11,
        barFontWeight: .medium,
        numericStyle: .monospacedDigit,
        cornerRadius: 6,
        density: .compact,
        chartStyle: .area,
        chartLineWidth: 1.0,
        showChartGrid: false,
        barGraphWidth: 40,
        useMaterialBackground: false,
        materialStyle: .menu,
        glowIntensity: 0.0,
        scanlineOverlay: false
    )

    /// Monokai — IDE-inspired.
    public static let monokai = Theme(
        id: "builtin.monokai",
        name: "Monokai",
        isBuiltIn: true,
        background: ThemeColor(hex: "#272822"),
        surface: ThemeColor(hex: "#3E3D32"),
        surfaceElevated: ThemeColor(hex: "#49483E"),
        textPrimary: ThemeColor(hex: "#F8F8F2"),
        textSecondary: ThemeColor(hex: "#A9A99C"),
        textTertiary: ThemeColor(hex: "#75715E"),
        accent: ThemeColor(hex: "#FD971F"),
        success: ThemeColor(hex: "#A6E22E"),
        warning: ThemeColor(hex: "#E6DB74"),
        danger: ThemeColor(hex: "#F92672"),
        chartGrid: ThemeColor(hex: "#FFFFFF", opacity: 0.08),
        chartFill: [ThemeColor(hex: "#FD971F", opacity: 0.35), ThemeColor(hex: "#FD971F", opacity: 0.0)],
        separator: ThemeColor(hex: "#FFFFFF", opacity: 0.08),
        metricColors: nocturneMetricColors(
            accent: ThemeColor(hex: "#FD971F"), success: ThemeColor(hex: "#A6E22E"),
            warning: ThemeColor(hex: "#E6DB74"), danger: ThemeColor(hex: "#F92672")
        ),
        fontFamily: .system,
        barFontSize: 11,
        barFontWeight: .medium,
        numericStyle: .monospacedDigit,
        cornerRadius: 6,
        density: .compact,
        chartStyle: .area,
        chartLineWidth: 1.0,
        showChartGrid: false,
        barGraphWidth: 40,
        useMaterialBackground: false,
        materialStyle: .menu,
        glowIntensity: 0.0,
        scanlineOverlay: false
    )

    /// All built-in presets, in display order: the adaptive default first, then
    /// the 2 fixed-appearance minimal presets, then the 5 IDE-inspired ones.
    public static let builtInPresets: [Theme] = [
        .notion, .slate, .paper, .nord, .dracula, .solarizedDark, .tokyoNight, .monokai,
    ]

    /// The single source of truth for "which theme when the user hasn't chosen
    /// one, or chose one that no longer exists". Call sites use this rather than
    /// naming a preset directly, so changing the default is a one-line edit
    /// here instead of a hunt through every `?? .slate` fallback.
    public static let defaultTheme: Theme = .notion
}

// MARK: - Typed metric-color lookup

extension Theme {
    /// `metricColors` is keyed by Appendix A's raw dotted strings (rather than
    /// `MetricID` directly) so a `.macstattheme` file stays a plain readable
    /// JSON object — `JSONEncoder` only emits dictionaries as objects for
    /// String/Int keys, and would otherwise write an alternating key/value
    /// array. This accessor gives call sites the type safety anyway.
    public func metricColor(for metric: MetricID) -> ThemeColor? {
        metricColors[metric.rawValue]
    }
}
