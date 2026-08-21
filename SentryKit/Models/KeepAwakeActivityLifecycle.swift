import Foundation

// MARK: - KeepAwakeActivityLifecycle: start / update / end, decided without ActivityKit

/// The whole start-update-end decision for the keep-awake Live Activity,
/// expressed as one pure function over "what is on screen" and "what the Mac
/// last said."
///
/// **Why the state machine is separated from the thing that drives it.**
/// `KeepAwakeActivityController` (`SentryMobile/LiveActivity/`) does the
/// ActivityKit calls — `Activity.request`, `activity.update`,
/// `activity.end` — and nothing else. Every rule about *when* those happen
/// is here, in a Foundation-only type that compiles for macOS and is
/// therefore reachable by `SentryTests`, which is a macOS unit-test bundle
/// (`project.yml`) and cannot so much as `import ActivityKit`. Put the rules
/// in the controller and the interesting behaviour of this feature — "does a
/// hold the Mac stopped reporting leave a ghost on the Lock Screen?" —
/// becomes untestable by construction.
///
/// **The rules, in the order they are applied and for the reasons given.**
///
/// 1. *A hold that has certainly ended is ended, unconditionally.* Before
///    anything else, including before looking at what the Mac said. A timed
///    hold past its own `expiresAt` is over — the Mac's OS-level assertion
///    timeout guarantees it even if the Mac app crashed and even if this
///    phone has heard nothing since — so an activity still describing it is
///    exactly the ghost this feature must not leave behind. This is also the
///    rule that cleans up after the app being killed: on relaunch the
///    controller adopts whatever activities survived and runs them through
///    here, and a dead hold's activity is ended on the spot without needing
///    a Mac to be reachable at all.
///
///    There is one gap this rule cannot close, and it is worth naming
///    rather than leaving for someone to discover: a phone that is *never*
///    opened again runs none of this, so an activity whose hold expired
///    while the app was dead sits on the Lock Screen showing "time is up,
///    waiting for your Mac to confirm" — the honest wording for exactly
///    that situation — until the system's own ceiling (ActivityKit ends an
///    activity that has gone eight hours without an update) removes it. A
///    server-backed app would push a correction instead; this one has no
///    server to push from, which is why the content is worded so that the
///    unattended case still reads true.
///
/// 2. *Disabled means end, never merely "stop updating."* If the user has
///    turned Live Activities off (`AppSettings`-style opt-out, here a phone
///    `@AppStorage` flag — see `SettingsTabView.liveActivitySection`), an
///    activity already on the Lock Screen is ended. Leaving it up but frozen
///    would be the worst of both: the setting appears not to work, and the
///    thing left behind is the un-updated surface this design exists to
///    avoid.
///
/// 3. *Silence never starts anything, and never ends anything indefinite.*
///    When the Mac has reported nothing (`reported == nil` — no snapshot yet,
///    or the transport is down), there is no news, and no news is not
///    evidence. Starting an activity would be fabricating a hold; ending an
///    indefinite one would be fabricating a release. The activity stays, and
///    `KeepAwakeActivityState.staleDate(asOf:isMacReachable:)` is what makes
///    the *system* visibly age it rather than this file pretending to know.
///    Same asymmetry as `SleepAssertionDisplay`, deliberately: these helpers
///    only ever withdraw a claim the data disproves, never invent one.
///
/// 4. *`.inactive` is real news and ends the activity.* Unlike silence, a
///    Mac that reported `.inactive` has actively said the hold is gone. That
///    is the ordinary end-of-session path, and it covers the case the brief
///    calls out specifically — the session ending on the Mac rather than
///    from the phone.
///
/// 5. *Start only on a hold that is credibly live.* A first snapshot
///    carrying an already-expired timed hold does not open a Live Activity
///    to immediately close it.
///
/// 6. *Update on material change, plus a confirmation heartbeat for
///    indefinite holds.* See `confirmationHeartbeat`.
public enum KeepAwakeActivityLifecycle {

    /// How often an *indefinite* hold's activity is re-stamped with a fresh
    /// `lastConfirmedAt` while the app is running and hearing from the Mac.
    ///
    /// Two minutes: comfortably less than half
    /// `KeepAwakeActivityState.unconfirmedIndefiniteTolerance` (five
    /// minutes), so a live, connected app always re-confirms before the
    /// system would begin aging the activity. If it were the same as the
    /// tolerance, a Live Activity would flicker in and out of the stale
    /// treatment on a running app, which would train the user to ignore the
    /// one signal that is supposed to mean something.
    ///
    /// **Why timed holds get no heartbeat.** Their `staleDate` is
    /// `expiresAt` — self-carried, indifferent to when the phone last heard
    /// anything — so re-stamping `lastConfirmedAt` would change nothing a
    /// viewer can see while costing an ActivityKit update every two minutes
    /// for the entire length of the hold.
    public static let confirmationHeartbeat: TimeInterval = 120

    /// What the controller should do next.
    ///
    /// `showing` is the state currently on the Lock Screen (`nil` if no
    /// activity is running), `reported` is the `SleepAssertionState` the Mac
    /// most recently sent (`nil` if it has sent nothing, or the transport is
    /// down, or what it sent is too old to still count as news).
    ///
    /// `reportedAt` is when the Mac *took* that reading — the timestamp on
    /// the `SystemSnapshot` that carried it, not the moment the phone
    /// decoded it, and not `now`. It becomes the resulting state's
    /// `lastConfirmedAt`, which is the anchor everything about staleness is
    /// measured from, so letting `now` stand in for it would quietly
    /// backdate every gap in the connection to zero. Defaults to `now` for
    /// the tests and call sites where the two genuinely coincide.
    public static func next(
        showing: KeepAwakeActivityState?,
        reported: SleepAssertionState?,
        reportedAt: Date? = nil,
        isEnabled: Bool,
        now: Date
    ) -> KeepAwakeActivityAction {

        // Rule 2 — the opt-out wins over everything, including a hold the
        // Mac is actively reporting.
        guard isEnabled else {
            return showing.map { .end($0) } ?? .none
        }

        // Rule 1 — an activity describing a hold that has certainly ended is
        // ended before any of the reported state is consulted, so a phone
        // with no Mac in earshot still cleans up after itself.
        if let showing, showing.hasCertainlyEnded(asOf: now) {
            return .end(showing)
        }

        switch reported {
        case nil:
            // Rule 3.
            return .none

        case .inactive:
            // Rule 4.
            return showing.map { .end($0) } ?? .none

        case .active(let mode, let expiresAt, let reason):
            let candidate = KeepAwakeActivityState(
                mode: mode,
                expiresAt: expiresAt,
                reason: reason,
                lastConfirmedAt: reportedAt ?? now
            )
            // Rule 1 again, from the other direction: a *reported* hold that
            // is already past its deadline never opens an activity, and ends
            // one that is open. (The `showing` branch above has already
            // handled the case where the activity itself is the expired one;
            // this catches a Mac still reporting a hold whose deadline has
            // since passed — the exact state the phone's other surfaces used
            // to render as "● Active".)
            guard candidate.isCrediblyActive(asOf: now) else {
                return showing.map { .end($0) } ?? .none
            }

            // Rule 5.
            guard let showing else { return .start(candidate) }

            // Rule 6. `endFailure` is dropped on any refresh: fresh news
            // from the Mac supersedes a stale complaint about a command that
            // failed minutes ago (see `clearingEndFailure`).
            if isMateriallyDifferent(showing, candidate) {
                return .update(candidate)
            }
            if showing.endFailure != nil {
                return .update(candidate)
            }
            // Compared confirmation-to-confirmation, not against `now`: the
            // question is whether the phone has meaningfully *newer* news
            // than what the Lock Screen is showing, and answering it with
            // the wall clock would fire an update for a Mac that has gone
            // quiet — republishing an old reading under a new timestamp,
            // which is the one thing `lastConfirmedAt` exists to prevent.
            if candidate.isIndefinite,
               candidate.lastConfirmedAt.timeIntervalSince(showing.lastConfirmedAt) >= confirmationHeartbeat {
                return .update(candidate)
            }
            return .none
        }
    }

    /// Whether two states differ in something a viewer can see — mode, the
    /// deadline (this is what an extend/truncate moves), or the Mac's reason
    /// sentence. Deliberately excludes `lastConfirmedAt`, which changes on
    /// every single snapshot: comparing whole values would mean an
    /// ActivityKit update every few seconds for the life of every hold,
    /// which is both wasteful and visually noisy on a Lock Screen. The
    /// heartbeat above is the controlled version of that refresh.
    static func isMateriallyDifferent(
        _ lhs: KeepAwakeActivityState,
        _ rhs: KeepAwakeActivityState
    ) -> Bool {
        lhs.mode != rhs.mode || lhs.expiresAt != rhs.expiresAt || lhs.reason != rhs.reason
    }
}

// MARK: - KeepAwakeActivityAction

/// The four things the controller can be told to do. `end` carries the final
/// content so the activity can be dismissed showing the truth rather than
/// whatever it happened to be displaying — ActivityKit renders a final
/// frame, and a Lock Screen's last word on a session should not be a
/// countdown frozen mid-tick.
public enum KeepAwakeActivityAction: Equatable, Sendable {
    case none
    case start(KeepAwakeActivityState)
    case update(KeepAwakeActivityState)
    case end(KeepAwakeActivityState)
}
