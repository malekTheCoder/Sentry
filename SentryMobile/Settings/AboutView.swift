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
/// **Typography deliberately uses `palette.font(size:)`**, the API every
/// surrounding iPhone view uses today, rather than a Dynamic Type text
/// style — matching the code around it is the point; a lone view using a
/// different font API would be the thing that looks wrong.
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
                .font(palette.font(size: 20, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .font(palette.font(size: 13, weight: .medium))
                .foregroundStyle(palette.textSecondary)
        }
    }

    // MARK: - Identity

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Sentry")
                .font(palette.font(size: 16, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            // Read from this bundle, never hardcoded — see
            // `AppCredits.versionSummary(bundle:)`.
            Text(AppCredits.versionSummary())
                .font(palette.font(size: 11.5))
                .foregroundStyle(palette.textSecondary)
            Text("The iPhone companion to Sentry for Mac.")
                .font(palette.font(size: 11.5))
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
                .font(palette.font(size: 10, weight: .semibold))
                .foregroundStyle(palette.textTertiary)
                .accessibilityAddTraits(.isHeader)
            ForEach(AppCredits.contributors, id: \.self) { name in
                Text(name)
                    .font(palette.font(size: 12.5))
                    .foregroundStyle(palette.textPrimary)
            }
            Text(AppCredits.copyright)
                .font(palette.font(size: 10.5))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Privacy

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: palette.spacingTight) {
            Text("PRIVACY")
                .font(palette.font(size: 10, weight: .semibold))
                .foregroundStyle(palette.textTertiary)
                .accessibilityAddTraits(.isHeader)
            if let url = AppCredits.privacyPolicyURL {
                Link("Privacy Policy", destination: url)
                    .font(palette.font(size: 12.5))
                    .foregroundStyle(palette.accent)
            }
            Text("Sentry keeps its data on your own devices. The full policy is docs/privacy-policy.md in the source repository; the published address above isn't live yet.")
                .font(palette.font(size: 10.5))
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
                .font(palette.font(size: 10, weight: .semibold))
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
                    .font(palette.font(size: 12.5))
                    .foregroundStyle(palette.textPrimary)
            }
            .tint(palette.textSecondary)

            Text("docs/third-party-licenses.md in the source repository carries the full list, including the packages that ship only in the Mac app.")
                .font(palette.font(size: 10.5))
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
            .font(palette.font(size: 12))

            Text("\(component.license) · \(component.copyright)")
                .font(palette.font(size: 10.5))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(component.name) \(component.version), \(component.license), \(component.copyright)")
    }
}
