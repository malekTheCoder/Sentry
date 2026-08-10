import SwiftUI
import SentryKit

// MARK: - ThemedToggleStyle

/// The switch every `Toggle` in the Mac app wears, drawn entirely from
/// `ThemePalette` instead of from AppKit's system colours.
///
/// **The bug this replaces.** AppKit's stock switch paints its off track in a
/// fixed system grey that was chosen against AppKit's own window background.
/// `.tint(_:)` — which one call site in the whole product bothered to apply —
/// only ever touches the *on* track, so the off state was never themed at all.
/// On Ivory (`background #FAF9F5`, `surface #F0EEE6`) that grey lands within
/// a couple of percent of the row behind it and the control is simply not
/// there. The screenshot that opened this was the Keep Awake row: an off
/// switch invisible against its own card.
///
/// **Why a custom style rather than 41 `.tint` calls.** `.tint` cannot fix
/// this — it does not address the off state, which is the broken one. And a
/// per-call-site fix is a fix with an expiry date: the next `Toggle` anyone
/// adds is unthemed again. This style is applied once at each view-tree root
/// (`DropdownView`, `SettingsView`, the theme-editor sheet, `WalkthroughView`)
/// and inherited by every switch beneath, so new call sites are correct by
/// default and `AIAccessPane` — which this branch is forbidden to edit — is
/// fixed without being touched.
///
/// **All colour decisions live in `ThemeControlColors`, not here.** This type
/// is deliberately only geometry, animation and state. The contrast maths sits
/// in `SentryKit` so `ThemedControlContrastTests` can sweep every preset
/// without a host app and so the numbers the test asserts are the exact bytes
/// this view fills with. See that type for the 3:1 floor, the outlined-off /
/// filled-on model, and how material themes are flattened.
struct ThemedToggleStyle: ToggleStyle {

    /// Which surface the switch is being drawn on. The caller knows and the
    /// style cannot infer it — a `Form` row paints on `surface`, a dropdown
    /// card on `surfaceElevated`, the dropdown's bare rows on `background` —
    /// and grading against the wrong one is how you ship a switch that passes
    /// its test and vanishes on screen.
    var surface: ThemeColorToken = .surface

    func makeBody(configuration: Configuration) -> some View {
        ThemedToggle(configuration: configuration, surface: surface)
    }
}

/// The style's body as a real `View`, which is what lets it read
/// `@Environment`. `ToggleStyle.makeBody` is not a view context, so a style
/// that wants the palette (or `isEnabled`, or Reduce Motion) has to hand off
/// to a nested view — this is the standard shape, not a workaround.
private struct ThemedToggle: View {

    let configuration: ToggleStyle.Configuration
    let surface: ThemeColorToken

    @Environment(\.themePalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Geometry
    //
    // Fixed points rather than scaling off `palette.spacing`. Density is a
    // property of *layout* — how much air sits between rows — and a switch
    // that changed size with it would change the row height of every grouped
    // form, which is a much larger blast radius than this fix has any business
    // having. The numbers track AppKit's own small switch closely enough that
    // replacing the stock control does not reflow anything.

    private let trackWidth: CGFloat = 30
    private let trackHeight: CGFloat = 18
    private let borderWidth: CGFloat = 1
    private var knobDiameter: CGFloat { trackHeight - 6 }
    private var knobTravel: CGFloat { (trackWidth - knobDiameter) / 2 - 3 }

    var body: some View {
        // `Toggle("", …)` at several call sites means an empty label, and an
        // empty `Text` still takes part in layout — `HStack` + `Spacer` gives
        // the same label-left/control-right shape a grouped `Form` produces
        // for the stock style, so no call site reflows.
        HStack {
            configuration.label
            Spacer(minLength: 0)
            switchBody(isOn: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        // The switch is the control; the row is just a bigger hit target for
        // it. Without this the custom style loses the stock control's
        // accessibility traits entirely.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }

    @ViewBuilder
    private func switchBody(isOn: Bool) -> some View {
        let track = Capsule(style: .continuous)

        ZStack {
            track
                .fill(fill(isOn ? colors?.onTrack : colors?.offTrack))
                .overlay(
                    track.strokeBorder(
                        fill(isOn ? colors?.onBorder : colors?.offBorder),
                        lineWidth: borderWidth
                    )
                )

            Circle()
                .fill(fill(isOn ? colors?.onKnob : colors?.offKnob))
                .frame(width: knobDiameter, height: knobDiameter)
                .offset(x: isOn ? knobTravel : -knobTravel)
        }
        .frame(width: trackWidth, height: trackHeight)
        .animation(ThemePalette.motion(reduceMotion: reduceMotion), value: isOn)
    }

    /// Resolved once per render. `nil` only when the theme's backdrop token
    /// cannot be parsed, which `ThemeControlColors.init?` treats as the one
    /// case it refuses to invent a number for.
    private var colors: ThemeControlColors? {
        ThemeControlColors(
            theme: palette.theme,
            appearance: palette.scheme.themeAppearance,
            backdrop: surface,
            isEnabled: isEnabled
        )
    }

    /// A resolved component as a `Color`, falling back to the palette's own
    /// secondary text when the theme is too malformed to derive one. Same P5
    /// reasoning as `ThemeColor.color(for:)`: visibly wrong beats invisible.
    private func fill(_ rgba: ThemeColor.RGBA?) -> Color {
        guard let rgba else { return palette.textSecondary }
        return Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

// MARK: - Application

extension View {
    /// Applies `ThemedToggleStyle` to everything beneath, graded against the
    /// surface those switches actually sit on.
    ///
    /// Applied at view-tree roots rather than at call sites — see
    /// `ThemedToggleStyle`'s doc comment. `.toggleStyle` propagates through the
    /// environment, so it survives `Form`, `Section`, `Group`, `AnyView` and
    /// the `switch`-based pane dispatch in `SettingsView`; it does **not**
    /// cross into a `.sheet` or an `NSPopover`, both of which start a fresh
    /// environment, which is why the theme editor's sheet and the onboarding
    /// walkthrough get their own application.
    func themedToggles(on surface: ThemeColorToken = .surface) -> some View {
        toggleStyle(ThemedToggleStyle(surface: surface))
    }
}
