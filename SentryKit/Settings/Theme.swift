import Foundation
import CoreGraphics

// MARK: - Supporting tokens

/// Typeface choice for bar-item and dropdown text. `.custom` carries a PostScript
/// font name so a user-imported `.sentrytheme` can request an installed font
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

/// Mirrors SwiftUI's `Font.TextStyle` cases as a plain token, for the same
/// reason `FontWeightToken` above mirrors `Font.Weight`: this file is the
/// model layer, and the model layer here is deliberately Foundation-only
/// (see `ThemeAppearance`'s doc comment for the full rationale — `SentryKit`
/// is linked by `SentryCLI`, `SentryMCP` and the fan daemon, none of which
/// should drag SwiftUI in). The app targets map this token to the real
/// `Font.TextStyle` at the rendering boundary.
///
/// `.headline` is deliberately absent. It shares `.body`'s 17pt default
/// size and differs only in weight, and weight is already carried
/// separately by every typography call site in this codebase — including it
/// would make `TypeScale.textStyle(forSize:)` below ambiguous at 17pt
/// without expressing anything the `weight:` argument doesn't already say.
public enum TextStyleToken: String, Codable, Equatable, Sendable, CaseIterable {
    case caption2
    case caption
    case footnote
    case subheadline
    case callout
    case body
    case title3
    case title2
    case title
    case largeTitle
}

/// Maps a hand-tuned point size onto the Dynamic Type text style that scales
/// most like it.
///
/// **Why this exists.** Every typography call site in the Mac and iPhone
/// apps is a literal point size (`palette.font(size: 11)`), because both
/// designs were drawn against menu-bar and card metrics where a fixed size
/// is the correct answer. On iPhone it is not: text that ignores the user's
/// Dynamic Type setting is an accessibility failure. The iPhone app
/// therefore scales those same literals relative to a text style, and this
/// type is how a literal picks its style without every call site having to
/// pass one by hand (and get it subtly wrong 58 different ways).
///
/// **Why nearest-anchor and not a fixed multiplier.** Each `Font.TextStyle`
/// has its own scaling curve — at the largest accessibility size `.caption2`
/// roughly quadruples while `.largeTitle` grows about 30%. That is the
/// point: a 64pt hero numeral must *not* quadruple, and an 11pt caption must
/// grow a lot to be readable at all. Choosing the anchor whose default size
/// is nearest the requested size inherits Apple's intended curve for text of
/// that visual weight, which is exactly what a hand-written multiplier would
/// spend a long time approximating badly.
///
/// **Ties go to the smaller style.** 14pt sits exactly between `.footnote`
/// (13) and `.subheadline` (15). Picking the smaller anchor makes the text
/// grow slightly *more*, which is the safe direction to be wrong in for an
/// accessibility feature: worst case something is a little larger than
/// ideal, rather than a little too small for the person who asked for large
/// text.
public enum TypeScale {
    /// Each style's default point size at the system's default content size
    /// category (`.large`) on iOS, in ascending order. These are Apple's
    /// published values, not measurements — they are the anchors that define
    /// what "relative to `.body`" means, so hardcoding them is reading the
    /// spec, not caching a runtime result.
    public static let anchors: [(style: TextStyleToken, size: CGFloat)] = [
        (.caption2, 11),
        (.caption, 12),
        (.footnote, 13),
        (.subheadline, 15),
        (.callout, 16),
        (.body, 17),
        (.title3, 20),
        (.title2, 22),
        (.title, 28),
        (.largeTitle, 34),
    ]

    /// The text style whose default size is nearest `size`, ties resolving to
    /// the smaller style. Sizes below 11pt clamp to `.caption2` and sizes
    /// above 34pt clamp to `.largeTitle` — both ends are saturating on
    /// purpose: there is no smaller or larger anchor to interpolate toward,
    /// and a 64pt hero numeral genuinely does want `.largeTitle`'s gentle
    /// curve rather than an extrapolated one nobody has design-reviewed.
    public static func textStyle(forSize size: CGFloat) -> TextStyleToken {
        var best = anchors[0]
        for anchor in anchors.dropFirst() {
            // Strict `<` keeps the earlier (smaller) anchor on an exact tie,
            // since `anchors` is ascending.
            if abs(anchor.size - size) < abs(best.size - size) {
                best = anchor
            }
        }
        return best.style
    }
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
/// on, but it lives in SwiftUI and `SentryKit` is deliberately
/// Foundation-only for the model layer — the contrast auditor
/// (`ThemeContrast`) and the `.sentrytheme` validator both need to resolve a
/// token pair without importing a UI framework. The two SwiftUI bridges
/// (`Sentry/Dropdown/ThemeColor+SwiftUI.swift` and its iOS mirror) map
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

/// The user's appearance choice for the whole app: follow macOS, or pin the
/// theme to one half of its light/dark pair. Distinct from `ThemeAppearance`
/// (which names a *resolved* half and has no "follow the system" case) so
/// the model layer never has to answer "what is the system appearance" —
/// only the rendering layer can, and only it consumes `.auto`.
public enum AppearanceMode: String, Codable, CaseIterable, Equatable, Sendable {
    case auto
    case light
    case dark

    public var displayName: String {
        switch self {
        case .auto: return String(localized: "Auto")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    /// The pinned half, or nil for "ask the system".
    public var fixedAppearance: ThemeAppearance? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
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
    /// **Why this lives in `SentryKit` now.** It used to exist twice, as a
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

// MARK: - Built-in presets (six themes, each a light/dark pair)

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

    /// Slate — minimal. Graphite dark half, cool paper light half.
    public static let slate = Theme(
        id: "builtin.slate",
        name: "Slate",
        isBuiltIn: true,
        background: ThemeColor(light: "#F4F5F8", dark: "#0D0E12"),
        surface: ThemeColor(light: "#EAECF1", dark: "#181A21"),
        surfaceElevated: ThemeColor(light: "#DFE2E9", dark: "#1F212B"),
        textPrimary: ThemeColor(light: "#24262E", dark: "#E7E7EA"),
        textSecondary: ThemeColor(light: "#565968", dark: "#9A9CA8"),
        textTertiary: ThemeColor(light: "#878B99", dark: "#6B6D78"),
        accent: ThemeColor(light: "#4553CE", dark: "#7C8CF0"),
        success: ThemeColor(light: "#1E6B41", dark: "#5FCE8F"),
        warning: ThemeColor(light: "#835C06", dark: "#E0A851"),
        danger: ThemeColor(light: "#B03340", dark: "#E0616B"),
        chartGrid: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.08),
        // The light half carries an alpha byte (#…4D ≈ 30%) so the shared
        // `opacity` can stay at the dark half's shipped 0.35 without the
        // light chart drowning in indigo — effective light fill ≈ 0.10.
        chartFill: [
            ThemeColor(light: "#4553CE4D", dark: "#7C8CF0", opacity: 0.35),
            ThemeColor(light: "#4553CE", dark: "#7C8CF0", opacity: 0.0),
        ],
        separator: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.08),
        metricColors: nocturneMetricColors(
            accent: ThemeColor(light: "#4553CE", dark: "#7C8CF0"),
            success: ThemeColor(light: "#1E6B41", dark: "#5FCE8F"),
            warning: ThemeColor(light: "#835C06", dark: "#E0A851"),
            danger: ThemeColor(light: "#B03340", dark: "#E0616B")
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

    /// One Dark — direction 1b of the exploration round: Atom's One Dark
    /// palette (its light half follows One Light), blue accent as the only
    /// chrome color.
    public static let oneDark = Theme(
        id: "builtin.onedark",
        name: "One Dark",
        isBuiltIn: true,
        background: ThemeColor(light: "#FAFAFA", dark: "#282C34"),
        surface: ThemeColor(light: "#F1F1F2", dark: "#2F343E"),
        surfaceElevated: ThemeColor(light: "#E7E8EA", dark: "#3A404C"),
        textPrimary: ThemeColor(light: "#383A42", dark: "#D7DAE0"),
        textSecondary: ThemeColor(light: "#5D626E", dark: "#9DA5B4"),
        textTertiary: ThemeColor(light: "#8B909B", dark: "#6B7382"),
        accent: ThemeColor(light: "#2864C8", dark: "#61AFEF"),
        success: ThemeColor(light: "#357034", dark: "#98C379"),
        warning: ThemeColor(light: "#875803", dark: "#E5C07B"),
        danger: ThemeColor(light: "#B93340", dark: "#E06C75"),
        chartGrid: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.05),
        chartFill: [
            ThemeColor(light: "#2864C8", dark: "#61AFEF", opacity: 0.10),
            ThemeColor(light: "#2864C8", dark: "#61AFEF", opacity: 0.0),
        ],
        separator: ThemeColor(light: "#DCDDE0", dark: "#3B4048"),
        metricColors: [
            "cpu.total_percent": ThemeColor(light: "#2864C8", dark: "#61AFEF"),
            "gpu.utilization_percent": ThemeColor(light: "#0A6C80", dark: "#56B6C2"),
            "memory.used_bytes": ThemeColor(light: "#8E34A5", dark: "#C678DD"),
            "disk.read_bytes_per_sec": ThemeColor(light: "#696E79", dark: "#ABB2BF"),
            "network.rx_bytes_per_sec": ThemeColor(light: "#357034", dark: "#98C379"),
            "thermal.soc_temp_c": ThemeColor(light: "#B93340", dark: "#E06C75"),
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
    /// muted dusty metric hues. The dark half keeps the same warmth on
    /// charcoal, with the terracotta lifted a step for legibility.
    public static let ivory = Theme(
        id: "builtin.ivory",
        name: "Ivory",
        isBuiltIn: true,
        background: ThemeColor(light: "#FAF9F5", dark: "#262624"),
        surface: ThemeColor(light: "#F0EEE6", dark: "#302F2C"),
        surfaceElevated: ThemeColor(light: "#E6E3D8", dark: "#3B3A36"),
        textPrimary: ThemeColor(light: "#3D3D3A", dark: "#ECEAE2"),
        textSecondary: ThemeColor(light: "#73726C", dark: "#B3B0A5"),
        textTertiary: ThemeColor(light: "#A3A29A", dark: "#817E74"),
        accent: ThemeColor(light: "#C96442", dark: "#D97757"),
        success: ThemeColor(light: "#6A8F5F", dark: "#8FB284"),
        warning: ThemeColor(light: "#A8742F", dark: "#D3A458"),
        danger: ThemeColor(light: "#BF4D43", dark: "#E68E82"),
        chartGrid: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.05),
        chartFill: [
            ThemeColor(light: "#5F7DA8", dark: "#8BA7CE", opacity: 0.09),
            ThemeColor(light: "#5F7DA8", dark: "#8BA7CE", opacity: 0.0),
        ],
        separator: ThemeColor(light: "#E4E2D8", dark: "#3E3D38"),
        metricColors: [
            "cpu.total_percent": ThemeColor(light: "#5F7DA8", dark: "#8BA7CE"),
            "gpu.utilization_percent": ThemeColor(light: "#A86F8E", dark: "#C393AF"),
            "memory.used_bytes": ThemeColor(light: "#8A6FA8", dark: "#AF94CC"),
            "disk.read_bytes_per_sec": ThemeColor(light: "#8A8778", dark: "#A6A392"),
            "network.rx_bytes_per_sec": ThemeColor(light: "#6A8F5F", dark: "#8FB284"),
            "thermal.soc_temp_c": ThemeColor(light: "#BF6A4D", dark: "#D98E70"),
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

    /// Tokyo Night — IDE-inspired; the light half follows Tokyo Night Day,
    /// darkened where the published palette sits under AA on paper.
    public static let tokyoNight = Theme(
        id: "builtin.tokyoNight",
        name: "Tokyo Night",
        isBuiltIn: true,
        background: ThemeColor(light: "#E1E2E7", dark: "#1A1B26"),
        surface: ThemeColor(light: "#D6D8E3", dark: "#24283B"),
        surfaceElevated: ThemeColor(light: "#CBCEDD", dark: "#2C3149"),
        textPrimary: ThemeColor(light: "#343B58", dark: "#C0CAF5"),
        textSecondary: ThemeColor(light: "#4E5573", dark: "#A9B1D6"),
        textTertiary: ThemeColor(light: "#7A7F9E", dark: "#565F89"),
        accent: ThemeColor(light: "#28479E", dark: "#7AA2F7"),
        success: ThemeColor(light: "#42591E", dark: "#9ECE6A"),
        warning: ThemeColor(light: "#775117", dark: "#E0AF68"),
        danger: ThemeColor(light: "#9F2745", dark: "#F7768E"),
        chartGrid: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.08),
        // Same alpha-byte trick as Slate: the shared opacity stays at the
        // shipped dark 0.35, the light half's #…4D byte tames it to ≈ 0.10.
        chartFill: [
            ThemeColor(light: "#28479E4D", dark: "#7AA2F7", opacity: 0.35),
            ThemeColor(light: "#28479E", dark: "#7AA2F7", opacity: 0.0),
        ],
        separator: ThemeColor(light: "#000000", dark: "#FFFFFF", opacity: 0.08),
        metricColors: nocturneMetricColors(
            accent: ThemeColor(light: "#28479E", dark: "#7AA2F7"),
            success: ThemeColor(light: "#42591E", dark: "#9ECE6A"),
            warning: ThemeColor(light: "#775117", dark: "#E0AF68"),
            danger: ThemeColor(light: "#9F2745", dark: "#F7768E")
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

    /// All built-in presets, in display order. Six themes, every one with a
    /// real light/dark pair: the adaptive natives first (System, then the
    /// warm Ivory), the glass treatment, then the three editor-heritage
    /// palettes (One Dark, Slate, Tokyo Night).
    public static let builtInPresets: [Theme] = [
        .system, .ivory, .translucent, .oneDark, .slate, .tokyoNight,
    ]

    /// The single source of truth for "which theme when the user hasn't chosen
    /// one, or chose one that no longer exists". Call sites use this rather than
    /// naming a preset directly, so changing the default is a one-line edit
    /// here instead of a hunt through every `?? .slate` fallback.
    public static let defaultTheme: Theme = .system
}

// MARK: - Typed metric-color lookup

extension Theme {
    /// `metricColors` is keyed by Appendix A's raw dotted strings (rather than
    /// `MetricID` directly) so a `.sentrytheme` file stays a plain readable
    /// JSON object — `JSONEncoder` only emits dictionaries as objects for
    /// String/Int keys, and would otherwise write an alternating key/value
    /// array. This accessor gives call sites the type safety anyway.
    public func metricColor(for metric: MetricID) -> ThemeColor? {
        metricColors[metric.rawValue]
    }
}
