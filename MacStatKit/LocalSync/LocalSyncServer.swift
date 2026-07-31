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

    private let queue = DispatchQueue(label: "dev.malekswilam.macstat.localsyncserver")
    private let log = Logger(subsystem: "dev.malekswilam.macstat", category: "LocalSyncServer")

    private var listener: NWListener?
    private var feedTask: Task<Void, Never>?

    /// One entry per open connection. `lastSendDate` is `nil` until the
    /// first snapshot has actually been sent, so a just-connected client
    /// always receives the very next snapshot immediately rather than
    /// waiting out `minSendInterval` for no reason.
    private final class ConnectionState {
        let connection: NWConnection
        var lastSendDate: Date?
        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private var connections: [ObjectIdentifier: ConnectionState] = [:]

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

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
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
        queue.sync {
            for state in connections.values {
                state.connection.cancel()
            }
            connections.removeAll()
        }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        let state = ConnectionState(connection: connection)
        connection.stateUpdateHandler = { [weak self] connectionState in
            switch connectionState {
            case .ready:
                self?.log.debug("LocalSyncServer: client connected")
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
