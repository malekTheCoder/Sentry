import Combine
import Foundation
import MacStatKit
import WatchConnectivity

// MARK: - WatchRelayManager: the phone's half of the Watch complication

/// Forwards a small, complication-shaped slice of whatever `AppDataSource`
/// is currently receiving (real local-sync data, or `MockDataSource`'s demo
/// data — see that type's doc comment) to a paired Apple Watch, so
/// `MacStatWatch`'s complication has something real to show. This is the
/// phone-side half of the Watch feature: a Watch cannot reach the Mac
/// directly (no Bonjour/Network.framework path exists from watchOS in this
/// app), so the already-running, already-connected phone app is the only
/// bridge — exactly the role `WCSession` exists to fill.
///
/// **Why a standalone singleton, started at app launch, not something
/// `DashboardViewModel` owns the way it owns `WidgetSnapshotWriter`.**
/// `WidgetSnapshotWriter` only has to run while the Dashboard tab's view
/// model is alive, because the iOS widget only ever needs "whatever the
/// Dashboard last saw." The Watch complication has to keep receiving
/// updates regardless of which tab is on screen (Alerts, Settings — the
/// user could sit there indefinitely), so this is wired up once from
/// `MacStatMobileApp`'s root `.task`, next to
/// `AppDataSource.shared.resolveIfNeeded()`, the same way that type
/// documents its own reason for living at the root rather than per-tab.
///
/// **Why this subscribes to `AppDataSource.shared.$transport` directly
/// instead of receiving snapshots from `DashboardViewModel`.**
/// `StatsTransport.snapshots()`'s doc comment is explicit that a transport
/// is free to fan one underlying subscription out to many returned
/// streams — a second subscriber here does not mean a second Bonjour
/// browser/socket, it means a second `AsyncStream` view onto the one
/// `LocalSyncClient` instance `AppDataSource` already owns. That is exactly
/// the fan-out this type exists to support.
///
/// **Why relays are throttled instead of firing on every snapshot.**
/// Complications have a small, system-enforced background-update budget —
/// Apple's own guidance for `WCSession.transferCurrentComplicationUserInfo`
/// is on the order of a handful of updates per hour even for an
/// actively-worn watch, far short of `AppDataSource`'s snapshot cadence.
/// Relaying every tick would exhaust that budget within minutes and get
/// silently throttled/dropped by the system, making the complication *less*
/// current than a deliberately-paced relay, not more — see `shouldRelay
/// (previous:next:at:)` below for the two independent guards this enforces
/// before it will call into `WCSession` at all.
@MainActor
final class WatchRelayManager: NSObject {
    static let shared = WatchRelayManager()

    /// Baseline heartbeat: even with no "significant" change, relay at
    /// least this often so a Watch that's been asleep/out of range still
    /// gets caught up promptly once reachable again, and so the
    /// complication's staleness label keeps advancing against real data
    /// rather than going quiet indefinitely just because nothing crossed a
    /// threshold.
    static let minimumRelayInterval: TimeInterval = 5 * 60

    /// A shorter floor that still applies even when a "significant change"
    /// (charging toggled, thermal tier changed) would otherwise trigger an
    /// immediate relay — stops a value oscillating right at a boundary
    /// (e.g. charge sitting at 100%, thermal pressure flapping between
    /// tiers under bursty load) from turning into a rapid-fire sequence of
    /// relays that would burn the budget just as fast as relaying every
    /// tick would.
    static let significantChangeCooldown: TimeInterval = 30

    private var lastRelayed: WatchRelaySnapshot?
    private var lastRelayedAt: Date?
    private var transportSubscription: AnyCancellable?
    private var snapshotTask: Task<Void, Never>?
    private var deviceNameCache: String?

    private override init() {
        super.init()
    }

    /// Called once from `MacStatMobileApp`'s root `.task`. Activating
    /// `WCSession` when the Watch app/`WCSession` isn't supported at all
    /// (e.g. running on an iPad, or a device with no paired Watch ever) is
    /// a documented no-op/early-return case — `WCSession.isSupported()`
    /// guards that so this never crashes or logs noise on those devices.
    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()

        transportSubscription = AppDataSource.shared.$transport
            .sink { [weak self] transport in
                self?.observeSnapshots(transport: transport)
            }
    }

    private func observeSnapshots(transport: any StatsTransport) {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            for await snapshot in transport.snapshots() {
                guard !Task.isCancelled else { return }
                await self?.consider(snapshot)
            }
        }
    }

    private func consider(_ snapshot: SystemSnapshot) async {
        if deviceNameCache == nil {
            deviceNameCache = await AppDataSource.shared.devices()
                .first { $0.deviceID == snapshot.deviceID }?.deviceName
        }

        let isDemoData = AppDataSource.shared.transport is MockDataSource
        let candidate = WatchRelaySnapshot(
            deviceName: deviceNameCache ?? snapshot.deviceID,
            lastSeen: snapshot.timestamp,
            relayedAt: Date(),
            sourceIsDemoData: isDemoData,
            batteryPercent: snapshot.battery?.chargePercent ?? 0,
            isCharging: snapshot.battery?.isCharging ?? false,
            isPluggedIn: snapshot.battery?.isPluggedIn ?? false,
            thermalPressure: Self.summarize(snapshot.thermal?.pressureLevel)
        )

        let now = Date()
        guard Self.shouldRelay(previous: lastRelayed, next: candidate, lastRelayedAt: lastRelayedAt, now: now) else {
            return
        }
        relay(candidate, at: now)
    }

    /// Pure decision logic, factored out of `consider(_:)` so it's testable
    /// without a live `WCSession`/`StatsTransport` — see
    /// `WatchRelayManagerTests` in `MacStatTests` (macOS-hosted, this logic
    /// has no watchOS/WatchConnectivity dependency of its own).
    ///
    /// - A `nil` `lastRelayedAt` (nothing relayed yet this run) always
    ///   relays immediately — the Watch should get *something* as soon as
    ///   one exists, not wait a full `minimumRelayInterval`.
    /// - Otherwise: relay if `minimumRelayInterval` has elapsed regardless
    ///   of content, OR if a value the complication actually renders
    ///   changed (whole-point battery percent, charging, thermal tier) and
    ///   at least `significantChangeCooldown` has elapsed.
    static func shouldRelay(
        previous: WatchRelaySnapshot?,
        next: WatchRelaySnapshot,
        lastRelayedAt: Date?,
        now: Date
    ) -> Bool {
        guard let lastRelayedAt else { return true }
        let age = now.timeIntervalSince(lastRelayedAt)
        if age >= minimumRelayInterval { return true }
        guard age >= significantChangeCooldown, let previous else { return false }
        if previous.isCharging != next.isCharging { return true }
        if previous.thermalPressure != next.thermalPressure { return true }
        if Int(previous.batteryPercent.rounded()) != Int(next.batteryPercent.rounded()) { return true }
        return false
    }

    private static func summarize(_ level: ThermalStats.PressureLevel?) -> ThermalPressureSummary {
        guard let level else { return .unknown }
        switch level {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        }
    }

    private func relay(_ snapshot: WatchRelaySnapshot, at now: Date) {
        lastRelayed = snapshot
        lastRelayedAt = now
        guard let payload = snapshot.wcSessionPayload() else { return }

        let session = WCSession.default
        guard session.activationState == .activated else { return }

        // `updateApplicationContext` is cheap and last-value-wins — always
        // send it so the Watch app has *something* current the next time it
        // wakes up for any reason, budget concerns or not (Apple's own docs
        // don't attach a hard daily cap to this API the way they do to
        // `transferUserInfo`/`transferCurrentComplicationUserInfo`).
        try? session.updateApplicationContext(payload)

        // `transferCurrentComplicationUserInfo` is the API that actually
        // nudges the complication's own background reload budget — reserved
        // for when the Watch app is actually installed (calling it
        // otherwise is a documented no-op that still counts against
        // nothing, but there is no reason to call it at all in that case).
        guard session.isWatchAppInstalled else { return }
        session.transferCurrentComplicationUserInfo(payload)
    }
}

// MARK: - WCSessionDelegate

extension WatchRelayManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // Nothing to do here today — `relay(_:at:)` re-checks
        // `activationState` itself before every send rather than caching a
        // "ready" flag off this callback, since the state can also change
        // later (e.g. the paired Watch is unpaired mid-session) and that
        // same check already handles it.
    }

    /// iOS-only requirement (watchOS has no notion of switching to a
    /// different paired counterpart) — required by the protocol on this
    /// platform even though this app has nothing state-bearing to tear down
    /// beyond what `activationDidCompleteWith` already no-ops.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Required alongside `sessionDidBecomeInactive` on iOS specifically so
    /// the system can hand the session off to a newly-paired Watch —
    /// re-activating is the documented way to opt into that, matching
    /// Apple's own sample code exactly.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
