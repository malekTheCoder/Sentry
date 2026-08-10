import SwiftUI
import SentryKit

// MARK: - ThemedToggleStyle (iOS)

/// The phone's half of the themed switch. All of the reasoning — why the off
/// state is outlined rather than filled, why the floor is 3:1, how material
/// themes are flattened — lives on `SentryKit.ThemeControlColors` and on the
/// Mac's `Sentry/App/ThemedToggleStyle.swift`; this file is deliberately only
/// the iOS rendering of the same resolved bytes and does not restate it.
///
/// **Why this is duplicated rather than shared.** `ThemePalette` itself is
/// already duplicated per platform (`Sentry/Dropdown/ThemeColor+SwiftUI.swift`
/// and `SentryMobile/Theme/ThemeColor+SwiftUI.swift`) because the two targets
/// share no view-layer module — only `SentryKit`. The part worth sharing is
/// the colour derivation, and that *is* shared: both platforms call the same
/// `ThemeControlColors`, so the same sweep test covers both. What is copied
/// here is sixty lines of geometry, which is the cheaper duplication than
/// inventing a cross-platform view module for one control.
///
/// **Scope on iOS is one switch**, `AlertsTabView`'s rule row — a permanently
/// `.disabled(true)` mirror of the Mac's state. That happens to be the exact
/// worst case the disabled floor exists for: off, disabled, and on a light
/// preset, which under UIKit's stock treatment is a washed-out grey capsule on
/// a near-identical warm surface.
struct ThemedToggleStyle: ToggleStyle {

    var surface: ThemeColorToken = .surface

    func makeBody(configuration: Configuration) -> some View {
        ThemedToggle(configuration: configuration, surface: surface)
    }
}

private struct ThemedToggle: View {

    let configuration: ToggleStyle.Configuration
    let surface: ThemeColorToken

    @Environment(\.themePalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Slightly larger than the Mac's 30×18: a touch target is not a pointer
    // target, and this still sits inside the 44pt row the rule list gives it.
    private let trackWidth: CGFloat = 38
    private let trackHeight: CGFloat = 23
    private var knobDiameter: CGFloat { trackHeight - 7 }
    private var knobTravel: CGFloat { (trackWidth - knobDiameter) / 2 - 3.5 }

    var body: some View {
        HStack {
            configuration.label
            Spacer(minLength: 0)
            switchBody(isOn: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
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
                .overlay(track.strokeBorder(fill(isOn ? colors?.onBorder : colors?.offBorder), lineWidth: 1))
            Circle()
                .fill(fill(isOn ? colors?.onKnob : colors?.offKnob))
                .frame(width: knobDiameter, height: knobDiameter)
                .offset(x: isOn ? knobTravel : -knobTravel)
        }
        .frame(width: trackWidth, height: trackHeight)
        .animation(ThemePalette.motion(reduceMotion: reduceMotion), value: isOn)
    }

    private var colors: ThemeControlColors? {
        ThemeControlColors(
            theme: palette.theme,
            appearance: palette.scheme.themeAppearance,
            backdrop: surface,
            isEnabled: isEnabled
        )
    }

    private func fill(_ rgba: ThemeColor.RGBA?) -> Color {
        guard let rgba else { return palette.textSecondary }
        return Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

extension View {
    func themedToggles(on surface: ThemeColorToken = .surface) -> some View {
        toggleStyle(ThemedToggleStyle(surface: surface))
    }
}
