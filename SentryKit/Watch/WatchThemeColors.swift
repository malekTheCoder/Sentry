import Foundation

// MARK: - WatchThemeColors: the watch's palette, resolved as numbers

/// Every colour the Watch app draws, resolved to sRGB against the surface
/// the watch actually composites it on — the pure, testable half of
/// `WatchPalette` (`SentryWatch/Theme/WatchPalette.swift`), which is now a
/// thin `Color` wrapper around this.
///
/// **Why this type exists, and why it lives in `SentryKit/Watch/`.** It is
/// the exact move `ThemeControlColors` made for the Mac's switches: if the
/// renderer computes its own colours and the test computes different ones,
/// the test is decoration. `WatchPalette` is an app-target type that no
/// macOS-hosted test bundle can import, so until now the only proof that a
/// preset rendered legibly on the wrist was a screenshot — and
/// `WatchThemeFidelityTests` could only argue about `Theme`'s raw tokens,
/// not about the tinted fills the watch's own pills and buttons derive from
/// them. Putting the derivation here means `WatchControlContrastTests`
/// sweeps the bytes `StatusPill` and `WatchActionButtonStyle` draw, over
/// `Theme.builtInPresets`, without a simulator. This directory is compiled
/// whole into `SentryKit_watchOS` (see `project.yml`), so nothing had to be
/// added to that target's source list, and the file imports only Foundation.
///
/// **Two things are derived here rather than passed through, and both are
/// the watch's own compositions rather than the theme's.** Everything else
/// — text tiers, semantic tokens, the separator — is resolved verbatim, for
/// the reason `WatchPalette`'s doc comment gives: a token drawn on the
/// surface it was authored against is the theme's call, not this file's.
///
/// 1. **The canvas is flattened onto the appearance's assumed backdrop.**
///    A watchOS window is black under everything an app draws. A preset
///    whose `background` is translucent — System's is white at 85% — was
///    therefore being composited onto black on the wrist, which turned the
///    System theme's light canvas into a mid grey (`#D9D9D9`) while the
///    phone, whose window is white under a light theme, showed it as
///    white. That is the watch failing to match the app it belongs to, in
///    the one theme that ships as the default. The fix reuses the exact
///    assumption `ThemeContrastAudit` and `ThemeControlColors
///    .resolvedBackdrop` already make for a translucent page — white under
///    `.light`, black under `.dark` (`ThemeContrast.assumedBackdrop`) —
///    rather than inventing a second one. Rejected: leaving the black
///    window to show through, on the grounds that OLED black is "right"
///    for a watch. The user picked a light theme; the canvas colour is the
///    theme's to decide, and the theme's own alpha was authored against a
///    light page.
///
/// 2. **A control's label is held to a contrast floor against the
///    control's own fill.** `StatusPill` and `WatchActionButtonStyle` draw
///    a token as a translucent wash (`controlFillOpacity`) and then draw
///    the same token as the label on top of it. No theme authored "accent
///    on 18% accent"; the watch invented that pairing, so the watch is
///    responsible for it being readable — and on a light appearance it
///    often is not. System's `success` (`#34C759`) over its own wash on a
///    white card measures about 1.8:1, which is the "Live" pill on the
///    default theme being pale green on pale green; Ivory's `success` and
///    `warning` land in the 2.6–2.9 range on theirs. `control(_:)` seeds
///    the label with the token and pushes it away from the fill with
///    `ThemeContrast.legible` only as far as `controlLabelMinimumRatio`
///    requires, so a token that already clears the floor — every dark
///    half, all of One Dark — comes back untouched. Rejected:
///    lowering the wash opacity instead. The wash is not the problem; the
///    token itself is under 3:1 against a light card (Apple's green on
///    white is about 2:1 as plain text too), so no fill alpha fixes it.
///
///    Measured over `Theme.builtInPresets` (the table is what
///    `WatchControlContrastTests` grades): every dark half and the whole of
///    One Dark's light half clear 3:1 verbatim and are untouched; Ivory's
///    light `danger` and `textSecondary` do too. What moves is System's
///    light `accent`/`danger` (2.9 and 2.6 on a card) by a hair, System's
///    light `success`/`warning` (1.8 on a card) by a visible step, and
///    Ivory's light `accent`/`success`/`warning` (2.8, 2.7, 2.9) by a hair.
public struct WatchThemeColors: Equatable, Sendable {

    // MARK: Floors

    /// The opacity `StatusPill` and `WatchActionButtonStyle` draw a tint at
    /// for their fill. Named here rather than as two literals in
    /// `WatchCard.swift` because `control(_:)` has to model the exact fill
    /// the label is graded against, and a value that drifted between the
    /// renderer and the grader would make the grade meaningless.
    public static let controlFillOpacity: Double = 0.18

    /// WCAG 2.1 SC 1.4.11's 3:1 for user-interface components — the same
    /// number `ThemeControlColors.componentMinimumRatio` argues for on the
    /// Mac (that file is not compiled into `SentryKit_watchOS`, so the
    /// constant is restated rather than referenced). A pill's word and a
    /// button's label are the visual information that identifies the
    /// control, and at `.caption2` semibold on a wrist they are also large
    /// enough that 3:1 is the honest text floor as well. Not 4.5: that would
    /// force a near-black label onto every light preset's tinted button and
    /// make the theme's own accent unreachable for no gain the criterion
    /// asks for.
    public static let controlLabelMinimumRatio: Double = 3.0

    /// How far a control's wash must sit from the surface behind it to read
    /// as a fill at all. The same 1.10 `ThemedControlContrastTests` holds
    /// the Mac switch's off-track recess to — a floor on "is this a shape",
    /// not on legibility, which the label carries.
    public static let controlFillMinimumRatio: Double = 1.10

    // MARK: Resolved tokens

    public let appearance: ThemeAppearance

    /// The page colour, **opaque** — the theme's `background` flattened onto
    /// `ThemeContrast.assumedBackdrop(for:)` when it carries alpha. See the
    /// type doc comment for why this is the one token not passed through.
    public let canvas: ThemeColor.RGBA

    /// `surface` as authored (possibly translucent — System's is a 4% wash).
    /// Drawn over `canvas` by SwiftUI; `backdrop(.card)` is the composited
    /// result for grading.
    public let surface: ThemeColor.RGBA
    public let surfaceElevated: ThemeColor.RGBA
    public let separator: ThemeColor.RGBA

    public let textPrimary: ThemeColor.RGBA
    public let textSecondary: ThemeColor.RGBA
    public let textTertiary: ThemeColor.RGBA

    public let accent: ThemeColor.RGBA
    public let success: ThemeColor.RGBA
    public let warning: ThemeColor.RGBA
    public let danger: ThemeColor.RGBA

    /// Resolves one theme for one appearance, preferring the colours the
    /// phone relayed (`RelayedPalette`) over the theme's own tokens exactly
    /// as `WatchPalette` always has — the relayed hex is already the right
    /// half of the pair, and it is the only thing a custom theme can arrive
    /// as.
    ///
    /// A hex that does not parse resolves to a flat grey per token (dark or
    /// light depending on the appearance and the token's role): obviously
    /// wrong to the eye and never invisible, which is the correct failure
    /// for a malformed theme rather than a design decision.
    public init(theme: Theme, appearance: ThemeAppearance, relayed: RelayedPalette? = nil) {
        self.appearance = appearance
        let dark = appearance == .dark

        func resolve(_ token: ThemeColor, _ hex: String?, fallback: Double) -> ThemeColor.RGBA {
            hex.flatMap(ThemeColor.components(fromHex:))
                ?? token.rgba(for: appearance)
                ?? ThemeColor.RGBA(red: fallback, green: fallback, blue: fallback, alpha: 1)
        }

        let page = resolve(theme.background, relayed?.bg, fallback: dark ? 0.0 : 1.0)
        canvas = page.alpha < 0.999
            ? ThemeContrast.flatten(page, onto: ThemeContrast.assumedBackdrop(for: appearance))
            : page

        surface = resolve(theme.surface, relayed?.sf, fallback: dark ? 0.08 : 0.96)
        surfaceElevated = resolve(theme.surfaceElevated, relayed?.se, fallback: dark ? 0.14 : 0.92)
        separator = resolve(theme.separator, relayed?.sp, fallback: dark ? 0.2 : 0.85)
        textPrimary = resolve(theme.textPrimary, relayed?.t1, fallback: dark ? 0.9 : 0.1)
        textSecondary = resolve(theme.textSecondary, relayed?.t2, fallback: dark ? 0.6 : 0.4)
        textTertiary = resolve(theme.textTertiary, relayed?.t3, fallback: dark ? 0.4 : 0.6)
        accent = resolve(theme.accent, relayed?.ac, fallback: 0.5)
        success = resolve(theme.success, relayed?.ok, fallback: 0.5)
        warning = resolve(theme.warning, relayed?.wn, fallback: 0.5)
        danger = resolve(theme.danger, relayed?.dg, fallback: 0.5)
    }

    // MARK: Hosts

    /// The two surfaces a watch control is genuinely drawn on. Buttons sit
    /// on the canvas (`KeepAwakePage`, `AgentActivityPage`); status pills
    /// sit inside a `WatchCard` (`OverviewPage.StatusChips`) or on the canvas
    /// (`AgentActivityPage`'s header, `OverviewPage`'s demo chip). Both are
    /// graded, for the reason `ThemeControlColors.hostSurfaces` gives:
    /// grading one would pass a pill that is invisible on the other.
    public enum Host: CaseIterable, Sendable {
        case canvas
        case card
    }

    /// The opaque colour actually behind a control on `host`.
    public func backdrop(_ host: Host) -> ThemeColor.RGBA {
        switch host {
        case .canvas: return canvas
        case .card: return ThemeContrast.flatten(surface, onto: canvas)
        }
    }

    // MARK: Controls

    /// The tokens that are ever used as a control tint. `textSecondary` is a
    /// member because the freshness pill draws `.stale`/`.asleep` in it and
    /// the thermal chip draws "Normal" in it — a control, even when the state
    /// it names is the calm one.
    public enum Role: CaseIterable, Sendable {
        case accent, success, warning, danger, textSecondary
    }

    /// A tinted control's two colours: the token it is drawn from (the fill
    /// is this at `controlFillOpacity`, composited by SwiftUI over whichever
    /// host it lands on) and the label held to `controlLabelMinimumRatio`
    /// against that fill on **both** hosts.
    public struct Control: Equatable, Sendable {
        public let tint: ThemeColor.RGBA
        public let label: ThemeColor.RGBA
    }

    public func token(_ role: Role) -> ThemeColor.RGBA {
        switch role {
        case .accent: return accent
        case .success: return success
        case .warning: return warning
        case .danger: return danger
        case .textSecondary: return textSecondary
        }
    }

    /// The wash a `role` control draws on `host`, composited exactly as
    /// SwiftUI composites `Color(token).opacity(controlFillOpacity)` over
    /// the host — a translucent token is flattened onto the host first,
    /// which is algebraically what stacking two alphas does.
    public func controlFill(_ role: Role, on host: Host) -> ThemeColor.RGBA {
        let backdrop = backdrop(host)
        var wash = ThemeContrast.flatten(token(role), onto: backdrop)
        wash.alpha = Self.controlFillOpacity
        return ThemeContrast.flatten(wash, onto: backdrop)
    }

    /// See the type doc comment, point 2. `legible` only ever moves a colour
    /// *away* from its backdrop, and both hosts sit on the same side of the
    /// label under one appearance, so repairing against the card and then
    /// against the canvas leaves the first guarantee intact — the second
    /// pass is a no-op whenever the first already cleared it.
    public func control(_ role: Role) -> Control {
        let tint = token(role)
        var label = ThemeContrast.flatten(tint, onto: backdrop(.card))
        for host in Host.allCases {
            label = ThemeContrast.legible(
                label,
                onto: controlFill(role, on: host),
                toRatioAtLeast: Self.controlLabelMinimumRatio
            )
        }
        return Control(tint: tint, label: label)
    }
}
