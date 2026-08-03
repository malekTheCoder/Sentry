import Foundation
import CoreGraphics

// MARK: - Addressable color tokens

/// Every scalar color token on `Theme`, as a value you can put in a `ForEach`.
///
/// **Why this exists at all.** §9.3 asks for "color wells for every token,
/// grouped into sections," per-token reset, and an inline contrast flag on
/// each one. Written against `Theme`'s stored properties directly, each of
/// those is a twelve-case switch that has to be kept in sync with the other
/// two by hand — and the failure mode is silent: add a token to `Theme`,
/// forget one switch, and the editor ships a well that edits nothing or a
/// contrast checker that quietly skips a color. Routing all three through one
/// `CaseIterable` enum with a settable subscript means a new token appears in
/// the editor, in the audit, and in reset, or in none of them.
///
/// `chartFill` is deliberately absent: it is an *array* of gradient stops, not
/// a scalar, and pretending otherwise would mean either editing only the first
/// stop (a well that half-works) or flattening the gradient (a well that
/// destroys data). It is edited by its own indexed section in the editor.
/// `metricColors` is absent for the same reason — it is keyed by `MetricID`
/// and has its own grid, per §9.3's separate "per-metric color assignment"
/// bullet.
public enum ThemeColorToken: String, CaseIterable, Codable, Identifiable, Sendable {
    case background
    case surface
    case surfaceElevated
    case textPrimary
    case textSecondary
    case textTertiary
    case accent
    case success
    case warning
    case danger
    case chartGrid
    case separator

    public var id: String { rawValue }

    /// §9.3's "grouped into sections."
    public enum Section: String, CaseIterable, Identifiable, Sendable {
        case surfaces
        case text
        case semantic
        case chrome

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .surfaces: return String(localized: "Surfaces")
            case .text: return String(localized: "Text")
            case .semantic: return String(localized: "Semantic State")
            case .chrome: return String(localized: "Chrome")
            }
        }

        /// One sentence naming what the group actually paints, so a user
        /// picking a color knows what they are about to change without
        /// having to change it and look.
        public var explanation: String {
            switch self {
            case .surfaces:
                return String(localized: "The backdrop and the fills stacked on it — dropdown, Dashboard cards, settings chrome.")
            case .text:
                return String(localized: "The three-step text ramp. Every one of these is contrast-checked against every surface above.")
            case .semantic:
                return String(localized: "State colors. Sentry never encodes state in color alone, so these always ride alongside an icon or a word.")
            case .chrome:
                return String(localized: "Hairlines and gridlines. Structural, never text — so they carry no contrast requirement.")
            }
        }

        public var tokens: [ThemeColorToken] {
            ThemeColorToken.allCases.filter { $0.section == self }
        }
    }

    public var section: Section {
        switch self {
        case .background, .surface, .surfaceElevated: return .surfaces
        case .textPrimary, .textSecondary, .textTertiary: return .text
        case .accent, .success, .warning, .danger: return .semantic
        case .chartGrid, .separator: return .chrome
        }
    }

    public var displayName: String {
        switch self {
        case .background: return String(localized: "Background")
        case .surface: return String(localized: "Surface")
        case .surfaceElevated: return String(localized: "Elevated Surface")
        case .textPrimary: return String(localized: "Primary Text")
        case .textSecondary: return String(localized: "Secondary Text")
        case .textTertiary: return String(localized: "Tertiary Text")
        case .accent: return String(localized: "Accent")
        case .success: return String(localized: "Success")
        case .warning: return String(localized: "Warning")
        case .danger: return String(localized: "Danger")
        case .chartGrid: return String(localized: "Chart Grid")
        case .separator: return String(localized: "Separator")
        }
    }

    /// Where the token is actually drawn. Shown next to each well because
    /// "Elevated Surface" tells a user nothing about which rectangle moves.
    public var usageNote: String {
        switch self {
        case .background: return String(localized: "The window and dropdown backdrop.")
        case .surface: return String(localized: "Sidebar and grouped-row fills.")
        case .surfaceElevated: return String(localized: "Cards sitting on the background; the selected sidebar row.")
        case .textPrimary: return String(localized: "Readouts and headings.")
        case .textSecondary: return String(localized: "Labels, units, and captions.")
        case .textTertiary: return String(localized: "Timestamps and disabled text.")
        case .accent: return String(localized: "Links, actions, and the default chart line.")
        case .success: return String(localized: "Charging, healthy, connected.")
        case .warning: return String(localized: "Approaching a threshold.")
        case .danger: return String(localized: "Over a threshold; failed operations.")
        case .chartGrid: return String(localized: "Gridlines behind history charts.")
        case .separator: return String(localized: "Hairlines between rows and sections.")
        }
    }

    /// Whether this token is ever rendered *as text*, and therefore whether
    /// WCAG AA's 4.5:1 applies to it. See `ThemeContrast` for what the
    /// non-text tokens are held to instead.
    public var isTextToken: Bool {
        switch self {
        case .textPrimary, .textSecondary, .textTertiary,
             .accent, .success, .warning, .danger:
            return true
        case .background, .surface, .surfaceElevated, .chartGrid, .separator:
            return false
        }
    }

    /// Whether this token is used as a *backdrop* that text is drawn on, and
    /// therefore appears as the second half of a contrast pair.
    public var isBackdropToken: Bool {
        switch self {
        case .background, .surface, .surfaceElevated: return true
        default: return false
        }
    }
}

// MARK: - Token access

extension Theme {

    /// Read/write a color token by name. The setter is what lets one generic
    /// color-well row drive any token, and what lets per-token reset be a
    /// single line rather than a twelfth switch case.
    public subscript(token: ThemeColorToken) -> ThemeColor {
        get {
            switch token {
            case .background: return background
            case .surface: return surface
            case .surfaceElevated: return surfaceElevated
            case .textPrimary: return textPrimary
            case .textSecondary: return textSecondary
            case .textTertiary: return textTertiary
            case .accent: return accent
            case .success: return success
            case .warning: return warning
            case .danger: return danger
            case .chartGrid: return chartGrid
            case .separator: return separator
            }
        }
        set {
            switch token {
            case .background: background = newValue
            case .surface: surface = newValue
            case .surfaceElevated: surfaceElevated = newValue
            case .textPrimary: textPrimary = newValue
            case .textSecondary: textSecondary = newValue
            case .textTertiary: textTertiary = newValue
            case .accent: accent = newValue
            case .success: success = newValue
            case .warning: warning = newValue
            case .danger: danger = newValue
            case .chartGrid: chartGrid = newValue
            case .separator: separator = newValue
            }
        }
    }
}

// MARK: - Reset to preset

/// What a "Reset to preset" button is allowed to do right now, and why not
/// if not. Returned rather than a bare `Bool` so the editor can print the
/// reason on screen instead of showing a disabled control with no
/// explanation — this codebase does not ship a button that silently declines.
public enum ThemeResetAvailability: Equatable, Sendable {
    /// The ancestor preset resolved and this token differs from it.
    case available(presetName: String)
    /// The ancestor resolved, but the value already matches it.
    case alreadyMatchesPreset(presetName: String)
    /// The theme has no recorded ancestor (imported, or hand-authored).
    case noBasePreset
    /// The theme records an ancestor this build doesn't ship.
    case basePresetMissing(id: String)

    public var canReset: Bool {
        if case .available = self { return true }
        return false
    }

    /// User-facing explanation for the two unavailable cases. `nil` when
    /// there is nothing to explain.
    public var unavailableReason: String? {
        switch self {
        case .available:
            return nil
        case .alreadyMatchesPreset(let name):
            return String(localized: "Already matches \(name).")
        case .noBasePreset:
            return String(localized: "This theme wasn't duplicated from a preset, so there's nothing to reset to.")
        case .basePresetMissing(let id):
            return String(localized: "The preset this theme came from (\(id)) isn't in this version of Sentry.")
        }
    }
}

extension Theme {

    /// Whether one token can be reset, and to what.
    public func resetAvailability(for token: ThemeColorToken) -> ThemeResetAvailability {
        guard let basePresetID else { return .noBasePreset }
        guard let preset = basePreset else { return .basePresetMissing(id: basePresetID) }
        return self[token] == preset[token]
            ? .alreadyMatchesPreset(presetName: preset.name)
            : .available(presetName: preset.name)
    }

    /// Whether the whole theme can be reset. "Available" here means the
    /// ancestor resolves *and* at least one token differs from it — resetting
    /// a theme that is already identical to its preset is a no-op the editor
    /// should say so about rather than perform.
    public var globalResetAvailability: ThemeResetAvailability {
        guard let basePresetID else { return .noBasePreset }
        guard let preset = basePreset else { return .basePresetMissing(id: basePresetID) }
        let differs = ThemeColorToken.allCases.contains { self[$0] != preset[$0] }
            || metricColors != preset.metricColors
            || chartFill != preset.chartFill
            || !matchesNonColorTokens(of: preset)
        return differs
            ? .available(presetName: preset.name)
            : .alreadyMatchesPreset(presetName: preset.name)
    }

    /// Typography/geometry/effects equality, ignoring identity and color.
    /// Spelled out rather than derived from `==` because `Theme`'s synthesized
    /// equality includes `id` and `name`, which always differ between a fork
    /// and its preset — a global-reset check written as `self == preset` would
    /// therefore always claim "differs" and the button would never go quiet.
    private func matchesNonColorTokens(of preset: Theme) -> Bool {
        fontFamily == preset.fontFamily
            && barFontSize == preset.barFontSize
            && barFontWeight == preset.barFontWeight
            && numericStyle == preset.numericStyle
            && cornerRadius == preset.cornerRadius
            && density == preset.density
            && chartStyle == preset.chartStyle
            && chartLineWidth == preset.chartLineWidth
            && showChartGrid == preset.showChartGrid
            && barGraphWidth == preset.barGraphWidth
            && useMaterialBackground == preset.useMaterialBackground
            && materialStyle == preset.materialStyle
            && glowIntensity == preset.glowIntensity
            && scanlineOverlay == preset.scanlineOverlay
    }

    /// Restore one token to its ancestor preset's value. A no-op (rather than
    /// a crash or a guessed value) when there is no ancestor to consult, which
    /// is why the editor asks `resetAvailability(for:)` first and disables the
    /// control with a printed reason — this method being safe is a backstop,
    /// not the user-facing story.
    public mutating func resetToPreset(_ token: ThemeColorToken) {
        guard let preset = basePreset else { return }
        self[token] = preset[token]
    }

    /// Restore one metric's color to its ancestor preset's value. Removing
    /// the key entirely is the correct reset when the preset itself has no
    /// entry for that metric: `ThemePalette.metricColor` falls back to the
    /// accent for a missing key, so writing *some* color in would leave the
    /// fork differing from its preset in a way the user couldn't undo.
    public mutating func resetMetricColorToPreset(_ metric: MetricID) {
        guard let preset = basePreset else { return }
        if let presetColor = preset.metricColors[metric.rawValue] {
            metricColors[metric.rawValue] = presetColor
        } else {
            metricColors.removeValue(forKey: metric.rawValue)
        }
    }

    /// Restore every token to the ancestor preset, keeping only this theme's
    /// own identity — its `id`, its `name`, and the ancestor link itself.
    ///
    /// Keeping the name is deliberate: the user named this theme, and a
    /// "reset" that also renamed "Malek's Dark" back to "One Dark" would be
    /// discarding something they typed rather than something they picked.
    public mutating func resetAllToPreset() {
        guard let preset = basePreset else { return }
        let keptID = id
        let keptName = name
        let keptBase = basePresetID
        self = preset
        id = keptID
        name = keptName
        isBuiltIn = false
        basePresetID = keptBase
    }
}

// MARK: - Editable numeric ranges

/// The bounds every numeric theme token is edited and validated within.
///
/// One table rather than magic numbers in the sliders and *different* magic
/// numbers in the importer: the ranges the editor can produce and the ranges
/// an imported file is allowed to contain have to be the same set, or a
/// perfectly ordinary theme exported from this app fails to import into it.
/// The bounds themselves are drawn from what the renderers can actually
/// survive — a 3pt bar font is unreadable at menu-bar size, a 400pt sparkline
/// would push every other status item off the bar.
public enum ThemeLimits {
    public static let barFontSize: ClosedRange<CGFloat> = 8...16
    public static let cornerRadius: ClosedRange<CGFloat> = 0...24
    public static let chartLineWidth: ClosedRange<CGFloat> = 0.5...6
    public static let barGraphWidth: ClosedRange<CGFloat> = 16...120
    public static let glowIntensity: ClosedRange<Double> = 0...1
    public static let opacity: ClosedRange<Double> = 0...1

    /// Gradient stops. Two is the useful minimum (SwiftUI degenerates on
    /// one); the cap exists so a hostile file can't ask the renderer to build
    /// a ten-thousand-stop gradient.
    public static let chartFillStops: ClosedRange<Int> = 0...8

    /// Theme names appear in a menu, a picker, and a sidebar; past this they
    /// stop being names and start being layout problems.
    public static let nameLength: ClosedRange<Int> = 1...60
}
