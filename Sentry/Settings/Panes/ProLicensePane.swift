import SwiftUI
import SentryKit

/// Settings ▸ Sentry Pro — the one place a license is activated, inspected,
/// confirmed, and removed. Prerequisite 4 of
/// `docs/pro-license-dryrun-checklist.md`, built.
///
/// **What it shows, top to bottom.** The store's current
/// `LicenseEntitlementDecision` in words (the payload's seats and dates
/// when entitled, `LicenseDenialReason.explanation` when not — never a
/// bare lock icon); the paste field and Activate button; a Remove button
/// whenever a blob is installed; and, while locked, the same purchase
/// decision every other locked surface renders (`ProPurchase`).
///
/// **What it deliberately does not show.** A "fetch my license by key"
/// promise this build can't keep: the key path exists in
/// `ProLicenseActivationModel` and lights up when a real
/// `LicenseActivationClient` is injected, but with none wired the caption
/// says to paste the full license and a pasted key gets a sentence
/// explaining the same. Likewise "Confirm with Server" appears only when
/// there is a server to ask. Both follow `GeneralPane`'s Updates section:
/// a control over a mechanism that cannot run is a change that appears to
/// take and then cannot matter.
///
/// **Entitlement flips ride the settings stream.** `installLicense` and
/// `removeLicense` write `settings.proLicenseBlob`, the observed `store`
/// republishes, and every Pro gate in the app — this pane's status
/// section included — re-reads on that emission. The model's own
/// `@Published phase` covers the parts of this screen (in-flight, the
/// last failure sentence) that aren't settings.
struct ProLicensePane: View {

    @Environment(\.themePalette) private var palette

    /// Observed for the reason above: a license write is a settings write,
    /// and this is how the status section learns about it.
    @ObservedObject var store: SettingsStore

    @StateObject private var model: ProLicenseActivationModel

    /// Injected for the same reason `ProUpsellCard.checkoutURL` is.
    private let checkoutURL: URL?

    @State private var isConfirmingRemoval = false

    init(store: SettingsStore, licenseStore: LicenseProEntitlementStore, checkoutURL: URL? = AppCredits.proCheckoutURL) {
        self.store = store
        self.checkoutURL = checkoutURL
        _model = StateObject(wrappedValue: ProLicenseActivationModel(store: licenseStore))
    }

    var body: some View {
        Form {
            statusSection
            activateSection
            if model.hasInstalledLicense {
                removeSection
            }
            if !model.decision.isEntitled {
                purchaseSection
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove the license from this Mac?",
            isPresented: $isConfirmingRemoval
        ) {
            Button("Remove License", role: .destructive) {
                model.removeLicense()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.removalDialogMessage)
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            let decision = model.decision
            // §9.4: never encode meaning in color alone — icon and sentence
            // both carry it, as in `GeneralPane`'s Updates section.
            Label {
                Text(Self.statusHeadline(for: decision, unlockSource: model.unlockSource))
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: Self.statusSymbol(for: decision, unlockSource: model.unlockSource))
                    .foregroundStyle(decision.isEntitled ? palette.accent : palette.warning)
            }
            .fixedSize(horizontal: false, vertical: true)

            switch decision {
            case .entitled(let payload):
                LabeledContent("Covers", value: Self.seatsLabel(payload.seats))
                LabeledContent("Issued", value: payload.issuedDate.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Expires", value: Self.expiryLabel(payload))
                if model.hasActivationBackend {
                    LabeledContent("Last confirmed", value: Self.lastConfirmedLabel(model.lastVerifiedDate))
                    Button("Confirm with Licensing Server Now") {
                        Task { await model.confirmWithServer() }
                    }
                    .disabled(model.phase == .working)
                    .accessibilityLabel("Confirm the license with the licensing server now")
                }
            case .denied(let reason):
                Text(reason.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.unlockSource == .developerOverride {
                    Text(Self.overrideNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Status")
        }
    }

    // MARK: - Activate

    private var activateSection: some View {
        Section {
            TextField("License", text: $model.input, prompt: Text("Paste your license here"), axis: .vertical)
                .lineLimit(3...8)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .accessibilityLabel("License text")

            HStack(spacing: 10) {
                Button("Activate") {
                    Task { await model.submit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSubmit)
                .accessibilityLabel("Activate the pasted license")

                if model.phase == .working {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Contacting the licensing server")
                }
            }

            feedbackRow
        } header: {
            Text(model.decision.isEntitled ? "Replace License" : "Activate")
        } footer: {
            Text(Self.activationCaption(hasActivationBackend: model.hasActivationBackend))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var feedbackRow: some View {
        switch model.phase {
        case .idle, .working:
            EmptyView()
        case .activated(let payload):
            Label {
                Text(Self.activatedSentence(payload))
                    .font(.callout)
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(palette.accent)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        case .confirmed:
            Label {
                Text("Confirmed with the licensing server just now.")
                    .font(.callout)
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(palette.accent)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        case .failed(let failure):
            Label {
                Text(failure.message)
                    .font(.callout)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(palette.warning)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Remove

    private var removeSection: some View {
        Section {
            Button(role: .destructive) {
                isConfirmingRemoval = true
            } label: {
                Text("Remove License from This Mac…")
            }
            .accessibilityLabel("Remove the license from this Mac")

            Text(Self.removalCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Remove")
        }
    }

    // MARK: - Purchase

    private var purchaseSection: some View {
        Section {
            switch ProPurchase.affordance(checkoutURL: checkoutURL) {
            case .buy(let url):
                Link(ProPurchase.buyButtonTitle, destination: url)
                    .accessibilityHint("Opens the checkout page in your web browser")
                Text(ProPurchase.buyCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .notOnSaleYet:
                Text(ProPurchase.notOnSaleNotice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Buy")
        }
    }

    // MARK: - Copy (pure, testable — same convention as `SyncPane`)

    static func statusHeadline(for decision: LicenseEntitlementDecision, unlockSource: ProUnlockSource) -> String {
        switch decision {
        case .entitled:
            return String(localized: "Sentry Pro is active on this Mac")
        case .denied(.noLicense):
            return unlockSource == .developerOverride
                ? String(localized: "No license — unlocked by the developer override")
                : String(localized: "No license on this Mac")
        case .denied:
            return String(localized: "The installed license isn't being honored")
        }
    }

    static func statusSymbol(for decision: LicenseEntitlementDecision, unlockSource: ProUnlockSource) -> String {
        switch decision {
        case .entitled: return "checkmark.seal.fill"
        case .denied(.noLicense): return unlockSource == .developerOverride ? "wrench.and.screwdriver" : "lock"
        case .denied: return "exclamationmark.triangle.fill"
        }
    }

    static let overrideNote = String(
        localized: "Every Pro feature is currently unlocked by the developer override in Settings ▸ Advanced. That is a testing switch, not a purchase, and the Insights header says so."
    )

    static func seatsLabel(_ seats: Int) -> String {
        seats == 1
            ? String(localized: "1 Mac")
            : String(localized: "\(seats) Macs")
    }

    /// nil-versus-value on the payload is the perpetual/expiring
    /// distinction (`LicensePayload.expiresAt`), so "Never" is a statement
    /// about the license, not a missing value.
    static func expiryLabel(_ payload: LicensePayload) -> String {
        guard let expiry = payload.expiryDate else {
            return String(localized: "Never — this is a perpetual license")
        }
        return expiry.formatted(date: .abbreviated, time: .omitted)
    }

    static func lastConfirmedLabel(_ date: Date?) -> String {
        guard let date else { return String(localized: "Not yet") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Says which path this build actually offers. With no backend, the
    /// only thing that works is the full blob, and the caption says so
    /// instead of inviting a key that would bounce.
    static func activationCaption(hasActivationBackend: Bool) -> String {
        if hasActivationBackend {
            return String(localized: "Paste the full license from your purchase email, or the short license key from the same email — the key is exchanged with the licensing server for your license. Either way the license is verified on this Mac before it's kept.")
        }
        return String(localized: "Paste the full license from your purchase email — it begins with “sentry-pro-v1”. Activation happens entirely on this Mac and needs no internet connection.")
    }

    static func activatedSentence(_ payload: LicensePayload) -> String {
        String(localized: "Activated. This license covers \(seatsLabel(payload.seats)); every Pro feature is unlocked on this one.")
    }

    /// Honest about seats: nothing here tells a server a seat was freed —
    /// no `deactivate` call exists on the seam (see
    /// `LicenseActivationClient`), so the copy promises only what the app
    /// does locally.
    static let removalCaption = String(
        localized: "Takes the license off this Mac and locks Sentry Pro here immediately. The license itself is unchanged — keep the text from your purchase email to activate again, here or on another Mac it covers."
    )

    static let removalDialogMessage = String(
        localized: "Sentry Pro locks on this Mac right away. Your license stays valid and can be pasted again at any time."
    )
}

/// What Settings shows when no `LicenseProEntitlementStore` was handed to
/// it — the same "say it, don't hide it" treatment `GeneralPane` gives a
/// nil `UpdateController`. A preview or a future settings host without a
/// license store is a real configuration, and a user who went looking for
/// the license pane and found no pane at all would reasonably conclude
/// the feature had been removed.
struct ProLicenseUnavailablePane: View {
    @Environment(\.themePalette) private var palette

    var body: some View {
        Form {
            Section {
                Label {
                    Text("This copy of Sentry has no license store wired.")
                        .fontWeight(.semibold)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(palette.warning)
                }
                .fixedSize(horizontal: false, vertical: true)
                Text("Nothing here can activate, inspect, or remove a license in this build. This is a configuration gap in how Settings was constructed, not a problem with any license.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Status")
            }
        }
        .formStyle(.grouped)
    }
}
