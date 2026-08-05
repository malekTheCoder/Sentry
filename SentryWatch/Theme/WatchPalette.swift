import SentryKit
import SwiftUI

// MARK: - WatchPalette: a Theme, resolved for the wrist

/// The watch app's single source of colour: whichever `Theme` the phone
/// relayed (`WatchRelaySnapshot.themeID`), resolved for whichever half of it
/// the phone is currently rendering (`themeAppearance`).
///
/// **The watch follows the app, including into light mode.** An earlier
/// version of this type hardcoded the dark half and a black canvas, reasoning
/// that watchOS has no light appearance to ask about and that black is the
/// right canvas for an OLED panel. Both of those facts are true and the
/// conclusion was still wrong: a user running a light theme looks at a light
/// phone, raises their wrist, and sees a black screen that plainly does not
/// match the app it belongs to. The platform having no *system* light mode is
/// not a reason for the app to have no light mode — it only means the watch
/// cannot work out which half to use on its own, which is why the phone now
/// puts its resolved appearance on the wire.
///
/// So the canvas is the theme's real `background`, the cards are its real
/// `surface`, and a light preset gets a light watch face. The cost is honest
/// and worth stating: a light face draws meaningfully more power on an OLED
/// display and is what the always-on mode dims hardest. That is the user's
/// trade to make by picking a light theme, not this type's to make for them.
///
/// **Tokens are rendered exactly as the theme authored them.** No contrast
/// repair, no luminance ceilings, no "safe" substitutions — the watch draws
/// Ivory's `#F0EEE6` cards and `#5F7DA8` CPU dial at those exact values,
/// because they are the values the Mac window and the phone dashboard draw.
/// An earlier version of this type ran every token through a WCAG floor
/// first, which was necessary while the canvas was forced black and became a
/// distortion the moment it wasn't: it would have darkened Ivory's
/// `textSecondary` and `textTertiary` and rendered a heavier palette on the
/// wrist than anywhere else in the product. Whether a theme's own ratios are
/// right is a question `ThemeContrastAudit` and the theme editor answer once,
/// on the Mac; this file does not get to re-answer it per device. See
/// `color(_:fallback:)`.
///
/// The one judgement call left is `metricColor(_:)`, which overrides a metric
/// hue *only* when a preset has aliased it onto its own warning or danger
/// token — see that method.
struct WatchPalette {

    let theme: Theme

    /// Which half of `theme`'s light/dark pair to resolve. Supplied by the
    /// phone rather than inferred — see this type's doc comment.
    let appearance: ThemeAppearance

    init(theme: Theme, appearance: ThemeAppearance = .dark) {
        self.theme = theme
        self.appearance = appearance
    }

    init(snapshot: WatchRelaySnapshot?) {
        self.theme = snapshot?.resolvedTheme ?? .defaultTheme
        self.appearance = snapshot?.resolvedAppearance ?? .dark
    }

    // MARK: Canvas

    /// The theme's own background — the page colour the Mac window and the
    /// phone dashboard draw, verbatim.
    var background: Color { color(theme.background, fallback: appearance == .dark ? 0.0 : 1.0) }

    /// Cards and wells: the theme's own surface.
    var surface: Color { color(theme.surface, fallback: appearance == .dark ? 0.08 : 0.96) }

    var surfaceElevated: Color { color(theme.surfaceElevated, fallback: appearance == .dark ? 0.14 : 0.92) }

    /// Hairlines and unfilled gauge tracks.
    ///
    /// Passed through at whatever contrast the theme gave it, which for a
    /// warm light preset is deliberately very low — Ivory's `#E4E2D8` sits at
    /// 1.12:1 against its own surface. That is not a bug to correct: a
    /// hairline and a gauge track are *supposed* to recede, it is exactly
    /// what the Mac's charts and the phone's battery bar draw, and lifting it
    /// here would make the watch the one surface where the theme looks
    /// heavier than everywhere else.
    var separator: Color { color(theme.separator, fallback: appearance == .dark ? 0.2 : 0.85) }

    // MARK: Text

    var textPrimary: Color { color(theme.textPrimary, fallback: appearance == .dark ? 0.9 : 0.1) }
    var textSecondary: Color { color(theme.textSecondary, fallback: appearance == .dark ? 0.6 : 0.4) }

    /// The dimmest tier, for units and inert labels.
    var textTertiary: Color { color(theme.textTertiary, fallback: appearance == .dark ? 0.4 : 0.6) }

    // MARK: Semantic

    var accent: Color { color(theme.accent, fallback: 0.5) }
    var success: Color { color(theme.success, fallback: 0.5) }
    var warning: Color { color(theme.warning, fallback: 0.5) }
    var danger: Color { color(theme.danger, fallback: 0.5) }

    /// The colour the Mac's own charts draw this metric in, contrast-repaired
    /// for the card it sits on — **unless that colour is one this theme also
    /// uses to mean "something is wrong."**
    ///
    /// **Why the exception, and why it is not just "don't use metric
    /// colours."** Most presets give each metric a distinct, purely
    /// decorative hue: Ivory draws CPU in slate `#5F7DA8`, memory in muted
    /// purple `#8A6FA8` and GPU in wine `#A86F8E`, none of which mean
    /// anything on their own. Those are exactly the colours the Mac window
    /// and the phone dashboard put on screen, so using them here is what
    /// makes the wrist look like the same product — and dropping them, as an
    /// earlier version of this file did, is what made the watch look
    /// generic.
    ///
    /// But a few presets reuse their *semantic* tokens as metric identities:
    /// `nocturneMetricColors`, which Notion and its siblings share, sends
    /// `memory.used_bytes` straight to `warning` and `thermal.soc_temp_c` to
    /// `danger`. On a Mac those land on separate labelled charts and read as
    /// decoration. On a watch, three dials sit side by side and this app has
    /// already taught the user that orange means elevated — so a memory dial
    /// drawn in the warning colour says "your Mac has a problem" about a Mac
    /// with perfectly normal memory pressure. Verified on the simulator under
    /// Notion, which is the shipping default.
    ///
    /// So the rule is narrow and mechanical: take the theme's colour unless
    /// it is (near enough) this theme's own warning or danger, in which case
    /// fall back to the accent. Themes that keep the two vocabularies
    /// separate get their real palette; themes that overload one lose only
    /// the overloaded entry.
    func metricColor(_ metric: MetricID) -> Color {
        guard let token = theme.metricColor(for: metric),
              let value = token.rgba(for: appearance) else { return accent }
        if collidesWithSeverityVocabulary(value) { return accent }
        return Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: value.alpha)
    }

    /// Whether `candidate` is close enough to this theme's `warning` or
    /// `danger` that using it as a metric identity would read as an alarm.
    ///
    /// Summed per-channel distance rather than an exact match: a preset that
    /// derives a metric colour by nudging its danger token a few points would
    /// pass an equality check and still look like an alarm. 0.08 across three
    /// channels is roughly "closer than two adjacent swatches in the same
    /// ramp" — tight enough that Ivory's wine `#A86F8E` and its danger
    /// `#BF4D43` stay comfortably distinct (verified in
    /// `WatchPaletteFidelityTests`), loose enough to catch the exact aliasing
    /// `nocturneMetricColors` does.
    private func collidesWithSeverityVocabulary(_ candidate: ThemeColor.RGBA) -> Bool {
        [theme.warning, theme.danger]
            .compactMap { $0.rgba(for: appearance) }
            .contains { severity in
                abs(severity.red - candidate.red)
                    + abs(severity.green - candidate.green)
                    + abs(severity.blue - candidate.blue) < 0.08
            }
    }

    // MARK: Derivation

    /// Resolves a token for this palette's appearance and returns it
    /// **exactly as the theme authored it**.
    ///
    /// **Why there is no contrast repair here any more.** An earlier version
    /// of this type ran every token through
    /// `ThemeContrast.legible(_:onto:toRatioAtLeast:)` before drawing it, and
    /// that was load-bearing while the watch canvas was hardcoded black: a
    /// preset authored for a warm paper page had to be dragged somewhere
    /// legible to survive on a background it was never designed for. Once the
    /// canvas became the theme's own `background`, every token is once again
    /// sitting on precisely the surface it was authored against — the same
    /// one the Mac window and the phone dashboard put it on — and the repair
    /// stopped fixing anything and started distorting the design.
    ///
    /// It was measurably not a no-op. Against Ivory's `#F0EEE6` surface,
    /// `textSecondary` (`#73726C`) lands at 4.15:1 and `textTertiary`
    /// (`#A3A29A`) at 2.21:1, so a 4.5/3.0 WCAG floor would have darkened
    /// both — the watch would have rendered a visibly heavier, higher-contrast
    /// version of a palette the rest of the product draws softly, which is the
    /// opposite of matching it. Whether those ratios are the right call is a
    /// question about the theme, and it is answered once, on the Mac, by
    /// `ThemeContrastAudit` and the theme editor. It is not this file's to
    /// re-answer behind the user's back on one device.
    ///
    /// The only thing still handled here is a hex that does not parse at all,
    /// which is a malformed theme rather than a design decision: that returns
    /// a flat grey, obviously wrong to the eye and never invisible.
    private func color(_ token: ThemeColor, fallback: Double) -> Color {
        guard let rgba = token.rgba(for: appearance) else {
            return Color(.sRGB, red: fallback, green: fallback, blue: fallback, opacity: 1)
        }
        return Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

// MARK: - Environment

private struct WatchPaletteKey: EnvironmentKey {
    static let defaultValue = WatchPalette(theme: .defaultTheme, appearance: .dark)
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
