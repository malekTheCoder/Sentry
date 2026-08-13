import Foundation
import SentryKit

// MARK: - AppDataSource: the one shared transport every view model reads

/// The single, app-wide `StatsTransport` instance this app's view models,
/// stub controls, and intents all read from — introduced specifically so
/// `LocalSyncClient`'s Bonjour browser and its one `NWConnection` are
/// stood up exactly once per app launch, not once per view model.
///
/// **The problem this replaces.** Before this type existed, every view
/// model that needed a `StatsTransport` (`DashboardViewModel`,
/// `HistoryViewModel`, `SettingsTabView`, `SleepStatusCard`'s intent-style
/// send calls, `SentryIntents`) constructed its own `MockDataSource()` via
/// a default parameter. That was harmless for a mock — stateless, cheap,
/// no real resource behind it — but would be actively wrong for
/// `LocalSyncClient`: five independent instances would mean five
/// independent Bonjour browsers and five independent sockets open to the
/// same Mac, for no benefit over sharing one.
///
/// **Resolution flow.** `resolveIfNeeded()` is called once, from
/// `SentryMobileApp`'s root `.task`, before any tab's view model actually
/// needs to read `transport`. It tries `LocalSyncClient.waitForFirstConnection
/// (timeout:)` with a short, bounded timeout, and falls back to
/// `MockDataSource()` if nothing answers in time. There is deliberately no
/// third option tried here — `LocalSyncClient` and `MockDataSource` are
/// the only `StatsTransport` conformers (the once-planned CloudKit
/// transport was deleted without ever being wired; see `StatsTransport
/// .swift`'s doc comment), so `MockDataSource` is the correct, honest
/// fallback when no Mac answers.
///
/// **The disclosure contract that fallback is conditional on.** Falling back
/// to fabricated readings is only defensible while the app says so, and the
/// bar for "says so" is higher than this type's doc comment used to imply
/// when it pointed at "the amber Demo data indicator" on the Dashboard. That
/// indicator was one 12pt line that scrolled away, History worded the same
/// fact differently, and Alerts and Settings disclosed nothing at all. The
/// contract is now: while `isShowingDemoData` is true, `RootTabView` pins
/// `DemoDataBanner` above **every** tab where it cannot scroll away, saying
/// what the numbers are, why, and what to do about it
/// (`SentryKit`'s `DemoDataDisclosure` owns the wording); the individual
/// chart and ledger surfaces carry their own inline sample tags; and the
/// whole thing disappears on the frame `transport` becomes a real
/// `LocalSyncClient`. Anything that changes the fallback must keep that end
/// of it.
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
    /// so `SentryIntents`' `AppIntent`s — instantiated by the system, not
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

    /// Whether the numbers currently on screen were invented by
    /// `MockDataSource` rather than reported by a Mac. The input to
    /// `SentryKit`'s `DemoDataDisclosure`, and therefore to the app-level
    /// banner `RootTabView` pins above every tab.
    ///
    /// **Why this and not `isUsingLocalSync`.** The two are not the same
    /// question and the difference is exactly where an honesty bug would
    /// live. `isUsingLocalSync` is false during the discovery window at
    /// launch, when `MockDataSource` is genuinely on screen (so it happens to
    /// agree here), but it stays *true* across a dropped connection, when the
    /// transport is still the real `LocalSyncClient` and the correct
    /// behaviour is the Dashboard's "Unreachable" degradation to em dashes —
    /// not a claim that the readings are fabricated, because they aren't;
    /// they're absent. Only the transport's identity answers "are these
    /// numbers made up," which is what the disclosure asserts. This mirrors
    /// the derivation `WatchRelayManager` and `DashboardViewModel` already
    /// use for `sourceIsDemoData` on the Watch and widget payloads — one
    /// definition of "demo," three consumers.
    ///
    /// Computed rather than stored so it cannot drift out of step with
    /// `transport`: because `transport` is `@Published`, every swap
    /// re-publishes and every SwiftUI reader re-evaluates this on the same
    /// frame. That is what makes the banner vanish the instant a real Mac
    /// connects, rather than at the mercy of a second flag somebody has to
    /// remember to clear.
    public var isShowingDemoData: Bool { transport is MockDataSource }

    /// `true` once `resolveIfNeeded()` has found and connected to a real Mac
    /// over the local network — `SettingsTabView`'s sync-status section
    /// reads this to show "Connected to <Mac>" instead of the honest
    /// "no live connection" copy it showed when only `MockDataSource`
    /// existed.
    @Published public private(set) var isUsingLocalSync = false

    /// Whether the local-sync connection is up *right now*. Meaningful only
    /// while `isUsingLocalSync` is true: the transport stays the
    /// `LocalSyncClient` across a drop (it reconnects on its own), but the
    /// UI must stop claiming a live link the moment the Mac goes away —
    /// the Dashboard shows a connection-lost banner off this flag.
    @Published public private(set) var isLocalSyncConnected = false

    /// The most recent reason a *direct* (remote, TLS-PSK) connect attempt
    /// failed, or `nil` if none has failed yet this session, or the most
    /// recent attempt succeeded. `SettingsTabView.remoteMacSection` reads
    /// this to show "Wrong code?" vs. "Mac not responding — check it's
    /// awake and on the network" instead of the identical, undifferentiated
    /// "still trying…" both cases produced before this existed
    /// (connection-honesty review gap #2). Meaningless — and never set —
    /// for the Bonjour/LAN path, which has no "wrong code" concept.
    @Published public private(set) var remoteConnectFailureReason: DirectConnectFailureReason?

    /// Every Mac currently visible over Bonjour on the local network, kept
    /// live via `LocalSyncClient.setDiscoveredMacsHandler(_:)` — the
    /// published surface `SettingsTabView`'s multi-Mac picker reads.
    /// Empty (not just while using `MockDataSource`, but genuinely) whenever
    /// no Bonjour browse has happened yet or nothing answers; never
    /// populated from the remote/TLS-PSK path, which has no discovered list
    /// at all (see `LocalSyncClient`'s top-level doc comment on why that
    /// path is out of scope here).
    @Published public private(set) var discoveredMacs: [DiscoveredMac] = []

    /// The Bonjour service name of the Mac this phone is connected to over
    /// the LAN path right now, or `nil` while disconnected or while
    /// connected over the remote/direct path instead. Lets `SettingsTabView`
    /// mark the right row in the picker as the current one — see
    /// `LocalSyncClient.currentServiceIdentity()`.
    @Published public private(set) var connectedMacIdentity: String?

    private var localClient: LocalSyncClient?
    private var resolveTask: Task<Void, Never>?

    private init() {}

    /// Kicks off local-network discovery exactly once per app run (repeat
    /// calls while a resolution is already in flight, or has already
    /// finished, are no-ops) and awaits its result. `SentryMobileApp`
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

    /// Reads the phone-side remote-Mac configuration (`SettingsTabView`'s
    /// "Remote Mac" section — keys must match its `@AppStorage` properties).
    /// `nil` unless a host and pairing code are both present.
    private static func remoteEndpointFromDefaults() -> (host: String, port: UInt16, code: String)? {
        let defaults = UserDefaults.standard
        let host = (defaults.string(forKey: "remoteSync.host") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let code = defaults.string(forKey: "remoteSync.code") ?? ""
        let port = UInt16(defaults.string(forKey: "remoteSync.port") ?? "") ?? 8643
        guard !host.isEmpty, !code.isEmpty else { return nil }
        return (host, port, code)
    }

    private func resolve() async {
        let client = LocalSyncClient()
        localClient = client
        // Registered before `waitForFirstConnection` runs, not after, so a
        // direct-connect failure during the very first resolution (not just
        // ones after a fallback-to-mock) still reaches `SettingsTabView` —
        // see `remoteConnectFailureReason`'s doc comment.
        await client.setDirectConnectFailureHandler { [weak self] reason in
            Task { @MainActor in
                guard let self, self.localClient != nil else { return }
                self.remoteConnectFailureReason = reason
            }
        }
        var timeout = Self.discoveryTimeout
        if let remote = Self.remoteEndpointFromDefaults() {
            await client.configureDirectEndpoint(host: remote.host, port: remote.port, pairingCode: remote.code)
            // A remote dial (possibly across a tunnel) legitimately takes
            // longer than LAN Bonjour — give it a little more runway
            // before falling back to demo data.
            timeout = max(timeout, 8)
        }
        // Registered before `waitForFirstConnection` runs too, for the same
        // reason `directConnectFailureHandler` is: a multi-Mac household's
        // second (and third...) advertisement can show up during the very
        // first discovery window, not only after a fallback-to-mock, and
        // `SettingsTabView`'s picker should see it as soon as it exists.
        await client.setDiscoveredMacsHandler { [weak self] macs in
            Task { @MainActor in
                guard let self, self.localClient != nil else { return }
                self.discoveredMacs = macs
            }
        }
        let found = await client.waitForFirstConnection(timeout: timeout)
        if found {
            transport = client
            isUsingLocalSync = true
            isLocalSyncConnected = true
            connectedMacIdentity = await client.currentServiceIdentity()
            await client.setConnectionStateHandler { [weak self] connected in
                Task { @MainActor in
                    guard let self, self.localClient != nil else { return }
                    self.isLocalSyncConnected = connected
                    self.connectedMacIdentity = connected ? await self.localClient?.currentServiceIdentity() : nil
                }
            }
        } else {
            await client.stop()
            localClient = nil
            transport = MockDataSource()
            isUsingLocalSync = false
            discoveredMacs = []
            connectedMacIdentity = nil
        }
    }

    /// Hands a user's tap in `SettingsTabView`'s multi-Mac picker down to
    /// `LocalSyncClient.switchTo(discovered:)` — see that method's doc
    /// comment for what "switch" actually does (tears down the current
    /// connection, dials the chosen one, and updates the sticky
    /// reconnect-preference so future automatic reconnects favor this
    /// choice too). No-ops if local sync was never resolved to a real
    /// client (e.g. still on `MockDataSource`) — there is nothing to switch
    /// between in that case, and `discoveredMacs` would be empty, so
    /// `SettingsTabView`'s picker wouldn't be showing this option anyway.
    public func switchToDiscoveredMac(_ mac: DiscoveredMac) async {
        guard let localClient else { return }
        await localClient.switchTo(discovered: mac)
        // Set optimistically rather than waiting on `connectionStateHandler`
        // to fire — the picker row should reflect the user's choice the
        // instant they tap it, not only once the new connection finishes
        // becoming ready a moment later.
        connectedMacIdentity = mac.id
    }

    // MARK: - QR pairing (sentry://pair deep link)

    /// Applies a pairing scanned from the Mac's QR code
    /// (`RemotePairing` in SentryKit — `SentryMobileApp`'s `onOpenURL`
    /// calls this after the user confirms). Three responsibilities:
    /// persist the endpoint under the same defaults keys the Settings
    /// tab's `@AppStorage` fields read (so the form shows the scanned
    /// values immediately), hand it to a live `LocalSyncClient` if one
    /// exists (its direct-dial retry loop picks it up without an app
    /// relaunch), and — the case that actually matters for a fresh
    /// install — re-run resolution if the app had already given up and
    /// fallen back to `MockDataSource`, since that fallback was decided
    /// before any remote endpoint existed to try.
    public func applyPairing(_ endpoint: RemotePairing.Endpoint) async {
        let defaults = UserDefaults.standard
        defaults.set(endpoint.host, forKey: "remoteSync.host")
        defaults.set(String(endpoint.port), forKey: "remoteSync.port")
        defaults.set(endpoint.code, forKey: "remoteSync.code")

        await reconfigureAndResolve(host: endpoint.host, port: endpoint.port, code: endpoint.code)
    }

    /// The `SettingsTabView` "Connect" button's live-apply path (bug #3 in
    /// the connection-honesty review): before this existed, the "Remote Mac"
    /// fields were `@AppStorage`-backed and read only once, by
    /// `remoteEndpointFromDefaults()` at launch — typing a corrected
    /// hostname did nothing until the app relaunched, even though the help
    /// text under the fields promised the new address "takes effect the next
    /// time the app connects." This re-reads those same defaults keys right
    /// now and hands them to the identical tail `applyPairing(_:)` already
    /// uses, rather than only writing to `UserDefaults` and hoping
    /// `resolveIfNeeded()` happens to run again. A no-op (returns `false`)
    /// when the fields don't yet form a valid endpoint — `SettingsTabView`
    /// uses the return value to decide whether to show a validation cue
    /// instead of silently doing nothing.
    @discardableResult
    public func applyRemoteSettingsFromDefaults() async -> Bool {
        guard let remote = Self.remoteEndpointFromDefaults() else { return false }
        await reconfigureAndResolve(host: remote.host, port: remote.port, code: remote.code)
        return true
    }

    /// Shared tail for `applyPairing(_:)` and
    /// `applyRemoteSettingsFromDefaults()`: let any in-flight resolution
    /// finish (racing a second one could stand up two `LocalSyncClient`s),
    /// then either hand the new endpoint to the already-running client's
    /// direct-dial retry loop, or — the case that matters for a fresh
    /// install or a prior launch that had already given up — re-run
    /// resolution from scratch, since that earlier fallback to
    /// `MockDataSource` was decided before this endpoint existed to try.
    private func reconfigureAndResolve(host: String, port: UInt16, code: String) async {
        if let resolveTask {
            await resolveTask.value
        }
        // A freshly-entered endpoint deserves a clean slate — otherwise a
        // "wrong code" message from a previous attempt could sit under the
        // Connect button while a corrected code is already being dialed.
        remoteConnectFailureReason = nil

        if let localClient {
            await localClient.configureDirectEndpoint(host: host, port: port, pairingCode: code)
        } else {
            resolveTask = nil
            await resolveIfNeeded()
        }
    }

    /// User- or system-initiated retry, deliberately bypassing
    /// `resolveIfNeeded()`'s once-per-launch guard (see that method's doc
    /// comment for why automatic resolution stays single-shot). Two call
    /// sites, both real bugs from the connection-honesty review:
    ///
    /// 1. The app-level demo-data banner's "Try again" action
    ///    (`DemoDataBanner`, pinned above every tab by `RootTabView`) calls
    ///    this — before any retry existed, a Mac that was merely asleep or
    ///    slow at launch latched the app onto `MockDataSource` forever, with
    ///    no recovery short of force-quitting. (The retry used to hang off
    ///    the Dashboard's own amber connection line, which was the only tab
    ///    that offered one; that line no longer duplicates the demo
    ///    disclosure, so the recovery path moved to the banner that is on
    ///    every tab.)
    /// 2. `SentryMobileApp`'s `scenePhase` observer calls this when the app
    ///    returns to `.active` from the background — iOS suspends the
    ///    process while backgrounded, so `LocalSyncClient`'s Bonjour browser
    ///    and its retry loops can go stale and not refire on resume, and
    ///    nothing was watching `scenePhase` at all before this.
    ///
    /// No-ops while already connected. Otherwise tears down whatever client
    /// exists (a stale, backgrounded one included) and re-runs resolution
    /// from a clean slate — simpler and more robust than trying to nudge a
    /// possibly-stale `NWBrowser`/`NWConnection` back to life, and cheap
    /// enough for a user-initiated or once-per-foregrounding retry.
    public func retryConnection() async {
        if let resolveTask {
            await resolveTask.value
        }
        guard !isLocalSyncConnected else { return }

        if let localClient {
            await localClient.stop()
        }
        localClient = nil
        transport = MockDataSource()
        isUsingLocalSync = false
        isLocalSyncConnected = false
        remoteConnectFailureReason = nil
        discoveredMacs = []
        connectedMacIdentity = nil
        resolveTask = nil
        await resolveIfNeeded()
    }

    /// Clears the phone's saved remote-Mac endpoint — the counterpart to
    /// `applyPairing(_:)`/`applyRemoteSettingsFromDefaults()`: those two
    /// write an endpoint and (re)dial it, this un-writes one and stops
    /// dialing it. Exists because a saved bad/stale endpoint had no way
    /// back except manually clearing three text fields in `SettingsTabView`
    /// — which still left `LocalSyncClient`'s direct-dial retry loop
    /// redialing the stale address every ~3s forever, a real background
    /// battery/network cost for an address the user no longer wants tried
    /// (connection-honesty review gap #3).
    ///
    /// Reuses `configureDirectEndpoint`'s existing "empty host/code clears
    /// it" contract (see that method's doc comment) rather than adding a
    /// second way to express "no direct endpoint" on `LocalSyncClient`. Does
    /// *not* tear down or re-resolve the transport — if this phone also has
    /// a Mac reachable over the LAN/Bonjour, that connection is unaffected;
    /// only the direct/remote fallback is forgotten.
    public func forgetRemoteMac() async {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "remoteSync.host")
        defaults.removeObject(forKey: "remoteSync.port")
        defaults.removeObject(forKey: "remoteSync.code")
        remoteConnectFailureReason = nil
        if let localClient {
            await localClient.configureDirectEndpoint(host: "", port: 0, pairingCode: "")
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
            // `lastSeen` is the last *snapshot* time, not catalog-fetch time
            // — stamping `Date()` here made the freshness banner claim "now"
            // for a Mac that stopped reporting an hour ago.
            let lastSeen = await local.lastSnapshotDate() ?? .distantPast
            return [
                Device(
                    deviceID: deviceID,
                    deviceName: "Mac on your network",
                    model: "Unknown",
                    chip: "Unknown",
                    osVersion: "Unknown",
                    appVersion: "Unknown",
                    lastSeen: lastSeen,
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
