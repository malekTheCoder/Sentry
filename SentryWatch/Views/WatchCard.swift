import SentryKit
import SwiftUI

// MARK: - WatchLayout: the numbers every page shares

/// The spacing constants the three pages are built from.
///
/// **Why these are constants in one place rather than literals at each use
/// site.** The bug this redesign exists to fix was not any single wrong
/// number — it was that every page picked its own, so nothing lined up and
/// each page independently discovered (or failed to discover) that content
/// runs off the right edge and disappears under the paging dots. One table
/// means a margin change is one edit and applies to all three pages at once.
enum WatchLayout {
    /// Horizontal inset from the display edge, applied by the shell.
    ///
    /// 10, up from the 4 this shipped with. Four points was measured against
    /// the *bezel* and is enough to clear it — but a watch display is a
    /// rounded rectangle whose corner radius eats into the top and bottom of
    /// every line of text near the edge, and the old value put the device
    /// name hard against that curve, where the simulator rendered it visibly
    /// clipped. Ten clears the curve at every supported size and is what
    /// makes the page read as laid out rather than as overflowing.
    static let horizontalMargin: CGFloat = 10

    /// Gap between the stacked sections of a page.
    static let sectionSpacing: CGFloat = 4

    /// Inner padding of a `WatchCard`.
    static let cardPadding: CGFloat = 6

    /// Corner radius for cards. Deliberately generous — it echoes the
    /// display's own corner curve, which is the single strongest visual cue
    /// that a watch app was designed for a watch rather than shrunk onto one.
    static let cardCornerRadius: CGFloat = 14

    /// Room reserved below the last element of every scrolling page.
    ///
    /// **This is the fix for the "cut off" complaint, and it is bigger than
    /// it looks like it should be.** `TabView`'s `.page` style draws its dot
    /// indicator *over* the bottom of each page rather than reserving space
    /// above it, so whatever a page puts last is the thing the dots sit on.
    /// The old 18 was not enough at 42mm: the Agent Activity page's tool list
    /// ran straight under the dots, and Overview's status chips — including
    /// "Memory critical", the most alarming thing the app can say — were
    /// clipped. Applied through `safeAreaInset` by the shell so a page cannot
    /// forget it.
    static let pagingIndicatorClearance: CGFloat = 8
}

// MARK: - WatchCard

/// The one container every grouped thing on this app's pages sits in.
///
/// **Why the redesign introduced cards at all.** The previous version drew
/// every element straight onto black with nothing but font size and vertical
/// gaps to separate them, which made all three pages read as one
/// undifferentiated left-aligned column — closer to a Settings screen than to
/// a watch app, and the specific reason a glance could not tell where one
/// fact ended and the next began. A filled, rounded surface is how watchOS
/// itself groups content, it gives the theme's `surface` token something to
/// actually colour, and — the practical part — it gives every page a shared
/// left and right edge, so nothing can quietly sit two points further out
/// than its neighbour.
struct WatchCard<Content: View>: View {
    @Environment(\.palette) private var palette

    /// Cards default to filling the page's width so a column of them shares
    /// one edge. A caller that wants to hug its content (a chip, say) opts
    /// out.
    var fillsWidth: Bool = true

    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(WatchLayout.cardPadding)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: WatchLayout.cardCornerRadius, style: .continuous)
                    .fill(palette.surface)
            )
    }
}

// MARK: - StatusPill

/// A small filled capsule: a glyph, a word, and a tint.
///
/// Used for the freshness badge, the thermal state, and every conditional
/// warning. Filled rather than the bare `Label` these used to be, because on
/// black a coloured word alone reads as text that happens to be coloured; a
/// tinted capsule reads as a *state*, which is what these are. The fill is
/// the tint at low opacity so it stays legible on the theme's own canvas
/// without becoming a second competing surface.
struct StatusPill: View {
    let text: String
    let symbol: String
    let tint: Color

    /// Draws the tint as a solid capsule with dark text instead of the
    /// default tinted-wash treatment. Reserved for the one pill per screen
    /// that has to be seen first.
    var isProminent: Bool = false

    /// Glyph-only when false. The caller that uses this
    /// (`OverviewPage.StatusChips`) does so to keep three simultaneous
    /// warnings on one row at 42mm rather than wrapping them below the fold —
    /// `text` is still passed and still spoken, so nothing is lost to
    /// VoiceOver and the tint plus symbol still distinguish the states.
    var showsText: Bool = true

    var body: some View {
        Label {
            if showsText { Text(text) }
        } icon: {
            Image(systemName: symbol)
        }
        .font(.system(.caption2, design: .rounded).weight(.semibold))
        .foregroundStyle(isProminent ? AnyShapeStyle(.black) : AnyShapeStyle(tint))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(isProminent ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.18)))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

// MARK: - WatchActionButtonStyle

/// Every tappable control in this app.
///
/// **Why a custom style rather than `.buttonStyle(.bordered).tint(...)`.**
/// `.bordered` derives its fill from the *system* accent colour with a fixed
/// wash on top, and `.tint` only shifts that wash — so the buttons stayed
/// visibly system-grey whatever theme was relayed, which was half of the
/// "doesn't match the themes" complaint. It also gave the destructive control
/// on the Keep Awake page and the constructive ones directly above it nearly
/// identical weight, which is the wrong emphasis for a page where one of them
/// stops something.
///
/// This style takes the tint explicitly and renders it as a tinted fill with
/// matching label — so a `palette.danger` button is unmistakably the red one
/// and a `palette.accent` button is unmistakably the theme's. `isPressed`
/// deepens the fill rather than dimming the whole control: on an OLED panel
/// read outdoors, a brightness change is far easier to perceive than the
/// opacity fade the system style uses.
struct WatchActionButtonStyle: ButtonStyle {
    let tint: Color

    /// Corner radius matched to `WatchCard` so a button sitting under a card
    /// reads as part of the same family rather than as a system control that
    /// wandered in.
    private var cornerRadius: CGFloat { WatchLayout.cardCornerRadius }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.34 : 0.18))
            )
    }
}

// MARK: - SectionHeading

/// The small all-caps label above a group.
///
/// Uppercased and tracked out rather than merely bold: at `.caption2` on a
/// watch, weight alone is not enough to read as a heading rather than as more
/// data, and this is the one typographic device on these pages that says
/// "what follows is a category, not a value."
struct SectionHeading: View {
    @Environment(\.palette) private var palette

    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(palette.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityAddTraits(.isHeader)
    }
}
