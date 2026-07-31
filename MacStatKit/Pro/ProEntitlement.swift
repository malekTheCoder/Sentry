import Foundation

/// The features Sentry charges for.
///
/// One case today. It is an enum rather than a `Bool` on purpose: the
/// entitlement check at every call site is `isUnlocked(.protectionInsights)`,
/// so adding a second paid feature later is a new case plus a new product
/// identifier, not a hunt through the app for `isPro` booleans that all
/// meant slightly different things.
public enum ProFeature: String, Codable, Sendable, CaseIterable, Hashable {
    case protectionInsights

    public var displayName: String {
        switch self {
        case .protectionInsights: return String(localized: "Protection Insights")
        }
    }

    public var summary: String {
        switch self {
        case .protectionInsights:
            return String(localized: "Personalised, evidence-backed recommendations built from this Mac's own measured history and security posture.")
        }
    }

    /// The App Store product identifier this feature *will* map to.
    ///
    /// Declared now, unused now. It exists so the StoreKit implementation
    /// described on `ProEntitlementProviding` has an obvious place to read
    /// from, rather than introducing a second, parallel notion of what a
    /// feature is called.
    public var productIdentifier: String {
        switch self {
        case .protectionInsights: return "dev.malekswilam.macstat.pro.protectioninsights"
        }
    }
}

/// Where an unlock came from. Shown in the UI so an unlocked build is never
/// ambiguous about *why* it's unlocked — a developer override that silently
/// looked identical to a purchase would be the easiest possible way to ship
/// a build that appears paid-for to everyone.
public enum ProUnlockSource: String, Codable, Sendable, Hashable {
    case locked
    /// The local developer/testing override. Never set by anything except
    /// an explicit toggle in Settings ▸ Advanced.
    case developerOverride
    /// Reserved for the StoreKit 2 implementation. Nothing produces this
    /// value today; it is declared so the UI's switch is already total when
    /// it does.
    case purchase
}

/// The seam a real StoreKit implementation drops into.
///
/// **There is deliberately no StoreKit in this repo yet.** Apple Developer
/// Program enrollment is currently blocked (see `PROGRESS.md` and
/// `StatsTransport.swift`'s doc comment for the same constraint elsewhere),
/// and a `Product.products(for:)` call that can never succeed would be an
/// inert control of exactly the kind this codebase has removed before. What
/// exists instead is the *boundary*: every call site asks this protocol, and
/// nothing else.
///
/// **How the StoreKit 2 version drops in, precisely:**
/// 1. Add a new type in this directory — `StoreKitProEntitlementStore` —
///    conforming to this same protocol. It listens to
///    `Transaction.updates`, checks `Transaction.currentEntitlements` for
///    `ProFeature.productIdentifier`, and publishes the result.
/// 2. Change the one line in `AppDelegate` that constructs
///    `ProEntitlementStore` to construct the StoreKit one instead, and have
///    it fall back to `ProEntitlementStore`'s developer override when the
///    App Store is unreachable.
/// 3. Nothing else changes. `InsightsViewModel` holds `any
///    ProEntitlementProviding`, `ProGate` is a pure function of a `Bool`,
///    and no view reads an entitlement directly.
///
/// `@MainActor` because both implementations are observed by SwiftUI and
/// mutated from user actions; `AnyObject` because entitlement state is
/// reference-shared across the app rather than copied.
@MainActor
public protocol ProEntitlementProviding: AnyObject {
    func isUnlocked(_ feature: ProFeature) -> Bool
    var unlockSource: ProUnlockSource { get }
}

/// The local, no-StoreKit implementation: unlocked only by an explicit
/// developer override stored in `AppSettings`.
///
/// **Why `SettingsStore` and not `UserDefaults`.** Everything else the user
/// can configure already round-trips through `settings.json` with
/// forward-compatible decoding (`AppSettings.init(from:)`), debounced atomic
/// writes, and one observable source of truth. A second persistence
/// mechanism for one boolean would mean two files to reason about and two
/// migration stories. The one thing `UserDefaults` would buy — surviving a
/// corrupt settings file — is not something a *developer override* needs.
///
/// **This is not a licence check and does not pretend to be one.** The
/// override is a plain boolean in a user-editable JSON file. That is
/// appropriate for a testing affordance and would be inappropriate for a
/// purchase, which is exactly why the two are different
/// `ProUnlockSource` cases.
@MainActor
public final class ProEntitlementStore: ProEntitlementProviding {

    private let settingsStore: SettingsStore

    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    public var unlockSource: ProUnlockSource {
        settingsStore.settings.proUnlockOverrideEnabled ? .developerOverride : .locked
    }

    /// Today the override unlocks everything, because there is one feature.
    /// The `switch` is written out anyway so adding a second feature is a
    /// compiler error here rather than a silent grant.
    public func isUnlocked(_ feature: ProFeature) -> Bool {
        switch feature {
        case .protectionInsights:
            return unlockSource != .locked
        }
    }

    public func setDeveloperOverride(_ enabled: Bool) {
        settingsStore.settings.proUnlockOverrideEnabled = enabled
    }
}
