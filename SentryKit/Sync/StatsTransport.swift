import Foundation

// MARK: - StatsTransport: the seam a real CloudKit implementation slots into

/// The abstraction plan §7.1 calls for so "a second transport can slot in
/// without touching the UI" — v2 is CloudKit, v4 is an optional local-network
/// (Bonjour) fast path, and per §7.1's own comment a later `CompositeTransport`
/// could prefer whichever of the two is fresher. Nothing above this protocol
/// (`SyncService`, and eventually the UI) is allowed to know which concrete
/// transport it's talking to.
///
/// **Why this file has no concrete conformer:** same constraint as
/// `SyncRecords.swift`/`CKMapper.swift` — there is no enrolled Apple
/// Developer Program account for this project (`project.yml`:
/// `CODE_SIGNING_REQUIRED: NO`, `DEVELOPMENT_TEAM: ""`), so there is no
/// provisioning profile, no push entitlement, and no way to stand up the
/// `iCloud.dev.malekswilam.sentry` container. A `CloudKitTransport` conforming
/// to this protocol is separate, later work gated on enrollment. What lives
/// here is the seam itself plus `SyncService` (see `SyncService.swift`), which
/// is written and fully tested today against a fake conformer.
///
/// **Shape vs. the plan's sketch:** the plan's §7.1 code block is
/// intentionally a sketch, not final Swift:
/// ```swift
/// public protocol StatsTransport {
///     var snapshots: AsyncStream<SystemSnapshot> { get }
///     var freshness: TimeInterval { get }
///     func send(command: ControlCommand) async throws
/// }
/// ```
/// Two adaptations were necessary to make it compile and behave correctly
/// under Swift's real concurrency rules, both preserving the sketch's shape:
///
/// 1. `snapshots` becomes a *function* returning a fresh `AsyncStream`, not a
///    stored/computed property vending the same stream to every caller. This
///    mirrors `StatsCoordinator.snapshots()` (`SentryKit/Services/StatsCoordinator.swift`)
///    exactly, for the same reason documented there: plain `AsyncStream` only
///    supports one consumer per stream, and `SyncService` (a `StatsCoordinator`
///    consumer itself, one architectural layer up) is exactly the kind of
///    second subscriber that pattern exists to support. A transport is free
///    to fan one underlying subscription out to many returned streams
///    internally, same as `StatsCoordinator` does.
/// 2. `freshness` becomes `async` (`freshness()`, not a stored property).
///    A real CloudKit-backed implementation's notion of "how stale is our
///    view of the world" is itself a network-adjacent fact (time since last
///    successful fetch/push round-trip), not free to read synchronously
///    off the main actor from an arbitrary caller — matching `send(command:)`,
///    which the sketch already marks `async throws`.
/// 3. `Sendable` conformance on the protocol itself: `SyncService` is a
///    queue-confined class (see its own doc comment) that must be able to
///    hold a `StatsTransport` and call into it from a background queue/Task
///    without the compiler flagging a data race. Requiring `Sendable`
///    conformers is what makes that legal; it costs real implementations
///    nothing since `CKContainer`/`CKDatabase` are themselves `Sendable`
///    reference types.
public protocol StatsTransport: Sendable {
    /// A fresh stream of snapshots this transport has (or will) receive.
    /// For a `CloudKitTransport` this means "records pushed via
    /// `CKQuerySubscription`/observed by polling," not "every snapshot this
    /// process itself produced" — `SyncService` is the *sender* of local
    /// snapshots (see `enqueue(snapshot:)`), not a consumer of this stream;
    /// this stream exists for the receiving side (e.g. the iPhone app, or a
    /// composite/fallback transport) to read what the transport last saw.
    func snapshots() -> AsyncStream<SystemSnapshot>

    /// How stale this transport's view of the world currently is. `async`
    /// because computing it may require asking the transport's own backing
    /// store/network layer (e.g. "seconds since the last successful CloudKit
    /// fetch"), not a value it's safe to assume is free to read synchronously.
    func freshness() async -> TimeInterval

    /// Sends one command (iPhone → Mac direction) through this transport.
    /// `qualityOfService` is a hint the real implementation should honor
    /// (plan §7.4: `.userInitiated` for commands, distinct from the
    /// `.utility` used for snapshot uploads) — see `UploadBatch` in
    /// `SyncService.swift` for where an analogous hint lives on the upload
    /// side.
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

    /// Uploads a batch of snapshots. Plan §7.4 is explicit that snapshots
    /// must never be saved one-at-a-time (`CKModifyRecordsOperation`,
    /// `savePolicy = .changedKeysOnly`, `qualityOfService = .utility`) — see
    /// `UploadBatch`'s doc comment in `SyncService.swift` for how that intent
    /// is encoded without a concrete `CKModifyRecordsOperation` call existing
    /// anywhere yet. Throws (rather than returning a partial-failure list)
    /// so `SyncService`'s backoff logic has one simple signal to react to;
    /// a real implementation that gets a mixed per-record CloudKit result
    /// back is expected to surface that as a thrown `UploadError` (see
    /// `SyncService.swift`) rather than leaking `CKRecord`-level detail
    /// through this protocol.
    func upload(_ batch: UploadBatch) async throws
}
