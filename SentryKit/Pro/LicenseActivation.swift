import Foundation

// MARK: - The activation seam (deliberately implementation-free)
//
// This file is the boundary between the license verification that exists
// in this build (`License.swift`, `LicenseProEntitlementStore`) and the
// checkout/activation service that cannot exist in it yet. It follows the
// same pattern as `FanControlBackend.swift`'s write seam: the protocol is
// real and every caller is written against it, but no conformer performs
// network IO anywhere in this repository.
//
// **Why there is no concrete client, stated plainly.** Selling licenses
// requires a merchant-of-record checkout (Paddle, Lemon Squeezy, or
// similar), and those come with an account, API keys, webhook endpoints,
// and a store URL that only the project owner can create. Inventing
// endpoint paths and request shapes for a service that hasn't been
// provisioned would be fiction with a compile step — the exact
// "confident-looking code describing a reality that isn't true" bug
// `SyncPane`'s doc comment catalogs. The honest artifact is this
// boundary: precise about what the app needs from such a service, silent
// about how a particular vendor spells it.
//
// **What the concrete client will need to decide (not decided here):**
// which vendor; how a checkout webhook gets payloads signed with the
// production private key (`LicenseKeys`); whether activation binds a
// device identifier for seat counting; retry/backoff. All of that is
// vendor-shaped and belongs in the conformer, next to the account that
// makes it real.

/// What the activation service can be asked, from the app's point of view.
///
/// Two calls, and only two, because the verification side only has two
/// questions a server can answer that cryptography cannot:
/// 1. "Turn this purchase into a signed license blob" (`activate`) — the
///    once-per-Mac exchange of the short key from the checkout email for
///    the full self-contained blob the app stores and verifies offline.
/// 2. "Is this license still in good standing?" (`revalidate`) — the
///    periodic check that feeds `LicenseRevalidationPolicy`'s grace
///    window, catching refunds and revocations that no offline check can.
///
/// Deliberately absent: a `deactivate` call for seat management. Freeing a
/// seat is real product surface, but its shape (self-serve portal on the
/// vendor's site vs. in-app) is a checkout-side design decision, and
/// declaring vocabulary for it before that decision would just be a guess
/// the conformer has to work around.
///
/// `Sendable` because the store calls it from `@MainActor` methods via
/// `await` and a conformer will live on whatever executor its networking
/// wants.
public protocol LicenseActivationClient: Sendable {

    /// Exchanges the short license key from the purchase email for a
    /// signed license blob (`SignedLicense` format). The store verifies
    /// the returned blob before trusting it — a server response is input,
    /// not authority.
    func activate(licenseKey: String) async throws -> String

    /// Asks whether the license identified by `licenseID`
    /// (`LicensePayload.licenseID`) is still in good standing.
    func revalidate(licenseID: String) async throws -> LicenseRevalidationOutcome
}

/// A revalidation answer, reduced to what the store acts on.
public enum LicenseRevalidationOutcome: Equatable, Sendable {
    /// Still good. `refreshedBlob` optionally carries a re-issued blob
    /// (e.g. a renewal extended the expiry) which the store verifies and
    /// installs like any other; nil means "keep what you have".
    case stillValid(refreshedBlob: String?)
    /// The server says this license is no longer good — refunded, charged
    /// back, or revoked. The reason is display text for the user, not a
    /// machine code.
    case revoked(reason: String)
}

/// Errors the store raises around the seam — these are the *app's* errors,
/// distinct from whatever transport errors a concrete client throws.
public enum LicenseActivationError: Error, Equatable, Sendable {
    /// No `LicenseActivationClient` is wired in this build. The truthful
    /// state of every build until the checkout side exists; callers show
    /// `LicenseProEntitlementStore` copy for it rather than a spinner that
    /// could never complete.
    case noActivationBackendConfigured
    /// The server returned a blob that failed local verification. Never
    /// installed — a server response that doesn't verify is treated
    /// exactly like a pasted blob that doesn't verify.
    case serverReturnedInvalidLicense(LicenseDenialReason)
}
