import SentryKit
import SwiftUI

// MARK: - WatchPalette: a Theme, resolved for the wrist

/// The watch app's single source of colour: whichever `Theme` the phone
/// relayed (`WatchRelaySnapshot.themeID`), resolved for whichever half of it
/// the phone is currently rendering (`themeAppearance`).
///
/// **The numbers live in `WatchThemeColors` (`SentryKit/Watch/`); this type
/// only turns them into `Color`.** That split is the one `ThemeControlColors`
/// / `ThemedToggleStyle` made on the Mac and for the same reason: an
/// app-target type cannot be imported by the macOS-hosted test bundle, so
/// while the resolution lived here the only proof a preset rendered legibly
/// on the wrist was a screenshot. `WatchControlContrastTests` now sweeps
/// `Theme.builtInPresets` against exactly the bytes this file draws. Nothing
/// below computes a colour of its own — if it did, the sweep would be
/// grading something other than the screen.
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
/// **Tokens are rendered exactly as the theme authored them, with two
/// exceptions that are the watch's own compositions rather than the
/// theme's** — see `WatchThemeColors`' doc comment for both arguments in
/// full. The canvas is made opaque against the appearance's assumed backdrop
/// (a translucent `background` over the black watch window turned System's
/// light page grey). And a *control's* label — the word in a `StatusPill`,
/// the text of a `WatchActionButtonStyle` button — is held to 3:1 against
/// the tinted wash the watch itself draws under it, because no theme ever
/// authored "accent on 18% accent" and on light presets that pairing was
/// measurably illegible. Everything else — Ivory's `#F0EEE6` cards, its
/// `#5F7DA8` CPU dial, its deliberately soft `textSecondary` — is drawn at
/// the authored value, because those are the values the Mac window and the
/// phone dashboard draw. An earlier version ran every token through a WCAG
/// floor, which was necessary while the canvas was forced black and became a
/// distortion the moment it wasn't: whether a theme's own text ratios are
/// right is a question `ThemeContrastAudit` and the theme editor answer
/// once, on the Mac; this file does not get to re-answer it per device.
///
/// The one judgement call left is `metricColor(_:)`, which overrides a metric
/// hue *only* when a preset has aliased it onto its own warning or danger
/// token — see that method.
struct WatchPalette {

    let theme: Theme

    /// The colours the sender resolved, when it sent any. Takes precedence
    /// over `theme` — see `RelayedPalette`.
    let relayed: RelayedPalette?

    /// Which half of `theme`'s light/dark pair to resolve. Supplied by the
    /// phone rather than inferred — see this type's doc comment.
    let appearance: ThemeAppearance

    /// Every token, resolved once. See the type doc comment for why the
    /// resolution is not done here.
    let colors: WatchThemeColors

    init(theme: Theme, appearance: ThemeAppearance = .dark, relayed: RelayedPalette? = nil) {
        self.theme = theme
        self.appearance = appearance
        self.relayed = relayed
        self.colors = WatchThemeColors(theme: theme, appearance: appearance, relayed: relayed)
    }

    init(snapshot: WatchRelaySnapshot?) {
        self.init(
            theme: snapshot?.resolvedTheme ?? .defaultTheme,
            appearance: snapshot?.resolvedAppearance ?? .dark,
            relayed: snapshot?.themePalette
        )
    }

    // MARK: Canvas

    /// The theme's own background — the page colour the Mac window and the
    /// phone dashboard draw — made opaque against the assumed backdrop for
    /// this appearance (`WatchThemeColors.canvas`). Opaque because the layer
    /// under it on a watch is the black window, which is not what any theme
    /// authored its page alpha against.
    var background: Color { Color(colors.canvas) }

    /// Cards and wells: the theme's own surface, drawn over `background` by
    /// SwiftUI exactly as the Mac draws it over its page.
    var surface: Color { Color(colors.surface) }

    var surfaceElevated: Color { Color(colors.surfaceElevated) }

    /// Hairlines and unfilled gauge tracks.
    ///
    /// Passed through at whatever contrast the theme gave it, which for a
    /// warm light preset is deliberately very low — Ivory's `#E4E2D8` sits at
    /// 1.12:1 against its own surface. That is not a bug to correct: a
    /// hairline and a gauge track are *supposed* to recede, it is exactly
    /// what the Mac's charts and the phone's battery bar draw, and lifting it
    /// here would make the watch the one surface where the theme looks
    /// heavier than everywhere else.
    var separator: Color { Color(colors.separator) }

    // MARK: Text

    var textPrimary: Color { Color(colors.textPrimary) }
    var textSecondary: Color { Color(colors.textSecondary) }

    /// The dimmest tier, for units and inert labels.
    var textTertiary: Color { Color(colors.textTertiary) }

    // MARK: Semantic

    var accent: Color { Color(colors.accent) }
    var success: Color { Color(colors.success) }
    var warning: Color { Color(colors.warning) }
    var danger: Color { Color(colors.danger) }

    // MARK: Controls

    /// The two colours a tinted control draws: `fill` is the token itself,
    /// to be laid down at `WatchThemeColors.controlFillOpacity`, and `label`
    /// is that token held to `controlLabelMinimumRatio` against the fill.
    /// Every `StatusPill` and every `WatchActionButtonStyle` takes one of
    /// these rather than a bare `Color`, so a call site cannot put an
    /// ungraded tint on a control by passing `palette.success` directly —
    /// the type is what closed the gap, not a review checklist.
    func control(_ role: WatchThemeColors.Role) -> WatchControlTint {
        let control = colors.control(role)
        return WatchControlTint(fill: Color(control.tint), label: Color(control.label))
    }

    /// The colour the Mac's own charts draw this metric in — **unless that
    /// colour is one this theme also uses to mean "something is wrong."**
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
    /// `nocturneMetricColors`, which System shares, sends `memory.used_bytes`
    /// straight to `warning` and `thermal.soc_temp_c` to `danger`. On a Mac
    /// those land on separate labelled charts and read as decoration. On a
    /// watch, three dials sit side by side and this app has already taught
    /// the user that orange means elevated — so a memory dial drawn in the
    /// warning colour says "your Mac has a problem" about a Mac with
    /// perfectly normal memory pressure. Verified on the simulator under
    /// System, which is the shipping default.
    ///
    /// So the rule is narrow and mechanical: take the theme's colour unless
    /// it is (near enough) this theme's own warning or danger, in which case
    /// fall back to the accent. Themes that keep the two vocabularies
    /// separate get their real palette; themes that overload one lose only
    /// the overloaded entry.
    func metricColor(_ metric: MetricID) -> Color {
        let relayedHex: String? = {
            switch metric {
            case .cpuTotalPercent: return relayed?.cpu
            case .memoryUsedBytes: return relayed?.mem
            case .diskReadBytesPerSec: return relayed?.dsk
            case .batteryChargePercent: return relayed?.bat
            default: return nil
            }
        }()
        guard let value = relayedHex.flatMap(ThemeColor.components(fromHex:))
            ?? theme.metricColor(for: metric)?.rgba(for: appearance) else { return accent }
        if collidesWithSeverityVocabulary(value) { return accent }
        return Color(value)
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
    /// `WatchThemeFidelityTests`), loose enough to catch the exact aliasing
    /// `nocturneMetricColors` does.
    ///
    /// Compares against the resolved `warning`/`danger` — the relayed pair
    /// when a custom theme was relayed, not the fallback preset's — because
    /// those are the two colours actually on screen.
    private func collidesWithSeverityVocabulary(_ candidate: ThemeColor.RGBA) -> Bool {
        [colors.warning, colors.danger].contains { severity in
            abs(severity.red - candidate.red)
                + abs(severity.green - candidate.green)
                + abs(severity.blue - candidate.blue) < 0.08
        }
    }
}

// MARK: - WatchControlTint

/// See `WatchPalette.control(_:)`. A value type rather than two `Color`
/// parameters on every control so the pair cannot be split up at a call site.
struct WatchControlTint {
    /// Drawn at `WatchThemeColors.controlFillOpacity` — the token verbatim.
    let fill: Color
    /// Opaque, graded against the fill on both hosts.
    let label: Color
}

// MARK: - Color bridging

private extension Color {
    /// `RGBA` → `Color`, straight sRGB, alpha carried through. The only place
    /// in the watch app a `Color` is minted from numbers.
    init(_ rgba: ThemeColor.RGBA) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
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
