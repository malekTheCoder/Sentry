import SwiftUI
import SentryKit

/// The iPhone's About screen — Settings ▸ About, presented as a sheet.
///
/// The iPhone counterpart of `Sentry/Settings/Panes/AboutPane.swift`, and
/// deliberately the *same facts from the same source*: version from this
/// bundle's own Info.plist keys, names/copyright/dependency list from
/// `AppCredits` (`SentryKit/Models/AppCredits.swift`). Two hand-maintained
/// About screens would eventually credit different people, which is the one
/// kind of drift attribution cannot tolerate.
///
/// **Why a sheet and not a pushed screen.** `SettingsTabView` is a plain
/// themed `ScrollView` inside `RootTabView`'s `TabView` — there is no
/// `NavigationStack` anywhere in this app's settings tab, and introducing
/// one would restyle the whole tab (navigation bar chrome, safe-area
/// insets) to add a single screen. A sheet reaches the same content without
/// touching any existing view's layout.
///
/// **The `Link`s on this screen are deliberately silent**, and they are the
/// only controls in the phone app that are. A `Link` has no action closure
/// and changes no state — it hands the URL to the system, which is why it
/// gets the system's own affordances (long-press preview, drag out, the
/// context menu) for free. The only way to attach feedback is to replace it
/// with a `Button` calling `openURL`, which would trade all of that plus the
/// link accessibility trait for one tick. The app leaving the foreground is
/// already an unmistakable acknowledgement, so the trade buys nothing.
///
/// **Typography uses `scaledFont(_:size:weight:)`**, like every surrounding
/// iPhone view. This screen was written on a branch that predated the
/// Dynamic Type migration and deliberately used the fixed `palette.font`
/// API to match its contemporaries; the two landed together, which briefly
/// made About the one iPhone screen whose text did not scale. Reconciled at
/// the merge — the rule is simply that iPhone views scale.
struct AboutView: View {

    @Environment(\.themePalette) private var palette
    @Environment(\.dismiss) private var dismiss

    /// Collapsed by default, same reasoning as the Mac pane's: the
    /// acknowledgements must be *available*, not first.
    @State private var showsThirdParty = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: palette.spacingSection) {
                header
                identityCard
                contributorsCard
                privacyCard
                thirdPartyCard
            }
            .padding(palette.spacingPage)
        }
        .themedScreenBackground(palette)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("About")
                .scaledFont(palette, size: 20, weight: .semibold)
                .foregroundStyle(palette.textPrimary)
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .scaledFont(palette, size: 13, weight: .medium)
                .foregroundStyle(palette.textSecondary)
        }
    }

    // MARK: - Identity

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Sentry")
                .scaledFont(palette, size: 16, weight: .semibold)
                .foregroundStyle(palette.textPrimary)
            // Read from this bundle, never hardcoded — see
            // `AppCredits.versionSummary(bundle:)`.
            Text(AppCredits.versionSummary())
                .scaledFont(palette, size: 11.5)
                .foregroundStyle(palette.textSecondary)
            Text("The iPhone companion to Sentry for Mac.")
                .scaledFont(palette, size: 11.5)
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(palette.spacingBlock)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(palette)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Contributors

    private var contributorsCard: some View {
        VStack(alignment: .leading, spacing: palette.spacingTight) {
            Text("MADE BY")
                .scaledFont(palette, size: 10, weight: .semibold)
                .foregroundStyle(palette.textTertiary)
                .accessibilityAddTraits(.isHeader)
            ForEach(AppCredits.contributors, id: \.self) { name in
                Text(name)
                    .scaledFont(palette, size: 12.5)
                    .foregroundStyle(palette.textPrimary)
            }
            Text(AppCredits.copyright)
                .scaledFont(palette, size: 10.5)
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Privacy

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: palette.spacingTight) {
            Text("PRIVACY")
                .scaledFont(palette, size: 10, weight: .semibold)
                .foregroundStyle(palette.textTertiary)
                .accessibilityAddTraits(.isHeader)
            if let url = AppCredits.privacyPolicyURL {
                Link("Privacy Policy", destination: url)
                    .scaledFont(palette, size: 12.5)
                    .foregroundStyle(palette.accent)
            }
            // Deliberately says neither a source-tree path nor a file
            // extension — connection-honesty review, "internal-type-name
            // leaks" — matching how the acknowledgements list below states
            // each package's actual `license`/`copyright` fact rather than
            // pointing at where that fact lives in the repo. Someone reading
            // this in the app has no source checkout to look in; "not live
            // yet" is the one thing that's both true and useful to them.
            Text("Sentry keeps its data on your own devices. The full written policy isn't published yet; the link above isn't live.")
                .scaledFont(palette, size: 10.5)
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Third-party

    /// Lists only what actually ships inside *this* app — see
    /// `AppCredits.iOSThirdPartyComponents`. On iPhone that is GRDB alone;
    /// Sparkle, SwiftNIO and the MCP SDK are linked by the Mac app only, and
    /// acknowledging them here would describe a binary the user doesn't have.
    private var thirdPartyCard: some View {
        VStack(alignment: .leading, spacing: palette.spacingTight) {
            Text("ACKNOWLEDGEMENTS")
                .scaledFont(palette, size: 10, weight: .semibold)
                .foregroundStyle(palette.textTertiary)
                .accessibilityAddTraits(.isHeader)

            DisclosureGroup(isExpanded: $showsThirdParty) {
                VStack(alignment: .leading, spacing: palette.spacingRow) {
                    ForEach(AppCredits.iOSThirdPartyComponents) { component in
                        componentRow(component)
                    }
                }
                .padding(.top, palette.spacingTight)
            } label: {
                Text("Third-Party Licenses")
                    .scaledFont(palette, size: 12.5)
                    .foregroundStyle(palette.textPrimary)
            }
            .tint(palette.textSecondary)
            // Expanding and collapsing are both `SentryHaptic.tap` — that
            // case names "expanded a disclosure" outright — which also makes
            // this feel identical to the Dashboard's ledger rows, the app's
            // other disclosure. Driven off `showsThirdParty` so the
            // chevron, the label, and VoiceOver's own activation all produce
            // the same one buzz.
            .haptic(.tap, on: showsThirdParty)

            // Same rewording as the privacy note above, same reason: no
            // repository path in front of a reader who only has the app.
            Text("The full list, including the packages that ship only in the Mac app, isn't published outside the app yet.")
                .scaledFont(palette, size: 10.5)
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func componentRow(_ component: AppCredits.ThirdPartyComponent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if let url = URL(string: component.url) {
                    Link(component.name, destination: url)
                        .foregroundStyle(palette.accent)
                } else {
                    Text(component.name)
                        .foregroundStyle(palette.textPrimary)
                }
                Text(component.version)
                    .foregroundStyle(palette.textTertiary)
            }
            .scaledFont(palette, size: 12)

            Text("\(component.license) · \(component.copyright)")
                .scaledFont(palette, size: 10.5)
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(component.name) \(component.version), \(component.license), \(component.copyright)")
    }
}
