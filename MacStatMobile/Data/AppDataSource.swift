import Foundation
import MacStatKit

// MARK: - AppDataSource: the one shared transport every view model reads

/// The single, app-wide `StatsTransport` instance this app's view models,
/// stub controls, and intents all read from — introduced specifically so
/// `LocalSyncClient`'s Bonjour browser and its one `NWConnection` are
/// stood up exactly once per app launch, not once per view model.
///
/// **The problem this replaces.** Before this type existed, every view
/// model that needed a `StatsTransport` (`DashboardViewModel`,
/// `HistoryViewModel`, `SettingsTabView`, `SleepStatusCard`'s intent-style
/// send calls, `MacStatIntents`) constructed its own `MockDataSource()` via
/// a default parameter. That was harmless for a mock — stateless, cheap,
/// no real resource behind it — but would be actively wrong for
/// `LocalSyncClient`: five independent instances would mean five
/// independent Bonjour browsers and five independent sockets open to the
/// same Mac, for no benefit over sharing one.
///
/// **Resolution flow.** `resolveIfNeeded()` is called once, from
/// `MacStatMobileApp`'s root `.task`, before any tab's view model actually
/// needs to read `transport`. It tries `LocalSyncClient.waitForFirstConnection
/// (timeout:)` with a short, bounded timeout, and falls back to
/// `MockDataSource()` if nothing answers in time. There is deliberately no
/// third option tried here — CloudKit ("v2" in `StatsTransport.swift`'s
/// doc comment) has no conformer anywhere in this tree yet (no enrolled
/// Apple Developer Program account), so `MockDataSource` remains the
/// correct, honest fallback until it exists, exactly as it was before this
/// type was introduced.
///
/// **Why an `ObservableObject` holding `any StatsTransport`, not the
/// transport type itself threaded everywhere.** View models
/// (`DashboardViewModel`, `HistoryViewModel`) already accept `any
/// StatsTransport` for their snapshot stream — they just used to receive a
/// concrete `MockDataSource` because that was the only conformer in scope.
/// Publishing `transport` here (rather than a fixed `let`) is what lets
/// `resolveIfNeeded()`'s async discovery result reach a `DashboardViewModel`
/// that may have already started observing the placeholder mock transport
/// during the brief discovery window — `start()` on those view models is
/// called from `.task` at view-appearance time, which can race the root's
/// own discovery `.task`, so the transport has to be able to change out
/// from under an already-started subscriber, not just be read once at
/// construction.
///
/// **The `devices()`/`dailyHealthHistory(deviceID:dayCount:)` gap.**
/// `MockDataSource` exposes two conveniences that were never part of
/// `StatsTransport` itself (see that type's doc comment on `devices()`
/// listing this exact reason) because the plan never specified how the
/// iPhone app fetches a device catalog or health history over a real
/// transport. `LocalSyncClient` only carries `SystemSnapshot`s (per
/// `LocalSyncFraming`'s deliberately minimal wire protocol) — no `Device`
/// metadata, no `DailyHealth` series — so this type's `devices()` and
/// `dailyHealthHistory(deviceID:dayCount:)` below synthesize a best-effort
/// single-device answer from whatever a connected `LocalSyncClient` has
/// actually seen (just a `deviceID`, from the latest received snapshot) for
/// the local-sync case, and return an honestly-empty array rather than
/// fabricating history the transport never sent. Once `LocalSyncServer`
/// carries device metadata / a health feed of its own, this is the one
/// place that needs to change.
@MainActor
public final class AppDataSource: ObservableObject {

    /// The one instance every tab/view model/intent in this app should read
    /// from. A true singleton (not injected via `.environmentObject` alone)
    /// so `MacStatIntents`' `AppIntent`s — instantiated by the system, not
    /// by SwiftUI, so they have no environment to read from — can reach the
    /// same shared transport too, instead of falling back to constructing
    /// their own `MockDataSource()` the way they did before this type
    /// existed.
    public static let shared = AppDataSource()

    /// How long `resolveIfNeeded()` waits for a Mac to answer over the
    /// local-network transport before giving up and falling back to the
    /// mock. A few seconds is enough for Bonjour discovery + a TCP
    /// handshake on a healthy local network without making every cold
    /// launch of the app visibly hang waiting on a Mac that may not be
    /// running or may not be on the same network at all — the expected,
    /// correct outcome in that case is falling back promptly, not hanging.
    public static let discoveryTimeout: TimeInterval = 5

    /// The transport every view model reads. Starts as a fresh
    /// `MockDataSource()` — a real, usable, if fake, data source — rather
    /// than `nil`/optional, so any view model that starts observing before
    /// `resolveIfNeeded()` finishes still gets to render *something*
    /// immediately instead of an empty/loading state that only exists
    /// because of app-launch sequencing.
    @Published public private(set) var transport: any StatsTransport = MockDataSource()

    /// `true` once `resolveIfNeeded()` has found and connected to a real Mac
    /// over the local network — `SettingsTabView`'s sync-status section
    /// reads this to show "Connected to <Mac>" instead of the honest
    /// "no live connection" copy it showed when only `MockDataSource`
    /// existed.
    @Published public private(set) var isUsingLocalSync = false

    private var localClient: LocalSyncClient?
    private var resolveTask: Task<Void, Never>?

    private init() {}

    /// Kicks off local-network discovery exactly once per app run (repeat
    /// calls while a resolution is already in flight, or has already
    /// finished, are no-ops) and awaits its result. `MacStatMobileApp`
    /// calls this from the root scene's `.task`.
    public func resolveIfNeeded() async {
        if let resolveTask {
            await resolveTask.value
            return
        }
        let task = Task { [weak self] () -> Void in
            await self?.resolve()
        }
        resolveTask = task
        await task.value
    }

    private func resolve() async {
        let client = LocalSyncClient()
        localClient = client
        let found = await client.waitForFirstConnection(timeout: Self.discoveryTimeout)
        if found {
            transport = client
            isUsingLocalSync = true
        } else {
            await client.stop()
            localClient = nil
            transport = MockDataSource()
            isUsingLocalSync = false
        }
    }

    // MARK: - Mock-only conveniences, generalized across both transports

    /// See this type's top-level doc comment for why this exists outside
    /// `StatsTransport` at all, and what "generalized" means for the
    /// local-sync case (a synthesized single-entry catalog, not a real
    /// fetch).
    public func devices() async -> [Device] {
        if let mock = transport as? MockDataSource {
            return await mock.devices()
        }
        if let local = transport as? LocalSyncClient, let deviceID = await local.lastKnownDeviceID() {
            return [
                Device(
                    deviceID: deviceID,
                    deviceName: "Mac on your network",
                    model: "Unknown",
                    chip: "Unknown",
                    osVersion: "Unknown",
                    appVersion: "Unknown",
                    lastSeen: Date(),
                    capabilitiesJSON: "{}",
                    lastViewedAt: nil
                )
            ]
        }
        return []
    }

    /// `LocalSyncFraming`'s wire protocol only ever carries
    /// `SystemSnapshot`s (see that file's doc comment) — there is no
    /// `DailyHealth` series to synthesize a real answer from over this
    /// transport yet, so the honest answer for the local-sync case is an
    /// empty array, not fabricated history. Only `MockDataSource` (which
    /// generates its own synthetic series specifically to give the History
    /// tab's charts something to render) returns anything here.
    public func dailyHealthHistory(deviceID: String, dayCount: Int) async -> [DailyHealth] {
        if let mock = transport as? MockDataSource {
            return await mock.dailyHealthHistory(deviceID: deviceID, dayCount: dayCount)
        }
        return []
    }
}
