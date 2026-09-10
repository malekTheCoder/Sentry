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
    static let sectionSpacing: CGFloat = 2

    /// Inner padding of a `WatchCard`.
    static let cardPadding: CGFloat = 5

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
/// Used for the freshness badge, the thermal state, the demo disclosure and
/// every conditional warning. Filled rather than the bare `Label` these used
/// to be, because on black a coloured word alone reads as text that happens
/// to be coloured; a tinted capsule reads as a *state*, which is what these
/// are. The fill is the tint at low opacity so it stays legible on the
/// theme's own canvas without becoming a second competing surface.
///
/// **Takes a `WatchControlTint`, not a `Color`.** The word is drawn in
/// `tint.label`, which `WatchPalette.control(_:)` has already held to 3:1
/// against the wash this view lays down — on a light preset the raw token
/// frequently is not (System's green over its own wash measured 1.8:1; see
/// `WatchThemeColors`). Taking the graded pair rather than a bare colour is
/// what makes it impossible to draw an ungraded one here.
///
/// The "prominent" variant this used to offer — a solid capsule with black
/// text — is gone: nothing called it, and black text on an arbitrary theme
/// token is exactly the ungraded pairing the rest of this change removes.
struct StatusPill: View {
    let text: String
    let symbol: String
    let tint: WatchControlTint

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
        .foregroundStyle(tint.label)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(tint.fill.opacity(WatchThemeColors.controlFillOpacity))
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
/// matching label — so a `.danger` button is unmistakably the red one and a
/// `.accent` button is unmistakably the theme's. `isPressed` deepens the
/// fill rather than dimming the whole control: on an OLED panel read
/// outdoors, a brightness change is far easier to perceive than the opacity
/// fade the system style uses.
///
/// Takes a `WatchControlTint` for the reason `StatusPill` does: the label is
/// the graded colour, the fill is the token. The pressed fill is denser than
/// the resting one and therefore *closer* to the label's own hue, so the
/// label's ratio dips while a finger is on the button; that is the one
/// state the sweep does not grade, deliberately — it lasts as long as the
/// press, and the affordance during a press is the brightness change itself.
struct WatchActionButtonStyle: ButtonStyle {
    let tint: WatchControlTint

    /// Corner radius matched to `WatchCard` so a button sitting under a card
    /// reads as part of the same family rather than as a system control that
    /// wandered in.
    private var cornerRadius: CGFloat { WatchLayout.cardCornerRadius }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.medium))
            .foregroundStyle(tint.label)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint.fill.opacity(configuration.isPressed ? 0.34 : WatchThemeColors.controlFillOpacity))
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

// MARK: - FreshnessPill

/// How old the reading is, as a `StatusPill` rather than the bare
/// icon-and-label `FreshnessBadge` renders.
///
/// **Why the watch has its own instead of using `FreshnessBadge`.** That view
/// is shared with the Mac and phone, where it sits inline in a header and a
/// plain tinted label is right. On this screen it now sits in the status row
/// beside the thermal chip, where a bare label would read as the odd one out —
/// two adjacent readouts saying the same *kind* of thing should look like the
/// same kind of thing. It also has to be able to drop its text and survive as
/// a glyph when three warnings are already competing for the row, which
/// `FreshnessBadge` has no way to express.
///
/// **What is deliberately copied rather than reinvented.** The tiers, the
/// labels, the dot-versus-moon glyph split and the refresh cadence all come
/// straight from `Freshness`/`FreshnessBadge` — this is a restyling, not a
/// second opinion about when a reading is stale. The one substitution is
/// colour: plan §12.2's green/amber/gray becomes the theme's
/// `success`/`warning`/`textSecondary`, so a user on Ivory gets Ivory's green
/// rather than the system's, matching every other colour on these pages.
///
/// `TimelineView(.periodic)` is what keeps "Live" from lying: a watch app left
/// open with no new relay arriving must not keep claiming the reading is
/// current, and this is the page's one element that must never do that.
struct FreshnessPill: View {
    @Environment(\.palette) private var palette

    let lastSeen: Date

    /// Glyph-only when false — see `StatusPill.showsText`.
    var showsText: Bool = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: FreshnessBadge.defaultRefreshInterval)) { context in
            pill(now: context.date)
        }
    }

    private func pill(now: Date) -> some View {
        let freshness = Freshness(lastSeen: lastSeen, now: now)
        return StatusPill(
            text: freshness.label(lastSeen: lastSeen, now: now),
            symbol: freshness.symbolName,
            tint: tint(for: freshness),
            showsText: showsText
        )
    }

    /// Plan §12.2's assignment, resolved through the theme. `.asleep` shares
    /// `.stale`'s tone deliberately: the plan gives it no colour of its own
    /// because the moon glyph is what marks it as categorically different,
    /// and inventing a fifth colour here would be this file overruling that.
    private func tint(for freshness: Freshness) -> WatchControlTint {
        switch freshness {
        case .live: return palette.control(.success)
        case .recent: return palette.control(.warning)
        case .stale, .asleep: return palette.control(.textSecondary)
        }
    }
}
