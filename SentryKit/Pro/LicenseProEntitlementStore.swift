import CryptoKit
import Foundation

/// The license-backed `ProEntitlementProviding`: the implementation that
/// replaces the StoreKit one the older doc comments promised, now that
/// Sentry's distribution decision (Developer ID, outside the Mac App
/// Store) has made StoreKit purchases impossible.
///
/// **What this type is and isn't.** It is a thin, `@MainActor`, stateful
/// shell around three pure pieces: `SignedLicense.verify` (crypto),
/// `LicenseEntitlementPolicy.decide` (policy), and `AppSettings`
/// (persistence). Every decision it publishes is reproducible from
/// (blob, key, lastVerifiedAt, policy, now) — the tests exercise the pure
/// functions with pinned dates and this shell only for wiring.
///
/// **Persistence: `settings.json`, eyes open.** The blob and
/// `lastVerifiedAt` live in `AppSettings`
/// (`proLicenseBlob` / `proLicenseLastVerifiedAt`) for the same reasons
/// `ProEntitlementStore` gives for the override — one persistence
/// mechanism, one migration story, survives a settings-file copy to a new
/// Mac. The obvious objection: it's a user-editable file. For the *blob*
/// that is fine by construction — editing it breaks the Ed25519 signature
/// and verification fails closed. For *`lastVerifiedAt`* it means a user
/// can hand-extend their own grace window, and that is accepted
/// deliberately: client-side licensing keeps honest users honest; it is
/// not DRM, and pretending a local timestamp could be tamper-proof (it
/// can't — the clock itself is the user's) would be security theater at
/// the cost of a second persistence mechanism. The enforcement that
/// matters for revoked licenses is the server's, through the
/// `LicenseActivationClient` seam.
///
/// **The developer override still works here.** The drop-in plan on
/// `ProEntitlementProviding` always said the real implementation should
/// fall back to the local override; honoring it keeps
/// Settings ▸ Advanced ▸ Developer truthful in a build where no license
/// can exist yet (no embedded public key, no checkout). `unlockSource`
/// keeps the two visibly distinct — a license reports `.license`, the
/// override reports `.developerOverride`, and the Insights UI already
/// renders different copy for each, so an unlocked build is never
/// ambiguous about why it's unlocked.
@MainActor
public final class LicenseProEntitlementStore: ProEntitlementProviding {

    private let settingsStore: SettingsStore
    private let publicKey: Curve25519.Signing.PublicKey?
    private let activationClient: (any LicenseActivationClient)?
    private let revalidationPolicy: LicenseRevalidationPolicy

    /// Injected clock, `Date.init` in production. The one impurity in
    /// this type, quarantined here so tests pin it and no assertion ever
    /// races the wall clock.
    private let now: () -> Date

    // Cached mirrors of the settings fields, seeded at construction and
    // updated by `applySettings(_:)` / the mutators below — cached rather
    // than read through on every access for the `@Published`-emits-in-
    // `willSet` reason documented on `ProEntitlementProviding.applySettings`.
    private var overrideEnabled: Bool
    private var licenseBlob: String?
    private var lastVerifiedAt: Date?

    /// The current decision, recomputed on every input change. Exposed so
    /// a settings pane can show the actual state — including the honest
    /// denial sentence (`LicenseDenialReason.explanation`) — instead of a
    /// bare lock icon.
    public private(set) var decision: LicenseEntitlementDecision

    /// - Parameters:
    ///   - publicKey: normally `LicenseKeys.productionPublicKey` (nil in
    ///     this build — see `LicenseKeys` for why, and
    ///     `LicenseDenialReason.verificationUnavailableInThisBuild` for how
    ///     that surfaces honestly). Injected rather than read from
    ///     `LicenseKeys` directly so tests supply their own test-only key.
    ///   - activationClient: nil in this build; see `LicenseActivation.swift`.
    ///   - revalidationPolicy: `.never` until an activation client exists —
    ///     see `LicenseRevalidationPolicy`'s doc comment for why enforcing
    ///     a grace window with no way to refresh it would brick paying
    ///     users.
    public init(
        settingsStore: SettingsStore,
        publicKey: Curve25519.Signing.PublicKey?,
        activationClient: (any LicenseActivationClient)? = nil,
        revalidationPolicy: LicenseRevalidationPolicy = .never,
        now: @escaping () -> Date = Date.init
    ) {
        self.settingsStore = settingsStore
        self.publicKey = publicKey
        self.activationClient = activationClient
        self.revalidationPolicy = revalidationPolicy
        self.now = now

        let settings = settingsStore.settings
        self.overrideEnabled = settings.proUnlockOverrideEnabled
        self.licenseBlob = settings.proLicenseBlob
        self.lastVerifiedAt = settings.proLicenseLastVerifiedAt
        self.decision = LicenseEntitlementPolicy.decide(
            blob: settings.proLicenseBlob,
            publicKey: publicKey,
            lastVerifiedAt: settings.proLicenseLastVerifiedAt,
            policy: revalidationPolicy,
            now: now()
        )
    }

    // MARK: - ProEntitlementProviding

    /// License first, then override: `.license` is the stronger claim and
    /// the one the UI should attribute an unlock to when both hold.
    public var unlockSource: ProUnlockSource {
        if decision.isEntitled { return .license }
        return overrideEnabled ? .developerOverride : .locked
    }

    public func isUnlocked(_ feature: ProFeature) -> Bool {
        // A Sentry Pro license unlocks every Pro feature — the license is
        // sold as one product, not per-feature (see `LicensePayload`; there
        // is deliberately no feature list in the payload to get out of sync
        // with `ProFeature`). The switch is still written out per-case so a
        // second feature is a compiler-forced decision here, exactly as in
        // `ProEntitlementStore.isUnlocked`.
        switch feature {
        case .protectionInsights:
            return unlockSource != .locked
        }
    }

    public func applySettings(_ settings: AppSettings) {
        overrideEnabled = settings.proUnlockOverrideEnabled
        licenseBlob = settings.proLicenseBlob
        lastVerifiedAt = settings.proLicenseLastVerifiedAt
        recompute()
    }

    // MARK: - Install / remove (the paste-a-license path)

    /// Verifies a pasted blob and, only if it is entitled *right now*,
    /// persists it. Returns the decision either way so the settings UI can
    /// show `LicenseDenialReason.explanation` for a rejection instead of a
    /// generic failure.
    ///
    /// A successful install also stamps `lastVerifiedAt`: holding a
    /// freshly-issued blob is the closest thing to an online check this
    /// build can witness, and it means a future revalidation-requiring
    /// policy starts its grace window at install rather than treating a
    /// just-activated license as already lapsed.
    ///
    /// Rejected blobs (including *expired* ones) persist nothing — an
    /// installed-but-dead license in `settings.json` would be a lie at
    /// rest, and the caller still holds the string if they want to retry.
    @discardableResult
    public func installLicense(_ blob: String) -> LicenseEntitlementDecision {
        let trimmed = blob.trimmingCharacters(in: .whitespacesAndNewlines)
        let verifiedAt = now()
        let candidate = LicenseEntitlementPolicy.decide(
            blob: trimmed,
            publicKey: publicKey,
            lastVerifiedAt: verifiedAt,
            policy: revalidationPolicy,
            now: verifiedAt
        )

        guard candidate.isEntitled else { return candidate }

        // Cache first, then persist — same read-your-own-write ordering as
        // `ProEntitlementStore.setDeveloperOverride`, so a caller checking
        // `isUnlocked` immediately after install sees the new state.
        licenseBlob = trimmed
        lastVerifiedAt = verifiedAt
        decision = candidate
        settingsStore.settings.proLicenseBlob = trimmed
        settingsStore.settings.proLicenseLastVerifiedAt = verifiedAt
        return candidate
    }

    public func removeLicense() {
        licenseBlob = nil
        lastVerifiedAt = nil
        settingsStore.settings.proLicenseBlob = nil
        settingsStore.settings.proLicenseLastVerifiedAt = nil
        recompute()
    }

    // MARK: - The seam-backed calls

    /// Exchanges a checkout license key for a blob via the activation
    /// client and installs it. Throws `.noActivationBackendConfigured` in
    /// this build — callers must treat that as "don't render an Activate
    /// button", not as a transient failure to retry.
    public func activate(licenseKey: String) async throws -> LicensePayload {
        guard let activationClient else {
            throw LicenseActivationError.noActivationBackendConfigured
        }
        let blob = try await activationClient.activate(licenseKey: licenseKey)
        let result = installLicense(blob)
        switch result {
        case .entitled(let payload):
            return payload
        case .denied(let reason):
            // The server's word is input, not authority — see
            // `LicenseActivationClient.activate`.
            throw LicenseActivationError.serverReturnedInvalidLicense(reason)
        }
    }

    /// Asks the server whether the installed license is still good and
    /// refreshes `lastVerifiedAt` on a positive answer. A `revoked` answer
    /// removes the license: keeping a blob the server has disowned would
    /// re-entitle on the next launch under a `.never` policy, which is the
    /// one outcome a revocation must preclude.
    ///
    /// Transport errors from the client propagate — an *unreachable*
    /// server is not a *negative* answer, and the grace window exists
    /// precisely so that difference doesn't punish offline Macs.
    public func revalidate() async throws {
        guard let activationClient else {
            throw LicenseActivationError.noActivationBackendConfigured
        }
        guard let payload = decision.payload ?? currentPayloadIgnoringGrace() else {
            // Nothing installed (or nothing that verifies): there is no
            // license to ask the server about.
            return
        }

        switch try await activationClient.revalidate(licenseID: payload.licenseID) {
        case .stillValid(let refreshedBlob):
            if let refreshedBlob {
                // A refreshed blob goes through the full install path —
                // verified locally, never trusted on the server's say-so.
                installLicense(refreshedBlob)
            } else {
                lastVerifiedAt = now()
                settingsStore.settings.proLicenseLastVerifiedAt = lastVerifiedAt
                recompute()
            }
        case .revoked:
            removeLicense()
        }
    }

    // MARK: - Private

    /// A grace-lapsed license is still a *verified* license — revalidation
    /// needs its `licenseID` even though it currently entitles nothing.
    private func currentPayloadIgnoringGrace() -> LicensePayload? {
        guard let licenseBlob, let publicKey else { return nil }
        if case .valid(let payload) = SignedLicense.verify(blob: licenseBlob, publicKey: publicKey, at: now()) {
            return payload
        }
        return nil
    }

    private func recompute() {
        decision = LicenseEntitlementPolicy.decide(
            blob: licenseBlob,
            publicKey: publicKey,
            lastVerifiedAt: lastVerifiedAt,
            policy: revalidationPolicy,
            now: now()
        )
    }
}
