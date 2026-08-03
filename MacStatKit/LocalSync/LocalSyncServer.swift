#if os(macOS)
import Foundation
import Network
import os.log

// MARK: - LocalSyncServer: the Mac side of the local-network (Bonjour) transport

/// Advertises this Mac on the local Wi-Fi network via Bonjour
/// (`_macstat._tcp`) and streams live `SystemSnapshot`s to any connected
/// iPhone, framed per `LocalSyncFraming.swift`. This is the concrete thing
/// `StatsTransport.swift`'s doc comment calls "v4 ... an optional
/// local-network (Bonjour) fast path" — built and shipped ahead of CloudKit
/// (v2) because it needs no Apple Developer Program enrollment at all, just
/// `Network.framework` and a Bonjour service type, both available today.
///
/// **Why this doesn't conform to `StatsTransport`.** `StatsTransport` is the
/// *receiving* side's abstraction (see its own doc comment: "this stream
/// exists for the receiving side ... to read what the transport last saw").
/// The Mac is the sender here, not a receiver of anyone else's snapshots —
/// there is no symmetric protocol need for the Mac side, the same way
/// `MCPXPCService` (the other place this process streams `SystemSnapshot`
/// data to an external process) isn't typed against `StatsTransport`
/// either. `LocalSyncClient` (`MacStatKit/LocalSync/LocalSyncClient.swift`)
/// is the `StatsTransport` conformer, on the iPhone side, where that
/// abstraction actually applies.
///
/// **Feed source.** Constructed with a snapshot-providing `AsyncStream`
/// rather than owning any collection logic itself — `AppDelegate` feeds it
/// from `StatsCoordinator.snapshots()`, the exact same stream
/// `historyStore`/`dropdownViewModel`/`dashboardViewModel` already consume
/// independently (plan §3.2 P3: one poll loop, many consumers). This type
/// is simply one more consumer, not a second poll loop.
///
/// **Throttling.** The coordinator can tick faster than once a second for
/// its fast-tier metrics; this server does not forward every tick to every
/// client at that rate. Each connection tracks its own "last sent at" time
/// and skips a tick if less than `minSendInterval` has elapsed since its
/// last send — a plain per-connection check, not a shared timer, so one
/// slow/just-connected client's catch-up doesn't affect another's cadence.
///
/// **Multiple clients.** `connections` holds every currently-open
/// `NWConnection`, keyed by `ObjectIdentifier` — a family with more than one
/// iPhone (or the same phone reconnecting after a network blip) is the
/// normal case, not an edge case. A connection that fails or is cancelled
/// removes itself from the dictionary via its `stateUpdateHandler`, so a
/// dead connection is never retried against.
///
/// **Bidirectional as of `commandHandler`.** Originally this type only ever
/// wrote to its connections (snapshots out); it now also reads from them, so
/// a `ControlCommand` sent by `LocalSyncClient.send(command:)` — from an
/// iPhone Siri intent, an Apple Watch intent relayed through the phone, or
/// the iPhone's own sleep card — reaches a real `PowerControlService` here.
/// See `receiveNext(on:)` and `LocalCommandExecutor`
/// (`MacStatKit/Services/LocalCommandExecutor.swift`).
///
/// **Reads and writes have deliberately different trust requirements.**
/// Both listeners feed one connection pool and both receive the snapshot
/// broadcast, but only connections accepted by the TLS-PSK `remoteListener`
/// may issue commands (`ConnectionState.isAuthenticated`). Streaming
/// read-only telemetry to an unauthenticated device on the same Wi-Fi is
/// the bargain this listener was always designed around; letting that same
/// device hold the machine awake indefinitely, or drop its keep-awake
/// mid-render, is not — control is a materially larger grant than
/// observation, so it requires proof of the pairing code even on the LAN.
/// Users who want control at home turn on Remote Access and pair once; that
/// listener is reachable over the local network too, not only from outside
/// it.
public final class LocalSyncServer: @unchecked Sendable {

    /// Must match `LocalSyncClient`'s browse type exactly — Bonjour service
    /// types are matched as opaque strings, not semantically.
    public static let serviceType = "_macstat._tcp"

    /// Matches `LocalSyncFraming`'s "roughly once per second" throttle
    /// target described in this type's own doc comment above.
    private let minSendInterval: TimeInterval = 1.0

    /// Hard ceiling on simultaneously-open client connections.
    ///
    /// This listener accepts **unauthenticated** connections from anything
    /// that can reach this Mac on the local network (see this type's doc
    /// comment — there is no pairing step, and the payload is read-only
    /// telemetry), so "how many clients" is not a number any trusted party
    /// controls: a hostile device on the same Wi-Fi can open sockets in a
    /// loop. Without a cap, `connections` and the per-connection send
    /// buffers grow until the app runs out of file descriptors or memory,
    /// turning a read-only telemetry feed into a remote crash of the whole
    /// menu-bar app. 16 is far above any real household (a few iPhones,
    /// iPads, reconnect churn) and far below anything that hurts.
    private static let maxConcurrentConnections = 16

    private let queue = DispatchQueue(label: "com.sentry.macstat.localsyncserver")
    private let log = Logger(subsystem: "com.sentry.macstat", category: "LocalSyncServer")

    private var listener: NWListener?

    /// The optional second listener behind "view this Mac from another
    /// network": a fixed, user-configured port speaking TLS-PSK (see
    /// `SyncSecurity`) instead of the Bonjour listener's plaintext-on-LAN.
    /// Connections accepted here join the same `connections` pool, the
    /// same broadcast path, and the same `maxConcurrentConnections` cap —
    /// the transports differ only in how a client reaches and
    /// authenticates to them.
    private var remoteListener: NWListener?

    private var feedTask: Task<Void, Never>?

    /// One entry per open connection. `lastSendDate` is `nil` until the
    /// first snapshot has actually been sent, so a just-connected client
    /// always receives the very next snapshot immediately rather than
    /// waiting out `minSendInterval` for no reason.
    /// `receiveBuffer` accumulates raw bytes for this connection's own
    /// receive loop, same role as `LocalSyncClient.receiveBuffer` but
    /// per-connection here since one server holds several open at once.
    private final class ConnectionState {
        let connection: NWConnection
        var lastSendDate: Date?
        var receiveBuffer = Data()

        /// Whether this connection proved knowledge of the pairing code.
        /// True only for connections accepted by the TLS-PSK
        /// `remoteListener` — reaching `.ready` there *is* the proof, since
        /// the handshake fails closed without the derived key (see
        /// `SyncSecurity`). Always false for the plaintext Bonjour
        /// listener. Gates `.command` frames only; snapshot broadcast is
        /// unaffected.
        let isAuthenticated: Bool

        init(connection: NWConnection, isAuthenticated: Bool) {
            self.connection = connection
            self.isAuthenticated = isAuthenticated
        }
    }

    private var connections: [ObjectIdentifier: ConnectionState] = [:]

    /// Invoked for every `.command` frame received from any connected
    /// phone/watch-via-phone; its returned `ControlStatus` is framed and
    /// sent straight back on the connection the command arrived on. `nil`
    /// (the default) means commands are decoded but dropped with no reply —
    /// the state `AppDelegate` is in before it constructs a
    /// `LocalCommandExecutor` and assigns this, so tests/previews that only
    /// exercise the snapshot-broadcast half don't need to supply one.
    /// `async` because `LocalCommandExecutor.execute(_:)` is `@MainActor`.
    ///
    /// Not `@Sendable`: this type is already `@unchecked Sendable` as a
    /// whole, and the closure `AppDelegate` assigns captures a
    /// `@MainActor`-isolated executor, which a `@Sendable`-typed closure
    /// would reject without ceremony for no real safety gain — every call
    /// site (`handle(_:from:)`, inside its own `Task`) already hops off this
    /// type's serial `queue` before invoking it.
    public var commandHandler: ((ControlCommand) async -> ControlStatus)?

    /// `serviceName` is what shows up in Bonjour browse results on the
    /// phone — the device's own name (e.g. "Malek's MacBook Pro") is the
    /// obvious choice so a multi-Mac household can eventually tell services
    /// apart, even though `LocalSyncClient`'s first pass (documented on
    /// that type) just connects to whichever result arrives first.
    public init(serviceName: String) {
        self.serviceName = serviceName
    }

    private let serviceName: String

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Starts the `NWListener`, advertises the Bonjour service, and begins
    /// forwarding every snapshot from `source` to every currently-open
    /// connection. Safe to call once; calling again while already running
    /// is a no-op (`stop()` first to restart).
    public func start(feedingFrom source: AsyncStream<SystemSnapshot>) {
        guard listener == nil else { return }

        let params = NWParameters.tcp
        params.includePeerToPeer = true

        guard let listener = try? NWListener(using: params) else {
            log.error("LocalSyncServer: failed to create NWListener")
            return
        }
        listener.service = NWListener.Service(name: serviceName, type: Self.serviceType)

        // Plaintext LAN listener — read-only by policy. Commands arriving
        // here are refused with an explanatory `ControlStatus`, never
        // executed. See `handle(_:from:)`.
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, isAuthenticated: false)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.log.error("LocalSyncServer: listener failed: \(String(describing: error))")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener

        feedTask = Task { [weak self] in
            for await snapshot in source {
                self?.broadcast(snapshot)
            }
        }
    }

    /// Tears down the listener and every open connection. Idempotent.
    public func stop() {
        feedTask?.cancel()
        feedTask = nil
        listener?.cancel()
        listener = nil
        disableRemote()
        queue.sync {
            for state in connections.values {
                state.connection.cancel()
            }
            connections.removeAll()
        }
    }

    // MARK: - Remote (off-LAN) listener

    /// Opens the TLS-PSK listener on `port`. Reachability from another
    /// network is the *user's* arrangement (Tailscale/VPN, or a router
    /// port-forward) — this Mac only ever opens the port; it never punches
    /// holes or talks to any relay. Idempotent per configuration: calling
    /// again with the same port+code is a no-op, a changed configuration
    /// tears the old listener down first.
    public func enableRemote(port: UInt16, pairingCode: String) {
        let normalized = SyncSecurity.normalize(pairingCode)
        guard !normalized.isEmpty else {
            log.error("LocalSyncServer: refusing remote listener with empty pairing code")
            return
        }
        if let current = remoteConfig, current.port == port, current.code == normalized {
            return
        }
        disableRemote()

        let params = SyncSecurity.remoteParameters(pairingCode: pairingCode)
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: params, on: nwPort) else {
            log.error("LocalSyncServer: failed to open remote listener on port \(port)")
            return
        }
        // Reaching `.ready` on this listener means the TLS-PSK handshake
        // succeeded, which is itself proof the client holds the pairing
        // code — so these connections are the authenticated ones, and the
        // only ones allowed to issue commands.
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, isAuthenticated: true)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.log.error("LocalSyncServer: remote listener failed: \(String(describing: error))")
            }
        }
        listener.start(queue: queue)
        remoteListener = listener
        remoteConfig = (port, normalized)
        log.info("LocalSyncServer: remote listener open on port \(port)")
    }

    /// Closes the remote listener. Existing remote connections are left to
    /// drain naturally through the shared pool (they were authenticated at
    /// handshake time; killing them mid-stream on a settings toggle would
    /// just force a reconnect race).
    public func disableRemote() {
        remoteListener?.cancel()
        remoteListener = nil
        remoteConfig = nil
    }

    private var remoteConfig: (port: UInt16, code: String)?

    // MARK: - Connection handling

    /// - Parameter isAuthenticated: `true` only from `enableRemote`'s
    ///   TLS-PSK listener. See `ConnectionState.isAuthenticated`.
    private func accept(_ connection: NWConnection, isAuthenticated: Bool) {
        let state = ConnectionState(connection: connection, isAuthenticated: isAuthenticated)
        connection.stateUpdateHandler = { [weak self] connectionState in
            switch connectionState {
            case .ready:
                self?.log.debug("LocalSyncServer: client connected")
                self?.receiveNext(on: connection)
            case .failed, .cancelled:
                self?.remove(connection)
            default:
                break
            }
        }
        queue.async { [weak self] in
            guard let self else {
                connection.cancel()
                return
            }
            guard self.connections.count < Self.maxConcurrentConnections else {
                self.log.error("LocalSyncServer: refusing connection — \(Self.maxConcurrentConnections) already open")
                connection.cancel()
                return
            }
            self.connections[ObjectIdentifier(connection)] = state
            // Started only after registration, and only for a connection
            // that was actually accepted — a refused one is cancelled
            // before it ever runs.
            connection.start(queue: self.queue)
        }
    }

    private func remove(_ connection: NWConnection) {
        queue.async { [weak self] in
            self?.connections.removeValue(forKey: ObjectIdentifier(connection))
        }
        connection.cancel()
    }

    // MARK: - Receiving commands

    /// Per-connection receive loop. This type was originally send-only
    /// (snapshots out); it reads now because `LocalSyncClient.send(command:)`
    /// needs a Mac-side listener on the other end of the same `NWConnection`
    /// to actually receive a `ControlCommand`. Mirrors `LocalSyncClient
    /// .receiveNext(on:)`/`.handleReceive(...)` structurally — both sides
    /// speak the same `LocalSyncFraming` envelope: accumulate raw bytes into
    /// this connection's `receiveBuffer`, hand them to
    /// `LocalSyncFraming.extractFrames(from:)`, act on the complete frames,
    /// keep the leftover partial frame for next time.
    ///
    /// Applies equally to LAN (Bonjour, plaintext) and remote (TLS-PSK)
    /// connections — they share one pool, and by the time a frame reaches
    /// here a remote client has already authenticated during the TLS
    /// handshake (see `SyncSecurity`), so no per-frame auth check is
    /// duplicated at this layer.
    private func receiveNext(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                self.handleReceive(connection: connection, data: data, isComplete: isComplete, error: error)
            }
        }
    }

    private func handleReceive(connection: NWConnection, data: Data?, isComplete: Bool, error: NWError?) {
        guard let state = connections[ObjectIdentifier(connection)] else { return }

        if let data, !data.isEmpty {
            state.receiveBuffer.append(data)
            do {
                let (messages, remainder) = try LocalSyncFraming.extractFrames(from: state.receiveBuffer)
                state.receiveBuffer = remainder
                for message in messages {
                    handle(message, from: connection)
                }
            } catch {
                log.error("LocalSyncServer: malformed frame from client, closing connection: \(String(describing: error))")
                remove(connection)
                return
            }
        }

        if let error {
            log.error("LocalSyncServer: receive error: \(String(describing: error))")
            remove(connection)
            return
        }
        guard !isComplete else {
            remove(connection)
            return
        }
        receiveNext(on: connection)
    }

    private func handle(_ message: LocalSyncMessage, from connection: NWConnection) {
        switch message {
        case .command(let command):
            // Control requires proof of the pairing code. The plaintext LAN
            // listener authenticates nobody, so a command arriving there is
            // refused — otherwise any device on the same Wi-Fi could put
            // this Mac to sleep or hold it awake indefinitely, which is a
            // materially different exposure from the read-only telemetry
            // that listener was designed around.
            //
            // Refused *explicitly*, with a `ControlStatus` the sender can
            // surface, rather than dropped silently: a phone whose commands
            // vanish looks identical to a broken connection, and this
            // codebase's whole posture is that a control which does nothing
            // must say so. The remedy is real and one step — turn on
            // Settings ▸ Sync ▸ Remote Access and enter the code once; it
            // works over the LAN too, not only from outside it.
            guard connections[ObjectIdentifier(connection)]?.isAuthenticated == true else {
                log.error("LocalSyncServer: refusing a command on an unauthenticated (LAN) connection")
                sendStatus(
                    ControlStatus(
                        deviceID: command.deviceID,
                        respondsToNonce: command.nonce,
                        state: "rejected",
                        message: "This Mac only accepts commands over an authenticated connection. Turn on Remote Access on the Mac and enter its pairing code on this device.",
                        assertionActive: false,
                        assertionExpiresAt: nil,
                        updatedAt: Date()
                    ),
                    on: connection
                )
                return
            }
            guard let commandHandler else {
                log.debug("LocalSyncServer: received a command with no commandHandler installed — dropping it")
                return
            }
            Task { [weak self] in
                let status = await commandHandler(command)
                guard let self else { return }
                self.sendStatus(status, on: connection)
            }
        case .snapshot, .status:
            // Clients never send either — logged and ignored rather than
            // treated as a protocol violation.
            log.debug("LocalSyncServer: received an unexpected snapshot/status frame from a client — ignoring")
        }
    }

    private func sendStatus(_ status: ControlStatus, on connection: NWConnection) {
        guard let framed = try? LocalSyncFraming.encode(.status(status)) else {
            log.error("LocalSyncServer: failed to encode ControlStatus reply")
            return
        }
        connection.send(content: framed, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.log.error("LocalSyncServer: failed to send ControlStatus reply: \(String(describing: error))")
            }
        })
    }

    /// Sends `snapshot`, framed, to every connection that hasn't been sent
    /// to within `minSendInterval`. Called from `feedTask`'s loop — not
    /// itself `queue`-confined, but every read/write of `connections`
    /// happens via `queue.async`/`queue.sync`, so this is safe to call from
    /// any context.
    private func broadcast(_ snapshot: SystemSnapshot) {
        guard let framed = try? LocalSyncFraming.encode(snapshot) else {
            log.error("LocalSyncServer: failed to encode snapshot for broadcast")
            return
        }
        let now = Date()
        queue.async { [weak self] in
            guard let self else { return }
            for state in self.connections.values {
                if let last = state.lastSendDate, now.timeIntervalSince(last) < self.minSendInterval {
                    continue
                }
                state.lastSendDate = now
                state.connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                    if let error {
                        self?.log.error("LocalSyncServer: send failed: \(String(describing: error))")
                        self?.remove(state.connection)
                    }
                })
            }
        }
    }
}
#endif
