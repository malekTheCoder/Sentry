import Foundation

// MARK: - WatchRelayStore: the on-Watch cache the complication reads

/// The Watch-local cache `SentryWatch`'s `WCSessionDelegate` writes into
/// after every relay received from the phone, and
/// `SentryWatchWidgetExtension`'s complication `TimelineProvider` reads
/// from. Exists for the same reason `WidgetSnapshotStore` does on iOS: a
/// `TimelineProvider` runs in its own process, which may not be alive at the
/// moment `WCSession` actually delivers a context/user-info payload — the
/// delivery has to land somewhere durable that both processes can see, not
/// just an in-memory property on whichever object happened to receive the
/// callback.
///
/// **Why a plain App Group here works, unlike the iPhone <-> Mac boundary
/// `WatchRelaySnapshot` itself crosses.** Unlike the Mac and the iPhone
/// (which cannot share a container — see `WatchRelaySnapshot`'s doc
/// comment), the Watch app and its widget extension both run *on the Watch
/// itself*, so this is exactly the same shape of problem `WidgetSnapshotStore`
/// solves on iOS between `SentryMobile` and `SentryWidgetExtension`, and
/// the same fix applies.
public enum WatchRelayStore {
    /// Shared between `SentryWatch` and `SentryWatchWidgetExtension`
    /// only — reused rather than minted fresh purely so this codebase has
    /// one App Group identifier to remember, not one per platform pairing;
    /// it identifies a *different* container on the Watch than the one the
    /// same string names on the iPhone (App Group containers are scoped
    /// per-device), so there is no cross-device leakage risk in sharing the
    /// literal.
    public static let appGroupIdentifier = "group.dev.malekswilam.sentry"

    private static let storageKey = "dev.malekswilam.sentry.watchRelaySnapshot.v1"

    /// `nil` when the suite isn't reachable (App Group entitlement missing
    /// or misprovisioned for this build/signing configuration). Every other
    /// method below routes through this so there is exactly one place this
    /// can fail.
    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    /// Called by `SentryWatch`'s `WatchSessionController` on every
    /// `WCSessionDelegate` callback that carries a `WatchRelaySnapshot`.
    /// Silently does nothing if the App Group isn't reachable — matches
    /// `WidgetSnapshotStore.write`'s "never throws for an expected absence"
    /// stance.
    public static func write(_ snapshot: WatchRelaySnapshot) {
        guard let defaults = sharedDefaults else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Called by the complication's `TimelineProvider` on every reload, and
    /// by `SentryWatch`'s `ContentView` to render its own minimal screen.
    /// `nil` covers three genuinely different situations neither caller can
    /// distinguish from here (App Group unreachable, nothing relayed yet, or
    /// a stale/undecodable schema) — all three get the same honest "no data
    /// yet" treatment at the call site.
    public static func read() -> WatchRelaySnapshot? {
        guard let defaults = sharedDefaults else { return nil }
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(WatchRelaySnapshot.self, from: data)
    }
}
