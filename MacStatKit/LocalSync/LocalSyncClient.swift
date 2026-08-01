import Foundation
import Network
import os.log

// MARK: - LocalSyncClient: the receiving side of the local-network (Bonjour) transport

/// A `StatsTransport` conformer (`MacStatKit/Sync/StatsTransport.swift`)
/// that discovers a Mac running `LocalSyncServer`
/// (`MacStatKit/LocalSync/LocalSyncServer.swift`) on the local Wi-Fi network
/// via Bonjour and streams the framed `SystemSnapshot`s it sends. This is
/// "v4" from `StatsTransport.swift`'s doc comment — built and usable today
/// specifically *because* it needs no Apple Developer Program enrollment,
/// unlike the CloudKit transport ("v2") that protocol was originally
/// written for.
///
/// **Cross-platform, but really an iOS type.** `Network.framework` works
/// identically on macOS and iOS, so this file compiles on both (no `#if
/// os(...)` guard, unlike `LocalSyncServer`, which is macOS-only because
/// only the Mac app runs a server). In practice only `MacStatMobile`
/// constructs one — the Mac has no reason to browse for itself.
///
/// **Known simplification: first-found, not a real picker.** Bonjour
/// browsing can surface more than one `_macstat._tcp` service on a
/// household network with more than one Mac. A real multi-Mac experience
/// would show a picker and let the user choose (and remember the choice).
/// That UI doesn't exist yet, and building it is out of scope for this
/// pass — this type connects to whichever result `NWBrowser` reports first
/// and stays connected to it for the lifetime of the instance. Documented
/// here rather than hidden, per this codebase's "say plainly what doesn't
/// work" convention (see `SettingsTabView`'s doc comment for the canonical
/// example of that discipline).
///
/// **Receive-only for this first pass.** `send(command:)` and
/// `upload(_:)` both `throw` — see their doc comments below — rather than
/// silently no-op-ing the way `MockDataSource`'s conformer does.
/// `MockDataSource` no-ops because there is genuinely nothing on the other
/// end to fail to reach; this type *is* connected to a real Mac, so
/// silently swallowing a command would misrepresent a real, working
/// connection as having done something it didn't. `AlertAction
/// .pushToPhone`/`.runShortcut` in `MacStatKit/Services/AlertRule.swift`
/// establish the same "throw/say-so rather than pretend" posture this
/// follows.
///
/// **Why an `actor`, matching `MockDataSource`.** `StatsTransport` requires
/// `Sendable` conformers (see that protocol's doc comment, point 3); an
/// actor is the natural way to hold mutable state (the current connection,
/// the fan-out continuations, `lastReceivedAt`) safely across the
/// concurrent contexts `Network.framework`'s callback-based API calls in
/// from.
public actor LocalSyncClient: StatsTransport {

    /// Must match `LocalSyncServer.serviceType` exactly.
    public static let serviceType = "_macstat._tcp"

    private let log = Logger(subsystem: "dev.malekswilam.macstat.mobile", category: "LocalSyncClient")
    private let queue = DispatchQueue(label: "dev.malekswilam.macstat.localsyncclient")

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
    /// `devices()` catalog (`MacStatMobile/Data/AppDataSource.swift`), since
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

    /// Wall-clock time of the most recently decoded snapshot, or nil —
    /// lets `AppDataSource.devices()` report an honest `lastSeen` instead
    /// of stamping catalog-fetch time.
    public func lastSnapshotDate() async -> Date? {
        lastReceivedAt
    }

    public init() {}

    deinit {
        browser?.cancel()
        directRetryTask?.cancel()
        connection?.cancel()
        for continuation in continuations.values { continuation.finish() }
    }

    // MARK: - Discovery + connection lifecycle

    /// Starts browsing for `_macstat._tcp` and connects to the first result.
    /// Safe to call more than once — a second call while already
    /// browsing/connected is a no-op. Called from `waitForFirstConnection
    /// (timeout:)` (the composition root's normal entry point) but also
    /// exposed directly for callers that want to kick off discovery without
    /// blocking on the result.
    /// Registers the remote fallback endpoint. Call before `start()` (or
    /// `waitForFirstConnection`); passing an empty host or code clears it.
    /// Bonjour remains the preferred path — same network means lower
    /// latency and no round trip through a tunnel — the direct endpoint is
    /// dialed only while no connection exists.
    public func configureDirectEndpoint(host: String, port: UInt16, pairingCode: String) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = SyncSecurity.normalize(pairingCode)
        guard !trimmedHost.isEmpty, !code.isEmpty, port > 0 else {
            directConfig = nil
            return
        }
        directConfig = (trimmedHost, port, code)
    }

    public func start() {
        guard browser == nil else { return }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: Self.serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, let first = results.first else { return }
            Task { await self.connect(to: first.endpoint, parameters: Self.lanParameters()) }
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

    private static func lanParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        return parameters
    }

    /// Dials the configured remote endpoint every few seconds while no
    /// connection exists, for as long as the client is started. A failed
    /// TLS handshake (wrong pairing code) surfaces as an ordinary failed
    /// connection — the loop just tries again later, and Bonjour keeps
    /// racing it; whichever path connects first wins.
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
        connect(to: endpoint, parameters: SyncSecurity.remoteParameters(pairingCode: config.code))
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
        resumeReadyWaiters(found: false)
    }

    /// Starts discovery (if not already running) and suspends until either
    /// a connection to a discovered Mac becomes ready, or `timeout` elapses
    /// — whichever comes first. Returns `true` if a connection was made in
    /// time, `false` otherwise.
    ///
    /// This is the method the iOS composition root (`AppDataSource`,
    /// `MacStatMobile/Data/AppDataSource.swift`) calls at launch: it needs a
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

    private func connect(to endpoint: NWEndpoint, parameters: NWParameters) {
        guard !isConnecting, !isReady else { return }
        isConnecting = true

        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { await self.handleReady(connection) }
            case .failed, .cancelled:
                Task { await self.handleClosed(connection) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        self.connection = connection
    }

    private func handleReady(_ connection: NWConnection) {
        guard connection === self.connection else { return }
        isConnecting = false
        isReady = true
        resumeReadyWaiters(found: true)
        connectionStateHandler?(true)
        receiveNext(on: connection)
    }

    private func handleClosed(_ connection: NWConnection) {
        guard connection === self.connection else { return }
        isConnecting = false
        isReady = false
        self.connection = nil
        resumeReadyWaiters(found: false)
        connectionStateHandler?(false)
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
    private func retryConnectFromBrowserResults() async {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard browser != nil, connection == nil, !isConnecting, !isReady else { return }
        guard let first = browser?.browseResults.first else { return }
        connect(to: first.endpoint, parameters: Self.lanParameters())
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
                let (snapshots, remainder) = try LocalSyncFraming.extractFrames(from: receiveBuffer)
                receiveBuffer = remainder
                for snapshot in snapshots {
                    lastReceivedAt = Date()
                    lastDeviceID = snapshot.deviceID
                    for continuation in continuations.values {
                        continuation.yield(snapshot)
                    }
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

    /// Always throws. This transport is receive-only for its first pass —
    /// see this type's top-level doc comment for why that's a deliberate,
    /// documented cut rather than a silent no-op: a phone connected to a
    /// real Mac over this channel that silently dropped a "keep awake"
    /// command would look, from the user's side, exactly like a command
    /// that was sent and ignored, which is worse than an explicit failure a
    /// caller can surface. Remote command support (and the keep-awake
    /// control this would carry) is separate, later work.
    public func send(command: ControlCommand) async throws {
        throw LocalSyncClientError.notSupported(
            "Sending commands is not supported over the local-network transport yet — this connection only carries snapshots from the Mac to this phone, not commands the other direction."
        )
    }

    /// Always throws, for the same reason as `send(command:)`. Uploading
    /// isn't a meaningful concept for this transport at all: the phone has
    /// nothing of its own to upload to the Mac over a local-network
    /// connection the way it would to a shared CloudKit container — the Mac
    /// is the sole source of `SystemSnapshot` data on this channel.
    public func upload(_ batch: UploadBatch) async throws {
        throw LocalSyncClientError.notSupported(
            "Uploading is not supported over the local-network transport — this transport only receives snapshots, it has no shared store to upload into."
        )
    }
}

/// Errors specific to `LocalSyncClient`, kept separate from
/// `StatsTransport`-level errors (`UploadError`, defined alongside
/// `SyncService`) since they describe *transport-level* unsupported
/// operations, not a CloudKit-shaped upload failure.
public enum LocalSyncClientError: Error, LocalizedError, Sendable {
    case notSupported(String)

    public var errorDescription: String? {
        switch self {
        case .notSupported(let message):
            return message
        }
    }
}
