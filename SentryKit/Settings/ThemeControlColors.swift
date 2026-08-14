import Foundation

// MARK: - ThemeControlColors: a switch, resolved against the surface it sits on

/// Every colour a themed switch draws, derived from a `Theme` and held to a
/// stated contrast floor against the surface it is actually painted on.
///
/// **Why this type exists at all.** Until now every `Toggle` in the product
/// rendered with AppKit's stock switch. There is no custom `ToggleStyle`
/// anywhere, and exactly one call site (`SleepControlCard`'s Keep Awake row)
/// bothered with `.tint(palette.accent)` — which only ever recolours the *on*
/// track. The off track is a fixed system grey chosen by AppKit against
/// AppKit's own window colours, and nothing in this app's palette was
/// consulted when it was picked. On a warm light preset that is not a
/// cosmetic mismatch, it is a missing control: Ivory paints its grouped rows
/// on `#F0EEE6`, the system off-track lands within a couple of percent of it,
/// and the switch disappears into the page. The user cannot see the thing
/// they are meant to click.
///
/// **Why the derivation lives in `SentryKit` and not next to the view.** The
/// same argument `ThemeColor.components(fromHex:)` already won: if the
/// renderer computes its own colours and the auditor computes different ones,
/// the audit is decoration. Putting the derivation here — pure, synchronous,
/// no AppKit, no SwiftUI — means `ThemedToggleStyle` draws exactly the bytes
/// `ThemedControlContrastTests` sweeps, so a preset that passes the test is a
/// preset that is genuinely visible on screen. It also means the sweep can
/// run over `Theme.builtInPresets` without a host application, which is what
/// makes it cheap enough to keep.
///
/// **The model: off is an outlined control, on is a filled one.** This is the
/// substantive design decision and it is what actually fixes the bug. Simply
/// giving the off track a themed *fill* is not enough and the arithmetic says
/// so: an off switch is supposed to recede, so any fill honest enough to look
/// "off" on Ivory sits within ~1.2:1 of the surface, which is precisely the
/// invisibility being complained about. The way out is the one WCAG 1.4.11
/// itself describes — a component's *boundary* is what has to be discernible,
/// not its interior. So the off state keeps a quiet recessed fill and gains a
/// border that is held to the full 3:1, and the affordance survives regardless
/// of how subtle the fill is. Rejected alternative: darkening the off fill
/// itself to 3:1, which reads as a filled — that is, *on* — switch on every
/// light preset and would have traded an invisible control for a lying one.
///
/// **On must not be carried by hue.** Position of the knob already
/// distinguishes the states, and this codebase's standing rule is that colour
/// is never the sole channel. Three independent things therefore change
/// between off and on: the knob moves, the track fill crosses a 3:1 boundary,
/// and the knob's own colour flips sides (it is graded against whichever track
/// it is currently sitting on, so it stays visible in both). A user who cannot
/// separate the accent from grey still sees a puck at the other end of a
/// trough that changed weight.
public struct ThemeControlColors: Equatable, Sendable {

    // MARK: Floors

    /// WCAG 2.1 SC 1.4.11, non-text contrast: **3:1** for "visual information
    /// required to identify user interface components and their states".
    ///
    /// Taken as stated rather than argued down. A switch is the textbook case
    /// the success criterion was written for, and this app already applies the
    /// same 3.0 to metric colours via `ContrastRequirement.nonText` — using a
    /// softer number here would mean a chart stroke is held to a higher bar
    /// than the control the user is supposed to operate, which is indefensible.
    /// Not argued *up* to 4.5 either: that is the text criterion, it would
    /// force a heavy black-bordered switch onto every light preset, and it
    /// would make the themes' own quiet aesthetic unreachable for no
    /// accessibility gain the spec asks for.
    public static let componentMinimumRatio: Double = 3.0

    /// **1.8:1** for a disabled switch.
    ///
    /// This one *is* a deviation and deserves its argument. WCAG 1.4.11
    /// explicitly exempts inactive components, so the defensible-by-the-letter
    /// choice is no floor at all — and that is exactly what produces the bug
    /// this file exists to kill, one rung down: the Alerts pane has genuinely
    /// disabled rules, and an unbounded "disabled" treatment on Ivory renders
    /// them as blank space where a switch should be. A user then cannot tell a
    /// disabled rule from a missing one.
    ///
    /// So a floor, but a lower one, because a disabled control that clears the
    /// same 3:1 as an enabled one does not *look* disabled and the dimming has
    /// to be visible as dimming. 1.8:1 is picked as roughly the midpoint of the
    /// perceptual gap between 1:1 (invisible) and 3:1 (fully present): far
    /// enough below the enabled floor that the two states are obviously
    /// different, far enough above 1:1 that the outline still resolves as an
    /// edge on every built-in preset. It is a judgement call, not a citation,
    /// and it is written down here so the next person can change it on purpose.
    public static let disabledMinimumRatio: Double = 1.8

    /// How far apart the off track and the on track must be from each other:
    /// **2:1** enabled, **1.4:1** disabled.
    ///
    /// Not 3:1, and the reason is arithmetic rather than taste. The two
    /// obligations WCAG 1.4.11 actually imposes are on each state against its
    /// *backdrop*, and both are met above. Those two constraints then bound
    /// what is left over, and the bound is tight: the off track deliberately
    /// sits only `offTrackRecessRatio` (1.12:1) from the surface, so the most
    /// the two states can ever be apart is roughly the state's own floor
    /// divided by that recess — about 2.68:1 enabled, about 1.6:1 disabled.
    /// Demanding 3:1 between them would therefore be demanding that the off
    /// track stop looking off, which is the same trap as filling it.
    ///
    /// So each bar is set just inside what the geometry allows, which is also
    /// why the disabled number is not simply the enabled one: a single
    /// constant would have been unsatisfiable for every disabled switch in the
    /// app, and the first version of this file shipped exactly that mistake —
    /// the sweep caught it on ten preset/surface combinations before it
    /// reached a screen. The separation the ratio cannot supply is carried by
    /// two non-colour channels instead: the knob's position, and the knob's
    /// own colour flipping sides with the track it sits on.
    public static func stateSeparationMinimumRatio(isEnabled: Bool) -> Double {
        isEnabled ? 2.0 : 1.4
    }

    /// How far the off track sits from the surface behind it — enough to read
    /// as a carved trough, not enough to read as a fill. Named rather than
    /// inlined because `stateSeparationMinimumRatio(isEnabled:)` is derived
    /// from it and the two must move together.
    public static let offTrackRecessRatio: Double = 1.12

    // MARK: Resolved colours

    /// The surface this switch is drawn on, already made opaque. Exposed
    /// because the contrast sweep grades against it and must not re-derive it.
    public let backdrop: ThemeColor.RGBA

    /// Off: a quiet recess. Deliberately close to `backdrop` — see the type's
    /// doc comment on why the fill is *not* what carries the affordance.
    public let offTrack: ThemeColor.RGBA
    /// Off: the rim that makes the control a control. Held to the floor.
    public let offBorder: ThemeColor.RGBA
    /// Off: the knob, graded against `offTrack` because that is what it is
    /// literally sitting on.
    public let offKnob: ThemeColor.RGBA

    /// On: a filled track, held to the floor against `backdrop` so the state
    /// change is legible as a change in weight and not only in hue.
    public let onTrack: ThemeColor.RGBA
    public let onBorder: ThemeColor.RGBA
    /// On: the knob, graded against `onTrack`.
    public let onKnob: ThemeColor.RGBA

    /// Whether `backdrop` had to be guessed because the theme is translucent
    /// all the way down. Mirrors `ContrastFinding.backdropIsApproximate`; the
    /// sweep reports it rather than skipping those presets.
    public let backdropIsApproximate: Bool

    // MARK: Derivation

    /// Resolves the switch palette for one theme, one appearance, one surface.
    ///
    /// Returns `nil` only when the theme's own backdrop token cannot be
    /// parsed — an unparseable colour has no contrast, and inventing one here
    /// would be the fabrication `ContrastFinding.ratio` refuses to make. The
    /// renderer falls back to the stock control in that case, which is wrong
    /// but honestly wrong.
    ///
    /// **Seed colours are chosen for hue, floors for visibility.** Each part
    /// starts from the theme token whose *role* it shares — the rim from
    /// `separator` (the theme's own hairline), the off knob from
    /// `textSecondary` (a mark, not a surface), the on track from `accent`,
    /// the on knob from `surface` (a puck cut from the page) — and is then
    /// pushed by `ThemeContrast.legible` only as far as the floor requires.
    /// A preset whose tokens already clear the floor is therefore drawn
    /// *verbatim*: Ivory's `#C96442` accent measures 3.7:1 on its own surface
    /// and comes back untouched. That is the same discipline `WatchPalette`
    /// settled on — repair where a canvas the author never saw forces it,
    /// never restyle for its own sake.
    public init?(
        theme: Theme,
        appearance: ThemeAppearance,
        backdrop backdropToken: ThemeColorToken,
        isEnabled: Bool = true
    ) {
        guard let resolved = Self.resolvedBackdrop(theme, appearance: appearance, token: backdropToken) else {
            return nil
        }
        self.backdrop = resolved.rgba
        self.backdropIsApproximate = resolved.approximate

        let floor = isEnabled ? Self.componentMinimumRatio : Self.disabledMinimumRatio
        let base = resolved.rgba

        // The recess. `legible` seeded with the backdrop *itself* is the
        // shortest honest spelling of "a hair away from the page, in whatever
        // direction the page leaves room": it shades on a light preset and
        // tints on a dark one, so the trough reads as carved in both without
        // either half needing its own constant.
        self.offTrack = ThemeContrast.legible(base, onto: base, toRatioAtLeast: Self.offTrackRecessRatio)

        // The rim, and the whole reason the off state is visible at all.
        self.offBorder = ThemeContrast.legible(
            Self.seed(theme.separator, appearance: appearance, onto: base),
            onto: base,
            toRatioAtLeast: floor
        )

        self.offKnob = ThemeContrast.legible(
            Self.seed(theme.textSecondary, appearance: appearance, onto: offTrack),
            onto: offTrack,
            toRatioAtLeast: floor
        )

        // A disabled switch that is "on" must not keep shouting in the accent
        // colour — an accent-filled track is the loudest thing on the row and
        // reads as the most active control on screen, which is the opposite of
        // the truth. Disabled borrows `textTertiary`, so a disabled-on switch
        // is a grey filled switch: still unmistakably in the on *position*,
        // obviously not available.
        let trackSeed = isEnabled ? theme.accent : theme.textTertiary
        self.onTrack = ThemeContrast.legible(
            Self.seed(trackSeed, appearance: appearance, onto: base),
            onto: base,
            toRatioAtLeast: floor
        )

        // Usually equal to `onTrack`, because a fill already held to the floor
        // needs no help resolving its own edge. It exists so the style can
        // stroke unconditionally in both states — a switch whose outline
        // vanishes on the on state and returns on the off state reads as two
        // different controls — and so a future accent that only just clears
        // the floor against its surface still gets a defined boundary.
        self.onBorder = ThemeContrast.legible(onTrack, onto: base, toRatioAtLeast: floor)

        self.onKnob = ThemeContrast.legible(
            Self.seed(theme.surface, appearance: appearance, onto: onTrack),
            onto: onTrack,
            toRatioAtLeast: floor
        )
    }

    /// A token resolved for `appearance` and composited onto the surface it
    /// will be drawn against, so `legible` receives an opaque starting point.
    ///
    /// Falls back to the backdrop when the token cannot be parsed: `legible`
    /// seeded with its own backdrop still returns a colour that clears the
    /// floor (it simply has no hue of its own to preserve), which degrades a
    /// malformed theme to a neutral-but-visible switch rather than to no
    /// switch. P5 again — a bad import must not render an invisible view.
    private static func seed(
        _ token: ThemeColor,
        appearance: ThemeAppearance,
        onto backdrop: ThemeColor.RGBA
    ) -> ThemeColor.RGBA {
        guard let raw = token.rgba(for: appearance) else { return backdrop }
        return raw.alpha < 0.999 ? ThemeContrast.flatten(raw, onto: backdrop) : raw
    }

    /// One backdrop token, made opaque, with the honesty flag the caller has
    /// to propagate.
    ///
    /// **Material themes are the interesting case and this is the compromise.**
    /// System draws over a real `NSVisualEffectView`
    /// (`themedBackdrop(_:)` → `VisualEffect`), so the effective backdrop is
    /// the user's desktop, blurred, plus whatever the theme washes over it.
    /// That is not a colour this process can know, and pretending alpha is 1
    /// is the one wrong answer that is actively dangerous — it *overstates*
    /// contrast, so the switch would pass the sweep and still vanish.
    ///
    /// So: `surface` and `surfaceElevated` are flattened onto the theme's own
    /// **`background`**, because that is literally the layer beneath them in
    /// the view tree — System's `#0000000A` surface really is sitting on
    /// System's `#FFFFFF` wash, and compositing those two is exact, not
    /// approximate. Only when `background` is *itself* translucent does a
    /// guess become unavoidable, and there we reuse the assumption
    /// `ThemeContrastAudit` already made rather than inventing a second one:
    /// `ThemeContrast.assumedBackdrop(for:)`, white under light and black
    /// under dark. Findings computed through that guess carry
    /// `backdropIsApproximate`, and the sweep prints it.
    ///
    /// Rejected alternative: sampling the actual `NSVisualEffectView` output
    /// at runtime and adapting. It would be more accurate and it would make
    /// the switch's colour depend on the user's wallpaper, so the same preset
    /// would look different on two machines and no test could pin it down.
    public static func resolvedBackdrop(
        _ theme: Theme,
        appearance: ThemeAppearance,
        token: ThemeColorToken
    ) -> (rgba: ThemeColor.RGBA, approximate: Bool)? {
        guard let raw = theme[token].rgba(for: appearance) else { return nil }

        // The page itself: nothing in the app is behind it but the desktop.
        guard token != .background else {
            guard raw.alpha < 0.999 else { return (raw, false) }
            return (
                ThemeContrast.flatten(raw, onto: ThemeContrast.assumedBackdrop(for: appearance)),
                true
            )
        }

        guard raw.alpha < 0.999 else { return (raw, false) }
        guard let page = resolvedBackdrop(theme, appearance: appearance, token: .background) else {
            return (
                ThemeContrast.flatten(raw, onto: ThemeContrast.assumedBackdrop(for: appearance)),
                true
            )
        }
        return (ThemeContrast.flatten(raw, onto: page.rgba), page.approximate)
    }

    // MARK: Grading

    /// The surfaces a themed switch is genuinely drawn on, and therefore the
    /// ones the sweep grades against.
    ///
    /// All three, because the product uses all three: the settings panes'
    /// grouped `Form` rows paint on `surface`, `SleepControlCard` sits in a
    /// dropdown card on `surfaceElevated`, and the dropdown's own ungrouped
    /// rows paint straight onto `background`. Grading only against `surface`
    /// would have passed the exact row in the bug report.
    public static let hostSurfaces: [ThemeColorToken] = [.background, .surface, .surfaceElevated]
}
