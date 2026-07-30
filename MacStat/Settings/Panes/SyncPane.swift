import SwiftUI
import MacStatKit

/// The plan §7 sync surface — but for a feature that cannot exist yet, not a
/// dashboard for one that does.
///
/// **Why this pane exists at all when there is nothing to show.** Plan §7's
/// CloudKit sync is blocked on an enrolled Apple Developer Program account —
/// `project.yml` ships `CODE_SIGNING_REQUIRED: NO` and `DEVELOPMENT_TEAM: ""`
/// today, so there is no `CKContainer`, no push subscription, and no schema
/// promotion anywhere in this app. `SyncService` (`MacStatKit/Sync/SyncService.swift`)
/// is real, tested, adaptive-cadence scheduling logic, but it is constructed
/// nowhere in `AppDelegate` and has no `uploadAttempt` closure that talks to a
/// server, because there is no server to talk to. A settings pane that hid
/// behind "coming soon" would leave a user wondering whether sync silently
/// isn't working for *them* specifically; saying plainly why it doesn't exist
/// yet is the honest version of the same disclosure.
///
/// **What this pane refuses to show, on purpose (house rule P5 — "never
/// overclaim").** This codebase has shipped exactly this bug before in
/// different clothes: a settings slider that silently did nothing, and a
/// history pane that reported "no alerts fired" when its database had
/// actually failed to open (`AdvancedPane`/history's honesty footnotes; see
/// `AlertsPane.historyIsAvailable`'s doc comment for the canonical writeup of
/// that second one). Both were bugs of confident-looking UI describing a
/// reality that wasn't true. Applying that lesson here rules out:
///   - Any word implying liveness — "Connected," "Syncing," "Up to date,"
///     "Last synced Xm ago." There has never been a successful upload, ever,
///     on any Mac running this build, because the upload path does not exist.
///   - A spinner, progress bar, or activity indicator of any kind — all of
///     those *read* as "something is happening right now," and nothing is.
///   - Fabricated-looking statistics (record counts, upload history, a
///     "queue" the user could believe is draining). `SyncService.pendingRecordCount()`
///     would always read 0 in this build (nothing calls `enqueue*` because
///     nothing produces `CKRecord`s to enqueue), and showing "0 pending"
///     reads exactly like a working queue that's merely caught up — the
///     specific shape of misleading this pane exists to avoid.
///   - The `cloudKitSyncEnabled` toggle already sitting in `AppSettings`
///     (`MacStatKit/Settings/AppSettings.swift`). It has no reader anywhere
///     in the app — flipping it changes a bit in `settings.json` and nothing
///     else observably happens, which is the textbook "slider that silently
///     does nothing" bug. Surfacing it as an interactive control here would
///     manufacture exactly that bug rather than merely inheriting a
///     pre-existing dead field; better to leave it unexposed until something
///     real reads it.
///
/// **What is honest to show: the cadence table, as documentation, not
/// status.** `SyncService.effectiveInterval(onBattery:iPhoneRecentlyActive:)`
/// and the "significant event → immediate" rule are pure, fully-tested logic
/// (see `SyncServiceTests`) — they are correct today independent of whether
/// any instance is running, the same way a function's unit tests are true
/// before the function is ever called from production code. Presenting them
/// as "the rules this build is written to follow once sync is connected" is a
/// claim about the *code*, which is verifiably true, not a claim about
/// *activity*, which would not be. The wording throughout below says
/// "configured to" / "will," never "is" / "currently," to keep that
/// distinction visible on screen and not just in this comment.
///
/// **Why no `SyncService` instance is threaded in here, live or otherwise.**
/// This task considered constructing a real `SyncService` in `AppDelegate`
/// with a no-op `uploadAttempt` closure (`{ _ in .failure(retryAfterSeconds: nil) }`)
/// purely so this pane would have a live object to observe. Rejected:
/// `start()` arms a real, self-rescheduling `DispatchSourceTimer` — cheap
/// relative to `StatsCoordinator`'s, but not free — that would then run for
/// the lifetime of the app, on every user's Mac, forever, in service of a
/// queue nothing ever populates and a closure that always fails. That is a
/// permanent resource cost paid by every installed copy of MacStat for zero
/// current benefit, which is a worse trade than this pane reading purely from
/// `SyncService`'s `static` cadence functions (`effectiveInterval`,
/// `backoffDelay`) — no instance, no timer, no queue, just the same numbers a
/// running instance would compute, shown as reference rather than telemetry.
/// The real instance still belongs in `AppDelegate` the moment there is an
/// `uploadAttempt` closure worth giving it — enrollment unblocks both at
/// once, and this pane's honest-empty-state framing should be revisited
/// alongside that wiring, not before it.
struct SyncPane: View {

    var body: some View {
        Form {
            Section {
                Label {
                    Text("iCloud sync isn't available in this build")
                        .fontWeight(.semibold)
                } icon: {
                    Image(systemName: "icloud.slash")
                        .foregroundStyle(.secondary)
                }

                Text("MacStat isn't enrolled in the Apple Developer Program yet, so it has no iCloud container to sync through — no account, no server, no network connection. Nothing has ever synced on this Mac, and nothing is attempting to. This isn't a per-user setting or a bug to troubleshoot; it's true for every copy of this build.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Status")
            }

            Section {
                ForEach(Self.cadenceRows()) { row in
                    LabeledContent(row.condition, value: row.interval)
                }
            } header: {
                Text("Upload Schedule")
            } footer: {
                Text("This is the cadence MacStat's sync engine is built and tested to follow once it's connected — it doesn't describe anything happening right now. A significant change (plugging in, unplugging, an alert firing, or a pull-to-refresh from the iPhone app) is configured to upload immediately rather than waiting out the interval above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Cadence table (pure, testable, no SyncService instance required)

    /// One row of the plan §7.4 cadence table, formatted for display.
    /// `Identifiable` by `condition` since the table is small and fixed —
    /// two rows can never share a condition string.
    struct CadenceRow: Identifiable, Equatable {
        var id: String { condition }
        let condition: String
        let interval: String
    }

    /// Builds the cadence table entirely from `SyncService`'s `static`
    /// functions and default constants — no `SyncService` instance, timer,
    /// or queue involved (see this file's top-level doc comment for why that
    /// matters). Kept `static` and free of view state so it's unit-testable
    /// without a view hierarchy, matching `AlertsPane.humanDuration`'s
    /// convention elsewhere in this codebase.
    static func cadenceRows() -> [CadenceRow] {
        [
            CadenceRow(
                condition: "On AC power, iPhone active in the last 10 min",
                interval: intervalLabel(
                    SyncService.effectiveInterval(onBattery: false, iPhoneRecentlyActive: true)
                )
            ),
            CadenceRow(
                condition: "On AC power, iPhone idle",
                interval: intervalLabel(
                    SyncService.effectiveInterval(onBattery: false, iPhoneRecentlyActive: false)
                )
            ),
            CadenceRow(
                condition: "On battery power",
                interval: intervalLabel(
                    SyncService.effectiveInterval(onBattery: true, iPhoneRecentlyActive: false)
                )
            ),
            CadenceRow(
                condition: "Significant event or manual refresh",
                interval: "Immediately"
            ),
        ]
    }

    /// Spells a cadence interval out the way a person would say it —
    /// "Every 30 seconds," "Every 5 minutes" — rather than a raw
    /// `TimeInterval`. Deliberately simpler than `AlertsPane.humanDuration`:
    /// every value this pane ever passes in comes from
    /// `SyncService.effectiveInterval`'s own default constants (30 s / 300 s /
    /// 600 s), which are always whole numbers of seconds or whole numbers of
    /// minutes, so there is no fractional case to handle.
    static func intervalLabel(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "Immediately" }
        if seconds < 60 {
            let value = Int(seconds.rounded())
            return "Every \(value) second\(value == 1 ? "" : "s")"
        }
        let minutes = Int((seconds / 60).rounded())
        return "Every \(minutes) minute\(minutes == 1 ? "" : "s")"
    }
}
