import Foundation
import Combine
import MacStatKit

/// Feeds the debug window from the same `StatsCoordinator` stream every other
/// consumer reads (plan §3.2 P3: one poll loop, many consumers). `ingest` is
/// called unconditionally from `AppDelegate`'s existing snapshot loop — the
/// same way `DropdownViewModel.ingest` already is — so opening or closing the
/// debug window never starts or stops a second timer.
///
/// **The expensive part — `SnapshotDebugFormatter.sections(for:)`'s recursive
/// `Mirror` walk over every field of every sub-struct — is gated on
/// `isWindowVisible`, not run unconditionally.** An earlier version of this
/// type assumed that walk was "cheap enough not to bother gating," but that
/// was never actually measured, and the app has no way to distinguish a
/// developer build from a shipped Release — this consumer runs in every
/// install, for every user, at the fast tier's cadence (~3s default),
/// forever, whether or not the debug window has ever been opened. That is
/// exactly the class of always-on cost plan R9 ("does this app use
/// noticeable CPU/battery") worries about, on a feature almost nobody will
/// ever look at. `latestSnapshot`/`lastUpdated` are still updated on every
/// tick regardless — they're plain struct copies, not reflection — so the
/// window shows genuinely current data the instant it opens rather than
/// waiting for the next tick.
@MainActor
public final class DebugDumpViewModel: ObservableObject {

    @Published public private(set) var sections: [SnapshotDebugFormatter.Section] = []
    @Published public private(set) var lastUpdated: Date?

    /// Retained (rather than just derived fields) so `plainTextDump` can
    /// re-render the full raw dump on demand for the Copy button without
    /// needing its own snapshot storage. Also what lets `isWindowVisible`
    /// immediately backfill `sections` from the most recent tick the moment
    /// the window opens, instead of showing stale/empty content until the
    /// next snapshot arrives.
    private var latestSnapshot: SystemSnapshot?

    /// Set by `DebugWindowController` as its window shows/closes. `false`
    /// until the window has ever been opened, matching P6 ("cheap by
    /// default") — the same reasoning `StatsCoordinator.popoverIsClosed`
    /// already uses for the dropdown.
    public var isWindowVisible: Bool = false {
        didSet {
            guard isWindowVisible, !oldValue, let latestSnapshot else { return }
            // Backfill immediately on becoming visible; otherwise the
            // window would show whatever `sections` last held (empty, or
            // stale from the last time it was open) until the next tick.
            sections = SnapshotDebugFormatter.sections(for: latestSnapshot)
        }
    }

    public init() {}

    public func ingest(_ snapshot: SystemSnapshot) {
        latestSnapshot = snapshot
        lastUpdated = snapshot.timestamp
        guard isWindowVisible else { return }
        sections = SnapshotDebugFormatter.sections(for: snapshot)
    }

    /// Text for the "Copy" button. Returns an explicit placeholder rather
    /// than an empty string before the first snapshot arrives (window opened
    /// before `StatsCoordinator`'s first tick) — an empty pasteboard entry
    /// would look like a bug in the copy action itself.
    public var plainTextDump: String {
        guard let latestSnapshot else { return "No snapshot received yet." }
        return SnapshotDebugFormatter.plainText(for: latestSnapshot)
    }
}
