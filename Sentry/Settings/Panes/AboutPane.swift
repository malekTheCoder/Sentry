import SwiftUI
import SentryKit

/// Settings ▸ About — who made Sentry, which build this is, and the
/// license/policy disclosures a shipping product owes its users.
///
/// **Why this lives in Settings rather than behind an "About Sentry" menu
/// item.** The conventional home is the application menu, and Sentry has no
/// application menu: it launches as an `LSUIElement` accessory
/// (`AppDelegate.main` calls `setActivationPolicy(.accessory)`, and
/// `project.yml` sets `LSUIElement: true`), so AppKit never installs a menu
/// bar for it, and `StatusItemController` builds no `NSMenu` either — the
/// status item routes both left and right clicks to the dropdown. There is
/// therefore no existing menu to hang "About Sentry" from, and
/// `orderFrontStandardAboutPanel(_:)` is never called anywhere in this app.
/// Adding a whole menu (or a second window) for one screen would be more
/// surface than the content justifies, so About joins the pane list of the
/// window the user already opens from the dropdown's gear.
///
/// **Every fact here is read, not typed.** The version comes from the
/// bundle's own `CFBundleShortVersionString`/`CFBundleVersion` (which
/// `project.yml` substitutes from `MARKETING_VERSION`/
/// `CURRENT_PROJECT_VERSION` — see the comment there about Sparkle
/// comparing exactly those keys), and the names, copyright and dependency
/// list come from `AppCredits` (`SentryKit/Models/AppCredits.swift`), which
/// the iPhone About screen reads too. Nothing on this screen is a literal
/// that could drift from what the app actually is.
struct AboutPane: View {

    @Environment(\.themePalette) private var palette

    /// Collapsed by default. The acknowledgements are an obligation to make
    /// available, not something a user opened Settings to read — nine rows
    /// of license identifiers above the privacy link would bury the two
    /// lines most people came for.
    @State private var showsThirdParty = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sentry")
                        .font(palette.font(size: 17, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    Text(AppCredits.versionSummary())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("A macOS menu bar system monitor, with iPhone and Apple Watch companions.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }

            Section {
                ForEach(AppCredits.contributors, id: \.self) { name in
                    Text(name)
                }
                Text(AppCredits.copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Made by")
            }

            Section {
                if let url = AppCredits.privacyPolicyURL {
                    Link("Privacy Policy", destination: url)
                }
                Text("Sentry keeps its data on your own devices. The full policy is docs/privacy-policy.md in the source repository; the published address above is not live yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Privacy")
            }

            Section {
                // A disclosure rather than a link, so the acknowledgement is
                // readable with no network and no repository access — the
                // obligation is to ship the notices with the app, not to
                // point at a page that may or may not resolve.
                DisclosureGroup(isExpanded: $showsThirdParty) {
                    ForEach(AppCredits.thirdPartyComponents) { component in
                        componentRow(component)
                    }
                } label: {
                    Text("Third-Party Licenses")
                }
                Text("Sentry bundles these open-source packages. docs/third-party-licenses.md carries the full detail, including Sparkle's embedded bsdiff and the MCP SDK's in-progress relicensing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Acknowledgements")
            }
        }
    }

    /// One acknowledgement: name and version on the first line, license and
    /// copyright underneath. The name links to the upstream repository,
    /// which is where the unabridged license text lives — reproducing nine
    /// full license texts inside a settings pane would be unreadable, and
    /// the identifier plus the copyright line is what the permissive
    /// licenses in use actually require to be carried.
    @ViewBuilder
    private func componentRow(_ component: AppCredits.ThirdPartyComponent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let url = URL(string: component.url) {
                    Link(component.name, destination: url)
                } else {
                    Text(component.name)
                }
                Text(component.version)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            Text("\(component.license) · \(component.copyright)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(component.name) \(component.version), \(component.license), \(component.copyright)")
    }
}
