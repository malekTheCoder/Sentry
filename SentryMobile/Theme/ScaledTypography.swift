import SwiftUI
import SentryKit

// MARK: - Dynamic Type for the iPhone app

/// The iPhone app's typography entry point.
///
/// **The problem this file solves.** Every text call site in this app was
/// written as `.font(palette.font(size: 13, weight: .semibold))`.
/// `ThemePalette.font(size:weight:)` (`ThemeColor+SwiftUI.swift`) resolves to
/// `Font.system(size:weight:design:)` or `Font.custom(_:size:)` — both of
/// which are *fixed size*. They ignore the user's Dynamic Type setting
/// completely, so someone who has turned text up to an accessibility size got
/// no change at all anywhere in this app. That is an accessibility failure and
/// a plausible App Store review rejection, not a cosmetic issue.
///
/// **Which platform uses which API, and why.**
///
/// - **iPhone (`SentryMobile`) — use the scaled API in this file.** Phone text
///   is read at arm's length by whoever installed the app, including people
///   who need 300% text. Every call site here scales.
/// - **Mac app (`Sentry`) — keeps the fixed `palette.font(size:)` API.** Two
///   reasons, and both are about *glyph metrics*, not preference. The menu bar
///   item is drawn into an `NSStatusItem` whose height is fixed by the system
///   menu bar (22pt); text that grew past it would be clipped by AppKit, not
///   reflowed, and the theme's own `barFontSize` token
///   (`SentryKit/Settings/Theme.swift`) exists precisely so a user tunes that
///   number directly. macOS also has no Dynamic Type: there is no system
///   control equivalent to iOS's text-size slider for a menu-bar app to
///   respond to, so "scaling" there would mean scaling against a setting that
///   doesn't exist.
/// - **Watch (`SentryWatch`) — keeps its existing hand-tuned layout.** watchOS
///   *does* have Dynamic Type, and those pages already handle it deliberately
///   and specifically: `OverviewPage` swaps its dials for a list at
///   accessibility sizes and sizes them with `@ScaledMetric`, `KeepAwakePage`
///   branches on `dynamicTypeSize.isAccessibilitySize` with a written
///   rationale. Those layouts are far tighter than a phone's and were tuned
///   against a 41mm screen; running them through this file's generic mapping
///   would undo per-page decisions that are better than a generic rule.
/// - **Widgets (`SentryWidget`, `SentryWatchWidget`) — unchanged.** A widget
///   is drawn into a fixed system-provided rectangle it cannot grow past.
///
/// **Why a `ViewModifier` and not a `Font`-returning function.** The only
/// SwiftUI primitive that scales an *arbitrary* point size against a text
/// style is `@ScaledMetric`, and a property wrapper needs a view to live in.
/// (`Font.custom(_:size:relativeTo:)` does the same job but only for
/// PostScript-named fonts — it has no `Font.system` equivalent, and three of
/// this app's four `FontChoice` cases are system fonts.) So the scaled size is
/// computed in a modifier and the theme's font is built from it, which also
/// means the theme's family and weight survive scaling untouched.

// MARK: - TextStyleToken bridge

extension TextStyleToken {
    /// The SwiftUI case this token names. Lives here rather than in
    /// `SentryKit` for the reason the token's own doc comment gives: the model
    /// layer stays Foundation-only, and this is the rendering boundary.
    var swiftUI: Font.TextStyle {
        switch self {
        case .caption2: return .caption2
        case .caption: return .caption
        case .footnote: return .footnote
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .body: return .body
        case .title3: return .title3
        case .title2: return .title2
        case .title: return .title
        case .largeTitle: return .largeTitle
        }
    }
}

// MARK: - The modifier

/// Scales `baseSize` against a text style and hands the result to a font
/// builder. `@ScaledMetric` re-evaluates whenever the environment's
/// `dynamicTypeSize` changes, so the font tracks the setting live — including
/// the simulator's `xcrun simctl ui <udid> content-size …` changes, which
/// arrive as an environment update rather than a relaunch.
private struct ScaledFontModifier: ViewModifier {
    @ScaledMetric private var scaledSize: CGFloat
    private let makeFont: (CGFloat) -> Font

    init(baseSize: CGFloat, textStyle: Font.TextStyle, makeFont: @escaping (CGFloat) -> Font) {
        _scaledSize = ScaledMetric(wrappedValue: baseSize, relativeTo: textStyle)
        self.makeFont = makeFont
    }

    func body(content: Content) -> some View {
        content.font(makeFont(scaledSize))
    }
}

extension View {
    /// Dynamic-Type-aware replacement for `.font(palette.font(size:weight:))`.
    ///
    /// - Parameters:
    ///   - palette: supplies the theme's font family, so a user-chosen theme's
    ///     typeface survives scaling.
    ///   - size: the design's point size at the *default* content size — the
    ///     same literal the fixed API took, so migrating a call site is a
    ///     rename, not a redesign.
    ///   - relativeTo: overrides the automatic anchor from
    ///     `TypeScale.textStyle(forSize:)`. Pass this only when a call site
    ///     genuinely wants a different growth curve than its point size
    ///     implies (e.g. a section header that is small by design but should
    ///     grow like body text), and say why at the call site.
    ///   - monospacedDigit: bakes tabular figures into the resolved `Font`
    ///     rather than relying on a trailing `.monospacedDigit()` view
    ///     modifier. This app's numeric readouts depend on digit alignment
    ///     (the vitals ledger's right-aligned column, the battery percentage),
    ///     and folding it into the font makes it survive scaling by
    ///     construction instead of by modifier-ordering luck.
    func scaledFont(
        _ palette: ThemePalette,
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle? = nil,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(
            ScaledFontModifier(
                baseSize: size,
                textStyle: textStyle ?? TypeScale.textStyle(forSize: size).swiftUI
            ) { scaled in
                let font = palette.font(size: scaled, weight: weight)
                return monospacedDigit ? font.monospacedDigit() : font
            }
        )
    }

    /// Dynamic-Type-aware replacement for `.font(.system(size:weight:design:))`
    /// — the call sites that deliberately bypass the theme's family: SF Symbol
    /// glyphs sized to sit beside a specific line of text, and the numeric
    /// readouts the redesign spec pins to true SF Mono (`design: .monospaced`)
    /// rather than the theme's chosen face.
    ///
    /// Glyphs are scaled too, on purpose: an icon paired with text that grew
    /// and didn't grow itself reads as a rendering bug, and every use of this
    /// in the app is a decorative symbol next to a label, never a fixed-size
    /// piece of chrome.
    func scaledSystemFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle? = nil,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(
            ScaledFontModifier(
                baseSize: size,
                textStyle: textStyle ?? TypeScale.textStyle(forSize: size).swiftUI
            ) { scaled in
                let font = Font.system(size: scaled, weight: weight, design: design)
                return monospacedDigit ? font.monospacedDigit() : font
            }
        )
    }
}

// MARK: - Layouts that have to change shape, not just size

/// A plain run of sibling views laid out horizontally, becoming vertical at
/// accessibility text sizes.
///
/// The no-`Spacer` counterpart to `AdaptiveRow` below, for groups whose
/// members are all the same kind of thing — a row of buttons, a legend —
/// rather than a leading/trailing pair.
struct AdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: spacing, content: content)
        } else {
            HStack(spacing: spacing, content: content)
        }
    }
}

/// A label/value row that becomes a two-line stack at accessibility text
/// sizes.
///
/// **Why a shape change and not just smaller text.** The horizontal
/// `label … value` idiom is used all over this app (battery detail rows, the
/// per-metric browser). It works because the
/// label and the value each need a fraction of the width. At an accessibility
/// size both roughly triple, the `Spacer` collapses, and the two sides start
/// fighting: SwiftUI resolves that by truncating one of them, which on a
/// metrics app means a number the user cannot read — the precise failure the
/// setting was turned up to avoid. Stacking removes the competition entirely;
/// vertical space is the one resource a `ScrollView` has in abundance.
///
/// **Why `dynamicTypeSize.isAccessibilitySize` and not `ViewThatFits`.**
/// `ViewThatFits` cannot measure this case: an `HStack` containing a `Spacer`
/// reports a tiny ideal width and therefore always "fits," so the horizontal
/// candidate would win at every size. The explicit branch is also the pattern
/// this codebase already uses for exactly this problem — see
/// `SentryWatch/Pages/KeepAwakePage.swift`'s `dynamicTypeSize` branch and its
/// doc comment.
struct AdaptiveRow<Leading: View, Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Minimum gap between the two sides in the horizontal layout, and the
    /// gap between the two lines in the stacked one.
    var spacing: CGFloat = 8
    var verticalAlignment: VerticalAlignment = .firstTextBaseline
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: spacing * 0.5) {
                leading()
                trailing()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: verticalAlignment, spacing: 0) {
                leading()
                Spacer(minLength: spacing)
                trailing()
            }
        }
    }
}
