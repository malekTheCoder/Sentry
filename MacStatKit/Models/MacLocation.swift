import Foundation

/// One approximate, point-in-time location reading for the Mac — the payload
/// behind the "Location Log" feature (never "Find My," see `LocationService`'s
/// doc comment for why that distinction is load-bearing, not cosmetic).
///
/// **What this is not.** There is no public API for a third-party app to
/// register an arbitrary Mac into Apple's actual Find My network — that mesh
/// is reserved for Apple's own devices and MFi-certified accessories via a
/// separate accessory program, not general third-party software. This type
/// carries nothing like that: it's a single `CLLocationManager` reading,
/// captured periodically while MacStat is running and the Mac is online, sent
/// to a connected iPhone over the existing local-sync transport. There is no
/// offline mesh lookup, no continuous tracking, and no capability to locate
/// the Mac while MacStat isn't running — see `LocationService`'s doc comment
/// for the full honesty framing this type exists to support.
///
/// **Why a separate struct, not bare fields on `SystemSnapshot`.** Grouping
/// latitude/longitude/timestamp/accuracy together means `SystemSnapshot
/// .location` is either a single meaningful reading or `nil` — never a
/// partial state like "we have a latitude but no timestamp for it," which
/// four independent optional `Double`/`Date` properties on `SystemSnapshot`
/// itself would allow by construction.
///
/// **Why it carries its own `timestamp`, separate from `SystemSnapshot
/// .timestamp`.** A location fix is captured on whatever cadence
/// `LocationService` runs (every 15–30 minutes, or on a significant-location
/// change) — much coarser than the snapshot tiers `StatsCoordinator` polls at
/// (seconds). Reusing `SystemSnapshot.timestamp` for the location's age would
/// misreport a location fix from 20 minutes ago as "just now" on every
/// snapshot broadcast in between, which is exactly the kind of overclaim
/// `Freshness`/plan §12.2 exists to prevent. `MacLocation.timestamp` is the
/// honest "as of" moment the iPhone app's map view actually displays.
public struct MacLocation: Codable, Sendable, Equatable {
    /// Degrees, WGS84 — whatever `CLLocationManager` reports. Reduced
    /// accuracy (`CLLocationManager.desiredAccuracy = kCLLocationAccuracyReduced`
    /// or the equivalent coarse authorization) is preferred over precise
    /// GPS-level accuracy for this feature — see `LocationService`'s doc
    /// comment.
    public let latitude: Double
    public let longitude: Double

    /// The moment this fix was captured on the Mac — not when it was sent,
    /// received, or when the containing `SystemSnapshot` was built. This is
    /// what `Freshness`/the iPhone map view label as "as of [time]."
    public let timestamp: Date

    /// `CLLocation.horizontalAccuracy` in meters, when the OS reports one.
    /// Carried through so the iPhone UI can honestly describe *how*
    /// approximate a reading is (Wi-Fi-based positioning can easily be
    /// hundreds of meters off) rather than implying pinpoint precision a
    /// reduced-accuracy fix never had.
    public let horizontalAccuracyMeters: Double?

    public init(
        latitude: Double,
        longitude: Double,
        timestamp: Date,
        horizontalAccuracyMeters: Double? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
    }
}
