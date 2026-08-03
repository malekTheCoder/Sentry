import SwiftUI

// MARK: - KeepAwakePage: the Watch's sleep-prevention control

/// The "keep my Mac awake" page of the redesigned, horizontally-paged Watch
/// app. Offers a duration when nothing is holding the Mac awake, and a live
/// countdown plus extend/end controls when something is.
///
/// **Why this takes six primitives instead of a `WatchRelaySnapshot`.** The
/// page deliberately knows nothing about `WatchRelaySnapshot`, `WCSession`,
/// `ControlCommand`, or `WatchControlBridge`. Two reasons, in order of
/// importance:
///
/// 1. *Honesty about what a Watch page can actually know.* Everything on this
///    page is a value the **Mac** reported and the phone relayed. A view that
///    reached for the transport itself would be tempted to derive state it
///    hasn't been told — "the assertion probably ended by now," "no reply, so
///    assume it worked." Taking `isActive`/`expiresAt`/`modeLabel` as inert
///    parameters makes that impossible: the page can only draw what it was
///    handed, and "the Mac didn't report this" arrives as `nil` rather than as
///    a plausible-looking default. This is the same discipline
///    `SleepStatusCard` (`SentryMobile/Dashboard/SleepStatusCard.swift`)
///    enforces on the phone, where `assertion: SleepAssertionState?` keeps
///    "we know it's off" and "we don't know" from collapsing into one case.
/// 2. *It makes the layout independently testable and independently
///    buildable.* Every state below — including ones that are awkward to
///    provoke on a real wrist (a hold with no expiry, a mode the Mac didn't
///    name) — is one initialiser call away, with no `WCSession` to stand up
///    and no paired-phone fixture to fake.
///
/// **Why the buttons hand back plain `Int` minutes rather than building a
/// `ControlCommand` here.** Constructing the command means choosing a nonce,
/// an `expiresAt` for the *command* (distinct from the assertion's expiry —
/// see `SleepStatusCard`), and a target `deviceID`, none of which this page
/// has or should have. The owner of the paged shell holds the session
/// controller and the relayed device identity, so it constructs the command;
/// this page's whole job is deciding *which duration the user asked for*.
///
/// **Nothing here is inert.** This codebase's standing rule (stated at length
/// in `SleepStatusCard`'s header: "a button that silently does nothing" is
/// the actual failure mode, not "a button exists") means every control below
/// must reach something. They do: each closure is non-optional and required
/// at the call site, so a caller cannot construct this page with a control
/// wired to nowhere. Reporting the *outcome* of a tap — sent / declined /
/// no reply — belongs to whoever owns the transport, for the same reason
/// command construction does; this page has no way to know and does not
/// pretend to.
///
/// **Why no `FreshnessBadge`.** Every other Mac-derived readout in this app
/// pairs its number with how old it is. This page is the exception on
/// purpose: it has no timestamp to describe. `expiresAt` is a point in the
/// *future*, not a reading age, and the assertion's own `lastSeen` belongs to
/// the shell's chrome, which renders it once for the whole paged app rather
/// than once per page. Adding a second, page-local freshness indicator here
/// would be a chance for the two to disagree.
///
/// **Sizing.** No fixed frames anywhere: the controls are full-width rows
/// with a `minHeight` floor, which grows with Dynamic Type instead of
/// clipping, and the whole page scrolls (Digital Crown) so a 40mm face at an
/// accessibility text size overflows downward rather than truncating. The
/// only hardcoded dimension is that `minHeight` floor, which is a *lower*
/// bound on the tap target — see `controlMinHeight`.
///
/// **Colours are system semantics, not `palette.*`.** The Mac and iPhone apps
/// resolve a themeable `ThemePalette`; the Watch app does not — `ContentView`
/// and `FreshnessBadge` both use SwiftUI's semantic colours directly, and
/// `FreshnessBadge`'s doc comment spells out why (the palette lives in the
/// app targets, and these particular meanings are fixed, not user-themeable).
/// This page follows that existing convention rather than inventing a
/// watch-side theme token set.
struct KeepAwakePage: View {

    /// Read so `extendRow` can choose between a side-by-side and a stacked
    /// pair of extend buttons — see its doc comment for why that decision is
    /// made explicitly here rather than left to a layout container.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The duration value meaning "hold it open until I say stop," with no
    /// expiry.
    ///
    /// **Why a sentinel at all.** The agreed initialiser hands durations back
    /// as a non-optional `Int` of minutes, which has no way to spell
    /// "indefinite" — the one duration this control most needs to offer,
    /// since it's what `AwakeMode`'s untimed hold on the Mac already supports
    /// and what `SleepStatusCard` renders as "ends when turned off on the
    /// Mac." An `Int?`, or a small enum, would carry that meaning in the type
    /// instead of in a magic number; that shape wasn't available here.
    ///
    /// So the sentinel is named and `public`-adjacent rather than typed
    /// inline as a bare `0` at the call site, because the receiving side has
    /// to agree with it and a literal `0` in this file would be undiscoverable
    /// from there. **A receiver that treats this as a literal zero-minute
    /// duration will expire the hold instantly** — it must branch on this
    /// constant before converting minutes to seconds.
    static let indefiniteMinutes = 0

    /// Durations offered when nothing is holding the Mac awake. Three, not
    /// six: this is a wrist, and every additional row pushes the next one off
    /// a 40mm screen. 15m and 1h mirror the two increments `SleepStatusCard`
    /// already offers on the phone, so the vocabulary matches across devices.
    private static let offeredDurations: [(minutes: Int, label: String)] = [
        (15, "15 minutes"),
        (60, "1 hour"),
        (indefiniteMinutes, "Until I turn it off"),
    ]

    /// Lower bound on a control's height. 44pt is Apple's minimum comfortable
    /// tap target and is a *floor*, never a fixed height — at larger Dynamic
    /// Type sizes the label's own intrinsic height exceeds it and wins.
    private static let controlMinHeight: CGFloat = 44

    /// Whether the Mac currently has something holding it awake, as last
    /// reported. Not optional: the paged shell decides what to show when it
    /// has heard nothing at all from the Mac (the whole-app "no data yet"
    /// state `ContentView` already owns), so by the time this page renders,
    /// active-or-not is a real reading rather than an absence.
    let isActive: Bool

    /// When the current hold ends, or `nil` for a hold with no expiry — the
    /// "until turned off" case. `nil` here is a genuine "there is no such
    /// time," not "the Mac forgot to tell us," and is rendered as its own
    /// sentence rather than as a zeroed-out countdown. Ignored when
    /// `isActive` is false.
    let expiresAt: Date?

    /// Human-readable mode string (the Watch's counterpart to
    /// `AwakeMode.mobileShortLabel` — "Keep display on", "System only", "Only
    /// while plugged in"). `nil` means the Mac did not report a mode, never a
    /// guessed default: "System only" and "we weren't told" are different
    /// facts, and silently printing the former would be fabricating a reading.
    ///
    /// It used to render as a bare em dash in a labelled "Mode" row. That row
    /// is gone — folded into `activeStatus` to buy the vertical space that
    /// brings "End Now" above the fold — and the absence is now spelled out in
    /// words instead, as "Mode not reported". That is a strictly better
    /// rendering of the same fact: an em dash on a line of its own needs the
    /// adjacent label to be read before it means anything, and this string now
    /// shares a line with three other fragments.
    let modeLabel: String?

    /// Requests a new hold for the given number of **minutes**, or for
    /// `Self.indefiniteMinutes`. Called only from the inactive state.
    let onKeepAwake: (Int) -> Void

    /// Requests that the current hold end now.
    let onRelease: () -> Void

    /// Requests that the current hold's expiry move out by the given number
    /// of **minutes**. Only offered when there is an `expiresAt` to move —
    /// extending a hold that has no expiry is meaningless, and the Mac's
    /// `PowerControlService.adjustAssertion(bySeconds:)` scopes itself the
    /// same way, so this page never sends a request that side would reject.
    let onExtend: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if isActive {
                    activeBody
                } else {
                    header
                    inactiveBody
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Keep Awake")
    }

    // MARK: - Header

    /// Rendered only in the **inactive** state now. When a hold is running,
    /// the same words are folded into `activeStatus` as a caption above the
    /// countdown — see `activeBody` for why that row had to go.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .foregroundStyle(Color.secondary)
            Text("Keep Mac awake")
                .font(.headline)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Inactive

    /// The offer state. Deliberately says what will happen *and* where it
    /// happens — a tap here has an effect on a machine the user may not be
    /// looking at, and a control whose consequences are invisible should at
    /// least name them.
    private var inactiveBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your Mac sleeps normally right now.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Self.offeredDurations, id: \.minutes) { duration in
                Button {
                    onKeepAwake(duration.minutes)
                } label: {
                    Text(duration.label)
                        .frame(maxWidth: .infinity, minHeight: Self.controlMinHeight)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Asks your Mac to stay awake")
            }
        }
    }

    // MARK: - Active

    /// **Why this state gained a hundred points of headroom.** On the
    /// simulator at 46mm, "End Now" — the one destructive control on the page
    /// — sat below the fold and needed a crown flick to reach. That is the
    /// wrong thing to hide: a user who has decided to stop holding their Mac
    /// awake should not have to hunt, and a control that is invisible until
    /// scrolled to is a control most users will not know exists.
    ///
    /// The fix is not to move "End Now" up. Promoting it above the extend
    /// buttons would put the destructive action directly under the thumb
    /// reaching for "+1 hr", which is the exact fat-finger this page's red
    /// tint was chosen to prevent (see `endButton`), and it would order the
    /// page by severity rather than by how often each control is wanted.
    /// Instead the state above it was compressed until everything fits:
    ///
    /// - The `.headline` "Keeping awake" row is gone. It was a full text line
    ///   restating what the countdown directly beneath it already made
    ///   obvious, and it was the single most expensive row on the page. The
    ///   words survive as `activeStatus`, a `.caption2` line with the moon
    ///   glyph inline — still present, a third of the height.
    /// - The "Mode / System only" row is folded into that same line. The data
    ///   is unchanged and the "we weren't told" case still renders explicitly
    ///   (see `activeStatus`); it just no longer occupies a full-width row of
    ///   its own to say two words.
    /// - Stack spacing dropped from 10 to 8, matched to `OverviewPage`'s
    ///   tightening for the same reason: on a wrist, every point of vertical
    ///   gap is paid for once per row.
    ///
    /// Together that is roughly 40pt reclaimed, which is what puts the end
    /// button on screen at rest at 46mm. It is **not** enough at 40mm with an
    /// active timed hold, where five controls' worth of content still exceeds
    /// the face; that case still scrolls, and that is the honest outcome
    /// rather than shrinking tap targets below 44pt to force a fit.
    private var activeBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            activeStatus
            countdown
            if expiresAt != nil {
                extendRow
            }
            endButton
        }
    }

    /// The former header and the former mode row, on one caption line.
    ///
    /// `nil` mode still renders explicitly as "Mode not reported" rather than
    /// being dropped: a missing mode would read as "there is no mode," which
    /// is a stronger and wronger claim than "we weren't told which one." That
    /// was the whole argument for the old `modeRow` and it survives the row
    /// being deleted — what changed is the shape, not the honesty.
    ///
    /// **The three text runs are one concatenated `Text`, not three siblings
    /// in the `HStack`.** As siblings they were separate layout children, so a
    /// 40mm face resolved the squeeze by *truncating the first one* — the
    /// simulator rendered "Keeping a… · System only", which loses the status
    /// and keeps the qualifier, exactly backwards. `minimumScaleFactor` cannot
    /// help there because it is applied per child and SwiftUI truncated rather
    /// than scaled. Concatenated, they are a single `Text` with one intrinsic
    /// width, so the scale factor applies to the whole line at once and the
    /// sentence shrinks intact instead of losing its subject.
    private var activeStatus: some View {
        HStack(spacing: 4) {
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(Color.accentColor)
            Text("Keeping awake")
                + Text("  ·  ").foregroundStyle(.secondary)
                + Text(modeLabel ?? "Mode not reported").foregroundStyle(.secondary)
        }
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            modeLabel.map { "Keeping awake, mode \($0)" } ?? "Keeping awake, mode not reported"
        )
    }

    /// The hero readout.
    ///
    /// `Text(_:style: .timer)` redraws itself once a second and counts down to
    /// the target on its own — the same reason `SleepStatusCard` uses it on
    /// the phone rather than a local `TimelineView` tick. On a Watch that
    /// matters more than on a Mac: a self-updating `Text` keeps ticking in the
    /// always-on dimmed state without this view owning a timer that would have
    /// to be torn down and restarted around every wrist-down.
    ///
    /// **The already-expired case is handled, and its limit is stated.** A
    /// `.timer` `Text` whose date has passed silently starts counting *up*,
    /// which would read as a hold that has been running for three minutes
    /// rather than one that ended three minutes ago. The `expiresAt > Date()`
    /// check below catches the common version of that — arriving at this page
    /// after the expiry has passed. What it does not catch is the expiry
    /// elapsing while the page is already on screen: `Date()` is evaluated at
    /// body-render time, and nothing here forces a re-render on that
    /// boundary. Making that instant self-correcting would mean this page
    /// keeping its own clock, and it would still only be guessing — the hold
    /// is the Mac's, and only the Mac can say it actually released. So the
    /// correction is left to the next relayed state, which is the only source
    /// that knows.
    ///
    /// **This is the one place the new dial language was rejected, and the
    /// reason matters.** A depleting arc is the obvious rendering for a
    /// countdown and it is the single most on-brand thing this page could
    /// draw — `SentryDial` exists, the icon is a timer face, it would have
    /// been three lines. It is not drawn because an arc needs a denominator
    /// and this page does not have one. The payload carries `awakeExpiresAt`
    /// (an absolute instant) and nothing else; the hold's *original* duration
    /// is not on the wire and cannot be derived, so any fraction would require
    /// inventing a full-scale value — a nominal hour, say — and the arc would
    /// then be a picture of a number the Mac never sent. A 90-minute hold
    /// would render as a ring that had been full for half an hour already.
    /// Adding the duration to `WatchRelaySnapshot` to enable it was considered
    /// and dropped: a new wire field to justify a shape is the tail wagging
    /// the dog. The monospaced digits stay.
    @ViewBuilder
    private var countdown: some View {
        if let expiresAt {
            if expiresAt > Date() {
                // "remaining" sits on the timer's own baseline rather than on
                // a line of its own. That was the last ~16pt needed to get
                // "End Now" fully above the fold at 46mm (see `activeBody`),
                // and it is the better shape anyway: a five-character
                // monospaced countdown leaves half the widest line on the
                // screen empty, and the word belongs to the number the way a
                // unit does. `ViewThatFits` is safe here where it was not for
                // `OverviewPage`'s dials — both children are plain `Text`
                // with honest intrinsic widths, so the horizontal candidate
                // can genuinely fail and the stacked fallback is reachable at
                // large Dynamic Type sizes.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        timerText(deadline: expiresAt)
                        remainingCaption
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        timerText(deadline: expiresAt)
                        remainingCaption
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Time remaining")
            } else {
                Text("This hold's time is up. Waiting for your Mac to confirm it ended.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("No countdown — ends when turned off.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Split out only so `countdown`'s two arrangements above can share one
    /// definition rather than repeating the font stack and risking the two
    /// drifting apart.
    ///
    /// Takes the deadline as a parameter rather than reading `self.expiresAt`
    /// and unwrapping with a `?? Date()`: that fallback would compile, would
    /// never be hit today, and would silently render a timer counting *up*
    /// from now the first time somebody used this outside the `if let` in
    /// `countdown` — which is precisely the already-expired failure that
    /// property's doc comment exists to warn about.
    private func timerText(deadline: Date) -> some View {
        Text(deadline, style: .timer)
            .font(.system(.title2, design: .monospaced, weight: .semibold))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
    }

    private var remainingCaption: some View {
        Text("remaining")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// Two side-by-side buttons are the right shape on any face at default
    /// text size; at an accessibility size on a 40mm face, "+15 min" in half
    /// of 162pt truncates to an ambiguous stub, so the pair stacks instead.
    ///
    /// **Why an explicit `dynamicTypeSize` branch and not `ViewThatFits`.**
    /// `ViewThatFits` was the first attempt and is silently wrong here: it
    /// picks the first candidate whose *ideal* size fits, and both buttons
    /// carry `frame(maxWidth: .infinity)` so they can fill their half of the
    /// row. An infinitely flexible child reports an ideal width small enough
    /// to always "fit", so the horizontal candidate wins unconditionally and
    /// the stacked fallback is dead code — a container that looks like it is
    /// adapting while never actually choosing the second branch is worse than
    /// no adaptation, because it reads as handled. Reading the environment
    /// directly makes the rule legible and, unlike a layout negotiation, it is
    /// deterministic under test.
    @ViewBuilder
    private var extendRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 6) {
                extendButton(minutes: 15, label: "+15 min")
                extendButton(minutes: 60, label: "+1 hr")
            }
        } else {
            HStack(spacing: 6) {
                extendButton(minutes: 15, label: "+15 min")
                extendButton(minutes: 60, label: "+1 hr")
            }
        }
    }

    /// `label` is a `LocalizedStringKey`, not a `String`, and that is the
    /// whole point: `Text(someString)` uses the non-localizing initializer,
    /// so a `String` parameter here would silently bypass the string catalog
    /// while looking identical at the call site. This is the exact
    /// String-typed bypass the localization pass on `main` was written to
    /// close; the dial redesign reintroduced it by accident when this helper
    /// was rewritten, and it is fixed here rather than lost in the merge.
    private func extendButton(minutes: Int, label: LocalizedStringKey) -> some View {
        Button {
            onExtend(minutes)
        } label: {
            Text(label)
                .frame(maxWidth: .infinity, minHeight: Self.controlMinHeight)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Extend by \(minutes) minutes")
    }

    /// Tinted red, not destructive-styled with a confirmation: ending a hold
    /// early is cheap and fully reversible (the durations on the inactive
    /// state are one tap away), so a confirmation sheet on a wrist would cost
    /// more than the mistake it prevents. The colour is there to keep it from
    /// being fat-fingered while reaching for "+1 hr", not to warn of anything
    /// permanent.
    private var endButton: some View {
        Button(role: .destructive) {
            onRelease()
        } label: {
            Text("End Now")
                .frame(maxWidth: .infinity, minHeight: Self.controlMinHeight)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .accessibilityHint("Lets your Mac sleep normally again")
    }
}

#if DEBUG
#Preview("Inactive") {
    KeepAwakePage(
        isActive: false,
        expiresAt: nil,
        modeLabel: nil,
        onKeepAwake: { _ in },
        onRelease: {},
        onExtend: { _ in }
    )
}

#Preview("Active — timed") {
    KeepAwakePage(
        isActive: true,
        expiresAt: Date().addingTimeInterval(42 * 60),
        modeLabel: "Keep display on",
        onKeepAwake: { _ in },
        onRelease: {},
        onExtend: { _ in }
    )
}

/// The two absences that must not render as zeroes: an untimed hold, and a
/// mode the Mac never reported.
#Preview("Active — no expiry, no mode") {
    KeepAwakePage(
        isActive: true,
        expiresAt: nil,
        modeLabel: nil,
        onKeepAwake: { _ in },
        onRelease: {},
        onExtend: { _ in }
    )
}
#endif
