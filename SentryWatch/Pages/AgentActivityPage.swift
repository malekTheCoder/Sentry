import SwiftUI

// MARK: - AgentActivityPage: what an AI agent has been doing on the Mac

/// The "agent activity" page of the redesigned, horizontally-paged Watch app:
/// a glanceable answer to "has anything been talking to my Mac through
/// Sentry's MCP server?"
///
/// **What it's summarising.** The Mac keeps `MCPActivityLog`
/// (`SentryKit/Services/MCPAccessController.swift`) — an in-memory ring
/// buffer of every tool call an MCP client made this session, which the
/// Mac's own AI Access settings pane renders in full (timestamp, client
/// identity, tool, arguments, allow/deny). This page is the wrist-sized
/// projection of that: a count, a recency, and the names of the last few
/// tools. Deliberately *not* the arguments summary or the allow/deny
/// decision — both are audit details that need reading, not glancing, and a
/// truncated audit trail is worse than none because it invites a conclusion
/// the truncation can't support.
///
/// **Why primitives instead of `WatchRelaySnapshot` or `MCPActivityLogEntry`.**
/// Same reasoning as `KeepAwakePage`'s header, plus one specific to this
/// page: `MCPActivityLogEntry` isn't `Codable` on purpose (see its own doc
/// comment — it never leaves the Mac's process), so *something* has to
/// flatten it for the relay regardless. Doing that flattening on the Mac/phone
/// side and handing this page four inert values keeps the projection in one
/// place and keeps this file free of any dependency on the MCP types, which
/// `SentryKit_watchOS` does not even compile.
///
/// **The zero case is the design centre, not the fallback.** Most users, most
/// of the time, have no agent activity at all — an empty MCP log is the
/// *healthy* state, not an error or a loading state. So zero gets a composed
/// empty state (`emptyState` below) rather than a bare "0" hanging under a
/// heading, and its icon and colour are calm and secondary. A red badge, a
/// warning glyph, or a spinner here would train users to read "nothing has
/// happened" as "something is broken."
///
/// **`nil` is not zero, and the difference is load-bearing here more than
/// anywhere.** "No agent touched your Mac" and "your Mac didn't tell us
/// whether an agent touched it" are opposite reassurances. `toolCallCount ==
/// 0` renders the calm empty state; `toolCallCount == nil` renders an em dash
/// and says plainly that the reading is missing. The same rule that keeps
/// `SleepStatusCard` from folding `nil` into `.inactive` on the phone applies
/// with more force to a security-adjacent readout: a page that renders an
/// unreported count as a confident "0" would be manufacturing an all-clear.
///
/// **Staleness is stated, not styled away.** `isStale` gets its own labelled
/// banner *above* the numbers and dims the numbers themselves, rather than
/// hiding them. Hiding would lose real information (a stale count of 12 still
/// tells you 12 calls happened at some point); showing them undimmed would
/// present an old reading as current. This mirrors the app-wide convention
/// `FreshnessBadge` sets — never a bare number, always paired with how old it
/// is.
///
/// **Why not `FreshnessBadge` itself.** It derives its tier from a timestamp
/// via `Freshness(lastSeen:)`. This page is *told* whether the reading is
/// stale by whoever owns the relay, and `lastActivityAt` is not the reading's
/// age — it's when an agent last did something, which can be hours old on a
/// perfectly fresh reading. Feeding `lastActivityAt` to `FreshnessBadge`
/// would produce a badge that says "stale" about a live, correct "no activity
/// in the last three hours." So the boolean the caller supplies is the
/// authority, and this page does not second-guess it with a derivation of its
/// own that could disagree.
///
/// **Sizing and colour.** Scrolls (Digital Crown) with no fixed frames, so a
/// 40mm face at an accessibility text size overflows downward rather than
/// clipping; system semantic colours only, following `ContentView` and
/// `FreshnessBadge` rather than the Mac/iPhone `palette.*` tokens, which the
/// Watch app does not have.
///
/// **What was wrong with the first version of this page, and what fixed it.**
/// The unreported state — which, per the note above, is what *every* user sees
/// *every* time, because nothing populates these fields yet — rendered a bare
/// `title2` em dash left-aligned in the middle of an otherwise empty screen,
/// with the explanation beneath it. It read as a rendering failure. The dash
/// was doing the right job (this codebase's placeholder for "no value") in the
/// wrong shape: floating on its own, an em dash is indistinguishable from a
/// glyph that failed to load.
///
/// It now sits in the well of a `SentryDial` drawn in its not-reported form —
/// a dotted, unfilled ring. That is the same mark `OverviewPage`'s metric
/// dials use for a metric the Mac didn't send, so a user meets one visual
/// vocabulary for absence across the whole app rather than a dash here and a
/// gap there, and the ring gives the dash a container that positively asserts
/// "this is an empty reading" instead of leaving it to look like debris. The
/// states are also centred rather than flush-left: with one short line of
/// content and a whole watch face to put it on, left alignment was leaving the
/// page looking like the top of a list that never arrived.
///
/// **No arc is ever filled on this page, in any state.** A tool-call count has
/// no denominator — there is no "out of" for "12 calls" — and drawing a
/// partial arc would require inventing a maximum, which would be a fabricated
/// number of exactly the kind the rest of this file argues against. The dial
/// appears here only in its dotted, valueless form, as a mark of absence. The
/// count, when there is one, stays a plain numeral.
struct AgentActivityPage: View {

    /// How many MCP tool calls the Mac has logged, or `nil` if it didn't
    /// report the figure. Never rendered as `0` when it is `nil` — see this
    /// type's header.
    let toolCallCount: Int?

    /// When the most recent tool call happened, or `nil` if unreported *or*
    /// if there has been no call to have a time for. Both absences render as
    /// "—"; neither is turned into "just now" or a zeroed date.
    let lastActivityAt: Date?

    /// Names of the most recent tools, newest first — e.g. `get_stats`,
    /// `keep_awake`. Not optional, because an empty array is genuinely
    /// meaningful here ("no names to show"), and merging that with "not
    /// reported" would be exactly the collapse the rest of this file argues
    /// against. When the count is unreported but names came through, the
    /// names are still shown: they're real, and suppressing them would
    /// discard a reading the Mac actually sent.
    let recentToolNames: [String]

    /// Whether this reading is old enough that it shouldn't be read as
    /// current. Supplied by the caller rather than derived here — see the
    /// header's note on why deriving it from `lastActivityAt` would be wrong.
    let isStale: Bool

    /// The kill switch: asks the Mac (via the phone relay — the shell owns
    /// the `ControlCommand`, same split as `KeepAwakePage`'s closures) to
    /// pause all agent access. Optional with a `nil` default so the existing
    /// previews stay honest presentational fixtures; `ContentView` always
    /// wires it. Shown in *every* data state, including "not reported" — the
    /// relay not carrying agent activity says nothing about whether an agent
    /// is misbehaving right now, and a stop control that hides exactly when
    /// the user is worried would be the wrong kind of quiet.
    var onStopAgents: (() -> Void)? = nil

    /// Whether the Mac's agent kill switch is currently engaged —
    /// `WatchRelaySnapshot.agentAccessPaused` passed straight through. `nil`
    /// (the state essentially every user is in today — see that field's doc
    /// comment for the composition-root hook still outstanding) renders
    /// exactly like `false`: neither the paused banner nor the resume
    /// button, because both would be asserting a pause this page cannot
    /// confirm. That asymmetry (unlike `toolCallCount`, where `nil` gets its
    /// own dedicated state) is deliberate — the only two controls this value
    /// governs are "show a resume button" and "show a paused banner," and
    /// both are opt-in UI a `nil` reading has no business turning on. The
    /// existing "Stop Agents" button already covers "we don't know," the
    /// same way it always has.
    var agentAccessPaused: Bool? = nil

    /// Un-pauses agent access — `WatchResumeAgentsIntent`'s button
    /// counterpart, shown only while `agentAccessPaused == true`. Optional
    /// with a `nil` default for the same preview-fixture reason
    /// `onStopAgents` is.
    var onResumeAgents: (() -> Void)? = nil

    /// How many tool names to list. Four rows plus the header and count fit a
    /// 40mm face without scrolling at default text size; beyond that the list
    /// stops being glanceable and becomes an audit trail, which is the Mac
    /// pane's job.
    /// Three, down from four. The fourth row cost about 16pt and this page's
    /// action button was already fighting for the bottom of a 42mm face — and
    /// a "+N more" line below the list already tells the reader the list is a
    /// sample rather than the whole log, so trimming it loses no information,
    /// only examples.
    private static let maximumListedTools = 3

    /// Diameter of the dotted "no reading" ring in `unreportedState`. Tied to
    /// `.title3` — the text style of the em dash it encloses — so the ring and
    /// its contents grow together under Dynamic Type instead of the dash
    /// outgrowing its well. Larger than `OverviewPage`'s 46pt metric dials
    /// because this one is alone on the page rather than one of three in a
    /// row, and at 40pt it read as a stray bullet rather than as the page's
    /// subject. Capped at 50 rather than the 64 first drawn: at 64 the
    /// explanatory sentence beneath ran off the bottom of a 46mm face, and the
    /// fine print explaining *why* nothing is reported is the part of this
    /// state that actually teaches the user something. The ring is the mark;
    /// the sentence is the message, and the mark does not get to crowd it out.
    @ScaledMetric(relativeTo: .title3) private var baseDialDiameter: CGFloat = 50

    private var dialDiameter: CGFloat { baseDialDiameter * WatchFace.scale }

    /// Every colour on this page resolves through the theme the phone
    /// relayed — see `WatchPalette`. The `.red`/`.orange`/`.green` literals
    /// this page used to carry were the last hardcoded ones in the app.
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WatchLayout.sectionSpacing) {
                headerRow
                WatchCard { content }
                // While paused, the resume button replaces the stop button
                // rather than sitting beside it — "Stop Agents" while agent
                // access is already stopped is a control offering to do
                // something that is already true, and a wrist-sized screen
                // has no room for a disabled duplicate.
                if agentAccessPaused == true, onResumeAgents != nil {
                    resumeAgentsButton
                } else if onStopAgents != nil {
                    stopAgentsButton
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Agent Activity")
    }

    // MARK: - Header

    /// Title and state pills on one row, mirroring `OverviewPage`'s header.
    ///
    /// **Why they were merged.** Each pill used to occupy a full row of its
    /// own below a full-row title, so the common paused case spent about 50pt
    /// of a 42mm face on two short phrases — and pushed this page's one
    /// control, the kill switch, off the bottom. On a paged app the user has
    /// just swiped to get here, so the title is orientation rather than news;
    /// it can share a line with the state it qualifies.
    ///
    /// `ViewThatFits` handles the case where both pills apply at once — the
    /// candidates are pills and a `Text` with honest intrinsic widths, which
    /// is the precondition the API needs (and which `OverviewPage`'s dials
    /// famously do not meet).
    private var headerRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                titleLabel
                Spacer(minLength: 4)
                pills
            }
            VStack(alignment: .leading, spacing: 5) {
                titleLabel
                HStack(spacing: 5) { pills }
            }
        }
    }

    private var titleLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .foregroundStyle(palette.accent)
            Text("Agent Activity")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var pills: some View {
        if isStale { staleBanner }
        if agentAccessPaused == true { pausedBanner }
    }

    /// States plainly, above everything else on the page, that the kill
    /// switch is currently engaged — the fact a user checking this page is
    /// most likely here to confirm. Distinct styling from `staleBanner`
    /// (a filled icon, not orange) since the two can be true at once and
    /// must read as two different facts, not variations on one.
    private var pausedBanner: some View {
        // A one-line pill rather than the wrapping sentence this used to be.
        // "Agent access is paused on your Mac." ran to three lines at 42mm and
        // pushed the count — the thing the page exists to show — most of the
        // way off the screen, which is the same "cut off" failure the rest of
        // this redesign is fixing. The full sentence survives verbatim as the
        // accessibility label, so nothing is lost for a VoiceOver reader; the
        // visual carries "Paused" plus a slashed-bolt glyph plus the theme's
        // danger colour, which is three independent cues for two words.
        StatusPill(text: "Agents paused", symbol: "bolt.slash.fill", tint: palette.danger)
            .accessibilityLabel("Agent access is paused on your Mac.")
    }

    /// Named plainly rather than shown as a bare icon or a colour shift: the
    /// user has to be able to tell a stale reading from a current one while
    /// glancing, and only words do that reliably.
    private var staleBanner: some View {
        // Same compaction as `pausedBanner`, and the two must stay visually
        // distinct because both can be true at once: this one is the theme's
        // warning colour with a clock glyph, that one is danger with a bolt.
        StatusPill(text: "Out of date", symbol: "clock.badge.exclamationmark", tint: palette.warning)
            .accessibilityLabel("Out of date — your Mac hasn't reported recently.")
    }

    @ViewBuilder
    private var content: some View {
        switch toolCallCount {
        case nil:
            unreportedState
        case 0:
            emptyState
        default:
            populatedState
        }
    }

    // MARK: - States

    /// The Mac didn't send a count. Distinct from zero in both glyph and
    /// wording, so the two can never be confused at a glance — this one names
    /// the *link* that's missing rather than making a claim about agents.
    ///
    /// This is the state essentially every user is in, all the time (the
    /// fields are wired and always `nil` — see `WatchRelaySnapshot`), so it
    /// gets the most composition on the page rather than the least. See the
    /// type header on why the em dash moved into a dotted dial.
    private var unreportedState: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(spacing: 6) {
                SentryDial(fraction: nil, tint: palette.textSecondary, lineWidth: 4) {
                    Text(WatchFormatting.placeholder)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .frame(maxWidth: .infinity, maxHeight: dialDiameter)

                Text("Not reported by your Mac")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tool call count not reported by your Mac")

            if recentToolNames.isEmpty {
                Text("This build of Sentry on your Mac may not send agent activity yet.")
                    .font(.caption2)
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Names arrived without a count. Show them — they're a real
                // reading — but do not infer the count from
                // `recentToolNames.count`: that array is capped at the last
                // few calls by construction, so its length is a floor, not a
                // total, and printing it as one would be a fabricated number.
                toolList
            }
        }
    }

    /// The healthy zero. Reads as a statement of fact, not as a void: a
    /// secondary-coloured glyph, a plain sentence, and one line explaining
    /// what would appear here if something did happen — so a user who has
    /// never seen this page populated still learns what it's for.
    ///
    /// Centred and stacked rather than left-aligned in a row, matching
    /// `unreportedState` above — but deliberately **not** given a dial. Zero
    /// is a real reading, and the dotted ring is this app's mark for the
    /// absence of one; putting it here would say "we weren't told", which is
    /// the opposite of what this state means. A `checkmark.circle` is the
    /// right glyph precisely because it is a closed, complete ring: the two
    /// read as opposites at a glance, which is the whole point of keeping
    /// `nil` and `0` visually distinct.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 4) {
                Image(systemName: "checkmark.circle")
                    .font(.title2)
                    .foregroundStyle(palette.textSecondary)
                Text("No agent activity")
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)

            Text("No AI assistant has used Sentry's tools on your Mac. Tool calls show up here as they happen.")
                .font(.caption2)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)

            // Even at zero, "last activity" can be a real, non-nil time — an
            // agent that ran and then fell outside the log's window. Shown
            // only when it exists; never invented to fill the row.
            if lastActivityAt != nil {
                HStack {
                    Spacer(minLength: 0)
                    lastActivityColumn
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// **The count and the last-activity time share a row.** Stacked, as they
    /// were, the count block alone stood about 50pt tall and the two together
    /// pushed the page's one *control* — Stop Agents, or Resume Agents while
    /// paused — clean off the bottom of a 42mm face. A control the user has
    /// to go looking for is the failure this codebase already called out on
    /// `KeepAwakePage`'s end button, and it applies with more force to a kill
    /// switch. Side by side they also read better: "128 tool calls, last one
    /// 58 seconds ago" is one sentence about one thing, and the count's own
    /// left-aligned column left the right half of the widest line on the
    /// screen empty.
    private var populatedState: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                countLine(
                    value: toolCallCount.map(String.init) ?? "—",
                    caption: toolCallCount == 1 ? "tool call" : "tool calls"
                )
                Spacer(minLength: 4)
                lastActivityColumn
            }
            if !recentToolNames.isEmpty {
                Rectangle()
                    .fill(palette.separator)
                    .frame(height: 1)
            }
            toolList
        }
        // Stale numbers stay legible but visibly recede, so the banner above
        // isn't the only cue. Not hidden: an old count is still information.
        .opacity(isStale ? 0.6 : 1)
    }

    // MARK: - Pieces

    private func countLine(value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(palette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(caption)")
    }

    /// Relative rather than an absolute clock time: "3 min. ago" answers the
    /// question a glance is actually asking, and doesn't require the reader to
    /// subtract. `nil` is an em dash — the row stays so the layout doesn't
    /// shift between states, but it makes no claim.
    ///
    /// **Why `RelativeDateTimeFormatter` and not `Text(_:style: .relative)`.**
    /// The `.relative` text style was the first attempt. It renders an
    /// *unsigned* duration with no direction word — the offscreen render came
    /// out as a bare "5 mths, 12 days", which reads identically whether the
    /// call happened five months ago or is somehow five months in the future,
    /// and on a page whose entire purpose is "when did something last touch my
    /// Mac" that ambiguity is the one thing it must not have. The formatter
    /// below always says "ago" (or "in", if a clock skew ever hands us a
    /// future timestamp — which is itself worth seeing rather than hiding).
    ///
    /// The tradeoff `.relative` was buying is real and is given up knowingly:
    /// this string is computed once per render and does not tick. That is
    /// acceptable here and would not be on `KeepAwakePage`'s countdown —
    /// "4 min. ago" silently aging into "5 min. ago" misleads nobody, whereas
    /// a frozen countdown would.
    private var lastActivityColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(lastActivityAt.map { Self.relativeLabel(for: $0) } ?? "—")
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(palette.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("last")
                .font(.caption2)
                .foregroundStyle(palette.textTertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(lastActivityAt == nil ? "Last activity not reported" : "Last activity")
    }

    /// Abbreviated units ("3 min. ago", not "3 minutes ago") because this
    /// shares a single line with its label on a 40mm face; `.numeric` rather
    /// than `.named` so a call from earlier today never renders as the vaguer
    /// "yesterday"/"last week" phrasing.
    static func relativeLabel(for date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Red like `KeepAwakePage.endButton` and for the same reason — a
    /// consequence-bearing control kept visually distinct from anything a
    /// thumb might be reaching for — and worded as what it does on the *Mac*,
    /// since the effect is on a machine the user isn't looking at. No local
    /// confirmation sheet: the outcome sentence the relay chain returns is
    /// surfaced by the shell (`ContentView`'s alert), and un-pausing is one
    /// switch away in Sentry on the Mac, so the action is cheap to undo.
    /// This page deliberately does not render a "paused" state of its own:
    /// the relay payload doesn't carry the kill-switch flag, and drawing a
    /// state the Mac never reported would be fabricating a reading.
    private var stopAgentsButton: some View {
        Button(role: .destructive) {
            onStopAgents?()
        } label: {
            Text("Stop Agents on Mac")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(WatchActionButtonStyle(tint: palette.danger))
        .accessibilityHint("Pauses all AI agent access to your Mac")
    }

    /// The un-pause counterpart, shown in place of `stopAgentsButton` while
    /// `agentAccessPaused == true`. Green rather than red — this button
    /// takes an action that *relieves* the alarming state `pausedBanner`
    /// just named, so it should not read as another warning.
    private var resumeAgentsButton: some View {
        Button {
            onResumeAgents?()
        } label: {
            Text("Resume Agents on Mac")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(WatchActionButtonStyle(tint: palette.success))
        .accessibilityHint("Resumes AI agent access to your Mac")
    }

    @ViewBuilder
    private var toolList: some View {
        if !recentToolNames.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(recentToolNames.prefix(Self.maximumListedTools).enumerated()), id: \.offset) { _, name in
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                        // Tool identifiers are snake_case and can be long
                        // (`get_agent_activity`); truncating the *head* keeps
                        // the distinguishing suffix visible on a 40mm face,
                        // where the shared `get_`/`set_` prefixes are the
                        // least informative part.
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if recentToolNames.count > Self.maximumListedTools {
                    Text("+\(recentToolNames.count - Self.maximumListedTools) more")
                        .font(.caption2)
                        .foregroundStyle(palette.textSecondary)
                }
            }
        }
    }
}

// MARK: - Previews

// `ForEach` over `enumerated()` keyed by offset rather than by name: tool
// names repeat constantly in a real log (three `get_stats` calls in a row is
// the normal shape), and keying by the string would collapse them into one
// row.

#if DEBUG
#Preview("Empty — the common case") {
    AgentActivityPage(
        toolCallCount: 0,
        lastActivityAt: nil,
        recentToolNames: [],
        isStale: false
    )
}

#Preview("Populated") {
    AgentActivityPage(
        toolCallCount: 12,
        lastActivityAt: Date().addingTimeInterval(-180),
        recentToolNames: ["get_stats", "get_agent_activity", "keep_awake", "get_stats", "list_alert_rules"],
        isStale: false
    )
}

#Preview("Stale") {
    AgentActivityPage(
        toolCallCount: 12,
        lastActivityAt: Date().addingTimeInterval(-9000),
        recentToolNames: ["get_stats", "keep_awake"],
        isStale: true
    )
}

#Preview("Paused — resume control shown") {
    AgentActivityPage(
        toolCallCount: 4,
        lastActivityAt: Date().addingTimeInterval(-600),
        recentToolNames: ["get_stats"],
        isStale: false,
        agentAccessPaused: true,
        onResumeAgents: {}
    )
}

/// The absence that must never render as a zero.
#Preview("Unreported") {
    AgentActivityPage(
        toolCallCount: nil,
        lastActivityAt: nil,
        recentToolNames: [],
        isStale: false
    )
}
#endif
