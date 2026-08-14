import Foundation

/// The features Sentry charges for.
///
/// It is an enum rather than a `Bool` on purpose: the entitlement check at
/// every call site names its feature — `isUnlocked(.fanControl)` — so
/// adding a paid feature is a new case, not a hunt through the app for
/// `isPro` booleans that all meant slightly different things. The
/// exhaustive `isUnlocked` switches in `ProEntitlementStore` and
/// `LicenseProEntitlementStore` make each new case a compiler-forced
/// decision.
///
/// There is deliberately no per-feature product identifier here anymore.
/// The one that used to exist was vocabulary for the StoreKit
/// implementation this file once promised, and that implementation is now
/// known to be impossible (see `ProEntitlementProviding`); the license
/// system that replaced it sells one product — Sentry Pro — whose payload
/// (`LicensePayload`) intentionally carries no feature list to drift out
/// of sync with this enum. Keeping a dead identifier "just in case" is the
/// same anti-pattern `FanControlBackend.swift`'s header names: vocabulary
/// for a thing that cannot happen reads as a thing that might.
public enum ProFeature: String, Codable, Sendable, CaseIterable, Hashable {
    case protectionInsights
    case fanControl
    case conditionalKeepAwake
    case processMatchAlerts
    case customThemes
    case remoteSync
    case historyExport

    public var displayName: String {
        switch self {
        case .protectionInsights: return String(localized: "Protection Insights")
        case .fanControl: return String(localized: "Fan Control")
        case .conditionalKeepAwake: return String(localized: "Conditional Keep-Awake")
        case .processMatchAlerts: return String(localized: "Process-Match Alerts")
        case .customThemes: return String(localized: "Custom Themes")
        case .remoteSync: return String(localized: "Remote Access")
        case .historyExport: return String(localized: "History Export & Retention")
        }
    }

    public var summary: String {
        switch self {
        case .protectionInsights:
            return String(localized: "Personalised, evidence-backed recommendations built from this Mac's own measured history and security posture.")
        case .fanControl:
            return String(localized: "Hold a fan at a fixed speed through the explicitly-installed root helper. Fan RPM readout stays free on every Mac with fans.")
        case .conditionalKeepAwake:
            return String(localized: "Release rules that end a keep-awake on their own — battery level, sustained CPU, a named app or process, an active download, or a schedule. Timed keep-awake stays free.")
        case .processMatchAlerts:
            return String(localized: "Alert rules that trigger on what's running, not just on metric thresholds.")
        case .customThemes:
            return String(localized: "Fork, edit, import, and export themes with WCAG contrast checking. The built-in themes stay free.")
        case .remoteSync:
            return String(localized: "Pair an iPhone over an encrypted connection from outside your Wi-Fi network. Same-network sync stays free.")
        case .historyExport:
            return String(localized: "Export recorded history and keep it beyond the default retention windows.")
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
    /// A verified Sentry Pro license (`LicenseProEntitlementStore`).
    /// Replaces the `.purchase` case that was reserved for a StoreKit 2
    /// implementation — removed, not kept alongside, because StoreKit
    /// purchase is impossible for this app (see `ProEntitlementProviding`)
    /// and a case nothing can ever produce is exactly the inert vocabulary
    /// this codebase strips elsewhere.
    case license
}

/// The seam a real entitlement implementation drops into.
///
/// **The StoreKit implementation this comment used to prescribe is dead,
/// and honestly so.** Earlier revisions promised a
/// `StoreKitProEntitlementStore` listening to `Transaction.updates` — a
/// plan written before the distribution decision landed. Sentry ships via
/// Developer ID, outside the Mac App Store, and StoreKit in-app purchase
/// simply does not exist for apps distributed that way; keeping the old
/// plan in this comment would be documentation describing an impossible
/// implementation, which is worse than no plan. What replaced it is the
/// license system in this directory: `SignedLicense` (an Ed25519-signed
/// blob, format documented on that type), `LicenseProEntitlementStore`
/// (this protocol's real conformer), and `LicenseActivationClient`
/// (`LicenseActivation.swift` — the deliberately implementation-free
/// boundary to the not-yet-provisioned checkout service).
///
/// **What stayed true from the original plan:** every call site asks this
/// protocol and nothing else. `InsightsViewModel` holds `any
/// ProEntitlementProviding`, `ProGate` is a pure function of a `Bool`, and
/// no view reads an entitlement directly — which is exactly why swapping
/// the promised StoreKit store for the license store was a one-line change
/// in `AppDelegate` and a rewrite of this comment, not a hunt through the
/// UI.
///
/// `@MainActor` because both implementations are observed by SwiftUI and
/// mutated from user actions; `AnyObject` because entitlement state is
/// reference-shared across the app rather than copied.
@MainActor
public protocol ProEntitlementProviding: AnyObject {
    func isUnlocked(_ feature: ProFeature) -> Bool
    var unlockSource: ProUnlockSource { get }

    /// Called by the composition root whenever settings change, with the
    /// **delivered** value.
    ///
    /// Not an implementation detail: `SettingsStore.settings` is a
    /// `@Published`, and `@Published` emits in `willSet`, so a provider that
    /// reached back into the store from inside a settings subscription
    /// would read the *previous* value — meaning a freshly-flipped unlock
    /// toggle wouldn't take effect until some unrelated setting changed
    /// next. `AppDelegate.applySettings` already documents this hazard for
    /// its own theme resolution; this hook is the same fix applied here.
    ///
    /// A StoreKit implementation can ignore the argument entirely — its
    /// entitlement doesn't live in settings — but still has to accept the
    /// call, which is why it's a protocol requirement rather than a method
    /// on the concrete type.
    func applySettings(_ settings: AppSettings)
}

/// The minimal, override-only implementation: unlocked by nothing except
/// an explicit developer override stored in `AppSettings`. Superseded in
/// the app's composition root by `LicenseProEntitlementStore` (which
/// honors the same override *and* verifies licenses), but kept: it is the
/// simplest possible conformer, useful in tests and as the reference for
/// what the override alone means.
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

    /// Mirrors `AppSettings.proUnlockOverrideEnabled`, seeded at
    /// construction and updated by `applySettings(_:)` / the setter below.
    /// Cached rather than read through to the store on every access for the
    /// `willSet` reason documented on `ProEntitlementProviding.applySettings`.
    private var overrideEnabled: Bool

    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.overrideEnabled = settingsStore.settings.proUnlockOverrideEnabled
    }

    public var unlockSource: ProUnlockSource {
        overrideEnabled ? .developerOverride : .locked
    }

    public func applySettings(_ settings: AppSettings) {
        overrideEnabled = settings.proUnlockOverrideEnabled
    }

    /// The override unlocks everything — Sentry Pro is one product, so
    /// every feature answers the same question. The `switch` stays
    /// exhaustive anyway so adding a feature is a compiler error here
    /// rather than a silent grant.
    public func isUnlocked(_ feature: ProFeature) -> Bool {
        switch feature {
        case .protectionInsights, .fanControl, .conditionalKeepAwake,
             .processMatchAlerts, .customThemes, .remoteSync, .historyExport:
            return unlockSource != .locked
        }
    }

    /// Updates the cache first, then persists — so a caller that reads
    /// `isUnlocked` immediately after setting it sees the new value without
    /// waiting for the settings subscription to come back around.
    public func setDeveloperOverride(_ enabled: Bool) {
        overrideEnabled = enabled
        settingsStore.settings.proUnlockOverrideEnabled = enabled
    }
}
