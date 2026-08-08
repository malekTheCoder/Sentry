import SwiftUI

// MARK: - SentryHaptic

/// The phone app's haptic vocabulary.
///
/// **The design rule this type exists to enforce: variation must be
/// meaningful, never decorative.** The brief was "vary the haptics so they
/// aren't all the same", and the obvious reading of that — give each button a
/// different buzz — produces the worst possible result. A device that
/// responds differently to two controls that do the same *kind* of thing
/// teaches the user that the differences are arbitrary, and once they are
/// arbitrary they are noise, and noise in the Taptic Engine is worse than
/// silence because it cannot be ignored.
///
/// So the variation is by **what happened**, not by which button was pressed.
/// There are nine distinct things a control in this app can say, listed
/// below. Two buttons that mean the same thing feel the same, and a user who
/// uses the app for a week can tell a committed command from a rejected one
/// with the phone in their pocket. That is the payoff, and it only exists if
/// the vocabulary is small and applied consistently.
///
/// **Why `.sensoryFeedback` rather than `UIImpactFeedbackGenerator`.** The
/// UIKit generators need a retained instance, a `prepare()` call to warm the
/// engine, and manual teardown — none of which is natural inside a SwiftUI
/// body. The common bug is a generator constructed per render, which never
/// warms up and so fires late or not at all. `.sensoryFeedback` is
/// declarative, has no lifecycle, and is what iOS 17 added for this.
///
/// **The user's own setting is respected for free, and deliberately not
/// re-implemented.** iOS routes all of this through Settings ▸ Sounds &
/// Haptics ▸ System Haptics, so someone who has turned haptics off
/// system-wide gets silence without this app checking anything. A
/// Sentry-level toggle on top would be a second switch that can disagree with
/// the first. (Reduce Motion is *not* the relevant setting: it governs
/// animation, and suppressing haptics for it would strip a non-visual
/// affordance from the users most likely to be relying on one.)
///
/// **What deliberately gets no haptic**, because restraint is part of this
/// feeling good: anything continuous or repeating — scrolling, chart
/// scrubbing as the finger moves, a value updating on its own. A phone that
/// ticks while you drag across a chart is unpleasant within about two
/// seconds. Chart scrubbing is the one place a *very* light tick is arguably
/// right, and it is handled separately at that call site with its own
/// throttling rather than from this list.
enum SentryHaptic {

    /// Moved between options in a set — metric chips, the time-range picker,
    /// a theme row, a segmented control.
    ///
    /// The short dry tick iOS uses for pickers. This is the most common one
    /// in the app and the most important to keep *quiet*: it fires often, so
    /// anything heavier would dominate everything else in the vocabulary.
    case selection

    /// An ordinary button that did something local and immediate — expanded a
    /// disclosure, opened a sheet, dismissed something, tapped Retry.
    ///
    /// Light on purpose. This is the "yes, that registered" of the set, and
    /// it is the one a user feels most often without having asked for
    /// anything consequential to happen.
    case tap

    /// Turned something on, or began a hold that persists — Keep Awake
    /// starting, enabling agent access, arming a rule.
    ///
    /// `.start` rather than a generic impact because it is directional: it
    /// pairs with `.stop` below, and the pair is what makes a Keep Awake
    /// toggle feel like a switch rather than two unrelated buttons.
    case begin

    /// Turned something off, or released a hold — Keep Awake ending, a rule
    /// disabled, agent access paused.
    case end

    /// Stepped a value up or down — the +15m / +1h / −15m controls.
    ///
    /// Directional feedback is the whole point here: a user adjusting a
    /// countdown without looking should be able to feel which way it went.
    case increase
    case decrease

    /// A command the Mac **accepted**. Reserved for round trips, not for
    /// local state changes.
    ///
    /// This is the most valuable entry in the vocabulary and the reason it is
    /// worth doing this properly. A keep-awake tap on the phone travels
    /// phone → Mac and the phone learns the outcome only when the reply
    /// arrives; until then the UI deliberately shows the last state the Mac
    /// actually confirmed (see `ContentView`'s note on why nothing is
    /// optimistically flipped). A success tap is the app telling you the far
    /// end agreed, without you having to read a sentence.
    case confirmed

    /// A command the Mac **refused**, or that could not be delivered —
    /// unreachable, declined by guardrails, timed out.
    ///
    /// Distinct from `confirmed` by design: these two are the pair a user
    /// most needs to tell apart, and they are the pair most likely to be felt
    /// while not looking at the screen.
    case rejected

    /// Something consequential and destructive was committed — the agent kill
    /// switch, deleting a rule.
    ///
    /// Heavier than `end`. A control that stops other software from working
    /// should not feel identical to flipping a display setting.
    case consequential

    /// The `SensoryFeedback` each case maps to.
    ///
    /// Kept as a single mapping rather than scattered `.sensoryFeedback(...)`
    /// calls so the whole vocabulary can be read — and re-tuned — in one
    /// screen. If two cases ever collapse to the same feedback, that is
    /// visible here and is a signal the vocabulary has one case too many.
    var feedback: SensoryFeedback {
        switch self {
        case .selection: return .selection
        case .tap: return .impact(weight: .light, intensity: 0.5)
        case .begin: return .start
        case .end: return .stop
        case .increase: return .increase
        case .decrease: return .decrease
        case .confirmed: return .success
        case .rejected: return .error
        case .consequential: return .warning
        }
    }
}

// MARK: - View plumbing

extension View {

    /// Fires `haptic` whenever `value` changes.
    ///
    /// **Trigger-based rather than fired inside the button's action**, and the
    /// difference is behavioural rather than stylistic:
    ///
    /// * Re-selecting the option that is *already* selected changes nothing,
    ///   so it produces nothing. Firing from a tap handler would buzz on a
    ///   no-op, which teaches the user that the haptic means "you touched the
    ///   screen" rather than "something changed".
    /// * A change that comes from somewhere other than a tap — VoiceOver
    ///   moving through a row, a restored default, a relayed update from the
    ///   Mac — feels identical to one that was tapped, because the feedback
    ///   is attached to the state rather than to one gesture recogniser.
    ///
    /// It also cannot fire on first appearance: `.sensoryFeedback(trigger:)`
    /// responds to changes, so a screen opening on its default selection is
    /// silent, which is what a user expects from a view they have not
    /// interacted with yet.
    func haptic<Value: Equatable>(_ haptic: SentryHaptic, on value: Value) -> some View {
        sensoryFeedback(haptic.feedback, trigger: value)
    }

    /// Fires `haptic` when `value` changes *and* `condition` accepts the new
    /// value — for the cases where one piece of state carries more than one
    /// meaning.
    ///
    /// The motivating case is a toggle: `isActive` flipping true should feel
    /// like `.begin` and false like `.end`, which is two different feedbacks
    /// off one `Bool`. Expressed as two `haptic(_:on:when:)` calls rather than
    /// by branching inside a single one, so each line names the meaning it
    /// carries.
    func haptic<Value: Equatable>(
        _ haptic: SentryHaptic,
        on value: Value,
        when condition: @escaping (Value) -> Bool
    ) -> some View {
        sensoryFeedback(haptic.feedback, trigger: value) { _, new in condition(new) }
    }

    /// Fires `haptic` on a plain action — for buttons whose effect is not
    /// observable as a changed value in this view (presenting a sheet handled
    /// elsewhere, a fire-and-forget command, opening a URL).
    ///
    /// Deliberately last in this file and deliberately the awkward one to
    /// reach for: a control whose result cannot be observed as state is
    /// usually a control that should be reporting its result, and reaching
    /// for this is worth a second's thought about whether the state is the
    /// thing that is missing.
    func haptic(_ haptic: SentryHaptic, onTapOf trigger: some Equatable) -> some View {
        sensoryFeedback(haptic.feedback, trigger: trigger)
    }
}

// MARK: - Phone → Mac round trips

/// Which entry of the vocabulary above a `ControlCommand` earns, at each of
/// the **two** moments one of them produces: the instant it is issued, and
/// the instant the Mac's `ControlStatus` (or its absence) comes back.
///
/// **Why a command gets two haptics and not one, which is the whole design
/// decision in this type.** `SleepStatusCard`'s three adjust buttons and its
/// End Now button do not change any state on this phone. They post a request
/// over the local-sync link and then wait; what the card shows afterwards is
/// whatever the *Mac* said, never a guess (that card's doc comment: "a send
/// failure, a silent Mac, and a Mac that actively declined are three distinct
/// messages, never collapsed into one optimistic 'Done'"). So there are
/// genuinely two events, a request and an answer, separated by a round trip
/// that is fast on a healthy LAN and up to `SentryIntents.statusTimeout`
/// when it is not — and each one gets the feedback that is true of it:
///
///   * **`issued(commandType:)`** says only which way the user pushed.
///     `.increase` for +15m/+1h, `.decrease` for −15m, `.end` for End Now.
///     This is not an optimistic success: `.increase` means "you stepped it
///     up", which is a fact about the tap, whereas `.confirmed` means "the
///     far end agreed", which is the claim that would be a lie here. It is
///     also the moment the directionality is *useful* — `SentryHaptic
///     .increase`'s own note is that a user adjusting a countdown without
///     looking should feel which way it went, and a tick that arrives after
///     the round trip is too late to guide a thumb that is already moving to
///     the next tap.
///   * **`outcome(of:)`** says what the Mac did, and nothing else.
///
/// **Alternatives rejected.** Firing nothing on the tap: a command that has
/// to time out leaves five seconds of a screen that felt dead, which is the
/// failure the brief for this work names first. Firing the *directional*
/// case on the reply instead: it makes `.confirmed` unreachable anywhere in
/// this app, and directional feedback that arrives after the gesture is over
/// guides nothing. Firing `.confirmed` on the tap: the exact optimism the
/// rest of this codebase refuses everywhere else.
///
/// **Kept as pure static functions over plain values** — not methods on a
/// view, not a `switch` inlined into `sendCommand` — for the same reason
/// `BatteryHealthTrendChart.readoutText` is: this is the part with real
/// branching, so it is the part worth being able to test. It is not tested
/// today, and that is a project fact rather than an oversight: `SentryTests`
/// is a macOS bundle that links `Sentry`/`SentryKit_macOS` only, so nothing
/// under `SentryMobile/` is reachable from any test target in this build.
enum SentryCommandHaptic {

    /// A command's reply, in the only three shapes this app can actually
    /// observe one. Modelled as a closed enum rather than an
    /// `Error?`/`ControlStatus?` pair so `outcome(of:)` is total and the
    /// "sent but silent" case cannot be quietly folded into either
    /// neighbour — it is a distinct thing that happened, and the card's own
    /// copy already treats it as one.
    enum Reply: Equatable {
        /// `StatsTransport.send(command:)` threw. Nothing left the phone.
        case undelivered
        /// Sent, but `awaitStatus(forNonce:timeout:)` returned nothing
        /// before the timeout.
        case unanswered
        /// The Mac answered. `state` is `ControlStatus.state` verbatim —
        /// deliberately the raw string rather than a parsed enum, because
        /// `ControlStatus` documents the set as
        /// `accepted`/`rejected`/`completed`/`expired` and a Mac running a
        /// newer build may send something this phone has never heard of.
        case answered(state: String)
    }

    /// What the tap itself is allowed to say.
    ///
    /// Keyed on `ControlCommand.commandType`, the same strings
    /// `SleepStatusCard` and `SentryIntents` construct, so two controls that
    /// send the same command feel the same however they were reached —
    /// including `keepAwake`, which only Siri sends today and which would
    /// need no change here the day a button for it lands on the card.
    ///
    /// An unrecognised command type falls back to `.tap` rather than to
    /// silence: "that registered" is true of every button in this app, and a
    /// command type this function has not been taught about is a gap in this
    /// function, not a reason to leave a real tap feeling dead.
    static func issued(commandType: String) -> SentryHaptic {
        switch commandType {
        case "extendAwake": return .increase
        case "truncateAwake": return .decrease
        case "releaseAwake": return .end
        case "keepAwake": return .begin
        default: return .tap
        }
    }

    /// What the reply says — or `nil` for a reply this app has no honest
    /// word for.
    ///
    /// `nil` is a real answer here, not an oversight, and it covers exactly
    /// one case: a `state` outside the documented set, `accepted` included.
    /// `accepted` means the Mac took the command and has not finished it, so
    /// `.confirmed` would claim an agreement that has not happened yet and
    /// `.rejected` would claim a refusal that never happened at all.
    /// Silence is the only non-lie available, and it costs the user nothing
    /// — they already felt `issued(commandType:)`, so they know the tap
    /// landed, and the card prints the Mac's own `message` on screen. This
    /// is deliberately *not* an argument for a tenth enum case: "the far end
    /// said something we can't classify" is not a thing a user should learn
    /// to recognise by feel.
    ///
    /// Both `undelivered` and `unanswered` are `.rejected`, matching that
    /// case's own doc comment ("a command the Mac **refused**, or that could
    /// not be delivered — unreachable, declined by guardrails, timed out").
    /// Splitting them would mean inventing a distinction the user cannot act
    /// on differently: in every one of the three, the thing they asked for
    /// did not happen.
    static func outcome(of reply: Reply) -> SentryHaptic? {
        switch reply {
        case .undelivered, .unanswered:
            return .rejected
        case .answered(let state):
            switch state {
            case "completed": return .confirmed
            case "rejected", "expired": return .rejected
            default: return nil
            }
        }
    }
}
