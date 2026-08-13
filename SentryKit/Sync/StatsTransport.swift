import Foundation

// MARK: - StatsTransport: the seam between the iOS app and a data source

/// The abstraction the iPhone app's view models consume their data through,
/// so "where the numbers come from" is swappable without touching the UI.
/// Two conformers exist: `LocalSyncClient` (`SentryKit/LocalSync/`), the
/// real local-network transport (Bonjour discovery + TLS-PSK, with an
/// optional user-configured remote endpoint), and `MockDataSource`
/// (`SentryMobile/Data/`), the clearly-disclosed demo source the app falls
/// back to when no Mac is reachable. `AppDataSource` owns the active
/// conformer and swaps between them — see its doc comment for the
/// fallback policy.
///
/// A planned CloudKit transport was deleted without ever being wired (no
/// container, no enrollment — see git history for the record types and
/// upload service that layer would have used); this protocol survives it
/// because the seam was never CloudKit-specific.
///
/// **Shape notes**, kept from the original design where they still apply:
///
/// 1. `snapshots()` is a *function* returning a fresh `AsyncStream`, not a
///    stored/computed property vending the same stream to every caller. This
///    mirrors `StatsCoordinator.snapshots()` (`SentryKit/Services/StatsCoordinator.swift`)
///    exactly, for the same reason documented there: plain `AsyncStream` only
///    supports one consumer per stream, and this app has several independent
///    subscribers (`DashboardViewModel`, `HistoryViewModel`, intents). A
///    transport is free to fan one underlying subscription out to many
///    returned streams internally, same as `StatsCoordinator` does.
/// 2. `freshness()` is `async` (not a stored property). A transport's
///    notion of "how stale is our view of the world" is a
///    network-adjacent fact (time since the last frame arrived), not free
///    to read synchronously off the main actor from an arbitrary caller —
///    matching `send(command:)`, which is `async throws` for the same
///    reason.
/// 3. `Sendable` conformance on the protocol itself: conformers are held
///    and called across actor/task boundaries (view models, intents, the
///    widget writer), and requiring `Sendable` is what makes that legal.
public protocol StatsTransport: Sendable {
    /// A fresh stream of snapshots this transport has (or will) receive.
    /// For `LocalSyncClient` this means frames decoded off the wire from
    /// the connected Mac; for `MockDataSource`, fabricated demo ticks.
    func snapshots() -> AsyncStream<SystemSnapshot>

    /// How stale this transport's view of the world currently is. `async`
    /// because computing it may require asking the transport's own backing
    /// store/network layer (e.g. "seconds since the last received frame"),
    /// not a value it's safe to assume is free to read synchronously.
    func freshness() async -> TimeInterval

    /// Sends one command (iPhone → Mac direction) through this transport.
    func send(command: ControlCommand) async throws

    /// Waits up to `timeout` seconds for a `ControlStatus` reply to a
    /// command previously passed to `send(command:)`, matched by
    /// `command.nonce`. Returns `nil` if no reply arrives in time (or if
    /// this transport doesn't have a concept of a reply at all — see
    /// `MockDataSource`'s conformance). Added alongside `LocalSyncClient`'s
    /// real `send(command:)` implementation (`SentryKit/LocalSync/LocalSyncClient.swift`)
    /// so a caller (`KeepAwakeIntent`, `SleepStatusCard`) can learn what a
    /// Mac actually did with a command rather than only knowing it was
    /// transmitted.
    func awaitStatus(forNonce nonce: String, timeout: TimeInterval) async -> ControlStatus?
}
