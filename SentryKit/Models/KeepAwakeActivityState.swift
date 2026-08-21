import Foundation

// MARK: - KeepAwakeActivityState: what a keep-awake Live Activity is allowed to claim

/// The content state of the keep-awake Live Activity — the small value that
/// crosses from the phone app into the Lock Screen / Dynamic Island
/// presentation, and the one place the "what may this surface claim?"
/// questions are answered.
///
/// **Why a keep-awake session gets a Live Activity and the Mac's stats do
/// not.** Sentry has no server; the shipped privacy policy says so out loud
/// ("no account to create, no server we run"), and every transport in this
/// project is a direct device-to-device one (`LocalSyncClient` over Bonjour
/// or a paired TLS-PSK socket). ActivityKit's *only* mechanism for updating
/// a Live Activity while the app is not running is an APNs push from a
/// server you operate. So a "live CPU / temperature / battery" Live Activity
/// is not a feature this app declined to build — it is architecturally
/// unavailable without breaking the promise, and what it would actually
/// degrade into is a widget frozen at whatever numbers happened to be on
/// screen when the phone was last unlocked, presented with the confidence of
/// a live readout. That is precisely the polished, confident lie
/// `WidgetSnapshot.sourceIsDemoData`'s doc comment warns this app is one
/// careless surface away from telling.
///
/// A keep-awake *session* has none of that problem, and that asymmetry is
/// the whole reason this type exists. A session is not a stream of readings;
/// it is a fact with a known start and (usually) a known end. The two
/// SwiftUI primitives `Text(timerInterval:)` and
/// `ProgressView(timerInterval:)` are rendered **by the system, on the Lock
/// Screen, with zero updates from anybody** — so a two-hour hold counts down
/// correctly for two hours while this app never runs once. No push, no
/// server, no stale numbers. The deadline is data, not telemetry.
///
/// **What the value carries, and why each field is load-bearing.**
///   * `mode` — which of the three `AwakeMode` shapes the Mac is holding, so
///     the presentation can say "system only" rather than implying the
///     display is being kept on too.
///   * `expiresAt` — the deadline, `nil` meaning *indefinite*. This single
///     optional is the difference between the two presentations the Lock
///     Screen must never confuse (see `KeepAwakeActivityPresentation`).
///   * `reason` — the Mac's own sentence for why it is awake, shown verbatim
///     rather than re-derived, exactly as `SleepStatusCard` shows it.
///   * `lastConfirmedAt` — when the phone last actually *heard* this from
///     the Mac. Nothing else in the value can answer "is this still true?",
///     and without it a Live Activity would age into a confident lie the
///     moment the phone lost the Mac. It is what `staleDate(asOf:
///     isMacReachable:)` is computed from.
///   * `endFailure` — non-`nil` only after the Lock Screen's End button
///     tried and did *not* get a confirmed release. See
///     `afterEndAttempt(_:)`: a failed End must be visible on the surface
///     the user tapped, and must not leave the activity claiming the hold
///     is over.
///
/// **Why it is a plain Foundation value with no `import ActivityKit`.** The
/// `ActivityAttributes` conformance lives next door in
/// `KeepAwakeActivityAttributes.swift`, behind `#if os(iOS)`, and does
/// nothing but name this type as its `ContentState`. Keeping the decisions
/// here means they compile — and are unit-tested — on macOS, where
/// `SentryTests` runs and where ActivityKit does not exist at all. The
/// alternative (declaring the fields inside the `ActivityAttributes` struct,
/// the way every ActivityKit sample does) would put every honesty rule in
/// this file inside a target no test in this project can reach.
public struct KeepAwakeActivityState: Codable, Hashable, Sendable {

    /// Which sleep-prevention shape the Mac is holding.
    public var mode: AwakeMode

    /// The recorded deadline, or `nil` for a hold that ends only when
    /// somebody ends it. Mirrors `SleepAssertionState.active`'s own
    /// `expiresAt` exactly, including its meaning for `nil` — this type
    /// deliberately does not invent a second spelling of "indefinite" (an
    /// `isIndefinite: Bool` alongside a date would be two fields that can
    /// disagree).
    public var expiresAt: Date?

    /// The Mac's own explanation, carried through verbatim.
    public var reason: String

    /// When the phone last received this state from the Mac. Not "when this
    /// activity was updated" — an update that only re-stamps a value the
    /// phone has not re-heard would defeat the entire point of the field.
    public var lastConfirmedAt: Date

    /// A short sentence describing an End attempt that did not result in a
    /// confirmed release, or `nil` when nothing has been tried or the last
    /// attempt succeeded. See `afterEndAttempt(_:)`.
    public var endFailure: String?

    public init(
        mode: AwakeMode,
        expiresAt: Date?,
        reason: String,
        lastConfirmedAt: Date,
        endFailure: String? = nil
    ) {
        self.mode = mode
        self.expiresAt = expiresAt
        self.reason = reason
        self.lastConfirmedAt = lastConfirmedAt
        self.endFailure = endFailure
    }

    // MARK: - Bridging to the shared honesty predicates

    /// The equivalent `SleepAssertionState`, so this type reuses
    /// `SleepAssertionDisplay`'s judgments instead of restating them.
    ///
    /// This is deliberate rather than convenient: `hasCertainlyEnded(asOf:)`
    /// and `isCrediblyActive(asOf:)` encode a specific, hard-won asymmetry —
    /// a *timed* hold past its own deadline has certainly ended (the
    /// OS-level `kIOPMAssertionTimeoutKey` guarantees it whether or not the
    /// Mac app is even alive), while an *indefinite* hold can never be
    /// declared over from a distance, because every path that ends one
    /// happens on the Mac out of a remote reader's sight. Re-deriving that
    /// here from `expiresAt` by hand would be a second implementation of the
    /// exact rule the phone's other surfaces just got wrong.
    public var assertion: SleepAssertionState {
        .active(mode: mode, expiresAt: expiresAt, reason: reason)
    }

    /// No deadline in the value — the case that must never render a
    /// countdown, a progress bar, or any other end-implying chrome.
    public var isIndefinite: Bool { expiresAt == nil }

    /// See `SleepAssertionState.hasCertainlyEnded(asOf:)`.
    public func hasCertainlyEnded(asOf date: Date) -> Bool {
        assertion.hasCertainlyEnded(asOf: date)
    }

    /// See `SleepAssertionState.isCrediblyActive(asOf:)`.
    public func isCrediblyActive(asOf date: Date) -> Bool {
        assertion.isCrediblyActive(asOf: date)
    }

    // MARK: - Presentation

    /// Which of the three mutually exclusive presentations the Lock Screen
    /// and Dynamic Island owe this state at `date`. A single function rather
    /// than each view branching on `expiresAt` itself, so "timed and
    /// indefinite look different, and both are honest" is one decision made
    /// once instead of eight `if let expiresAt` sites that can drift.
    public func presentation(asOf date: Date) -> KeepAwakeActivityPresentation {
        guard let expiresAt else { return .indefinite }
        return expiresAt <= date ? .ended(at: expiresAt) : .countingDown(until: expiresAt)
    }

    // MARK: - Staleness

    /// How long an *indefinite* hold's last confirmation stays good before
    /// the system should visibly age the activity.
    ///
    /// `Freshness.recentThreshold` (five minutes) rather than a number
    /// invented here: it is already this codebase's boundary for "this
    /// reading has stopped being recent," used by every freshness badge and
    /// dot the app draws. An indefinite hold has *nothing* self-carried
    /// backing its claim — no deadline, no OS timeout, only the phone's
    /// memory of a sentence the Mac said — so the moment the reading behind
    /// the claim stops being fresh, the claim stops being confident.
    ///
    /// `Freshness.staleThreshold` (an hour) was the obvious alternative and
    /// is wrong for this surface: a Lock Screen that says a Mac is being
    /// held awake is read at a glance, believed, and acted on, and an hour
    /// is long enough for the user to have released the hold from the Mac
    /// itself and walked away.
    public static let unconfirmedIndefiniteTolerance: TimeInterval = Freshness.recentThreshold

    /// The `staleDate` to hand `ActivityContent` — the instant after which
    /// the system stops presenting this activity at full confidence and
    /// applies its own aged treatment.
    ///
    /// Three cases, and the split *is* the design:
    ///
    ///   * **Known out of contact** (`isMacReachable == false`). The phone
    ///     is not guessing here — it watched the transport go down. Return
    ///     `now`, so the activity ages immediately rather than waiting out a
    ///     timer for news that is already known not to be coming.
    ///
    ///   * **Timed, in contact.** Return `expiresAt` itself. This is the
    ///     case the whole feature is built around: the deadline is carried
    ///     inside the value and enforced by the Mac's OS-level assertion
    ///     timeout, so the countdown stays correct with no updates from
    ///     anyone for as long as it runs — the two-hour hold that counts
    ///     down for two hours on a Lock Screen while this app never once
    ///     executes. Capping it at some tolerance after `lastConfirmedAt`
    ///     (the shape used for indefinite holds below) was considered and
    ///     rejected: it would grey out a countdown that is *still correct*
    ///     after a few minutes of ordinary backgrounding, which is not more
    ///     honest, just less useful. The residual risk is a hold released
    ///     early on the Mac while the phone is out of contact, and the
    ///     honest framing of the countdown is therefore an upper bound —
    ///     "ends by", not "ends at", which is how the presentation words it.
    ///
    ///   * **Indefinite, in contact.** Return `lastConfirmedAt +
    ///     unconfirmedIndefiniteTolerance`. See that constant.
    ///
    /// Note what this deliberately does *not* do: it never returns a date
    /// that would make the activity go stale while the app is running and
    /// receiving snapshots, because `KeepAwakeActivityLifecycle`'s
    /// confirmation heartbeat re-stamps `lastConfirmedAt` well inside the
    /// tolerance. Staleness here means the phone genuinely stopped hearing
    /// from the Mac, never merely that time passed.
    public func staleDate(asOf now: Date, isMacReachable: Bool) -> Date {
        guard isMacReachable else { return now }
        if let expiresAt { return expiresAt }
        return lastConfirmedAt.addingTimeInterval(Self.unconfirmedIndefiniteTolerance)
    }

    // MARK: - End attempts

    /// The state this activity should show after an End attempt reported
    /// `outcome`.
    ///
    /// Returns `nil` for a *confirmed* release — the caller's instruction to
    /// end the activity outright, because there is no longer a hold to
    /// describe. Every other outcome returns the same hold with
    /// `endFailure` set: the hold is, as far as anyone knows, still running,
    /// and the failure has to be visible on the surface the user tapped.
    ///
    /// **Why a failed End must not optimistically dismiss the activity.**
    /// It is the same rule `SentryIntents.sendAndDescribe(_:whenCompleted:)`
    /// enforces for Siri and `ToggleMacAwakeIntent` enforces for the Control
    /// Center toggle (which reverts on a thrown `perform()`): a command with
    /// no confirmed effect is never reported as having succeeded. A Live
    /// Activity that vanishes on tap *is* a success report — arguably the
    /// most emphatic one this app can make, since the evidence disappears
    /// along with it. So the activity stays, the hold stays described, and
    /// the sentence underneath says what actually happened.
    public func afterEndAttempt(_ outcome: KeepAwakeCommandOutcome) -> KeepAwakeActivityState? {
        guard let failure = outcome.failureMessage else { return nil }
        var updated = self
        updated.endFailure = failure
        return updated
    }

    /// The same value with any previous End failure cleared — applied
    /// whenever fresh news arrives from the Mac, since a stale "couldn't
    /// reach your Mac" line sitting under a hold the phone is currently
    /// hearing about is its own small lie.
    public var clearingEndFailure: KeepAwakeActivityState {
        var updated = self
        updated.endFailure = nil
        return updated
    }
}

// MARK: - KeepAwakeActivityPresentation

/// The three shapes a keep-awake Live Activity can take. Exhaustive and
/// mutually exclusive on purpose: the bug this whole branch descends from is
/// a phone surface showing "● Active" for holds that had ended, which is
/// what happens when a view has an "active" branch and an implicit
/// everything-else.
public enum KeepAwakeActivityPresentation: Equatable, Sendable {

    /// A timed hold still running. `until` is safe to hand straight to
    /// `Text(timerInterval:)` / `ProgressView(timerInterval:)`, which the
    /// system renders and ticks locally with no updates from the app — the
    /// no-server escape hatch this feature is built on.
    case countingDown(until: Date)

    /// A hold with no deadline. Renders no countdown, no progress bar, and
    /// no end time, because there is no end to show; anything that implies
    /// one is a fabrication. Note that `Text(_, style: .timer)` counting
    /// *up* from the start was considered as a "something is happening"
    /// affordance and rejected — a ticking number reads as a live
    /// measurement, and this state is the one the phone can least support
    /// that claim for.
    case indefinite

    /// A timed hold whose deadline has passed. Reached whenever the surface
    /// still holds a state the Mac has not yet contradicted; the honest
    /// wording is that the time is up and the Mac has not confirmed yet, not
    /// a countdown (`Text(_, style: .timer)` silently counts up past its
    /// date, rendering "ended three minutes ago" as "running for three
    /// minutes" — the trap `SleepStatusCard.expiredNotice` and
    /// `KeepAwakePage.countdown` both document).
    case ended(at: Date)
}

// MARK: - KeepAwakeCommandOutcome

/// What actually happened to a keep-awake `ControlCommand` sent from a
/// surface with nowhere to print a paragraph — the Lock Screen's End button,
/// the Dynamic Island's.
///
/// **Why this enum exists rather than reusing a `String` dialog.**
/// `SentryIntents.sendAndDescribe(_:whenCompleted:)` collapses exactly these
/// five situations into a spoken sentence, which is right for Siri and
/// useless for a caller that must *decide something* — end the activity, or
/// keep it and annotate it. Keeping the outcomes as values means the
/// decision (`KeepAwakeActivityState.afterEndAttempt(_:)`) is a pure
/// function that `SentryTests` can pin without a Mac, a network, or a real
/// `Activity` anywhere in sight, which is the only way the failure path of a
/// Lock Screen button is testable at all.
public enum KeepAwakeCommandOutcome: Equatable, Sendable {

    /// The Mac replied and said it did the thing. The only outcome any
    /// surface may present as success.
    case completed

    /// The Mac replied and declined, carrying its own message (e.g. there
    /// was no adjustable assertion to release).
    case declined(String)

    /// Transmitted over a live connection, but no `ControlStatus` came back
    /// inside the timeout. Distinct from `notSent` because the command may
    /// well have run — "we don't know" is not "it didn't happen."
    case unanswered

    /// The send itself threw; nothing reached the Mac.
    case notSent(String)

    /// There was no Mac to send to at all — nothing was transmitted. The
    /// counterpart to `SentryIntents.demoModeSendDialog`'s guard, which
    /// exists because "sent, but no reply" is a false sentence about a
    /// command that never left the phone.
    case noMacConnected

    /// Whether the Mac itself confirmed the effect.
    public var isConfirmed: Bool {
        self == .completed
    }

    /// A Lock-Screen-sized sentence for anything short of confirmation, or
    /// `nil` when the Mac confirmed. Short by necessity: this renders inside
    /// a Live Activity, where there is room for one line under the hold.
    public var failureMessage: String? {
        switch self {
        case .completed:
            return nil
        case .declined(let message):
            // The Mac's own words, not a paraphrase — it knows why it said
            // no and this surface does not.
            return message.isEmpty
                ? String(localized: "Your Mac declined that.")
                : String(localized: "Your Mac declined that: \(message)")
        case .unanswered:
            return String(localized: "Sent, but your Mac hasn't confirmed.")
        case .notSent(let reason):
            return reason.isEmpty
                ? String(localized: "Couldn't reach your Mac.")
                : String(localized: "Couldn't reach your Mac — \(reason)")
        case .noMacConnected:
            return String(localized: "No Mac connected — nothing was sent.")
        }
    }
}
