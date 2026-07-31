import Foundation

// MARK: - WatchRelaySnapshot: the sliver of a SystemSnapshot relayed to the Watch

/// The minimal payload `MacStatMobile` relays to a paired Apple Watch over
/// `WCSession`, and what `MacStatWatch`'s complication ultimately renders.
///
/// **Why this exists separately from `WidgetSnapshot`.** `WidgetSnapshot`
/// (`MacStatKit/Sync/WidgetSnapshot.swift`) crosses an App-Group boundary
/// *within one device* (the iPhone app process and the iPhone widget
/// extension process both read the same container on the same phone). The
/// Watch is a different physical device with no access to the iPhone's App
/// Group at all — the Mac cannot reach the Watch directly either (no
/// Bonjour/Network.framework path from watchOS in this app), so the only
/// channel across that boundary is `WCSession`
/// (`updateApplicationContext`/`transferCurrentComplicationUserInfo`), whose
/// payloads must be small, plist-safe dictionaries and which carry their
/// own, much stricter size/budget constraints than an App Group write. This
/// type is deliberately narrower than `WidgetSnapshot` — no battery-history
/// sparkline, no memory fraction — a complication has no room to render
/// either, and shipping them would spend part of a scarce budget on values
/// nothing on the Watch displays.
///
/// **Why it lives in `MacStatKit`, not `MacStatMobile` or `MacStatWatch`.**
/// Both the phone (sender) and the watch app + its widget extension
/// (receivers) need the exact same `Codable` shape. Same reasoning as
/// `WidgetSnapshot`'s doc comment on why that type lives here rather than in
/// either endpoint's target — except this one also has to compile against
/// `MacStatKit_watchOS`, which is why this file (plus `Freshness.swift`/
/// `FreshnessBadge.swift`, both already platform-agnostic) is deliberately
/// kept free of any macOS/iOS-only import so it can be shared by all three
/// platform variants of `MacStatKit` without `#if os(...)` splitting.
public struct WatchRelaySnapshot: Codable, Sendable, Equatable {
    /// Human-readable label for the Mac this reading came from — e.g.
    /// `Device.deviceName`, same convention as `WidgetSnapshot.deviceName`.
    public var deviceName: String

    /// When the *underlying reading* was taken on the Mac —
    /// `SystemSnapshot.timestamp`'s equivalent for this projection. This is
    /// what `Freshness(lastSeen:)` should be computed against on the Watch,
    /// not `relayedAt` below — a relay sent seconds ago from a reading that
    /// is itself an hour stale must still render as stale, matching
    /// `WidgetSnapshot.lastSeen`'s exact reasoning.
    public var lastSeen: Date

    /// When the phone actually called into `WCSession` with this value.
    /// Kept separate from `lastSeen` for the same diagnostic reason
    /// `WidgetSnapshot.writtenAt` is — "the phone hasn't relayed in N hours"
    /// (a phone-side or connectivity problem) is a different failure mode
    /// than "the Mac hasn't reported in N hours" (a Mac-side one).
    public var relayedAt: Date

    /// Whether this value was fabricated by `MockDataSource` rather than
    /// synced from a real Mac — travels with the data for the exact reason
    /// `WidgetSnapshot.sourceIsDemoData` does (see that type's doc comment):
    /// a complication pinned to a watch face has no companion banner to
    /// disclose this any other way.
    public var sourceIsDemoData: Bool

    public var batteryPercent: Double
    public var isCharging: Bool
    public var isPluggedIn: Bool

    public var thermalPressure: ThermalPressureSummary

    public init(
        deviceName: String,
        lastSeen: Date,
        relayedAt: Date,
        sourceIsDemoData: Bool,
        batteryPercent: Double,
        isCharging: Bool,
        isPluggedIn: Bool,
        thermalPressure: ThermalPressureSummary
    ) {
        self.deviceName = deviceName
        self.lastSeen = lastSeen
        self.relayedAt = relayedAt
        self.sourceIsDemoData = sourceIsDemoData
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.thermalPressure = thermalPressure
    }
}

/// A deliberately coarser mirror of `ThermalStats.PressureLevel`
/// (`MacStatKit/Models/ThermalStats.swift`) — same four named tiers, plus
/// `.unknown` for a `SystemSnapshot` whose `thermal` field wasn't reported.
/// Redeclared here rather than reusing `ThermalStats.PressureLevel` directly
/// so this file has zero dependency on the rest of `MacStatKit/Models/`,
/// keeping `MacStatKit_watchOS`'s source list (`project.yml`) exactly the
/// three files it actually needs rather than pulling in `ThermalStats.swift`
/// and whatever *it* transitively expects to compile alongside it.
public enum ThermalPressureSummary: String, Codable, Sendable, Equatable {
    case nominal, fair, serious, critical, unknown
}

// MARK: - WCSession wire format

extension WatchRelaySnapshot {
    /// The one key both sides agree on inside the `[String: Any]`
    /// dictionaries `WCSession`'s `updateApplicationContext`/
    /// `transferCurrentComplicationUserInfo` APIs require.
    private static let payloadKey = "dev.malekswilam.macstat.watchRelay.v1"

    /// `WCSession`'s context/user-info APIs require a plain
    /// `[String: Any]` of property-list-compatible values, not an arbitrary
    /// `Encodable` — wrapping the JSON-encoded bytes as one `Data` value
    /// under a single fixed key sidesteps hand-mapping every field to a
    /// plist type individually (and keeps this the one place the wire
    /// format is defined, matching `WidgetSnapshotStore`'s single
    /// `storageKey` precedent), while still surviving `WCSession`'s plist
    /// coercion, since `Data` is natively plist-safe.
    public func wcSessionPayload() -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return [Self.payloadKey: data]
    }

    /// The receiving half of `wcSessionPayload()` — used by both
    /// `session(_:didReceiveApplicationContext:)` and
    /// `session(_:didReceiveUserInfo:)` on the Watch side, since both
    /// deliver the same dictionary shape.
    public static func from(wcSessionPayload dictionary: [String: Any]) -> WatchRelaySnapshot? {
        guard let data = dictionary[payloadKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchRelaySnapshot.self, from: data)
    }
}
