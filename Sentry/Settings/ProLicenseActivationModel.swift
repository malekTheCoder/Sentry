import Foundation
import SentryKit

/// The state machine behind Settings ▸ Sentry Pro, kept out of the view so
/// every transition is testable against a stub `LicenseActivationClient`
/// with no SwiftUI in the loop.
///
/// **Two ways in, one store.** A license reaches this Mac either as the
/// full signed blob from the purchase email (pasted; verified offline by
/// `LicenseProEntitlementStore.installLicense` — the path that works with
/// no vendor at all) or, once a real activation client exists, as the
/// short key the checkout issues, exchanged for a blob by
/// `LicenseProEntitlementStore.activate`. `classify(_:)` decides which the
/// pasted text is; `submit()` routes accordingly. The key path is refused
/// — with a sentence saying what to paste instead — when no backend is
/// wired, rather than spinning on a call that can only throw
/// `.noActivationBackendConfigured`.
///
/// **Every failure is a typed case with its own sentence**, following
/// `LicenseDenialReason.explanation`'s convention: the view never composes
/// an error string, so the words a user reads on a bad paste are the same
/// words the tests pin.
@MainActor
final class ProLicenseActivationModel: ObservableObject {

    /// What the pasted text turned out to be.
    enum Input: Equatable {
        case empty
        /// Begins with `SignedLicense.blobPrefix`'s family ("sentry-pro").
        /// Includes a future `sentry-pro-v2`: routing that through
        /// `installLicense` yields the honest `.unsupportedFormat` sentence
        /// rather than a guess that it might be a vendor key.
        case signedBlob(String)
        /// Anything else non-empty: assumed to be a checkout key.
        case licenseKey(String)
    }

    enum Failure: Equatable {
        /// `installLicense` (or the post-`activate` verification) said no.
        case rejected(LicenseDenialReason)
        /// The pasted text is a short key and this build has no client to
        /// exchange it with.
        case keyNeedsBackend
        /// `activate` reached the server, which returned a blob that
        /// failed local verification — see `LicenseActivationClient`.
        case serverReturnedInvalidLicense(LicenseDenialReason)
        /// `activate` or `revalidate` threw something that was not one of
        /// the store's own errors: transport failure, or the client's own
        /// rejection (a key the server doesn't recognize, a revoked key).
        /// The concrete client's error type is Part 5b's to define; until
        /// then its `localizedDescription` is the only honest thing to show.
        case activationFailed(String)
        /// A "confirm now" came back revoked; the store has already removed
        /// the license. Carries the server's display reason.
        case revokedByServer(String)

        var message: String {
            switch self {
            case .rejected(let reason):
                return reason.explanation
            case .keyNeedsBackend:
                return String(localized: "That looks like a short license key, not a license. This version of Sentry activates with the full license text from your purchase email — it begins with “sentry-pro-v1”. Paste that instead.")
            case .serverReturnedInvalidLicense(let reason):
                return String(localized: "The licensing server sent back a license that doesn't verify on this Mac, so it was not installed. \(reason.explanation)")
            case .activationFailed(let description):
                return String(localized: "Activation didn't complete: \(description) Nothing on this Mac was changed.")
            case .revokedByServer(let reason):
                return String(localized: "The licensing server reports this license is no longer valid (\(reason)), so it has been removed from this Mac.")
            }
        }
    }

    enum Phase: Equatable {
        case idle
        /// An `activate`/`revalidate` round trip is in flight. Only ever
        /// entered on the key path — a blob paste is synchronous.
        case working
        case activated(LicensePayload)
        /// A "confirm now" came back still-valid.
        case confirmed
        case failed(Failure)
    }

    @Published var input: String = ""
    @Published private(set) var phase: Phase = .idle

    private let store: LicenseProEntitlementStore

    init(store: LicenseProEntitlementStore) {
        self.store = store
    }

    // MARK: - Read-through to the store (so the view has one object to ask)

    var decision: LicenseEntitlementDecision { store.decision }
    var unlockSource: ProUnlockSource { store.unlockSource }
    var hasActivationBackend: Bool { store.hasActivationBackend }
    var hasInstalledLicense: Bool { store.hasInstalledLicense }
    var lastVerifiedDate: Date? { store.lastVerifiedDate }

    // MARK: - Classification

    static func classify(_ raw: String) -> Input {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.hasPrefix("sentry-pro") { return .signedBlob(trimmed) }
        return .licenseKey(trimmed)
    }

    var canSubmit: Bool {
        if case .working = phase { return false }
        return Self.classify(input) != .empty
    }

    // MARK: - Actions

    func submit() async {
        switch Self.classify(input) {
        case .empty:
            return

        case .signedBlob(let blob):
            switch store.installLicense(blob) {
            case .entitled(let payload):
                input = ""
                phase = .activated(payload)
            case .denied(let reason):
                phase = .failed(.rejected(reason))
            }

        case .licenseKey(let key):
            guard store.hasActivationBackend else {
                phase = .failed(.keyNeedsBackend)
                return
            }
            phase = .working
            do {
                let payload = try await store.activate(licenseKey: key)
                input = ""
                phase = .activated(payload)
            } catch LicenseActivationError.serverReturnedInvalidLicense(let reason) {
                phase = .failed(.serverReturnedInvalidLicense(reason))
            } catch LicenseActivationError.noActivationBackendConfigured {
                // Unreachable given the guard above, but the store is the
                // authority; if it ever says so, say so.
                phase = .failed(.keyNeedsBackend)
            } catch {
                phase = .failed(.activationFailed(error.localizedDescription))
            }
        }
    }

    /// Takes the license off this Mac. Locks Pro immediately; the pasted
    /// text is the user's to keep, so nothing here needs confirming beyond
    /// the dialog the view puts in front of it.
    func removeLicense() {
        store.removeLicense()
        input = ""
        phase = .idle
    }

    /// The manual counterpart of `LicenseRevalidationScheduler`'s tick.
    /// Only offered by the view when `hasActivationBackend`, but guarded
    /// here too for the same authority reason as `submit()`.
    func confirmWithServer() async {
        guard store.hasActivationBackend else {
            phase = .failed(.keyNeedsBackend)
            return
        }
        phase = .working
        do {
            switch try await store.revalidate() {
            case .stillValid?:
                phase = .confirmed
            case .revoked(let reason)?:
                phase = .failed(.revokedByServer(reason))
            case nil:
                // Nothing installed to confirm; the status section already
                // says so.
                phase = .idle
            }
        } catch {
            phase = .failed(.activationFailed(error.localizedDescription))
        }
    }
}
