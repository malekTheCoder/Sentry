import SentryKit
import SwiftUI

// MARK: - WatchPalette: a Theme, resolved for the wrist

/// The watch app's single source of colour, derived from whichever `Theme`
/// the phone relayed (`WatchRelaySnapshot.themeID`).
///
/// **Why the watch does not simply resolve the theme's tokens directly, the
/// way the Mac and phone do.** Two things are true of this platform that are
/// not true of the other two, and each one breaks a straight token read.
///
/// 1. *watchOS has no light appearance.* `ThemeColor` stores a light/dark
///    pair, and every other surface picks a half by asking the environment
///    for its `ColorScheme`. There is nothing to ask here — the platform is
///    always dark — so the dark half is the only candidate.
/// 2. *Most of the built-in presets do not actually have a dark half.*
///    `ThemeColor(hex:)` assigns the same string to `light` and `dark` (see
///    that initialiser), and every built-in preset is authored with it. So
///    "the dark half" of Paper's `#FFFFFF` background is `#FFFFFF`. Resolving
///    tokens naively would hand a light preset a **white** watch face: wrong
///    on an OLED panel that is black when off, wrong for an always-on display
///    whose whole power budget assumes dark pixels, wrong outdoors, and
///    unlike anything else on the device.
///
/// **So the canvas is black and the theme supplies the colour on top of it.**
/// That split is the design, not a compromise. Black is the correct watchOS
/// canvas for the reasons above and is what every first-party app does; the
/// theme's job here is the part that actually carries identity — the accent,
/// the per-metric hues the Mac's own charts use, the semantic
/// success/warning/danger trio, and the surface tint the cards are drawn in.
/// A user who picks Nord gets Nord's blues on their wrist and a user who
/// picks Dracula gets its purples, which is what "the watch matches my theme"
/// means; neither gets a white rectangle strapped to their arm.
///
/// **Every colour that lands on screen is contrast-checked against that
/// canvas rather than trusted.** A theme authored for a white page can easily
/// contain a `textPrimary` of `#1F2328` or a metric colour dark enough to
/// vanish on black, and the failure mode is invisible text rather than ugly
/// text. `readable(_:minimumRatio:)` lifts any such token toward white until
/// it clears the WCAG ratio the same `ThemeContrast` the Mac's theme editor
/// audits with says it needs — preserving hue, so a dark navy stays navy and
/// simply becomes a navy that can be read.
struct WatchPalette {
    let theme: Theme

    /// WCAG AA for normal-size text. Applied to secondary text as well as
    /// primary: a watch is read at arm's length in daylight, which is the
    /// condition the "large text" exemption is least safe to claim.
    private static let textContrast: Double = 4.5

    /// WCAG AA for graphical objects and UI components (1.4.11). Dial arcs,
    /// chips and glyphs are shapes, not prose, so they carry the lower
    /// requirement — but they do carry one, which is the difference between
    /// this and trusting the token.
    private static let graphicContrast: Double = 3.0

    /// The canvas the page is drawn on. Black, always — see this type's doc
    /// comment.
    static let canvas = ThemeColor.RGBA(red: 0, green: 0, blue: 0, alpha: 1)

    /// The backdrop every contrast check is actually made against.
    ///
    /// **Not the canvas, and that distinction is a bug this type shipped
    /// with.** Text and glyphs on these pages almost always sit inside a
    /// `WatchCard`, whose fill is `surface` — a colour that is darker than
    /// the theme intended but still meaningfully lighter than black. Judging
    /// a token against pure black therefore flatters it: Paper's `#1F2328`
    /// primary text was lifted just far enough to clear 4.5:1 *on black*, and
    /// then drawn on a card several shades up from black, where it landed at
    /// roughly 2:1 and rendered as grey-on-grey. Verified on the simulator
    /// under the Paper preset, which is exactly the case the lifting exists
    /// for.
    ///
    /// Measuring against the surface instead is safe in both directions,
    /// because `surface` is by construction never darker than the canvas: a
    /// token that clears the ratio here clears it on black too, so the
    /// handful of elements drawn directly on the canvas (the Overview header,
    /// a pill outside a card) are covered by the same guarantee rather than
    /// needing a second one.
    var contrastBackdrop: ThemeColor.RGBA {
        guard let raw = theme.surface.rgba(for: .dark) else { return Self.canvas }
        let flat = raw.alpha < 1 ? ThemeContrast.flatten(raw, onto: Self.canvas) : raw
        return ThemeContrast.dimmed(flat, toLuminanceAtMost: Self.surfaceMaxLuminance)
    }

    /// Ceiling for the card fill's luminance. Low enough that a preset
    /// authored for a white page becomes a dark-mode surface, high enough
    /// that the card is still visibly a card against black.
    static let surfaceMaxLuminance: Double = 0.055

    init(theme: Theme) {
        self.theme = theme
    }

    init(snapshot: WatchRelaySnapshot?) {
        self.theme = snapshot?.resolvedTheme ?? .defaultTheme
    }

    // MARK: Canvas

    /// Pure black. Deliberately not `Color.black` from an asset or a
    /// `.background(.regularMaterial)`: an always-on display keeps these
    /// pixels lit, and a true zero is the only value that turns them off.
    var background: Color { .black }

    /// Cards and wells. The theme's own surface token, pulled down to a
    /// luminance that reads as "slightly raised off black" rather than as a
    /// light panel — which keeps a light preset's *hue* (GitHub's cool grey
    /// stays cool, Ivory's warm grey stays warm) while making it behave like
    /// a dark-mode surface.
    var surface: Color { color(darkening: theme.surface, toAtMost: Self.surfaceMaxLuminance) }

    /// One step brighter than `surface`, for a control that sits on top of a
    /// card rather than directly on the canvas.
    var surfaceElevated: Color { color(darkening: theme.surfaceElevated, toAtMost: 0.10) }

    /// Hairlines. Low enough to read as structure rather than as content,
    /// but — unlike the menu bar's old separator token — high enough to
    /// actually be visible, which is the same bug this codebase just fixed on
    /// the Mac.
    var separator: Color { color(darkening: theme.separator, toAtMost: 0.22) }

    // MARK: Text

    var textPrimary: Color { readable(theme.textPrimary, minimumRatio: Self.textContrast) }
    var textSecondary: Color { readable(theme.textSecondary, minimumRatio: Self.textContrast) }

    /// The dimmest tier, used for units and inert labels. Held to the
    /// graphical ratio rather than the text one on purpose: it is never the
    /// only carrier of a fact — everything it labels is stated in
    /// `textPrimary` beside it — and holding it to 4.5:1 would flatten it
    /// into `textSecondary` and cost the hierarchy a level.
    var textTertiary: Color { readable(theme.textTertiary, minimumRatio: Self.graphicContrast) }

    // MARK: Semantic

    var accent: Color { readable(theme.accent, minimumRatio: Self.graphicContrast) }
    var success: Color { readable(theme.success, minimumRatio: Self.graphicContrast) }
    var warning: Color { readable(theme.warning, minimumRatio: Self.graphicContrast) }
    var danger: Color { readable(theme.danger, minimumRatio: Self.graphicContrast) }

    /// The colour the Mac's own charts draw this metric in, contrast-lifted
    /// for the black canvas. Falls back to the accent for a theme with no
    /// entry — matching `ThemePalette.metricColor`'s rule on the other two
    /// platforms rather than inventing a watch-only default.
    ///
    /// **Deliberately not used by the Overview dials, and that is a design
    /// decision worth stating rather than a leftover.** Several presets map a
    /// metric onto a *semantic* token — Notion's `nocturneMetricColors` sends
    /// `memory.used_bytes` to `warning` and `thermal.soc_temp_c` to `danger`
    /// — which is fine on a Mac, where those colours land on separate labelled
    /// charts, and actively wrong on a watch, where three dials sit side by
    /// side and this app's own grammar has already taught the user that
    /// orange means *elevated*. A memory dial drawn in the warning colour
    /// while pressure is normal tells the user their Mac has a problem it
    /// does not have. `OverviewPage` therefore lets hue mean severity and
    /// nothing else, and leans on the CPU/MEM/DISK labels — which are right
    /// there — to carry identity. This accessor stays for surfaces where a
    /// per-metric hue is genuinely the right call and the semantic collision
    /// cannot arise.
    func metricColor(_ metric: MetricID) -> Color {
        guard let token = theme.metricColor(for: metric) else { return accent }
        return readable(token, minimumRatio: Self.graphicContrast)
    }

    // MARK: Derivation

    /// Resolves a token and, if it is too dark to be seen on the backdrop,
    /// blends it toward white until it clears `minimumRatio`.
    ///
    /// The blend itself lives in `ThemeContrast.lifted(_:onto:toRatioAtLeast:)`
    /// rather than here: it is pure model arithmetic with a guarantee worth
    /// testing (`WatchPaletteTests` sweeps every built-in preset through it),
    /// and a view-layer type in an app target is not reachable from the test
    /// bundle.
    private func readable(_ token: ThemeColor, minimumRatio: Double) -> Color {
        guard let rgba = token.rgba(for: .dark) else {
            // Same fallback the Mac and phone bridges use for a malformed
            // token: obviously wrong to the eye, never invisible.
            return Color(.sRGB, red: 0.5, green: 0.5, blue: 0.5, opacity: token.clampedOpacity)
        }
        let fixed = ThemeContrast.lifted(rgba, onto: contrastBackdrop, toRatioAtLeast: minimumRatio)
        return Color(.sRGB, red: fixed.red, green: fixed.green, blue: fixed.blue, opacity: 1)
    }

    /// Resolves a token and pushes it *down* to at most `maxLuminance`, so a
    /// surface authored for a white page becomes a dark-mode surface of the
    /// same hue instead of a glowing panel.
    private func color(darkening token: ThemeColor, toAtMost maxLuminance: Double) -> Color {
        guard let rgba = token.rgba(for: .dark) else {
            return Color(.sRGB, red: 0.1, green: 0.1, blue: 0.1, opacity: 1)
        }
        let flat = rgba.alpha < 1 ? ThemeContrast.flatten(rgba, onto: Self.canvas) : rgba
        let fixed = ThemeContrast.dimmed(flat, toLuminanceAtMost: maxLuminance)
        return Color(.sRGB, red: fixed.red, green: fixed.green, blue: fixed.blue, opacity: 1)
    }
}

// MARK: - Environment

private struct WatchPaletteKey: EnvironmentKey {
    static let defaultValue = WatchPalette(theme: .defaultTheme)
}

extension EnvironmentValues {
    /// Injected once by `ContentView` from the relayed snapshot, so no page
    /// has to thread a palette through its initialiser or — worse — reach for
    /// a hardcoded `Color` because the plumbing was inconvenient.
    var palette: WatchPalette {
        get { self[WatchPaletteKey.self] }
        set { self[WatchPaletteKey.self] = newValue }
    }
}
