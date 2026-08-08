import SwiftUI
import SentryKit

// MARK: - The app-level demo-data banner

/// The strip pinned above every tab while this app is rendering
/// `MockDataSource`'s invented readings.
///
/// **Why this is one view at the app shell and not four per-tab banners.**
/// The app already tried the per-tab arrangement and it failed in the
/// predictable way: Dashboard had a 12pt sentence, History had a
/// differently-worded card, and Alerts and Settings had nothing at all — two
/// entire tabs of fabricated numbers with no disclosure on them anywhere. Any
/// scheme where four files each remember to disclose the same fact is a
/// scheme where the fifth tab someone adds next month does not. Mounted once
/// in `RootTabView` via `.safeAreaInset(edge: .top)`, it covers every tab
/// that exists and every tab that ever will, and there is exactly one wording
/// to keep honest. (The words themselves live one layer further out still, in
/// `SentryKit`'s `DemoDataDisclosure` — see that type for why.)
///
/// **Why `safeAreaInset` and not an overlay, a `ZStack`, or a sheet.** The
/// requirement is that this cannot scroll away, and `safeAreaInset` is the
/// only one of those that both pins the strip *and* tells every tab's
/// `ScrollView` to inset its content so nothing is permanently hidden
/// underneath it. An overlay would pin the banner and silently cover the top
/// of four scroll views; a `ZStack` would do the same with worse ergonomics.
/// A sheet or an alert was rejected outright: both are dismissable to
/// nothing, and both are gone the moment a reviewer takes a screenshot.
///
/// **Why the strip is opaque.** `ScrollView` content scrolls *under* a safe
/// area inset rather than stopping at it, so a translucent banner would have
/// the tab's own numbers sliding through the sentence that says those numbers
/// are fake. The theme's `background` goes behind the warning tint for that
/// reason, not for looks.
///
/// **Colour is never the signal.** §9.4's standing rule in this codebase —
/// applied here for the specific reason that a reviewer's first pass over
/// this app is a scan of four screenshots. The glyph, the words, and
/// `palette.warning` all carry the same state, so the disclosure survives
/// greyscale, colour-blindness, a thumbnail, and a black-and-white printout
/// of a review report.
struct DemoDataBanner: View {

    let prominence: DemoDataDisclosure.Prominence

    /// Quiets the full banner to the permanent marker. Not a dismissal —
    /// see `RootTabView.isDemoBannerQuieted`.
    let onQuiet: () -> Void

    /// Restores the full banner from the marker. The marker is the tap
    /// target for this, so the quieting is never a one-way door within a
    /// session either.
    let onExpand: () -> Void

    let onRetry: () -> Void

    /// Opens the walkthrough, whose pairing step carries the live connection
    /// card and the QR-pairing explanation.
    let onSetUp: () -> Void

    @Environment(\.themePalette) private var palette

    var body: some View {
        switch prominence {
        case .hidden:
            EmptyView()
        case .full:
            full
        case .marker:
            marker
        }
    }

    // MARK: Full

    private var full: some View {
        VStack(alignment: .leading, spacing: palette.spacingRow) {
            HStack(alignment: .top, spacing: palette.spacingRow) {
                Image(systemName: DemoDataDisclosure.symbolName)
                    .scaledSystemFont(size: 15, weight: .semibold)
                    .foregroundStyle(palette.warning)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(DemoDataDisclosure.headline)
                        .scaledFont(palette, size: 13, weight: .semibold)
                        .foregroundStyle(palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(DemoDataDisclosure.cause)
                        .scaledFont(palette, size: 11.5)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(DemoDataDisclosure.remedy)
                        .scaledFont(palette, size: 11.5)
                        .foregroundStyle(palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // One element, one announcement, all three sentences — rather
            // than three separate VoiceOver stops for what is one statement.
            // The buttons below stay individually reachable because they are
            // outside this element, not inside a `children: .ignore`.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(DemoDataDisclosure.accessibilityLabel(for: .full))
            .accessibilityAddTraits(.isHeader)

            // Becomes a vertical run at accessibility text sizes: three
            // labels that each roughly triple in width cannot share a row,
            // and SwiftUI's answer to that is truncation — on the one control
            // that fixes the situation the banner is describing.
            AdaptiveStack(spacing: palette.spacingBlock) {
                action(DemoDataDisclosure.retryActionLabel, action: onRetry)
                    .accessibilityHint("Looks again for a Mac running Sentry on this Wi-Fi network, then tries any saved remote Mac.")
                action(DemoDataDisclosure.setUpActionLabel, action: onSetUp)
                    .accessibilityHint("Opens the walkthrough, which explains what to install on your Mac and how to pair it with this iPhone.")
                action(DemoDataDisclosure.quietActionLabel, prominent: false, action: onQuiet)
                    .accessibilityHint("Shrinks this notice to a small sample tag. The tag stays on screen, and the full notice returns the next time you open Sentry.")
            }
        }
        .padding(.horizontal, palette.spacingPage)
        .padding(.vertical, palette.spacingBlock)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(BannerChrome(palette: palette))
    }

    private func action(_ title: String, prominent: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .scaledFont(palette, size: 12.5, weight: prominent ? .semibold : .regular)
                .foregroundStyle(prominent ? palette.accent : palette.textTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Marker

    /// What quieting leaves behind. Same position, same warning colour, same
    /// glyph, still un-scrollable — one line instead of four. A user who has
    /// read the explanation is not made to re-read it on every tab switch;
    /// a screenshot of any tab still carries the word "SAMPLE" in the top
    /// bar, which is the property that actually has to hold.
    private var marker: some View {
        Button(action: onExpand) {
            HStack(spacing: palette.spacingTight) {
                Image(systemName: DemoDataDisclosure.symbolName)
                    .scaledSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(palette.warning)
                    .accessibilityHidden(true)
                Text(DemoDataDisclosure.headline)
                    .scaledFont(palette, size: 11.5, weight: .semibold)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .scaledSystemFont(size: 9, weight: .semibold)
                    .foregroundStyle(palette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, palette.spacingPage)
            .padding(.vertical, palette.spacingTight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(BannerChrome(palette: palette))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DemoDataDisclosure.accessibilityLabel(for: .marker))
        .accessibilityHint("Double-tap to show the full explanation and the reconnect options again.")
    }
}

// MARK: - Shared chrome

/// Both prominences wear the same skin so the quieted form reads as the same
/// object shrunk, not a different notice: warning wash over an opaque theme
/// background (see `DemoDataBanner`'s doc comment on why opacity here is
/// load-bearing), with a warning hairline along the bottom edge to separate
/// it from whatever tab is scrolling underneath.
private struct BannerChrome: ViewModifier {
    let palette: ThemePalette

    func body(content: Content) -> some View {
        content
            .background(palette.warning.opacity(0.16))
            .background(palette.background)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(palette.warning.opacity(0.55))
                    .frame(height: 1)
            }
    }
}

// MARK: - Marking the data itself, not just the chrome

/// The inline tag that rides on an individual chart or value block.
///
/// **Why the banner is not enough on its own.** A banner at the top with
/// obviously-real-looking numbers under it is still the failure mode this
/// whole change exists to fix — and screenshots crop. Every other surface in
/// this project that renders a fabricated reading already carries the flag
/// *with the data* rather than beside it: `WidgetSnapshot.sourceIsDemoData`
/// exists because a home-screen widget has no banner, and
/// `WatchRelaySnapshot.sourceIsDemoData` exists because a complication has no
/// banner either. This is the phone's version of the same discipline.
struct DemoDataTag: View {
    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: DemoDataDisclosure.symbolName)
                .scaledSystemFont(size: 8, weight: .semibold)
            Text(DemoDataDisclosure.markerLabel.uppercased())
                .scaledFont(palette, size: 8.5, weight: .semibold)
                .kerning(0.6)
        }
        .foregroundStyle(palette.warning)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(palette.warning.opacity(0.14))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sample data")
    }
}

extension View {
    /// Pins a `DemoDataTag` to the top-trailing corner of a data surface.
    ///
    /// **How far this was taken, and what was deliberately left alone.**
    /// Applied to the surfaces that a reviewer would read as *telemetry* —
    /// the Dashboard's activity chart, the vitals ledger, and History's
    /// battery-health chart. Rejected: tagging every individual row and
    /// readout. Eight tags down the vitals ledger and one on each battery
    /// detail row would turn the tag into wallpaper, and a marker that
    /// appears everywhere stops being read anywhere — the same reason this
    /// app does not put a freshness badge on every number. Also rejected: a
    /// diagonal "SAMPLE" watermark across the content. It reads as a
    /// paywalled stock photo, it fights every chart it crosses, and it would
    /// have to be defeated for anyone to actually use the app they are
    /// evaluating.
    ///
    /// Alerts and Settings get no tags at all, and that is not an oversight:
    /// the Alerts tab renders `AppSettings.defaultAlertRules`, which is the
    /// real rule set Sentry ships (see `AlertsTabView`'s doc comment) — those
    /// values are true regardless of whether a Mac is connected, and tagging
    /// them "sample" would be its own small lie. Settings' device card
    /// already names the state on the row that carries it.
    @ViewBuilder
    func demoDataTagged(_ isMarking: Bool, alignment: Alignment = .topTrailing) -> some View {
        if isMarking {
            overlay(alignment: alignment) { DemoDataTag() }
        } else {
            self
        }
    }
}
