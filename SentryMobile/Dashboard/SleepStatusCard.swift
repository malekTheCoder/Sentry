import SwiftUI
import SentryKit

/// Plan §12.1 asks for a "Sleep-prevention control card (toggle + duration +
/// countdown)." Historically this was deliberately *not* a control — see the
/// "Why no toggle" section below for the reasoning that still applies to
/// *why a silent no-op button is worse than no button*. What changed: this
/// card now offers extend/truncate/end buttons anyway, because the
/// established `KeepAwakeIntent`/`ReleaseAwakeIntent` precedent
/// (`SentryMobile/Intents/SentryIntents.swift`) shows the actual failure
/// mode isn't "a button exists" — it's "a button silently does nothing." A
/// button that visibly, immediately reports "not sent — no connection to
/// your Mac yet" on every tap (see `feedback`/`sendCommand(_:)` below) is the
/// honest version of "coming soon, and here's the control that'll work the
/// day it ships" — the same shape Siri's spoken dialog already uses for
/// `KeepAwakeIntent`.
///
/// **These buttons are real now.** They were originally inert (every tap
/// reported "not sent — no connection to your Mac yet") because
/// `StatsTransport.send(command:)` had no working conformer. It does now:
/// `LocalSyncClient.send(command:)` transmits over the live connection —
/// LAN (Bonjour) or remote (TLS-PSK), whichever `AppDataSource` resolved —
/// and `awaitStatus(forNonce:timeout:)` reports what the Mac actually did.
/// `sendCommand(_:)` below still never claims success unless a real
/// `ControlStatus` said so: a send failure, a silent Mac, and a Mac that
/// actively declined are three distinct messages, never collapsed into one
/// optimistic "Done."
///
/// **The haptics follow the same rule as the copy.** Each button produces
/// two: one when the request is issued, saying only which way the user pushed
/// (`.increase`/`.decrease`/`.end`), and one when the Mac answers, saying
/// what it actually did (`.confirmed`/`.rejected`). Nothing here buzzes
/// success at the moment of the tap, for exactly the reason nothing here
/// *prints* "Done." at the moment of the tap. See `SentryCommandHaptic`
/// (`SentryMobile/Theme/Haptics.swift`) for the full argument and the
/// alternatives it rejects.
///
/// **Why still no toggle.** A toggle needs a persistent, always-current
/// on/off binding to mean anything; this card has point-in-time taps plus
/// whatever `SystemSnapshot.sleepAssertion` the Mac last reported, with no
/// two-way binding in between. The extend/truncate/end buttons remain the
/// right shape: each tap is its own request-and-report round trip, not a
/// state the UI must keep synchronized between taps.
///
/// **What's real and shown:** the *current* sleep-assertion state as last
/// reported by the Mac, read straight off `SystemSnapshot.sleepAssertion` —
/// formatted with the same vocabulary `SleepControlCard`'s `activeDetail(for:)`
/// uses on the Mac side (mode label, reason string, countdown/"until turned
/// off").
struct SleepStatusCard: View {
    @Environment(\.themePalette) private var palette

    /// `nil` when the snapshot predates `sleepAssertion` being populated, or
    /// the Mac hasn't reported one yet — distinct from `.inactive`, which is
    /// a real "not preventing sleep right now" reading. Rendered as
    /// "Unavailable," never folded into the inactive case, so the two
    /// meanings ("we know it's off" vs "we don't know") stay distinguishable.
    let assertion: SleepAssertionState?

    /// The Mac this card's buttons would target — `Device.deviceID` from
    /// `DashboardViewModel.selectedDevice`, mirroring `ControlCommand
    /// .deviceID`'s doc comment ("Target Mac"). Falls back to `"unknown"`,
    /// the same placeholder `SentryIntents.swift`'s two intents already use
    /// when nothing better is available — there's no live pairing/device
    /// picker result to be more specific with yet either.
    var deviceID: String = "unknown"

    /// Whether the transport this state arrived over is currently down —
    /// `DashboardTabView`'s own unreachable predicate, the one that blanks
    /// every other value on the tab to "—". This card deliberately keeps
    /// rendering the last-reported assertion instead of blanking (a timed
    /// countdown carries its own end time and stays meaningful), but the
    /// *"● Active"* pill is a present-tense claim, and for an indefinite
    /// hold there is nothing self-carried backing it up: the exact
    /// failure this app exists to catch is a Mac that released its hold
    /// hours ago while the phone kept saying ON. So while unreachable, the
    /// pill downgrades to "Last reported" and the active detail carries an
    /// explicit as-of qualifier — the state stays visible, the tense stops
    /// lying. Defaulted `false` so previews and any pre-existing call site
    /// keep their meaning.
    var isMacUnreachable: Bool = false

    /// Non-nil for a few seconds right after a button tap — see
    /// `sendCommand(_:)`. Never claims success; always the honest "not
    /// connected yet" line, so a tap always gets a visible reaction instead
    /// of silently doing nothing.
    @State private var feedback: String?
    @State private var feedbackTask: Task<Void, Never>?

    /// The last command this card put on the wire, and the last answer it got
    /// back — the two triggers behind this card's haptics. See
    /// `SentryCommandHaptic` (`SentryMobile/Theme/Haptics.swift`) for why a
    /// command produces two of them rather than one, and `CommandTrace` just
    /// below for why each carries a nonce.
    @State private var issued: CommandTrace?
    @State private var answered: CommandTrace?

    /// One command's identity plus what happened to it.
    ///
    /// **The nonce is what makes this work as a haptic trigger, and it is the
    /// whole reason this is a struct rather than a bare
    /// `SentryCommandHaptic.Reply`.** `.sensoryFeedback(trigger:)` fires on a
    /// *change*, which is exactly the property that keeps a re-selected
    /// picker row silent (see `View.haptic(_:on:)`). Here the same property
    /// would work against the truth: tapping +15m twice, or having two
    /// commands in a row both come back `completed`, are two real events that
    /// a plain `Reply` would collapse into one value and therefore into one
    /// buzz. `ControlCommand.nonce` is unique per command by construction, so
    /// carrying it makes every issue and every answer a distinct value.
    private struct CommandTrace: Equatable {
        let nonce: String
        let commandType: String
        /// `nil` on the issue side — nothing has been answered yet.
        var reply: SentryCommandHaptic.Reply?

        /// What the tap says. See `SentryCommandHaptic.issued(commandType:)`.
        var issuedHaptic: SentryHaptic { SentryCommandHaptic.issued(commandType: commandType) }

        /// What the reply says, or `nil` while there isn't one (and for a
        /// reply this app has no honest word for).
        var outcomeHaptic: SentryHaptic? { reply.flatMap(SentryCommandHaptic.outcome(of:)) }
    }

    /// Split from `card` below rather than written as one property, because a
    /// single `body` carrying this view's `switch` *and* five trigger
    /// modifiers with closures is past what the type checker will solve in
    /// reasonable time. Behaviourally identical; the modifiers apply to the
    /// same view either way.
    var body: some View {
        card
            // Beat one: which way the user pushed, the instant they pushed
            // it. Three lines rather than one branching modifier because each
            // names the meaning it carries — the shape
            // `View.haptic(_:on:when:)` was written for. Nothing here claims
            // the Mac agreed; that is beat two.
            .haptic(.increase, on: issued) { $0?.issuedHaptic == .increase }
            .haptic(.decrease, on: issued) { $0?.issuedHaptic == .decrease }
            .haptic(.end, on: issued) { $0?.issuedHaptic == .end }
            // Beat two: what the Mac actually did. Driven off the reply,
            // never off the tap — an optimistic success buzz for a command
            // the Mac then refused is the lie this whole card is built to
            // avoid. A reply this app has no word for is silent, deliberately.
            .haptic(.confirmed, on: answered) { $0?.outcomeHaptic == .confirmed }
            .haptic(.rejected, on: answered) { $0?.outcomeHaptic == .rejected }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            header
            switch assertion {
            case .active(let mode, let expiresAt, let reason):
                activeDetail(mode: mode, expiresAt: expiresAt, reason: reason)
            case .inactive:
                Text("Sleep behaves normally on this Mac.")
                    .scaledFont(palette, size: 11)
                    .foregroundStyle(palette.textTertiary)
            case nil:
                Text("Unavailable")
                    .scaledFont(palette, size: 11)
                    .foregroundStyle(palette.textTertiary)
            }
            if let feedback {
                Text(feedback)
                    .scaledFont(palette, size: 10, weight: .medium)
                    .foregroundStyle(palette.warning)
                    .transition(.opacity)
            } else {
                remoteControlNote
            }
        }
        .padding(palette.spacing * 1.4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(palette)
        .overlay(
            RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                .stroke(isActive ? palette.accent.opacity(0.5) : palette.separator, lineWidth: 1)
        )
        .animation(.default, value: feedback)
    }

    /// Raw `.active` — the layout gate. Deliberately not
    /// `isCrediblyActive`: a hold whose deadline has passed still renders
    /// the active layout, because an ended hold is worth *explaining*
    /// (see `expiredNotice`), not silently collapsing into "Sleep behaves
    /// normally" on the phone's say-so alone.
    private var isActive: Bool {
        if case .active = assertion { return true }
        return false
    }

    /// Whether the reported hold is timed and past its own `expiresAt` —
    /// the case whose present-tense chrome (title, pill, live countdown)
    /// must all stand down, per `SleepAssertionState.hasCertainlyEnded
    /// (asOf:)`'s argument: the recorded deadline released this hold
    /// whether or not the Mac ever got another snapshot out.
    ///
    /// `Date()` is read at body-render time, so the boundary elapsing
    /// while the card sits on screen isn't self-correcting — the same
    /// documented limit as `KeepAwakePage.countdown` on the watch, and
    /// the same resolution: the next received snapshot is the only source
    /// that actually knows, and it corrects this the moment it lands.
    private var hasCertainlyEnded: Bool {
        assertion?.hasCertainlyEnded(asOf: Date()) ?? false
    }

    /// Nocturne redesign spec: when active, this card leads with "Preventing
    /// sleep" + an "● Active" status pill in the accent color — the header
    /// used to always say "Sleep Prevention" regardless of state, with the
    /// active/inactive distinction buried in a 10px subtitle underneath.
    private var header: some View {
        // Present-tense chrome ("Keeping", the filled glyph) only while the
        // claim is still credible — a timed hold past its own deadline gets
        // the inactive wording and lets `expiredNotice` explain.
        let claimsActive = isActive && !hasCertainlyEnded
        return AdaptiveRow(spacing: palette.spacing, verticalAlignment: .center) {
            HStack(spacing: palette.spacing) {
                Image(systemName: claimsActive ? "moon.zzz.fill" : "moon.zzz")
                    .foregroundStyle(claimsActive ? palette.accent : palette.textSecondary)
                    // `minWidth`, not `width`: the 16pt column keeps the two
                    // header variants' text aligned at normal sizes, but a
                    // hard width would clip the glyph once it scales.
                    .frame(minWidth: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(claimsActive ? "Keeping Mac awake" : "Keep Mac awake")
                        .scaledFont(palette, size: 13, weight: .semibold)
                        .foregroundStyle(palette.textPrimary)
                    if !isActive {
                        Text("Reporting from your Mac")
                            .scaledFont(palette, size: 10)
                            .foregroundStyle(palette.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } trailing: {
            // "● Active" is a present-tense claim about a machine this
            // phone can't currently hear from when `isMacUnreachable` —
            // so the pill says what is actually known: this is the Mac's
            // last report, not a live reading. An ended hold shows no pill
            // at all; `expiredNotice` carries that explanation.
            if claimsActive {
                if isMacUnreachable {
                    lastReportedPill
                } else {
                    activeStatusPill
                }
            }
        }
    }

    private var activeStatusPill: some View {
        HStack(spacing: 4) {
            Text("●")
                .scaledSystemFont(size: 8)
            Text("Active")
                .scaledFont(palette, size: 11, weight: .semibold)
        }
        .foregroundStyle(palette.accent)
    }

    /// The unreachable-Mac stand-in for `activeStatusPill` — secondary, no
    /// dot, past tense. See `isMacUnreachable`'s doc comment for why the
    /// accent "● Active" must not survive a dead transport.
    private var lastReportedPill: some View {
        Text("Last reported")
            .scaledFont(palette, size: 11, weight: .semibold)
            .foregroundStyle(palette.textTertiary)
    }

    @ViewBuilder
    private func activeDetail(mode: AwakeMode, expiresAt: Date?, reason: String) -> some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            if let expiresAt {
                if hasCertainlyEnded {
                    // A `.timer` text whose date has passed silently counts
                    // *up* — rendering as a hold that's been running three
                    // minutes rather than one that ended three minutes ago,
                    // the exact trap `KeepAwakePage.countdown` documents on
                    // the watch. Same fix, same wording, so the two devices
                    // describe one situation identically. The adjust
                    // buttons hide with it: "+15m" on a hold that already
                    // released is an offer the Mac would rightly decline.
                    expiredNotice
                } else {
                    // SwiftUI's `.timer` text style redraws itself every second
                    // and counts down to `expiresAt` on its own — no local
                    // `TimelineView`/tick logic needed to match the Mac card's
                    // live countdown. Explicit `design: .monospaced` (true SF
                    // Mono), not just `.monospacedDigit()` on the system font,
                    // per the redesign spec's "SF Mono tabular for every
                    // numeric readout" — this is the one big/hero numeric value
                    // on this card, so it gets the 24px treatment.
                    //
                    // `monospacedDigit: true` on top of `design: .monospaced` is
                    // not redundant here: SF Mono is uniform-width for *all*
                    // glyphs, but a `.timer` text redraws every second and the
                    // tabular-figures feature is what guarantees the seconds
                    // column doesn't shift as digits change. Scaling preserves
                    // both — the modifier scales the point size and rebuilds the
                    // same monospaced font at the new size.
                    Text(expiresAt, style: .timer)
                        .scaledSystemFont(size: 24, weight: .semibold, design: .monospaced, monospacedDigit: true)
                        .foregroundStyle(palette.textPrimary)
                    adjustRow
                }
            } else {
                Text("No countdown — ends when turned off on the Mac")
                    .scaledFont(palette, size: 11)
                    .foregroundStyle(palette.textTertiary)
            }
            if isMacUnreachable {
                unreachableQualifier
            }
            DashboardDetailRow(label: String(localized: "Mode"), value: mode.mobileShortLabel)
            Text(reason)
                .scaledFont(palette, size: 10)
                .foregroundStyle(palette.textTertiary)
                // No `.lineLimit(2)` any more. The reason string is the Mac's
                // own explanation of why it's staying awake; two lines held it
                // at the design size, but at an accessibility size the same
                // string needs five or six and the limit would silently eat
                // the end of the sentence. Vertical space is free in this
                // ScrollView.
                .fixedSize(horizontal: false, vertical: true)
            endNowButton
        }
    }

    /// The timed hold's deadline has passed — same wording as
    /// `KeepAwakePage.countdown`'s expired branch on the watch, on purpose:
    /// one situation, one sentence, whichever device is in hand. "Waiting
    /// for your Mac to confirm" is the honest tense — the recorded deadline
    /// guarantees the release happened (see `SleepAssertionState
    /// .hasCertainlyEnded(asOf:)`), but only the Mac's next snapshot can
    /// say so, and this card never claims what it hasn't been told.
    private var expiredNotice: some View {
        Text("This hold's time is up. Waiting for your Mac to confirm it ended.")
            .scaledFont(palette, size: 11)
            .foregroundStyle(palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The as-of qualifier shown under the active detail while the
    /// transport is down — the sentence that keeps a last-reported
    /// indefinite hold from reading as live telemetry. Present tense about
    /// the *connection* (which this phone does know), past tense about the
    /// *hold* (which it no longer does).
    private var unreachableQualifier: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .scaledSystemFont(size: 10)
            Text("Your Mac is unreachable right now — this is its last report, and the hold may have ended since.")
                .scaledFont(palette, size: 10)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(palette.warning)
    }

    /// Extend/truncate only apply to a timed hold (an `expiresAt` to move) —
    /// same scoping `PowerControlService.adjustAssertion(bySeconds:)` enforces
    /// on the Mac side, so a tap here would ask for exactly what that method
    /// would accept once a real command reaches it.
    ///
    /// Three side-by-side pills fit comfortably at design sizes; at an
    /// accessibility size their labels plus padding exceed the card's width
    /// and the last one would be pushed off the edge (a `Button` label
    /// doesn't wrap or shrink to make room). Stacking them keeps all three
    /// reachable, which matters more here than on a read-only row: these are
    /// the card's only controls.
    private var adjustRow: some View {
        AdaptiveStack(spacing: palette.spacing * 0.6) {
            adjustButton("-15m", commandType: "truncateAwake", seconds: -15 * 60)
            adjustButton("+15m", commandType: "extendAwake", seconds: 15 * 60)
            adjustButton("+1h", commandType: "extendAwake", seconds: 60 * 60)
        }
    }

    private func adjustButton(_ title: String, commandType: String, seconds: TimeInterval) -> some View {
        Button(title) {
            sendCommand(
                ControlCommand(
                    deviceID: deviceID,
                    issuedAt: Date(),
                    commandType: commandType,
                    parametersJSON: #"{"deltaSeconds":\#(Int(seconds))}"#,
                    nonce: UUID().uuidString,
                    expiresAt: Date().addingTimeInterval(5 * 60)
                )
            )
        }
        .buttonStyle(.plain)
        .scaledFont(palette, size: 10, weight: .medium)
        .foregroundStyle(palette.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius * 0.6, style: .continuous))
    }

    private var endNowButton: some View {
        Button("End Now") {
            sendCommand(
                ControlCommand(
                    deviceID: deviceID,
                    issuedAt: Date(),
                    commandType: "releaseAwake",
                    parametersJSON: "{}",
                    nonce: UUID().uuidString,
                    expiresAt: Date().addingTimeInterval(5 * 60)
                )
            )
        }
        .buttonStyle(.plain)
        .scaledFont(palette, size: 10, weight: .medium)
        .foregroundStyle(palette.danger)
    }

    /// Constructs and sends a real `ControlCommand` — through the app-wide
    /// `AppDataSource.shared.transport` (`SentryMobile/Data/AppDataSource.swift`)
    /// every other call site in this app now reads from, not a locally
    /// constructed `MockDataSource()` — then always shows the honest
    /// result, never a fabricated success. Four outcomes, four messages,
    /// never collapsed: demo mode (nothing to send to — `MockDataSource
    /// .send(command:)` is a documented no-op, so claiming "Sent" would be
    /// the lie this guard exists to prevent), a send that threw, a real
    /// send with no `ControlStatus` reply inside `SentryIntents
    /// .statusTimeout`, and a reply reporting what the Mac actually did.
    /// Mirrors `SentryIntents.sendAndDescribe(_:whenCompleted:)`'s
    /// "construct, send, report what actually happened" shape, including
    /// its demo-mode guard.
    private func sendCommand(_ command: ControlCommand) {
        feedbackTask?.cancel()
        feedback = String(localized: "Sending…")
        // Beat one of this card's haptics — see the modifiers on `body` and
        // `SentryCommandHaptic`. Recorded here rather than inside each
        // button's action so the three adjust buttons and End Now cannot
        // drift apart on it: they all come through this one function, so the
        // rule "which command it was decides how it feels" is stated once.
        issued = CommandTrace(nonce: command.nonce, commandType: command.commandType)
        feedbackTask = Task {
            let transport = await AppDataSource.shared.transport
            // Demo mode: `MockDataSource.send(command:)` deliberately
            // no-ops without throwing and `awaitStatus` returns `nil`
            // immediately, so without this guard the card would claim
            // "Sent, but no reply from your Mac yet." for a command that
            // was never transmitted anywhere. Say what actually happened
            // instead: there is no Mac on the other end of demo data.
            guard !(transport is MockDataSource) else {
                feedback = String(localized: "Demo mode — there's no Mac connected, so nothing was sent.")
                record(.undelivered, for: command)
                await clearFeedbackAfterDelay()
                return
            }
            do {
                try await transport.send(command: command)
            } catch {
                feedback = String(localized: "Not sent — \(error.localizedDescription)")
                record(.undelivered, for: command)
                await clearFeedbackAfterDelay()
                return
            }
            guard let status = await transport.awaitStatus(
                forNonce: command.nonce,
                timeout: SentryIntents.statusTimeout
            ) else {
                feedback = String(localized: "Sent, but no reply from your Mac yet.")
                record(.unanswered, for: command)
                await clearFeedbackAfterDelay()
                return
            }
            feedback = status.state == "completed" ? String(localized: "Done.") : status.message
            record(.answered(state: status.state), for: command)
            await clearFeedbackAfterDelay()
        }
    }

    /// Beat two: publishes what the Mac did, for the `.confirmed`/`.rejected`
    /// modifiers on `body` to read.
    ///
    /// **The cancellation check is the load-bearing line.** A second tap
    /// cancels the first tap's `feedbackTask`, but a cancelled task can still
    /// be sitting inside `awaitStatus`, which returns `nil` on cancellation
    /// exactly as it does on a timeout. Without this guard, tapping +15m
    /// twice in quick succession would buzz `.rejected` for the first
    /// command — reporting a refusal that never happened, for a request the
    /// user themselves superseded.
    private func record(_ reply: SentryCommandHaptic.Reply, for command: ControlCommand) {
        guard !Task.isCancelled else { return }
        answered = CommandTrace(nonce: command.nonce, commandType: command.commandType, reply: reply)
    }

    private func clearFeedbackAfterDelay() async {
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        guard !Task.isCancelled else { return }
        feedback = nil
    }

    private var remoteControlNote: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "info.circle")
                .scaledSystemFont(size: 10)
            Text("Reaches your Mac over local Wi-Fi, or from anywhere if you've set up Remote Access. Sentry must be open on your Mac.")
                .scaledFont(palette, size: 10)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(palette.textTertiary)
    }
}

// MARK: - AwakeMode labels (mobile)

/// iOS-local vocabulary for `AwakeMode`, mirroring
/// `Sentry/Dropdown/SleepControlCard.swift`'s `shortLabel` extension. Kept
/// separate rather than shared for the same reason as that file's own doc
/// comment: `SentryKit` is shared with the MCP tool, which shouldn't inherit
/// either app's UI phrasing, and the Mac extension lives in the `Sentry` app
/// target this target can't import.
extension AwakeMode {
    var mobileShortLabel: String {
        switch self {
        case .displayAndSystem: return String(localized: "Keep display on")
        case .systemOnly: return String(localized: "System only")
        case .systemWhileOnAC: return String(localized: "Only while plugged in")
        }
    }
}
