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

/// Which half of a `ThemeColor`'s light/dark pair a caller wants.
///
/// SwiftUI's `ColorScheme` is the type the rendering layers actually branch
/// on, but it lives in SwiftUI and `MacStatKit` is deliberately
/// Foundation-only for the model layer — the contrast auditor
/// (`ThemeContrast`) and the `.sentrytheme` validator both need to resolve a
/// token pair without importing a UI framework. The two SwiftUI bridges
/// (`MacStat/Dropdown/ThemeColor+SwiftUI.swift` and its iOS mirror) map
/// `ColorScheme` onto this.
public enum ThemeAppearance: String, Codable, CaseIterable, Equatable, Sendable {
    case light
    case dark

    /// For UI that names the appearance being edited or audited.
    public var displayName: String {
        switch self {
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }
}

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

    /// The raw hex string for one half of the pair, unparsed and unvalidated —
    /// exactly what is stored. Callers that want numbers want `rgba(for:)`.
    public func hex(for appearance: ThemeAppearance) -> String {
        appearance == .dark ? dark : light
    }

    /// A copy with one half of the pair replaced. The editor's color wells
    /// mutate a single appearance at a time (you can't pick two colors with
    /// one well), so this is the shape every write in the editor takes.
    public func settingHex(_ hex: String, for appearance: ThemeAppearance) -> ThemeColor {
        var copy = self
        switch appearance {
        case .light: copy.light = hex
        case .dark: copy.dark = hex
        }
        return copy
    }

    public var clampedOpacity: Double { min(max(opacity, 0), 1) }
}

// MARK: - Hex parsing

extension ThemeColor {

    /// Straight, premultiplication-free sRGB components in 0...1.
    ///
    /// A plain struct rather than the labelled tuple the SwiftUI bridges used
    /// to return, because it now crosses a module boundary and appears in
    /// `ThemeContrast`'s public surface, where `(r: Double, g: Double, ...)`
    /// reads as an implementation detail that leaked.
    public struct RGBA: Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double
        /// The alpha carried *by the hex string itself* (the `AA` of
        /// `RRGGBBAA`). `ThemeColor.opacity` is a separate multiplier and is
        /// deliberately not folded in here — see `rgba(for:)`.
        public var alpha: Double

        public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
    }

    /// Accepts `RGB`, `RRGGBB`, and `RRGGBBAA`, with or without a leading `#`.
    /// Returns nil (never a force-unwrap or a crash) for anything else.
    ///
    /// **Why this lives in `MacStatKit` now.** It used to exist twice, as a
    /// private helper inside each SwiftUI bridge, with a doc comment in the
    /// iOS copy explaining that duplication was the intended state until
    /// someone promoted the theming surface to the framework. This is a
    /// partial version of that promotion: only the *parser* moved, because
    /// the contrast auditor and the `.sentrytheme` validator are pure model
    /// code that must agree, byte for byte, with what the renderer will draw
    /// — a validator that accepts a hex string the renderer then falls back
    /// to gray for is worse than no validator. `ThemePalette` itself stayed
    /// put; promoting it is still the larger refactor that comment describes.
    public static func components(fromHex raw: String) -> RGBA? {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard !hex.isEmpty, hex.allSatisfy({ $0.isHexDigit }) else { return nil }

        let expanded: String
        switch hex.count {
        case 3: expanded = hex.map { "\($0)\($0)" }.joined()
        case 6, 8: expanded = hex
        default: return nil
        }

        guard let value = UInt64(expanded, radix: 16) else { return nil }
        if expanded.count == 8 {
            return RGBA(
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                alpha: Double(value & 0xFF) / 255
            )
        }
        return RGBA(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: 1.0
        )
    }

    /// This token resolved for one appearance, with `opacity` already folded
    /// into `alpha` — i.e. exactly the color the renderer produces.
    ///
    /// `nil` for a malformed hex string, which the *renderer* answers with a
    /// neutral gray (see the bridges' `color(for:)`) and the *validator*
    /// answers with a rejection. Both behaviours are correct for their
    /// caller, so this returns the honest "couldn't parse" rather than
    /// picking one of them here.
    public func rgba(for appearance: ThemeAppearance) -> RGBA? {
        guard var parsed = Self.components(fromHex: hex(for: appearance)) else { return nil }
        parsed.alpha *= clampedOpacity
        return parsed
    }

    /// True when both halves of the pair parse. The theme editor's own color
    /// wells can't produce anything else; a hand-edited `.sentrytheme` can.
    public var isWellFormed: Bool {
        ThemeAppearance.allCases.allSatisfy { Self.components(fromHex: hex(for: $0)) != nil }
    }
}

// MARK: - Theme

public struct Theme: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var isBuiltIn: Bool

    /// For a custom theme, the `id` of the built-in preset it was duplicated
    /// from; `nil` for the built-ins themselves and for a theme imported from
    /// a `.sentrytheme` file that named no ancestor.
    ///
    /// This is what makes §9.3's "Reset to preset" answerable *per token* and
    /// not merely globally: without a remembered ancestor, "reset this one
    /// color well" has no value to reset to, and the only honest offer would
    /// be "discard everything." The editor consults it through
    /// `Theme.basePreset` and disables both reset affordances (with the reason
    /// on screen) when it resolves to nothing, rather than silently resetting
    /// to whatever the current default preset happens to be — a user who
    /// imported someone else's theme has no relationship to Notion, and
    /// snapping their accent to Notion blue would be an invented answer.
    ///
    /// Deliberately *not* a strong reference or an embedded copy: presets are
    /// code, they change between builds, and a stored copy would silently
    /// preserve a stale idea of "the preset value." An id that no longer
    /// resolves is a real outcome and is handled as one.
    public var basePresetID: String?

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
        scanlineOverlay: Bool,
        basePresetID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.basePresetID = basePresetID
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

// MARK: - Forward-compatible decoding

extension Theme {

    private enum CodingKeys: String, CodingKey {
        case id, name, isBuiltIn, basePresetID
        case background, surface, surfaceElevated
        case textPrimary, textSecondary, textTertiary
        case accent, success, warning, danger
        case chartGrid, chartFill, separator
        case metricColors
        case fontFamily, barFontSize, barFontWeight, numericStyle
        case cornerRadius, density, chartStyle, chartLineWidth
        case showChartGrid, barGraphWidth
        case useMaterialBackground, materialStyle, glowIntensity, scanlineOverlay
    }

    /// Hand-written for the same reason `AppSettings.init(from:)` is, and now
    /// for the same *stakes*: from the theme editor onward a `Theme` is
    /// user-owned data that round-trips through `settings.json`, so a build
    /// that adds a token must not make every previously-saved custom theme
    /// undecodable. `decodeIfPresent ?? fallback` on every key is what keeps
    /// that promise; the fallback is the default preset's value for that
    /// token, which is the only value in the program that is guaranteed to
    /// exist and to be sane.
    ///
    /// **This decoder is deliberately permissive, and that is exactly why
    /// import does not rely on it.** A `.sentrytheme` file is untrusted
    /// input: run through this initializer alone, `{}` would decode into a
    /// perfect copy of Notion wearing whatever name the file claimed, and the
    /// user would be told the import succeeded. `ThemeDocument.decode(_:)`
    /// therefore performs its own required-key and range checking *before*
    /// handing anything to this initializer — see that type's doc comment.
    /// Tolerance is right for our own file; it is wrong for someone else's.
    ///
    /// `id`, `name` and `isBuiltIn` have no meaningful per-token fallback, so
    /// a settings file missing them yields an obviously-inert custom theme
    /// (a fresh id, an "Untitled Theme" name, `isBuiltIn == false`) rather
    /// than a throw that would take the whole settings file down with it —
    /// `SettingsStore` falls back to wholesale defaults on a decode failure,
    /// and losing every unrelated setting to one malformed theme object is a
    /// far worse outcome than showing one oddly-named theme in the list.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Theme.defaultTheme

        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id)
                ?? Theme.newCustomID(),
            name: try container.decodeIfPresent(String.self, forKey: .name)
                ?? String(localized: "Untitled Theme"),
            isBuiltIn: try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn)
                ?? false,
            background: try container.decodeIfPresent(ThemeColor.self, forKey: .background)
                ?? fallback.background,
            surface: try container.decodeIfPresent(ThemeColor.self, forKey: .surface)
                ?? fallback.surface,
            surfaceElevated: try container.decodeIfPresent(ThemeColor.self, forKey: .surfaceElevated)
                ?? fallback.surfaceElevated,
            textPrimary: try container.decodeIfPresent(ThemeColor.self, forKey: .textPrimary)
                ?? fallback.textPrimary,
            textSecondary: try container.decodeIfPresent(ThemeColor.self, forKey: .textSecondary)
                ?? fallback.textSecondary,
            textTertiary: try container.decodeIfPresent(ThemeColor.self, forKey: .textTertiary)
                ?? fallback.textTertiary,
            accent: try container.decodeIfPresent(ThemeColor.self, forKey: .accent)
                ?? fallback.accent,
            success: try container.decodeIfPresent(ThemeColor.self, forKey: .success)
                ?? fallback.success,
            warning: try container.decodeIfPresent(ThemeColor.self, forKey: .warning)
                ?? fallback.warning,
            danger: try container.decodeIfPresent(ThemeColor.self, forKey: .danger)
                ?? fallback.danger,
            chartGrid: try container.decodeIfPresent(ThemeColor.self, forKey: .chartGrid)
                ?? fallback.chartGrid,
            chartFill: try container.decodeIfPresent([ThemeColor].self, forKey: .chartFill)
                ?? fallback.chartFill,
            separator: try container.decodeIfPresent(ThemeColor.self, forKey: .separator)
                ?? fallback.separator,
            // An explicitly-empty `metricColors` is honored verbatim rather
            // than upgraded to the default map — `ThemePalette.metricColor`
            // already falls back to the accent per metric, so "no per-metric
            // colors" is a legal theme a user can deliberately author, and is
            // a different statement from "this file predates the key."
            metricColors: try container.decodeIfPresent([String: ThemeColor].self, forKey: .metricColors)
                ?? fallback.metricColors,
            fontFamily: try container.decodeIfPresent(FontChoice.self, forKey: .fontFamily)
                ?? fallback.fontFamily,
            barFontSize: try container.decodeIfPresent(CGFloat.self, forKey: .barFontSize)
                ?? fallback.barFontSize,
            barFontWeight: try container.decodeIfPresent(FontWeightToken.self, forKey: .barFontWeight)
                ?? fallback.barFontWeight,
            numericStyle: try container.decodeIfPresent(NumericStyle.self, forKey: .numericStyle)
                ?? fallback.numericStyle,
            cornerRadius: try container.decodeIfPresent(CGFloat.self, forKey: .cornerRadius)
                ?? fallback.cornerRadius,
            density: try container.decodeIfPresent(Density.self, forKey: .density)
                ?? fallback.density,
            chartStyle: try container.decodeIfPresent(ChartStyle.self, forKey: .chartStyle)
                ?? fallback.chartStyle,
            chartLineWidth: try container.decodeIfPresent(CGFloat.self, forKey: .chartLineWidth)
                ?? fallback.chartLineWidth,
            showChartGrid: try container.decodeIfPresent(Bool.self, forKey: .showChartGrid)
                ?? fallback.showChartGrid,
            barGraphWidth: try container.decodeIfPresent(CGFloat.self, forKey: .barGraphWidth)
                ?? fallback.barGraphWidth,
            useMaterialBackground: try container.decodeIfPresent(Bool.self, forKey: .useMaterialBackground)
                ?? fallback.useMaterialBackground,
            materialStyle: try container.decodeIfPresent(MaterialToken.self, forKey: .materialStyle)
                ?? fallback.materialStyle,
            glowIntensity: try container.decodeIfPresent(Double.self, forKey: .glowIntensity)
                ?? fallback.glowIntensity,
            scanlineOverlay: try container.decodeIfPresent(Bool.self, forKey: .scanlineOverlay)
                ?? fallback.scanlineOverlay,
            // Genuinely optional rather than defaulted: `nil` means "no known
            // ancestor," which the editor reports on screen. There is no
            // sensible fallback ancestor to invent.
            basePresetID: try container.decodeIfPresent(String.self, forKey: .basePresetID)
        )
    }
}

// MARK: - Custom themes

extension Theme {

    /// Every user-authored theme's `id` starts with this. Built-ins use
    /// `builtin.`, and `ThemeDocument` refuses to import anything claiming
    /// the built-in namespace — a downloaded file that could name itself
    /// `builtin.notion` would shadow a preset in `Theme.resolve(id:in:)` and
    /// silently replace it everywhere in the app.
    public static let customIDPrefix = "custom."
    public static let builtInIDPrefix = "builtin."

    /// Fresh identity for a duplicated or imported theme. A UUID rather than
    /// a slug of the name, so two themes called "My Theme" (a duplicate of a
    /// duplicate, an import of a file you already had) are two themes rather
    /// than one overwriting the other.
    public static func newCustomID() -> String {
        customIDPrefix + UUID().uuidString.lowercased()
    }

    public var isCustom: Bool { !isBuiltIn }

    /// §9.3's "Duplicate & Edit": an independent copy of the receiver with a
    /// fresh identity, editable, and remembering where it came from.
    ///
    /// Duplicating a *custom* theme keeps that theme's own `basePresetID`
    /// rather than pointing at the custom theme — "reset to preset" means the
    /// shipped preset at the root of the chain, and a chain of forks all
    /// resetting to each other's current state would make the button's answer
    /// depend on edits the user made to an unrelated theme afterwards.
    public func duplicated(named newName: String? = nil) -> Theme {
        var copy = self
        copy.id = Theme.newCustomID()
        copy.isBuiltIn = false
        copy.name = newName ?? String(localized: "\(name) Copy")
        copy.basePresetID = isBuiltIn ? id : basePresetID
        return copy
    }

    /// The shipped preset this theme was forked from, if it still exists in
    /// this build. `nil` is a real answer — an import with no ancestor, or a
    /// preset that was renamed or removed between versions.
    public var basePreset: Theme? {
        guard let basePresetID else { return nil }
        return Theme.builtInPresets.first { $0.id == basePresetID }
    }

    /// The one place "which theme is `themeID`?" is answered, so custom
    /// themes reach every surface the presets already do.
    ///
    /// Custom themes are searched **first**: a custom theme cannot legally
    /// hold a `builtin.` id (see `customIDPrefix`), so the two namespaces
    /// can't actually collide — but if a hand-edited `settings.json` ever
    /// managed it, resolving to the user's own theme is the less surprising
    /// of the two wrong answers, and the built-in remains reachable by
    /// picking it again in the preset grid.
    public static func resolve(id: String, in customThemes: [Theme]) -> Theme {
        customThemes.first { $0.id == id }
            ?? builtInPresets.first { $0.id == id }
            ?? defaultTheme
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

    /// Paper — direction 1a of the Claude Design exploration round: light,
    /// GitHub Primer palette, blue accent. Fixed-light by design (the dark
    /// counterpart in the exploration is One Dark, its own preset). Unlike
    /// the earlier presets it carries the handoff's per-metric hues rather
    /// than reusing the four semantic tokens — the redesign wants CPU blue,
    /// memory purple, GPU pink as *data* colors, with accent reserved
    /// strictly for actions.
    public static let paper = Theme(
        id: "builtin.paper",
        name: "Paper",
        isBuiltIn: true,
        background: ThemeColor(hex: "#FFFFFF"),
        surface: ThemeColor(hex: "#F6F8FA"),
        surfaceElevated: ThemeColor(hex: "#EAEEF2"),
        textPrimary: ThemeColor(hex: "#1F2328"),
        textSecondary: ThemeColor(hex: "#59636E"),
        textTertiary: ThemeColor(hex: "#8B949E"),
        accent: ThemeColor(hex: "#0969DA"),
        success: ThemeColor(hex: "#1A7F37"),
        warning: ThemeColor(hex: "#9A6700"),
        danger: ThemeColor(hex: "#CF222E"),
        chartGrid: ThemeColor(hex: "#000000", opacity: 0.05),
        // 8–10% fill under the line, per the handoff's chart rules.
        chartFill: [ThemeColor(hex: "#0969DA", opacity: 0.09), ThemeColor(hex: "#0969DA", opacity: 0.0)],
        separator: ThemeColor(hex: "#D8DEE4"),
        metricColors: [
            "cpu.total_percent": ThemeColor(hex: "#0969DA"),
            "gpu.utilization_percent": ThemeColor(hex: "#BF3989"),
            "memory.used_bytes": ThemeColor(hex: "#8250DF"),
            "disk.read_bytes_per_sec": ThemeColor(hex: "#57606A"),
            "network.rx_bytes_per_sec": ThemeColor(hex: "#1A7F37"),
            "thermal.soc_temp_c": ThemeColor(hex: "#D1242F"),
        ],
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
        useMaterialBackground: false,
        materialStyle: .contentBackground,
        glowIntensity: 0.0,
        scanlineOverlay: false
    )

    /// One Dark — direction 1b of the exploration round: Atom's One Dark
    /// palette, fixed-dark, blue accent as the only chrome color.
    public static let oneDark = Theme(
        id: "builtin.onedark",
        name: "One Dark",
        isBuiltIn: true,
        background: ThemeColor(hex: "#282C34"),
        surface: ThemeColor(hex: "#2F343E"),
        surfaceElevated: ThemeColor(hex: "#3A404C"),
        textPrimary: ThemeColor(hex: "#D7DAE0"),
        textSecondary: ThemeColor(hex: "#9DA5B4"),
        textTertiary: ThemeColor(hex: "#6B7382"),
        accent: ThemeColor(hex: "#61AFEF"),
        success: ThemeColor(hex: "#98C379"),
        warning: ThemeColor(hex: "#E5C07B"),
        danger: ThemeColor(hex: "#E06C75"),
        chartGrid: ThemeColor(hex: "#FFFFFF", opacity: 0.05),
        chartFill: [ThemeColor(hex: "#61AFEF", opacity: 0.10), ThemeColor(hex: "#61AFEF", opacity: 0.0)],
        separator: ThemeColor(hex: "#3B4048"),
        metricColors: [
            "cpu.total_percent": ThemeColor(hex: "#61AFEF"),
            "gpu.utilization_percent": ThemeColor(hex: "#56B6C2"),
            "memory.used_bytes": ThemeColor(hex: "#C678DD"),
            "disk.read_bytes_per_sec": ThemeColor(hex: "#ABB2BF"),
            "network.rx_bytes_per_sec": ThemeColor(hex: "#98C379"),
            "thermal.soc_temp_c": ThemeColor(hex: "#E06C75"),
        ],
        fontFamily: .system,
        barFontSize: 11,
        barFontWeight: .medium,
        numericStyle: .monospacedDigit,
        cornerRadius: 10,
        density: .comfortable,
        chartStyle: .area,
        chartLineWidth: 1.5,
        showChartGrid: false,
        barGraphWidth: 36,
        useMaterialBackground: false,
        materialStyle: .menu,
        glowIntensity: 0.0,
        scanlineOverlay: false
    )

    /// Ivory — direction 1c of the exploration round, and the most
    /// Claude-like of the three: warm paper neutrals, terracotta accent,
    /// muted dusty metric hues. Fixed-light.
    public static let ivory = Theme(
        id: "builtin.ivory",
        name: "Ivory",
        isBuiltIn: true,
        background: ThemeColor(hex: "#FAF9F5"),
        surface: ThemeColor(hex: "#F0EEE6"),
        surfaceElevated: ThemeColor(hex: "#E6E3D8"),
        textPrimary: ThemeColor(hex: "#3D3D3A"),
        textSecondary: ThemeColor(hex: "#73726C"),
        textTertiary: ThemeColor(hex: "#A3A29A"),
        accent: ThemeColor(hex: "#C96442"),
        success: ThemeColor(hex: "#6A8F5F"),
        warning: ThemeColor(hex: "#A8742F"),
        danger: ThemeColor(hex: "#BF4D43"),
        chartGrid: ThemeColor(hex: "#000000", opacity: 0.05),
        chartFill: [ThemeColor(hex: "#5F7DA8", opacity: 0.09), ThemeColor(hex: "#5F7DA8", opacity: 0.0)],
        separator: ThemeColor(hex: "#E4E2D8"),
        metricColors: [
            "cpu.total_percent": ThemeColor(hex: "#5F7DA8"),
            "gpu.utilization_percent": ThemeColor(hex: "#A86F8E"),
            "memory.used_bytes": ThemeColor(hex: "#8A6FA8"),
            "disk.read_bytes_per_sec": ThemeColor(hex: "#8A8778"),
            "network.rx_bytes_per_sec": ThemeColor(hex: "#6A8F5F"),
            "thermal.soc_temp_c": ThemeColor(hex: "#BF6A4D"),
        ],
        fontFamily: .system,
        barFontSize: 11,
        barFontWeight: .medium,
        numericStyle: .monospacedDigit,
        cornerRadius: 12,
        density: .comfortable,
        chartStyle: .area,
        chartLineWidth: 1.5,
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
    /// (minimal → native → glass), then the redesign exploration trio
    /// (Paper / One Dark / Ivory — see the design handoff), then the
    /// remaining fixed-appearance and IDE/brand-inspired sets.
    public static let builtInPresets: [Theme] = [
        .notion, .system, .translucent, .liquidGlass,
        .paper, .oneDark, .ivory,
        .slate,
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
