import Foundation
import os

#if os(macOS)
import CoreLocation

// MARK: - LocationService: the Mac side of the "Location Log" feature

/// Periodically captures this Mac's approximate location via
/// `CLLocationManager` and publishes it for the composition root
/// (`AppDelegate`) to push into `StatsCoordinator.location`, from which it
/// rides `SystemSnapshot.location` out over `LocalSyncServer` to any
/// connected iPhone.
///
/// **This is not Find My, and must never be presented as such.** There is no
/// public API for a third-party app to register an arbitrary Mac into
/// Apple's actual Find My network — that mesh (offline finding via nearby
/// Apple devices, the crowdsourced Bluetooth relay) is reserved for Apple's
/// own devices and MFi-certified accessories enrolled through a specific
/// accessory program, not general software like this app. This service does
/// something much smaller and entirely honest about it: while MacStat is
/// running and the Mac is online, it asks CoreLocation for an approximate
/// fix every so often and sends the most recent one to a connected phone.
/// That is a **location log**, not a tracker — it cannot find an offline
/// Mac, cannot triangulate via other people's devices, and stops the moment
/// this process isn't running. Every doc comment, log line, and UI string
/// touching this feature (see `MacLocation`, `LocationPane`, and the
/// iPhone-side location section) says "Location Log" / "last known
/// location," never "Find My."
///
/// **Why periodic, not continuous.** `startUpdatingLocation()`'s continuous
/// stream is the wrong tool here — this feature only needs "roughly where is
/// this Mac right now," not a movement trail, and a Mac (unlike an iPhone)
/// is mostly stationary between polls anyway. `captureInterval` below (30
/// minutes) plus `startMonitoringSignificantLocationChanges()` — which wakes
/// on genuine movement between polls without any polling cost while
/// stationary — covers "the Mac stayed at a desk all day" and "the Mac moved
/// to a different building" without ever running a tight GPS poll loop that
/// would cost meaningfully more power for a menu-bar utility whose entire
/// premise is being cheap to leave running (plan §3.2 P6).
///
/// **Reduced accuracy is the deliberate default, not a fallback.** This
/// feature only needs "which building/neighborhood," not turn-by-turn GPS
/// precision — `desiredAccuracy = kCLLocationAccuracyReduced` asks
/// CoreLocation to prefer Wi-Fi-based positioning over GPS, which is both
/// less power-hungry and a smaller, more proportionate privacy ask than
/// requesting full-accuracy location for a stat-monitoring app.
///
/// **Permission is opt-in and explicit, never silent.** `requestAuthorization()`
/// is only ever called from `AppDelegate` in direct response to
/// `AppSettings.locationLogEnabled` turning on — see `LocationPane`'s doc
/// comment for the exact flow. Nothing in this type calls it at launch or
/// as a side effect of any other init path; a user who never opens Settings
/// and never enables the toggle is never prompted for location access at
/// all, matching `AlertEngine`'s existing "request authorization lazily"
/// convention (plan §11.3) for the identical reason.
///
/// **`@MainActor`, matching `PowerControlService`.** Driven by infrequent
/// timer ticks and `CLLocationManagerDelegate` callbacks, not a hot polling
/// loop — no contention to protect against with a private serial queue, and
/// `CLLocationManager`'s delegate callbacks are documented to arrive on the
/// queue the manager was created on, which for a plain `CLLocationManager()`
/// initialized here is the main queue.
@MainActor
public final class LocationService: NSObject, ObservableObject {

    private static let logger = Logger(subsystem: "dev.malekswilam.macstat.kit", category: "LocationService")

    /// How often a fresh fix is requested while the feature is enabled.
    /// Deliberately not continuous — see this type's doc comment.
    public static let captureInterval: TimeInterval = 30 * 60

    /// What this type currently knows about permission — a small, explicit
    /// mirror of `CLAuthorizationStatus` rather than passing that raw
    /// framework enum straight to the UI, so `LocationPane`/the iPhone-side
    /// UI can switch over a type that only has the cases relevant to this
    /// feature's honest-empty-state requirements.
    public enum PermissionState: Equatable, Sendable {
        case notDetermined
        case denied
        case restricted
        case authorized
    }

    @Published public private(set) var permissionState: PermissionState = .notDetermined

    /// The most recent fix this service has actually captured. `nil` until
    /// the first one lands (or forever, if permission was never granted) —
    /// `AppDelegate` mirrors this straight into `StatsCoordinator.location`.
    @Published public private(set) var lastLocation: MacLocation?

    /// `true` between `start()` and `stop()` — read by `LocationPane` so the
    /// toggle reflects whether this instance is actually polling, not just
    /// whether the user last asked it to.
    @Published public private(set) var isActive = false

    private let manager: CLLocationManager
    private var captureTimer: Timer?

    /// Injectable for tests that construct a `LocationService` without
    /// touching real `CLLocationManager` state; production code always uses
    /// the default `CLLocationManager()`.
    public init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        super.init()
        manager.delegate = self
        // Reduced accuracy, Wi-Fi-preferred — see type doc comment.
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        permissionState = Self.permissionState(for: manager.authorizationStatus)
    }

    /// Asks the OS for permission. Safe to call more than once — macOS
    /// no-ops a repeat request once a decision (allow/deny) has already been
    /// made, same as `CLLocationManager` always has. Callers should gate
    /// this behind explicit user action (a Settings toggle), never call it
    /// at launch — see type doc comment.
    public func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Starts the periodic capture timer and significant-change monitoring.
    /// A no-op if permission hasn't been granted yet — callers should check
    /// `permissionState == .authorized` first if they want to distinguish
    /// "didn't start because no permission" from "started," but this method
    /// itself refuses to spin up a timer that could never produce a fix
    /// rather than silently doing nothing forever once permission is denied.
    public func start() {
        guard permissionState == .authorized else { return }
        guard !isActive else { return }
        isActive = true

        captureFix()
        captureTimer?.invalidate()
        captureTimer = Timer.scheduledTimer(withTimeInterval: Self.captureInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureFix() }
        }
        manager.startMonitoringSignificantLocationChanges()
    }

    /// Stops the timer and significant-change monitoring. Idempotent. Does
    /// **not** clear `lastLocation` — the last known fix stays known (and
    /// its `Freshness`/age keeps growing) until a new one arrives or the
    /// process restarts, same "last known, not blanked out" convention every
    /// other honest-staleness surface in this codebase follows.
    public func stop() {
        isActive = false
        captureTimer?.invalidate()
        captureTimer = nil
        manager.stopMonitoringSignificantLocationChanges()
    }

    deinit {
        captureTimer?.invalidate()
    }

    // MARK: - Capture

    private func captureFix() {
        guard permissionState == .authorized else { return }
        manager.requestLocation()
    }

    private static func permissionState(for status: CLAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorizedAlways, .authorized, .authorizedWhenInUse:
            return .authorized
        @unknown default:
            return .denied
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.permissionState = Self.permissionState(for: status)
            if self.permissionState == .authorized {
                self.start()
            } else {
                self.stop()
            }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let captured = MacLocation(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            timestamp: location.timestamp,
            horizontalAccuracyMeters: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
        )
        Task { @MainActor [weak self] in
            self?.lastLocation = captured
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Best-effort (P5): a failed fix just means `lastLocation` stays
        // whatever it already was — never replaced with a fake/zeroed
        // reading. Logged so a persistent failure (e.g. Location Services
        // disabled system-wide) is visible in Console without surfacing an
        // error the UI has no good way to act on beyond what the honest
        // "no location yet" empty state already says.
        Self.logger.error("LocationService: fix failed: \(String(describing: error))")
    }
}
#endif
