import Foundation
import Network
import os.log

// MARK: - LocalSyncClient: the receiving side of the local-network (Bonjour) transport

/// A `StatsTransport` conformer (`SentryKit/Sync/StatsTransport.swift`)
/// that discovers a Mac running `LocalSyncServer`
/// (`SentryKit/LocalSync/LocalSyncServer.swift`) on the local Wi-Fi network
/// via Bonjour and streams the framed `SystemSnapshot`s it sends. This is
/// the transport that actually shipped — it needs no cloud infrastructure
/// and no Apple Developer Program enrollment, which is why it exists and
/// the once-planned CloudKit transport (deleted; see `StatsTransport
/// .swift`'s doc comment) never did.
///
/// **Cross-platform, but really an iOS type.** `Network.framework` works
/// identically on macOS and iOS, so this file compiles on both (no `#if
/// os(...)` guard, unlike `LocalSyncServer`, which is macOS-only because
/// only the Mac app runs a server). In practice only `SentryMobile`
/// constructs one — the Mac has no reason to browse for itself.
///
/// **First-found by default, but a real picker exists now.** On its very
/// first connection of the process, this type still connects to whichever
/// result `NWBrowser` reports first (browse results are a `Set`, so "first"
/// isn't even a stable notion across calls) — that default is deliberately
/// unchanged, since *some* Mac has to be chosen automatically before a user
/// has ever had a chance to express a preference. What's fixed
/// (connection-honesty review gap #5): every reconnect *after* that — a
/// drop, a Mac going to sleep and coming back, a Wi-Fi blip — prefers
/// dialing the *same* Mac by Bonjour service name (`preferredEndpoint(
/// among:preferring:)` below) rather than re-running "first result wins" on
/// every retry, which used to mean a phone could silently hop to a second
/// Mac's advertisement mid-session with no indication anything changed. And
/// on top of that sticky-reconnect mechanism, `setDiscoveredMacsHandler(_:)`
/// / `discoveredMacs(from:)` / `switchTo(discovered:)` below now let a user
/// with more than one Mac on the network actually *see* every Mac
/// `NWBrowser` currently reports and deliberately switch to one —
/// `AppDataSource` publishes the list and `SettingsTabView` renders the
/// picker (only when there's genuinely more than one Mac to choose
/// between). Switching updates the same sticky identity `preferredEndpoint`
/// reads, so a deliberate choice sticks across future automatic reconnects
/// too, not just the one connection made right now. Documented here rather
/// than hidden, per this codebase's "say plainly what doesn't work"
/// convention (see `SettingsTabView`'s doc comment for the canonical
/// example of that discipline). Explicitly still out of scope: picking
/// between multiple *remote* (TLS-PSK) Macs — that path is a single
/// user-entered host:port + pairing code, not a discovered list, and
/// supporting several stored pairing codes at once is a bigger, separate
/// project.
///
/// **`send(command:)` is real.** It used to throw unconditionally
/// ("receive-only for this first pass"); it now frames and writes the
/// `ControlCommand` onto the live connection, and
/// `awaitStatus(forNonce:timeout:)` lets a caller wait for the Mac's
/// `ControlStatus` reply — see `LocalSyncServer`'s matching receive loop and
/// `LocalCommandExecutor` (`SentryKit/Services/LocalCommandExecutor.swift`).
/// This works over both the LAN and remote (TLS-PSK) connections, so an
/// iPhone or Apple Watch can control a Mac from anywhere the remote listener
/// is reachable. Where it *does* fail, it throws rather than silently
/// no-op-ing the way `MockDataSource`'s conformer does:
/// `MockDataSource` no-ops because there's genuinely nothing on the other
/// end to reach; this type *is* connected to a real Mac, so quietly
/// swallowing a command would misrepresent a working connection as having
/// done something it didn't.
///
/// **Why an `actor`, matching `MockDataSource`.** `StatsTransport` requires
/// `Sendable` conformers (see that protocol's doc comment, point 3); an
/// actor is the natural way to hold mutable state (the current connection,
/// the fan-out continuations, `lastReceivedAt`) safely across the
/// concurrent contexts `Network.framework`'s callback-based API calls in
/// from.
public actor LocalSyncClient: StatsTransport {

    /// Must match `LocalSyncServer.serviceType` exactly.
    public static let serviceType = "_sentry._tcp"

    private let log = Logger(subsystem: "dev.malekswilam.sentry.mobile", category: "LocalSyncClient")
    private let queue = DispatchQueue(label: "dev.malekswilam.sentry.localsyncclient")

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receiveBuffer = Data()

    /// The remote (off-LAN) fallback: a user-entered host:port + pairing
    /// code, dialed with TLS-PSK (`SyncSecurity`) whenever Bonjour hasn't
    /// produced a connection. Set via `configureDirectEndpoint` before
    /// `start()`/`waitForFirstConnection`.
    private var directConfig: (host: String, port: UInt16, code: String)?
    private var directRetryTask: Task<Void, Never>?

    /// Fan-out targets for `snapshots()`, matching `StatsCoordinator
    /// .snapshots()`'s documented pattern: one underlying subscription (one
    /// `NWConnection`), many independently-terminable `AsyncStream`s handed
    /// out to callers.
    private var continuations: [UUID: AsyncStream<SystemSnapshot>.Continuation] = [:]

    /// Backs `freshness()`: the wall-clock time of the last snapshot this
    /// instance actually decoded off the wire. `nil` until the first one
    /// arrives.
    private var lastReceivedAt: Date?

    /// The `deviceID` carried by the most recently received snapshot —
    /// exposed via `lastKnownDeviceID()` for `AppDataSource`'s synthesized
    /// `devices()` catalog (`SentryMobile/Data/AppDataSource.swift`), since
    /// this transport's wire protocol never sends a `Device` record, only
    /// `SystemSnapshot`s.
    private var lastDeviceID: String?

    /// Set once discovery finds a service and a connection attempt begins;
    /// read by `waitForFirstConnection(timeout:)` to decide whether a
    /// timeout should be treated as "still trying" vs "genuinely nothing
    /// found."
    private var isConnecting = false
    private var isReady = false

    /// Continuations waiting on the very first successful connection —
    /// see `waitForFirstConnection(timeout:)`.
    private var readyWaiters: [CheckedContinuation<Bool, Never>] = []

    /// Invoked with `true` when a connection becomes ready and `false` when
    /// it closes — the surface `AppDataSource` uses to keep the UI honest
    /// about a Mac that went away *mid-session* (before this existed, the
    /// launch-time yes/no was the only signal, and a dropped connection left
    /// the app claiming a live link forever).
    private var connectionStateHandler: (@Sendable (Bool) -> Void)?

    public func setConnectionStateHandler(_ handler: (@Sendable (Bool) -> Void)?) {
        connectionStateHandler = handler
    }

    /// Invoked whenever a *direct* (remote, TLS-PSK) connection attempt
    /// fails, with the best-guess reason, or with `nil` once a direct
    /// connection succeeds (clearing a previously-shown reason). Never
    /// invoked for LAN/Bonjour connect failures — there is no "wrong code"
    /// concept on that plaintext path, so those keep retrying silently the
    /// way they always have.
    ///
    /// Exists because `attemptDirectConnect()` used to retry every 3s on
    /// *any* failure with no distinction (connection-honesty review gap
    /// #2): a wrong pairing code and an unreachable Mac produced the exact
    /// same "still trying…" UI forever, even though one of them (wrong
    /// code) is something the user can actually fix by re-typing, and the
    /// other isn't fixable from this screen at all. See `classifyDirect
    /// ConnectFailure(_:)` below for how the two are told apart, and
    /// `SettingsTabView.remoteMacSection` for where this surfaces.
    private var directConnectFailureHandler: (@Sendable (DirectConnectFailureReason?) -> Void)?

    public func setDirectConnectFailureHandler(_ handler: (@Sendable (DirectConnectFailureReason?) -> Void)?) {
        directConnectFailureHandler = handler
    }

    /// Invoked with the full, de-duplicated, stably-ordered list of Macs
    /// currently visible over Bonjour, every time `NWBrowser`'s result set
    /// changes — the piece this pass adds on top of `preferredEndpoint(
    /// among:preferring:)`. That method (see its doc comment) only ever
    /// decides which *one* Mac to dial; it deliberately has no notion of
    /// "show the user everything that's out there," because until now
    /// nothing consumed that information. `AppDataSource` wires this handler
    /// to a `@Published` property the same way it already does for
    /// `connectionStateHandler`/`directConnectFailureHandler`, and
    /// `SettingsTabView` reads that to show a picker — but only when more
    /// than one Mac is actually discovered (`LocalSyncClient
    /// .hasMultipleMacs(_:)`), so the common single-Mac household sees no
    /// new UI at all.
    public func setDiscoveredMacsHandler(_ handler: (@Sendable ([DiscoveredMac]) -> Void)?) {
        discoveredMacsHandler = handler
    }

    private var discoveredMacsHandler: (@Sendable ([DiscoveredMac]) -> Void)?

    /// Set only while the in-flight `connect(to:parameters:isDirect:)` call
    /// is a direct (remote) attempt — read back in `handleClosed`/
    /// `handleReady` to decide whether a failure/success should update
    /// `directConnectFailureHandler`. Not part of `connection` itself
    /// because `NWConnection` carries no such flag of its own.
    private var connectionIsDirect = false

    /// The Bonjour service name of the Mac this client most recently
    /// connected to over the LAN path, or `nil` before any LAN connection
    /// has succeeded. Read by `preferredEndpoint(among:preferring:)` so a
    /// drop-and-reconnect prefers dialing the *same* Mac again rather than
    /// whichever result `NWBrowser` happens to report first — see this
    /// type's top-level doc comment, "First Bonjour result wins," for the
    /// two-Mac-household bug this fixes (connection-honesty review gap #5).
    /// Never set from a direct/remote connection — that path is dialed by
    /// explicit host:port, not discovered by name, so "which Mac" is never
    /// ambiguous there.
    private var lastConnectedServiceIdentity: String?

    /// The Bonjour service name of the Mac this client is connected to right
    /// now, or `nil` while disconnected or connected over the direct/remote
    /// path (which has no service name at all). Read by `AppDataSource` to
    /// mark the right row in `SettingsTabView`'s multi-Mac picker as "this
    /// one" — deliberately a read of live state rather than reusing
    /// `lastConnectedServiceIdentity` directly, since that field stays set
    /// across a drop (that's the point of it) whereas this answers "which
    /// Mac, if any, is actually live right now."
    public func currentServiceIdentity() async -> String? {
        isReady && !connectionIsDirect ? lastConnectedServiceIdentity : nil
    }

    /// Wall-clock time of the most recently decoded snapshot, or nil —
    /// lets `AppDataSource.devices()` report an honest `lastSeen` instead
    /// of stamping catalog-fetch time.
    public func lastSnapshotDate() async -> Date? {
        lastReceivedAt
    }

    /// Continuations waiting on a `ControlStatus` reply to a specific
    /// `nonce` — see `awaitStatus(forNonce:timeout:)`. Keyed by nonce rather
    /// than a single "next status" slot because nothing prevents a caller
    /// from issuing a second command (another `SleepStatusCard` adjust tap,
    /// a Siri phrase) while a first reply is still in flight.
    private var statusWaiters: [String: CheckedContinuation<ControlStatus?, Never>] = [:]

    public init() {}

    deinit {
        browser?.cancel()
        directRetryTask?.cancel()
        connection?.cancel()
        for continuation in continuations.values { continuation.finish() }
        for waiter in statusWaiters.values { waiter.resume(returning: nil) }
    }

    // MARK: - Discovery + connection lifecycle

    /// Starts browsing for `_sentry._tcp` and connects to the first result.
    /// Safe to call more than once — a second call while already
    /// browsing/connected is a no-op. Called from `waitForFirstConnection
    /// (timeout:)` (the composition root's normal entry point) but also
    /// exposed directly for callers that want to kick off discovery without
    /// blocking on the result.
    /// Registers the remote fallback endpoint. Normally called before
    /// `start()`/`waitForFirstConnection`, but safe after them too — a QR
    /// pairing scanned mid-session (`RemotePairing`) lands here on an
    /// already-started client, so the retry loop is kicked off on the spot
    /// rather than only from `start()`. Passing an empty host or code
    /// clears it. Bonjour remains the preferred path — same network means
    /// lower latency and no round trip through a tunnel — the direct
    /// endpoint is dialed only while no connection exists.
    public func configureDirectEndpoint(host: String, port: UInt16, pairingCode: String) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = SyncSecurity.normalize(pairingCode)
        guard !trimmedHost.isEmpty, !code.isEmpty, port > 0 else {
            directConfig = nil
            return
        }
        directConfig = (trimmedHost, port, code)
        if isStarted() {
            startDirectRetryLoopIfConfigured()
        }
    }

    public func start() {
        guard browser == nil else { return }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: Self.serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let endpoints = results.map(\.endpoint)
            Task {
                await self.publishDiscoveredMacs(endpoints)
                await self.connectToPreferredBrowseResult(endpoints)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.log.error("LocalSyncClient: browser failed: \(String(describing: error))")
            }
        }
        browser.start(queue: queue)
        self.browser = browser

        startDirectRetryLoopIfConfigured()
    }

    /// TCP parameters for the LAN (plaintext Bonjour) path. Keepalive is set
    /// here for the identical reason `SyncSecurity.remoteParameters`
    /// documents it (gap #1, connection-honesty review): without it a LAN
    /// connection can sit in `.ready` long after the Mac went to sleep or
    /// dropped off Wi-Fi, silently misreporting `isLocalSyncConnected`.
    /// Reuses `SyncSecurity.keepaliveIdleSeconds` rather than a second
    /// constant — one interval, chosen once, for both paths this client can
    /// take; see that constant's doc comment for why 15s.
    private static func lanParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = Int(SyncSecurity.keepaliveIdleSeconds)
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        return parameters
    }

    /// Dials the configured remote endpoint every few seconds while no
    /// connection exists, for as long as the client is started. The loop
    /// itself doesn't distinguish *why* an attempt failed — it just tries
    /// again later, and Bonjour keeps racing it; whichever path connects
    /// first wins — but each failure's likely cause (wrong pairing code vs.
    /// Mac unreachable) is now classified and surfaced separately via
    /// `directConnectFailureHandler`, so a caller isn't stuck reading "still
    /// trying…" for both cases alike.
    private func startDirectRetryLoopIfConfigured() {
        guard directConfig != nil, directRetryTask == nil else { return }
        directRetryTask = Task { [weak self] in
            while let self, await self.isStarted() {
                await self.attemptDirectConnect()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func isStarted() -> Bool {
        browser != nil
    }

    private func attemptDirectConnect() {
        guard let config = directConfig, !isConnecting, !isReady, connection == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: config.port) else { return }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(config.host), port: port)
        connect(to: endpoint, parameters: SyncSecurity.remoteParameters(pairingCode: config.code), isDirect: true)
    }

    /// Stops browsing and closes any open connection. Every open
    /// `snapshots()` stream is finished, and any pending `waitForFirst
    /// Connection(timeout:)` callers are resumed with `false`.
    public func stop() {
        browser?.cancel()
        browser = nil
        directRetryTask?.cancel()
        directRetryTask = nil
        connection?.cancel()
        connection = nil
        isReady = false
        isConnecting = false
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
        for waiter in statusWaiters.values { waiter.resume(returning: nil) }
        statusWaiters.removeAll()
        resumeReadyWaiters(found: false)
    }

    /// Starts discovery (if not already running) and suspends until either
    /// a connection to a discovered Mac becomes ready, or `timeout` elapses
    /// — whichever comes first. Returns `true` if a connection was made in
    /// time, `false` otherwise.
    ///
    /// This is the method the iOS composition root (`AppDataSource`,
    /// `SentryMobile/Data/AppDataSource.swift`) calls at launch: it needs a
    /// yes/no answer within a bounded time to decide whether to hand the
    /// rest of the app this transport or fall back to `MockDataSource` —
    /// hanging indefinitely waiting for a Mac that may not be on the
    /// network at all (the expected case in a build-sandbox/no-Wi-Fi
    /// environment) is exactly the failure mode this method exists to
    /// avoid.
    public func waitForFirstConnection(timeout: TimeInterval) async -> Bool {
        if isReady { return true }
        start()
        return await withCheckedContinuation { continuation in
            readyWaiters.append(continuation)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                await self.timeoutIfStillWaiting()
            }
        }
    }

    private func timeoutIfStillWaiting() {
        guard !isReady else { return }
        resumeReadyWaiters(found: false)
    }

    private func resumeReadyWaiters(found: Bool) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: found)
        }
    }

    private func connect(to endpoint: NWEndpoint, parameters: NWParameters, isDirect: Bool = false) {
        guard !isConnecting, !isReady else { return }
        isConnecting = true
        connectionIsDirect = isDirect

        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { await self.handleReady(connection) }
            case .failed(let error):
                Task { await self.handleClosed(connection, error: error) }
            case .cancelled:
                Task { await self.handleClosed(connection, error: nil) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        self.connection = connection
    }

    /// Picks which discovered Mac to dial next and connects to it — the LAN
    /// counterpart of `attemptDirectConnect()`. Threaded through
    /// `preferredEndpoint(among:preferring:)` (gap #5) rather than
    /// `results.first` directly, so a reconnect after a drop prefers the
    /// same Mac this client was already talking to.
    private func connectToPreferredBrowseResult(_ endpoints: [NWEndpoint]) {
        guard let endpoint = Self.preferredEndpoint(among: endpoints, preferring: lastConnectedServiceIdentity) else { return }
        connect(to: endpoint, parameters: Self.lanParameters())
    }

    /// Maps the browser's raw endpoints through `discoveredMacs(from:)` and
    /// hands the result to `discoveredMacsHandler`, if one is set. A thin
    /// actor-isolated wrapper around a pure function purely so the mapping
    /// itself stays testable without a live `NWBrowser` — see
    /// `LocalSyncClientTests`.
    private func publishDiscoveredMacs(_ endpoints: [NWEndpoint]) {
        discoveredMacsHandler?(Self.discoveredMacs(from: endpoints))
    }

    /// Explicitly connects to a Mac the user picked from
    /// `SettingsTabView`'s multi-Mac picker, rather than whichever endpoint
    /// `connectToPreferredBrowseResult`/`retryConnectFromBrowserResults`
    /// would otherwise choose. Two things happen, matching this type's
    /// existing "sticky reconnect" contract (`preferredEndpoint(among:
    /// preferring:)`'s doc comment):
    ///
    /// 1. `lastConnectedServiceIdentity` is updated to the chosen Mac
    ///    *before* dialing it, so a drop five minutes from now reconnects to
    ///    the Mac the user deliberately picked, not silently back to
    ///    whichever one this client happened to be talking to before — the
    ///    same "don't silently switch Macs" principle `preferredEndpoint`
    ///    exists for, just applied to a deliberate user choice instead of an
    ///    automatic first-connect.
    /// 2. Any existing connection is torn down first. `connect(to:
    ///    parameters:isDirect:)` is guarded by `!isConnecting, !isReady`
    ///    specifically to stop two dial attempts from racing each other, but
    ///    that guard would also block this deliberate switch while already
    ///    connected to a *different* Mac — so this resets that state
    ///    up front, the one place in this type allowed to bypass the guard,
    ///    because a user-initiated switch is exactly the case where "already
    ///    connected" shouldn't win.
    public func switchTo(discovered mac: DiscoveredMac) {
        lastConnectedServiceIdentity = mac.id
        connection?.cancel()
        connection = nil
        isReady = false
        isConnecting = false
        connectionStateHandler?(false)
        connect(to: mac.endpoint, parameters: Self.lanParameters())
    }

    private func handleReady(_ connection: NWConnection) {
        guard connection === self.connection else { return }
        isConnecting = false
        isReady = true
        if connectionIsDirect {
            // A successful direct connection means whatever failure reason
            // was showing (wrong code / unreachable) is stale — clear it
            // rather than leaving it to linger next to a working connection.
            directConnectFailureHandler?(nil)
        } else if let identity = Self.serviceIdentity(for: connection.endpoint) {
            lastConnectedServiceIdentity = identity
        }
        resumeReadyWaiters(found: true)
        connectionStateHandler?(true)
        receiveNext(on: connection)
    }

    private func handleClosed(_ connection: NWConnection, error: NWError?) {
        guard connection === self.connection else { return }
        isConnecting = false
        isReady = false
        self.connection = nil
        resumeReadyWaiters(found: false)
        connectionStateHandler?(false)
        if connectionIsDirect {
            directConnectFailureHandler?(Self.classifyDirectConnectFailure(error))
        }
        // Discovery keeps running (the browser wasn't stopped), so a
        // reconnect happens when `browseResultsChangedHandler` next fires —
        // but a bare TCP drop (Mac app crash, socket reset) often leaves
        // the Bonjour result set UNCHANGED, and that handler only fires on
        // changes. The retry loop below covers that gap by re-attempting
        // against whatever the browser currently sees, backing off between
        // tries, until either a connection lands or `stop()` runs.
        Task { await self.retryConnectFromBrowserResults() }
    }

    /// Re-attempts a connection against the browser's current result set —
    /// see `handleClosed`. Gives up silently when discovery has been
    /// stopped, a connection attempt is already in flight, or there is
    /// nothing to connect to (the next results-changed event covers that).
    /// Uses `preferredEndpoint(among:preferring:)` for the same reason
    /// `connectToPreferredBrowseResult` does — a drop shouldn't silently
    /// reconnect to a *different* Mac just because `NWBrowser.browseResults`
    /// (a `Set`) happens to enumerate in a different order this time.
    private func retryConnectFromBrowserResults() async {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard browser != nil, connection == nil, !isConnecting, !isReady else { return }
        let endpoints = (browser?.browseResults ?? []).map(\.endpoint)
        guard let endpoint = Self.preferredEndpoint(among: endpoints, preferring: lastConnectedServiceIdentity) else { return }
        connect(to: endpoint, parameters: Self.lanParameters())
    }

    // MARK: - Pure helpers (unit-tested directly — see `LocalSyncClientTests`)

    /// Extracts a Bonjour service's advertised name from an `NWEndpoint`,
    /// or `nil` for any endpoint that isn't a `.service` case (e.g. a
    /// direct `.hostPort` dial). Endpoint `Equatable`/`Hashable` conformance
    /// is stricter than "same service" — it also factors in domain/
    /// interface, which can legitimately differ between two browse results
    /// for the very same Mac — so "same service" is decided by name alone.
    public static func serviceIdentity(for endpoint: NWEndpoint) -> String? {
        if case let .service(name, _, _, _) = endpoint {
            return name
        }
        return nil
    }

    /// Chooses which discovered endpoint to (re)connect to: the one whose
    /// service name matches `preferredIdentity` if it's still present in
    /// `endpoints`, falling back to `endpoints.first` otherwise (no
    /// preference yet, or that Mac is no longer being advertised at all —
    /// nothing to prefer). A pure function, deliberately free of any
    /// `Network.framework` I/O or actor isolation, so `LocalSyncClientTests`
    /// can exercise the "don't silently switch Macs on a drop" behavior
    /// (gap #5) with fabricated `NWEndpoint.service` values instead of a
    /// live `NWBrowser`.
    ///
    /// This is intentionally still "prefer one, not a picker" — a real
    /// multi-Mac UI that lets a user choose between several simultaneously
    /// advertised Macs is out of scope here (see this type's top-level doc
    /// comment); this only stops a *drop* from silently landing on a
    /// different Mac than the one the user was already connected to.
    public static func preferredEndpoint(among endpoints: [NWEndpoint], preferring preferredIdentity: String?) -> NWEndpoint? {
        if let preferredIdentity, let match = endpoints.first(where: { serviceIdentity(for: $0) == preferredIdentity }) {
            return match
        }
        return endpoints.first
    }

    /// Maps raw browse-result endpoints to the list `SettingsTabView`'s
    /// multi-Mac picker actually renders — the real feature this pass adds
    /// on top of `preferredEndpoint(among:preferring:)`'s "prefer one"
    /// logic. Three things this does that a bare `endpoints.map(...)`
    /// wouldn't:
    ///
    /// 1. Drops any endpoint `serviceIdentity(for:)` can't name (a direct/
    ///    remote `.hostPort` dial never reaches this function in practice,
    ///    but the filter keeps the mapping honest regardless of caller).
    /// 2. De-duplicates by service name. A single Mac can legitimately
    ///    appear as more than one `NWBrowser.Result` — e.g. advertised over
    ///    both Wi-Fi and a wired interface — and a picker listing "Malek's
    ///    MacBook Pro" twice would look like a bug, not two real Macs.
    /// 3. Sorts by name. `NWBrowser.browseResults` is a `Set` (see this
    ///    type's top-level doc comment on why "first" isn't a stable
    ///    notion) — left unsorted, the picker's row order would reshuffle
    ///    on every unrelated browse-results update, which reads as broken
    ///    even though nothing about the underlying Macs changed.
    ///
    /// A pure function, deliberately free of any `Network.framework` I/O or
    /// actor isolation, so `LocalSyncClientTests` can exercise it with
    /// fabricated `NWEndpoint.service` values the same way it already does
    /// for `preferredEndpoint(among:preferring:)`.
    public static func discoveredMacs(from endpoints: [NWEndpoint]) -> [DiscoveredMac] {
        var seenNames = Set<String>()
        var macs: [DiscoveredMac] = []
        for endpoint in endpoints {
            guard let name = serviceIdentity(for: endpoint), seenNames.insert(name).inserted else { continue }
            macs.append(DiscoveredMac(id: name, endpoint: endpoint))
        }
        return macs.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// The picker-gating rule `SettingsTabView` uses to decide whether to
    /// show any multi-Mac UI at all: only when there is genuinely something
    /// to choose between. The common case — one Mac on the household
    /// network, or none yet discovered — renders no picker at all, matching
    /// this pass's brief not to clutter that case with UI it doesn't need.
    public static func hasMultipleMacs(_ macs: [DiscoveredMac]) -> Bool {
        macs.count > 1
    }

    /// Whether tapping `mac` in the picker is a real switch (a different Mac
    /// than the one currently connected) as opposed to re-tapping the row
    /// that's already marked selected. `SettingsTabView` uses this purely to
    /// skip the round trip through `AppDataSource.switchToDiscoveredMac(_:)`
    /// for a no-op tap; `switchTo(discovered:)` itself is idempotent either
    /// way, so this is an optimization/clarity helper, not a correctness
    /// requirement.
    public static func isSwitchingMac(from currentIdentity: String?, to mac: DiscoveredMac) -> Bool {
        currentIdentity != mac.id
    }

    /// Classifies why a *direct* (remote, TLS-PSK) connection attempt
    /// failed, so `attemptDirectConnect()`'s retry loop can tell a wrong
    /// pairing code apart from an unreachable Mac (gap #2) instead of both
    /// looking like an identical "still trying…" forever.
    ///
    /// **The heuristic, and why it's good enough.** `SyncSecurity.tlsOptions
    /// (pairingCode:)` is the *only* thing this connection's TLS layer does
    /// — there is no certificate validation, no ALPN negotiation, nothing
    /// else that could produce a `.tls` failure on this specific listener.
    /// So on this narrowly-scoped path, any `NWError.tls` case reaching here
    /// is the PSK handshake rejecting a key derived from the wrong code;
    /// every other `NWError` case (`.posix` timeout/refused/host-unreachable,
    /// `.dns`, or no error at all from a plain `.cancelled`) means the TLS
    /// layer was never reached at all, i.e. the transport itself couldn't
    /// get through. Network.framework does not expose a more specific
    /// "PSK mismatch" case to distinguish further, and inspecting the
    /// underlying `OSStatus` inside `.tls`'s associated value would tie this
    /// to Security-framework error codes that aren't part of any documented,
    /// stable contract — rejected as more fragile than the coarser but
    /// reliable "any TLS failure here is a PSK failure" rule.
    public static func classifyDirectConnectFailure(_ error: NWError?) -> DirectConnectFailureReason {
        guard let error else { return .unreachable }
        switch error {
        case .tls:
            return .wrongPairingCode
        default:
            return .unreachable
        }
    }

    // MARK: - Receiving + framing

    private func receiveNext(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                await self.handleReceive(connection: connection, data: data, isComplete: isComplete, error: error)
            }
        }
    }

    private func handleReceive(connection: NWConnection, data: Data?, isComplete: Bool, error: NWError?) {
        guard connection === self.connection else { return }

        if let data, !data.isEmpty {
            receiveBuffer.append(data)
            do {
                let (messages, remainder) = try LocalSyncFraming.extractFrames(from: receiveBuffer)
                receiveBuffer = remainder
                for message in messages {
                    handle(message)
                }
            } catch {
                log.error("LocalSyncClient: malformed frame, closing connection: \(String(describing: error))")
                connection.cancel()
                return
            }
        }

        if let error {
            log.error("LocalSyncClient: receive error: \(String(describing: error))")
            connection.cancel()
            return
        }
        guard !isComplete else {
            connection.cancel()
            return
        }
        receiveNext(on: connection)
    }

    /// Routes a decoded `LocalSyncMessage` to whichever consumer it's for:
    /// `.snapshot` fans out to every open `snapshots()` stream (the original
    /// behavior); `.status` resolves the matching
    /// `awaitStatus(forNonce:timeout:)` waiter, if one is still pending.
    /// `.command` never arrives here — the Mac is never the one sending a
    /// command over this connection — so it's logged and ignored rather than
    /// treated as a protocol violation, matching `LocalSyncServer
    /// .handle(_:from:)`'s identical posture for the frames it doesn't
    /// expect.
    private func handle(_ message: LocalSyncMessage) {
        switch message {
        case .snapshot(let snapshot):
            lastReceivedAt = Date()
            lastDeviceID = snapshot.deviceID
            for continuation in continuations.values {
                continuation.yield(snapshot)
            }
        case .status(let status):
            if let waiter = statusWaiters.removeValue(forKey: status.respondsToNonce) {
                waiter.resume(returning: status)
            }
        case .command:
            log.debug("LocalSyncClient: received an unexpected command frame from the Mac — ignoring")
        }
    }

    /// The `deviceID` of the most recent snapshot this instance has
    /// actually decoded, or `nil` if none has arrived yet. Not part of
    /// `StatsTransport` — see `AppDataSource.devices()`'s doc comment for
    /// the one caller that uses this to synthesize a minimal device catalog
    /// entry for the local-sync case.
    public func lastKnownDeviceID() async -> String? {
        lastDeviceID
    }

    // MARK: - StatsTransport

    /// A fresh stream fanned out from the single underlying `NWConnection`,
    /// matching `StatsTransport.snapshots()`'s documented contract (and
    /// `StatsCoordinator.snapshots()`'s identical pattern this mirrors).
    /// `nonisolated` for the same reason `MockDataSource.snapshots()` is:
    /// `StatsTransport.snapshots()` is a synchronous, non-`async`
    /// requirement, so callers must get the stream back immediately without
    /// awaiting into the actor first. The actual fan-out registration
    /// happens inside a `Task` hopping onto the actor, same technique
    /// `StatsCoordinator.snapshots()` uses via `queue.async`.
    public nonisolated func snapshots() -> AsyncStream<SystemSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            Task {
                await self.registerContinuation(id: id, continuation: continuation)
            }
            continuation.onTermination = { _ in
                Task {
                    await self.unregisterContinuation(id: id)
                }
            }
        }
    }

    private func registerContinuation(id: UUID, continuation: AsyncStream<SystemSnapshot>.Continuation) {
        continuations[id] = continuation
    }

    private func unregisterContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    /// Time since the last snapshot this instance actually received and
    /// decoded, or `.infinity` if none has arrived yet — mirroring
    /// `MockDataSource.freshness()`'s "no upstream to be fresh relative to
    /// yet" convention for the not-yet-connected case, rather than reporting
    /// `0` (which would read as "just synced" when nothing has synced at
    /// all).
    public func freshness() async -> TimeInterval {
        guard let lastReceivedAt else { return .infinity }
        return Date().timeIntervalSince(lastReceivedAt)
    }

    /// Frames `command` and writes it onto the live connection to the Mac,
    /// where `LocalSyncServer`'s receive loop hands it to
    /// `LocalCommandExecutor` (`SentryKit/Services/LocalCommandExecutor.swift`).
    /// Works identically over the LAN (Bonjour) and remote (TLS-PSK)
    /// connections — this method only needs *a* live connection, and by the
    /// time one exists a remote client has already authenticated during the
    /// TLS handshake.
    ///
    /// Throws `LocalSyncClientError.notConnected` when there's no open
    /// connection right now, rather than silently dropping the command —
    /// the same "say so, don't pretend" posture `MockDataSource
    /// .send(command:)` documents, now with a real success path alongside
    /// the honest failure one. Call `awaitStatus(forNonce:timeout:)`
    /// afterward to learn what the Mac actually did with it.
    public func send(command: ControlCommand) async throws {
        guard let connection, isReady else {
            throw LocalSyncClientError.notConnected(
                "Not connected to a Mac right now — nothing to send this command to."
            )
        }
        let framed = try LocalSyncFraming.encode(.command(command))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Waits up to `timeout` seconds for the `ControlStatus` reply whose
    /// `respondsToNonce` matches `nonce` — what `LocalSyncServer` sends back
    /// once `LocalCommandExecutor` has finished acting on that command.
    /// Returns `nil` on timeout (the Mac never replied — a dropped
    /// connection, a Mac running a build without command support, or simply
    /// a slow reply) rather than throwing, because "no reply yet" is an
    /// outcome callers (`KeepAwakeIntent`, `SleepStatusCard`) must render
    /// honestly, not an exceptional failure.
    public func awaitStatus(forNonce nonce: String, timeout: TimeInterval) async -> ControlStatus? {
        await withCheckedContinuation { continuation in
            statusWaiters[nonce] = continuation
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                await self.timeoutStatusWaiter(forNonce: nonce)
            }
        }
    }

    private func timeoutStatusWaiter(forNonce nonce: String) {
        guard let waiter = statusWaiters.removeValue(forKey: nonce) else { return }
        waiter.resume(returning: nil)
    }
}

/// One Mac currently visible over Bonjour, as surfaced to
/// `SettingsTabView`'s multi-Mac picker via `LocalSyncClient
/// .setDiscoveredMacsHandler(_:)` and `AppDataSource.discoveredMacs`. LAN/
/// Bonjour-scoped only — see `LocalSyncClient.discoveredMacs(from:)`'s doc
/// comment for how the list is built, and this type's top-level doc comment
/// for why the remote (TLS-PSK) path is explicitly out of scope for any of
/// this: that path is dialed by a single user-entered host:port, not
/// discovered, so there is nothing to pick between there.
public struct DiscoveredMac: Identifiable, Equatable, Sendable {
    /// The Bonjour service name, doubling as this list's stable identity —
    /// the same string `LocalSyncClient.serviceIdentity(for:)` extracts and
    /// `preferredEndpoint(among:preferring:)` matches on, so "the Mac the
    /// picker shows as selected" and "the Mac a reconnect prefers" are
    /// always the same notion of identity.
    public let id: String

    /// The endpoint this entry resolves to right now — passed back to
    /// `LocalSyncClient.switchTo(discovered:)` to actually dial it. Not
    /// `Equatable`-compared beyond what `NWEndpoint`'s own conformance does;
    /// `DiscoveredMac`'s `Equatable` conformance (needed for SwiftUI diffing
    /// in the picker list) is otherwise driven entirely by `id`, since two
    /// browse results for the same Mac can differ in interface/domain while
    /// still meaning "the same Mac" for display purposes.
    public let endpoint: NWEndpoint

    public init(id: String, endpoint: NWEndpoint) {
        self.id = id
        self.endpoint = endpoint
    }

    /// What the picker actually renders. Just `id` today — Bonjour's
    /// advertised name (e.g. "Malek's MacBook Pro") already reads as a
    /// display name with no further formatting needed — but kept as a
    /// separate computed property rather than having call sites read `id`
    /// directly, so a future change to how names are presented has one
    /// place to change.
    public var displayName: String { id }
}

/// Why a *direct* (remote, TLS-PSK) connection attempt failed — see
/// `LocalSyncClient.classifyDirectConnectFailure(_:)` for how one is chosen,
/// and `directConnectFailureHandler` for how it reaches `AppDataSource` and
/// then `SettingsTabView`. Deliberately has no `.unknown`/`.other` case:
/// every `NWError` this connection can produce falls cleanly into one of
/// these two buckets per the classifier's doc comment, and a third bucket
/// with no distinct UI message would just be a confusing thing to render.
public enum DirectConnectFailureReason: Sendable, Equatable {
    /// The TLS-PSK handshake completed the round trip but was rejected —
    /// the pairing code typed into `SettingsTabView`'s "Remote Mac" fields
    /// doesn't match the one the Mac is listening with.
    case wrongPairingCode
    /// The transport itself never got far enough to attempt a handshake —
    /// connection timed out, was refused, or the host couldn't be resolved.
    /// Usually means the Mac is asleep, off the configured network, or the
    /// address/port is simply wrong.
    case unreachable
}

/// Errors specific to `LocalSyncClient` — transport-level "can't do that
/// right now" conditions callers are expected to render honestly.
public enum LocalSyncClientError: Error, LocalizedError, Sendable {
    case notConnected(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected(let message):
            return message
        }
    }
}
