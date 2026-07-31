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
        // Small on purpose. Notion's own surfaces sit around 3–4pt; 6 is the
        // most a Mac popover wants. Large radii read as "card" and invite the
        // nested-rounded-rectangle look this redesign is specifically moving
        // away from — interior elements should mostly have no radius at all
        // because they should mostly have no fill or border.
        cornerRadius: 6,
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

    /// System — native macOS. Apple's semantic colors (system blue/green/
    /// orange/red), neutral surfaces, and a translucent popover material, so
    /// every surface reads like it shipped with the OS. Adaptive.
    public static let system = Theme(
        id: "builtin.system",
        name: "System",
        isBuiltIn: true,
        background: ThemeColor(light: "#FFFFFF", dark: "#1E1E1E", opacity: 0.85),
        surface: ThemeColor(light: "#0000000A", dark: "#FFFFFF0D"),
        surfaceElevated: ThemeColor(light: "#F5F5F7", dark: "#2A2A2C"),
        textPrimary: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.85),
        textSecondary: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.5),
        textTertiary: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.26),
        accent: ThemeColor(light: "#007AFF", dark: "#0A84FF"),
        success: ThemeColor(light: "#34C759", dark: "#30D158"),
        warning: ThemeColor(light: "#FF9500", dark: "#FF9F0A"),
        danger: ThemeColor(light: "#FF3B30", dark: "#FF453A"),
        chartGrid: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.06),
        chartFill: [
            ThemeColor(light: "#007AFF", dark: "#0A84FF", opacity: 0.2),
            ThemeColor(light: "#007AFF", dark: "#0A84FF", opacity: 0.0),
        ],
        separator: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.08),
        metricColors: nocturneMetricColors(
            accent: ThemeColor(light: "#007AFF", dark: "#0A84FF"),
            success: ThemeColor(light: "#34C759", dark: "#30D158"),
            warning: ThemeColor(light: "#FF9500", dark: "#FF9F0A"),
            danger: ThemeColor(light: "#FF3B30", dark: "#FF453A")
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

    /// GitHub — Primer's palette, adaptive (github.com light / dark dimmed-free).
    public static let github = Theme(
        id: "builtin.github",
        name: "GitHub",
        isBuiltIn: true,
        background: ThemeColor(light: "#FFFFFF", dark: "#0D1117"),
        surface: ThemeColor(light: "#F6F8FA", dark: "#161B22"),
        surfaceElevated: ThemeColor(light: "#EFF2F5", dark: "#1C2129"),
        textPrimary: ThemeColor(light: "#1F2328", dark: "#E6EDF3"),
        textSecondary: ThemeColor(light: "#59636E", dark: "#8D96A0"),
        textTertiary: ThemeColor(light: "#818B98", dark: "#6E7681"),
        accent: ThemeColor(light: "#0969DA", dark: "#58A6FF"),
        success: ThemeColor(light: "#1A7F37", dark: "#3FB950"),
        warning: ThemeColor(light: "#9A6700", dark: "#D29922"),
        danger: ThemeColor(light: "#CF222E", dark: "#F85149"),
        chartGrid: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.06),
        chartFill: [
            ThemeColor(light: "#0969DA", dark: "#58A6FF", opacity: 0.18),
            ThemeColor(light: "#0969DA", dark: "#58A6FF", opacity: 0.0),
        ],
        separator: ThemeColor(light: "#D1D9E0", dark: "#30363D"),
        metricColors: nocturneMetricColors(
            accent: ThemeColor(light: "#0969DA", dark: "#58A6FF"),
            success: ThemeColor(light: "#1A7F37", dark: "#3FB950"),
            warning: ThemeColor(light: "#9A6700", dark: "#D29922"),
            danger: ThemeColor(light: "#CF222E", dark: "#F85149")
        ),
        fontFamily: .system,
        barFontSize: 11,
        barFontWeight: .medium,
        numericStyle: .monospacedDigit,
        cornerRadius: 6,
        density: .comfortable,
        chartStyle: .area,
        chartLineWidth: 1.5,
        showChartGrid: false,
        barGraphWidth: 36,
        useMaterialBackground: false,
        materialStyle: .popover,
        glowIntensity: 0.0,
        scanlineOverlay: false
    )

    /// Xcode — the editor's default light/dark chrome and syntax accents.
    public static let xcode = Theme(
        id: "builtin.xcode",
        name: "Xcode",
        isBuiltIn: true,
        background: ThemeColor(light: "#FFFFFF", dark: "#1F1F24"),
        surface: ThemeColor(light: "#F5F5F5", dark: "#292A30"),
        surfaceElevated: ThemeColor(light: "#ECECEC", dark: "#313239"),
        textPrimary: ThemeColor(light: "#262626", dark: "#DFDFE0"),
        textSecondary: ThemeColor(light: "#6C6C6C", dark: "#A0A0A6"),
        textTertiary: ThemeColor(light: "#9B9B9B", dark: "#6C6C73"),
        accent: ThemeColor(light: "#0F68A0", dark: "#4FB0CC"),
        success: ThemeColor(light: "#1C464A", dark: "#78C2B3"),
        warning: ThemeColor(light: "#78492A", dark: "#FD8F3F"),
        danger: ThemeColor(light: "#AD3DA4", dark: "#FC5FA3"),
        chartGrid: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.06),
        chartFill: [
            ThemeColor(light: "#0F68A0", dark: "#4FB0CC", opacity: 0.2),
            ThemeColor(light: "#0F68A0", dark: "#4FB0CC", opacity: 0.0),
        ],
        separator: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.09),
        metricColors: nocturneMetricColors(
            accent: ThemeColor(light: "#0F68A0", dark: "#4FB0CC"),
            success: ThemeColor(light: "#1C464A", dark: "#78C2B3"),
            warning: ThemeColor(light: "#78492A", dark: "#FD8F3F"),
            danger: ThemeColor(light: "#AD3DA4", dark: "#FC5FA3")
        ),
        fontFamily: .systemMono,
        barFontSize: 11,
        barFontWeight: .regular,
        numericStyle: .monospacedDigit,
        cornerRadius: 6,
        density: .compact,
        chartStyle: .line,
        chartLineWidth: 1.5,
        showChartGrid: false,
        barGraphWidth: 40,
        useMaterialBackground: false,
        materialStyle: .contentBackground,
        glowIntensity: 0.0,
        scanlineOverlay: false
    )

    /// Translucent — near-transparent surfaces over the popover material, so
    /// the dropdown reads as frosted glass over whatever is behind it.
    /// Everything structural is monochrome at low opacity; only semantic
    /// state gets a hue.
    public static let translucent = Theme(
        id: "builtin.translucent",
        name: "Translucent",
        isBuiltIn: true,
        background: ThemeColor(light: "#FFFFFF", dark: "#1A1A1A", opacity: 0.35),
        surface: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.06),
        surfaceElevated: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.09),
        textPrimary: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.88),
        textSecondary: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.52),
        textTertiary: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.28),
        accent: ThemeColor(light: "#007AFF", dark: "#0A84FF"),
        success: ThemeColor(light: "#34C759", dark: "#30D158"),
        warning: ThemeColor(light: "#FF9500", dark: "#FF9F0A"),
        danger: ThemeColor(light: "#FF3B30", dark: "#FF453A"),
        chartGrid: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.05),
        chartFill: [
            ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.14),
            ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.0),
        ],
        separator: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.1),
        metricColors: nocturneMetricColors(
            accent: ThemeColor(light: "#007AFF", dark: "#0A84FF"),
            success: ThemeColor(light: "#34C759", dark: "#30D158"),
            warning: ThemeColor(light: "#FF9500", dark: "#FF9F0A"),
            danger: ThemeColor(light: "#FF3B30", dark: "#FF453A")
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
        materialStyle: .hudWindow,
        glowIntensity: 0.0,
        scanlineOverlay: false
    )

    /// Liquid Glass — the heaviest glass treatment: ultra-thin material, a
    /// bare wash of tint, large continuous radii, and a whisper of glow on
    /// charts. Where Translucent is frosted, this is wet.
    public static let liquidGlass = Theme(
        id: "builtin.liquidGlass",
        name: "Liquid Glass",
        isBuiltIn: true,
        background: ThemeColor(light: "#FFFFFF", dark: "#101014", opacity: 0.2),
        surface: ThemeColor(light: "#FFFFFF", dark: "#FFFFFF", opacity: 0.1),
        surfaceElevated: ThemeColor(light: "#FFFFFF", dark: "#FFFFFF", opacity: 0.14),
        textPrimary: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.9),
        textSecondary: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.55),
        textTertiary: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.3),
        accent: ThemeColor(light: "#0A84FF", dark: "#64D2FF"),
        success: ThemeColor(light: "#30D158", dark: "#66E58C"),
        warning: ThemeColor(light: "#FF9F0A", dark: "#FFC53F"),
        danger: ThemeColor(light: "#FF453A", dark: "#FF7A70"),
        chartGrid: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.05),
        chartFill: [
            ThemeColor(light: "#0A84FF", dark: "#64D2FF", opacity: 0.22),
            ThemeColor(light: "#0A84FF", dark: "#64D2FF", opacity: 0.0),
        ],
        separator: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.12),
        metricColors: nocturneMetricColors(
            accent: ThemeColor(light: "#0A84FF", dark: "#64D2FF"),
            success: ThemeColor(light: "#30D158", dark: "#66E58C"),
            warning: ThemeColor(light: "#FF9F0A", dark: "#FFC53F"),
            danger: ThemeColor(light: "#FF453A", dark: "#FF7A70")
        ),
        fontFamily: .rounded,
        barFontSize: 11,
        barFontWeight: .medium,
        numericStyle: .monospacedDigit,
        cornerRadius: 14,
        density: .comfortable,
        chartStyle: .area,
        chartLineWidth: 1.5,
        showChartGrid: false,
        barGraphWidth: 36,
        useMaterialBackground: true,
        materialStyle: .hudWindow,
        glowIntensity: 0.25,
        scanlineOverlay: false
    )

    /// All built-in presets, in display order: the adaptive defaults first
    /// (minimal → native → glass), then the fixed-appearance minimal pair,
    /// then the IDE/brand-inspired set.
    public static let builtInPresets: [Theme] = [
        .notion, .system, .translucent, .liquidGlass,
        .slate, .paper,
        .github, .xcode, .nord, .dracula, .solarizedDark, .tokyoNight, .monokai,
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
