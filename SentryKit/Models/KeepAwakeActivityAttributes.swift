#if os(iOS)
import ActivityKit
import Foundation

// MARK: - KeepAwakeActivityAttributes: the ActivityKit shim, and nothing else

/// The `ActivityAttributes` for the keep-awake Live Activity — the fixed
/// half of the activity (things that cannot change for the life of a
/// session) plus the declaration that `KeepAwakeActivityState` is its
/// changing half.
///
/// **Why this file is four lines of substance and a page of reasoning.**
/// Everything a reader would expect to find here — the fields, the
/// timed-versus-indefinite split, the staleness arithmetic, the End-failure
/// rule — is deliberately *not* here. It is in
/// `KeepAwakeActivityState.swift`, a Foundation-only file, because
/// `SentryTests` is a macOS unit-test bundle and ActivityKit does not exist
/// on macOS. Anything declared inside this `#if os(iOS)` block is
/// permanently unreachable by every test in this project, so the rule
/// applied here is that only the ActivityKit *conformance* may live inside
/// it. `ContentState` is a typealias, not a nested struct, precisely to
/// enforce that.
///
/// **Why it lives in `SentryKit` rather than in either app target.** Two
/// separate processes need this type: `SentryMobile`, which requests and
/// updates the activity, and `SentryWidgetExtension`, which renders it. An
/// app extension cannot import its containing app's target (only the
/// reverse), so the type has to sit in the framework both of them already
/// link — the same route `WidgetSnapshot` takes to reach `SentryWidget`, and
/// the same reason.
///
/// **Why there is no second widget extension for this.** Live Activity
/// presentations are ordinary `Widget`s registered in a `WidgetBundle`, and
/// this project already ships exactly one iOS widget extension
/// (`SentryWidgetExtension`, `project.yml`) whose bundle
/// (`SentryWidgetBundle.swift`) already declares a static widget and a
/// Control Center control. A second extension would mean a second appex to
/// sign, provision, privacy-manifest, version-match against the host app,
/// and embed — all of it to host one more `Widget` conformance in a bundle
/// that already exists.
///
/// **What `staleDate` does with all this** — see
/// `KeepAwakeActivityState.staleDate(asOf:isMacReachable:)`. The short
/// version: this app has no server, therefore no APNs push, therefore no way
/// to correct a Live Activity while it is not running; `staleDate` is the
/// one mechanism ActivityKit gives for saying "past this instant, do not
/// present my content as current," and it is the entire reason a
/// server-less Live Activity can be honest at all.
public struct KeepAwakeActivityAttributes: ActivityAttributes {

    /// See `KeepAwakeActivityState` — deliberately a typealias to a type
    /// declared outside this file's `#if os(iOS)` fence.
    public typealias ContentState = KeepAwakeActivityState

    /// The Mac being held awake, for the presentation's title. Fixed for the
    /// life of the session: a keep-awake hold belongs to one machine, and a
    /// name that could change mid-activity would be a name worth doubting.
    public var deviceName: String

    /// When this session started, as known to the phone.
    ///
    /// Carried in the *attributes* rather than the content state because it
    /// genuinely never changes — extending or truncating a hold moves its
    /// end, never its beginning. It is what
    /// `ProgressView(timerInterval:countsDown:)` needs as the lower bound of
    /// its range so the Lock Screen can draw a bar that drains: without a
    /// start there is no proportion to draw, only a number.
    public var startedAt: Date

    public init(deviceName: String, startedAt: Date) {
        self.deviceName = deviceName
        self.startedAt = startedAt
    }
}
#endif
