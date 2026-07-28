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

// MARK: - Built-in presets (plan §9.2)

extension Theme {
    /// Terminal — near-black background, phosphor-green accents, monospaced
    /// digits, subtle glow, thin line charts. The default theme.
    public static let terminal = Theme(
        id: "builtin.terminal",
        name: "Terminal",
        isBuiltIn: true,
        background: ThemeColor(hex: "#0A0D0A"),
        surface: ThemeColor(hex: "#10140F"),
        surfaceElevated: ThemeColor(hex: "#161C15"),
        textPrimary: ThemeColor(hex: "#E8FFE9"),       // ~16.8:1 on background
        textSecondary: ThemeColor(hex: "#9FCBA3"),     // ~7.9:1 on background
        textTertiary: ThemeColor(hex: "#6E8F70"),      // ~4.6:1 on background
        accent: ThemeColor(hex: "#33FF66"),
        success: ThemeColor(hex: "#33FF66"),
        warning: ThemeColor(hex: "#FFD166"),
        danger: ThemeColor(hex: "#FF5C5C"),
        chartGrid: ThemeColor(hex: "#1E2B1E", opacity: 0.6),
        chartFill: [ThemeColor(hex: "#33FF66", opacity: 0.35), ThemeColor(hex: "#33FF66", opacity: 0.0)],
        separator: ThemeColor(hex: "#1C261C"),
        metricColors: [
            "cpu.total_percent": ThemeColor(hex: "#33FF66"),
            "gpu.utilization_percent": ThemeColor(hex: "#33D6FF"),
            "memory.used_bytes": ThemeColor(hex: "#D6FF33"),
            "network.rx_bytes_per_sec": ThemeColor(hex: "#33FFC7"),
            "disk.read_bytes_per_sec": ThemeColor(hex: "#B366FF"),
            "battery.charge_percent": ThemeColor(hex: "#FFD166"),
        ],
        fontFamily: .systemMono,
        barFontSize: 11,
        barFontWeight: .medium,
        numericStyle: .monospacedDigit,
        cornerRadius: 4,
        density: .compact,
        chartStyle: .line,
        chartLineWidth: 1.0,
        showChartGrid: false,
        barGraphWidth: 40,
        useMaterialBackground: false,
        materialStyle: .menu,
        glowIntensity: 0.25,
        scanlineOverlay: false
    )

    /// Nocturne — deep navy/slate, cyan + magenta metric colors, area charts.
    public static let nocturne = Theme(
        id: "builtin.nocturne",
        name: "Nocturne",
        isBuiltIn: true,
        background: ThemeColor(hex: "#0B1120"),
        surface: ThemeColor(hex: "#121A2E"),
        surfaceElevated: ThemeColor(hex: "#1A2440"),
        textPrimary: ThemeColor(hex: "#F1F5FF"),        // ~16.9:1 on background
        textSecondary: ThemeColor(hex: "#AAB8DA"),      // ~7.6:1 on background
        textTertiary: ThemeColor(hex: "#7686AC"),       // ~4.6:1 on background
        accent: ThemeColor(hex: "#38BDF8"),
        success: ThemeColor(hex: "#34D399"),
        warning: ThemeColor(hex: "#FBBF24"),
        danger: ThemeColor(hex: "#FB7185"),
        chartGrid: ThemeColor(hex: "#25325A", opacity: 0.6),
        chartFill: [ThemeColor(hex: "#38BDF8", opacity: 0.4), ThemeColor(hex: "#38BDF8", opacity: 0.0)],
        separator: ThemeColor(hex: "#22304F"),
        metricColors: [
            "cpu.total_percent": ThemeColor(hex: "#38BDF8"),   // cyan
            "gpu.utilization_percent": ThemeColor(hex: "#E879F9"), // magenta
            "memory.used_bytes": ThemeColor(hex: "#A78BFA"),
            "network.rx_bytes_per_sec": ThemeColor(hex: "#34D399"),
            "disk.read_bytes_per_sec": ThemeColor(hex: "#FBBF24"),
            "battery.charge_percent": ThemeColor(hex: "#FB7185"),
        ],
        fontFamily: .system,
        barFontSize: 11,
        barFontWeight: .regular,
        numericStyle: .monospacedDigit,
        cornerRadius: 8,
        density: .comfortable,
        chartStyle: .area,
        chartLineWidth: 1.5,
        showChartGrid: true,
        barGraphWidth: 44,
        useMaterialBackground: true,
        materialStyle: .hudWindow,
        glowIntensity: 0.1,
        scanlineOverlay: false
    )

    /// System — approximates stock macOS appearance (light/dark semantic grays,
    /// systemBlue-like accent). Cannot literally bind to `NSColor.controlAccentColor`
    /// at the data-model level (that dynamic resolution is a rendering concern),
    /// so the light/dark hex pair below is a static approximation of the default
    /// macOS accent + label colors.
    public static let system = Theme(
        id: "builtin.system",
        name: "System",
        isBuiltIn: true,
        background: ThemeColor(light: "#FFFFFF", dark: "#1E1E1E"),
        surface: ThemeColor(light: "#F5F5F7", dark: "#2C2C2E"),
        surfaceElevated: ThemeColor(light: "#FFFFFF", dark: "#3A3A3C"),
        textPrimary: ThemeColor(light: "#1D1D1F", dark: "#F5F5F7"),     // ~15.6:1 both ways
        textSecondary: ThemeColor(light: "#6E6E73", dark: "#AEAEB2"),  // ~4.6:1 / ~7.5:1
        // Independent review computed the actual contrast (not eyeballed)
        // and found the original #8E8E93 light value was 3.26:1 against
        // this preset's white background — a real WCAG AA failure despite
        // its inline comment claiming 4.5:1. #767676 is the well-known
        // canonical "exactly at the 4.5:1 boundary on white" gray; dark
        // mode's #8E8E93 (5.11:1 on #1E1E1E) was already fine and unchanged.
        textTertiary: ThemeColor(light: "#767676", dark: "#8E8E93"),
        accent: ThemeColor(light: "#007AFF", dark: "#0A84FF"),
        // Apple's stock systemGreen/Orange/Red (used here for their light
        // variants originally) are legitimately sub-AA for text on white —
        // that's why Apple itself only uses them for icons/fills, never body
        // text. Plan §9.4 explicitly expects "a red battery number" to be
        // legible text, so the light variants use darker, text-safe
        // equivalents (matching the values already used in the Paper preset
        // below, which independent review did not flag) rather than the
        // vivid stock colors. Dark variants keep the vivid stock colors —
        // those read fine against this preset's dark backgrounds.
        success: ThemeColor(light: "#1E7E34", dark: "#30D158"),
        warning: ThemeColor(light: "#8A5B00", dark: "#FF9F0A"),
        danger: ThemeColor(light: "#B00020", dark: "#FF453A"),
        chartGrid: ThemeColor(light: "#D1D1D6", dark: "#3A3A3C", opacity: 0.7),
        chartFill: [
            ThemeColor(light: "#007AFF", dark: "#0A84FF", opacity: 0.35),
            ThemeColor(light: "#007AFF", dark: "#0A84FF", opacity: 0.0),
        ],
        separator: ThemeColor(light: "#E5E5EA", dark: "#38383A"),
        metricColors: [
            "cpu.total_percent": ThemeColor(light: "#007AFF", dark: "#0A84FF"),
            "gpu.utilization_percent": ThemeColor(light: "#AF52DE", dark: "#BF5AF2"),
            "memory.used_bytes": ThemeColor(light: "#34C759", dark: "#30D158"),
            "network.rx_bytes_per_sec": ThemeColor(light: "#5AC8FA", dark: "#64D2FF"),
            "disk.read_bytes_per_sec": ThemeColor(light: "#FF9500", dark: "#FF9F0A"),
            "battery.charge_percent": ThemeColor(light: "#34C759", dark: "#30D158"),
        ],
        fontFamily: .system,
        barFontSize: 12,
        barFontWeight: .regular,
        numericStyle: .proportional,
        cornerRadius: 10,
        density: .comfortable,
        chartStyle: .line,
        chartLineWidth: 1.5,
        showChartGrid: false,
        barGraphWidth: 44,
        useMaterialBackground: true,
        materialStyle: .sidebar,
        glowIntensity: 0.0,
        scanlineOverlay: false
    )

    /// Paper — light, high-contrast, minimal chrome, no glow.
    public static let paper = Theme(
        id: "builtin.paper",
        name: "Paper",
        isBuiltIn: true,
        background: ThemeColor(hex: "#FFFFFF"),
        surface: ThemeColor(hex: "#FAFAFA"),
        surfaceElevated: ThemeColor(hex: "#F0F0F0"),
        textPrimary: ThemeColor(hex: "#111111"),        // ~18.6:1 on background
        textSecondary: ThemeColor(hex: "#4A4A4A"),      // ~8.9:1 on background
        textTertiary: ThemeColor(hex: "#6B6B6B"),       // ~5.4:1 on background
        accent: ThemeColor(hex: "#1A1A1A"),
        success: ThemeColor(hex: "#1E7E34"),
        warning: ThemeColor(hex: "#8A5B00"),
        danger: ThemeColor(hex: "#B00020"),
        chartGrid: ThemeColor(hex: "#DDDDDD"),
        chartFill: [ThemeColor(hex: "#1A1A1A", opacity: 0.12), ThemeColor(hex: "#1A1A1A", opacity: 0.0)],
        separator: ThemeColor(hex: "#E2E2E2"),
        metricColors: [
            "cpu.total_percent": ThemeColor(hex: "#1E7E34"),
            "gpu.utilization_percent": ThemeColor(hex: "#5B3AA0"),
            "memory.used_bytes": ThemeColor(hex: "#8A5B00"),
            "network.rx_bytes_per_sec": ThemeColor(hex: "#0B6E99"),
            "disk.read_bytes_per_sec": ThemeColor(hex: "#B00020"),
            "battery.charge_percent": ThemeColor(hex: "#1E7E34"),
        ],
        fontFamily: .system,
        barFontSize: 11,
        barFontWeight: .medium,
        numericStyle: .proportional,
        cornerRadius: 6,
        density: .compact,
        chartStyle: .bars,
        chartLineWidth: 1.0,
        showChartGrid: false,
        barGraphWidth: 36,
        useMaterialBackground: false,
        materialStyle: .contentBackground,
        glowIntensity: 0.0,
        scanlineOverlay: false
    )

    /// Neon — high-saturation gradients, thick charts, strong glow.
    public static let neon = Theme(
        id: "builtin.neon",
        name: "Neon",
        isBuiltIn: true,
        background: ThemeColor(hex: "#08060F"),
        surface: ThemeColor(hex: "#120C22"),
        surfaceElevated: ThemeColor(hex: "#1C1333"),
        textPrimary: ThemeColor(hex: "#F5F0FF"),        // ~17.8:1 on background
        textSecondary: ThemeColor(hex: "#C9B8F5"),      // ~10.0:1 on background
        textTertiary: ThemeColor(hex: "#9585C4"),       // ~5.6:1 on background
        accent: ThemeColor(hex: "#FF2DD4"),
        success: ThemeColor(hex: "#39FF88"),
        warning: ThemeColor(hex: "#FFE94D"),
        danger: ThemeColor(hex: "#FF3860"),
        chartGrid: ThemeColor(hex: "#3A2A5C", opacity: 0.5),
        chartFill: [
            ThemeColor(hex: "#FF2DD4", opacity: 0.55),
            ThemeColor(hex: "#7B2FFF", opacity: 0.25),
            ThemeColor(hex: "#00E5FF", opacity: 0.0),
        ],
        separator: ThemeColor(hex: "#2C1F4A"),
        metricColors: [
            "cpu.total_percent": ThemeColor(hex: "#FF2DD4"),
            "gpu.utilization_percent": ThemeColor(hex: "#00E5FF"),
            "memory.used_bytes": ThemeColor(hex: "#39FF88"),
            "network.rx_bytes_per_sec": ThemeColor(hex: "#7B2FFF"),
            "disk.read_bytes_per_sec": ThemeColor(hex: "#FFE94D"),
            "battery.charge_percent": ThemeColor(hex: "#FF3860"),
        ],
        fontFamily: .rounded,
        barFontSize: 12,
        barFontWeight: .bold,
        numericStyle: .monospacedDigit,
        cornerRadius: 12,
        density: .spacious,
        chartStyle: .area,
        chartLineWidth: 2.5,
        showChartGrid: false,
        barGraphWidth: 48,
        useMaterialBackground: false,
        materialStyle: .popover,
        glowIntensity: 0.85,
        scanlineOverlay: false
    )

    /// Monochrome — pure grayscale. Metric differentiation at the data level
    /// comes from genuinely distinct gray shades/opacities (rendering-level
    /// differentiation by line weight + dash pattern is a later, out-of-scope
    /// concern per the plan).
    public static let monochrome = Theme(
        id: "builtin.monochrome",
        name: "Monochrome",
        isBuiltIn: true,
        background: ThemeColor(hex: "#000000"),
        surface: ThemeColor(hex: "#141414"),
        surfaceElevated: ThemeColor(hex: "#1F1F1F"),
        textPrimary: ThemeColor(hex: "#FFFFFF"),        // 21:1 on background
        textSecondary: ThemeColor(hex: "#BFBFBF"),      // ~10.3:1 on background
        textTertiary: ThemeColor(hex: "#8A8A8A"),       // ~4.9:1 on background
        accent: ThemeColor(hex: "#FFFFFF"),
        success: ThemeColor(hex: "#E0E0E0"),
        warning: ThemeColor(hex: "#A0A0A0"),
        danger: ThemeColor(hex: "#FFFFFF"),
        chartGrid: ThemeColor(hex: "#3A3A3A", opacity: 0.6),
        chartFill: [ThemeColor(hex: "#FFFFFF", opacity: 0.25), ThemeColor(hex: "#FFFFFF", opacity: 0.0)],
        separator: ThemeColor(hex: "#2A2A2A"),
        metricColors: [
            "cpu.total_percent": ThemeColor(hex: "#FFFFFF", opacity: 1.0),
            "gpu.utilization_percent": ThemeColor(hex: "#D6D6D6", opacity: 1.0),
            "memory.used_bytes": ThemeColor(hex: "#ADADAD", opacity: 1.0),
            "network.rx_bytes_per_sec": ThemeColor(hex: "#FFFFFF", opacity: 0.65),
            "disk.read_bytes_per_sec": ThemeColor(hex: "#D6D6D6", opacity: 0.65),
            "battery.charge_percent": ThemeColor(hex: "#8A8A8A", opacity: 1.0),
        ],
        fontFamily: .systemMono,
        barFontSize: 11,
        barFontWeight: .semibold,
        numericStyle: .monospacedDigit,
        cornerRadius: 4,
        density: .compact,
        chartStyle: .stepped,
        chartLineWidth: 1.25,
        showChartGrid: false,
        barGraphWidth: 40,
        useMaterialBackground: false,
        materialStyle: .menu,
        glowIntensity: 0.0,
        scanlineOverlay: false
    )

    /// All built-in presets, in the display order given by plan §9.2.
    public static let builtInPresets: [Theme] = [
        .terminal, .nocturne, .system, .paper, .neon, .monochrome,
    ]
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
