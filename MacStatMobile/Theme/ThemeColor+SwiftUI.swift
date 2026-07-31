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

extension ThemeColor {
    /// Resolves this token against a color scheme. See the Mac counterpart's
    /// doc comment for why parsing lives at the rendering layer rather than
    /// in `Theme.swift` itself.
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

    var glow: Double { min(max(theme.glowIntensity, 0), 1) }
}

// MARK: - Glass chrome

extension View {
    /// The one card chrome every card in the iPhone app wears — the iOS
    /// sibling of the Mac Dashboard's `dashboardCard`. Material themes get
    /// Apple's real Liquid Glass on iOS 26+ (`glassEffect`), an
    /// ultra-thin-material tile below; opaque themes keep the flat
    /// elevated-surface fill. One modifier, one geometry.
    @ViewBuilder
    func glassCard(_ palette: ThemePalette) -> some View {
        let shape = RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
        if palette.theme.useMaterialBackground {
            if #available(iOS 26.0, *) {
                self.glassEffect(.regular, in: shape)
            } else {
                self
                    .background(shape.fill(palette.surfaceElevated))
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.strokeBorder(palette.separator, lineWidth: 1))
            }
        } else {
            self
                .background(palette.surfaceElevated)
                .clipShape(shape)
                .overlay(shape.stroke(palette.separator, lineWidth: 1))
        }
    }

    /// Screen backdrop: material themes get the theme's translucent wash
    /// over the system background (letting Liquid Glass cards refract
    /// something), opaque themes their solid background color.
    @ViewBuilder
    func themedScreenBackground(_ palette: ThemePalette) -> some View {
        if palette.theme.useMaterialBackground {
            self.background(palette.background.opacity(0.6)).background(.regularMaterial)
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
