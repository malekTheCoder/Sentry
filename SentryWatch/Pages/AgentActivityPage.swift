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

    /// How many tool names to list. Four rows plus the header and count fit a
    /// 40mm face without scrolling at default text size; beyond that the list
    /// stops being glanceable and becomes an audit trail, which is the Mac
    /// pane's job.
    private static let maximumListedTools = 4

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                if isStale {
                    staleBanner
                }
                content
                if onStopAgents != nil {
                    stopAgentsButton
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Agent Activity")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            Text("Agent Activity")
                .font(.headline)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    /// Named plainly rather than shown as a bare icon or a colour shift: the
    /// user has to be able to tell a stale reading from a current one while
    /// glancing, and only words do that reliably.
    private var staleBanner: some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "clock.badge.exclamationmark")
            Text("Out of date — your Mac hasn't reported recently.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2)
        .foregroundStyle(.orange)
        .accessibilityElement(children: .combine)
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
                SentryDial(fraction: nil, tint: .secondary, lineWidth: 4) {
                    Text(WatchFormatting.placeholder)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
                Text("No agent activity")
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)

            Text("No AI assistant has used Sentry's tools on your Mac. Tool calls show up here as they happen.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)

            // Even at zero, "last activity" can be a real, non-nil time — an
            // agent that ran and then fell outside the log's window. Shown
            // only when it exists; never invented to fill the row.
            if lastActivityAt != nil {
                lastActivityRow
            }
        }
    }

    private var populatedState: some View {
        VStack(alignment: .leading, spacing: 8) {
            countLine(
                value: toolCallCount.map(String.init) ?? "—",
                caption: toolCallCount == 1 ? "tool call" : "tool calls"
            )
            lastActivityRow
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
                .font(.system(.title2, design: .monospaced, weight: .semibold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
    private var lastActivityRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Last")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(lastActivityAt.map { Self.relativeLabel(for: $0) } ?? "—")
                .font(.caption)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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
        .buttonStyle(.bordered)
        .tint(.red)
        .accessibilityHint("Pauses all AI agent access to your Mac")
    }

    @ViewBuilder
    private var toolList: some View {
        if !recentToolNames.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Recent tools")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
