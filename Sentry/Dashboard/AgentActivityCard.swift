import SwiftUI
import SentryKit

/// AI-agent-integration pass (see Sentry-AI-Features-Research.md item #15,
/// "agent-flavored historical trend view"): summarizes MCP write-tool
/// activity — persisted by `HistoryStore.logAgentActivity` — over the same
/// `TimeRangePicker` window every other Dashboard chart tracks, so "how much
/// has an AI agent been doing to this Mac this week/month" is a real,
/// answerable question instead of only a live, session-scoped view (the
/// dropdown's transient pill, the AI Access pane's in-memory log).
///
/// Honest empty state, not a hidden card, when `summary.eventCount == 0` —
/// most users won't have an agent connected most of the time, and the panel
/// should say that plainly (plan §3.2 P5) rather than fabricate activity or
/// disappear in a way that reads as "this feature doesn't exist."
///
/// # The PID is gone (agent-activity legibility pass)
///
/// Every live row used to read `claude · pid 79408 · idle`, and a PID is the
/// least useful thing that slot could hold. It is an operating-system
/// bookkeeping number: it is not stable across a restart, it is not
/// comparable between two rows, it tells you nothing about what the process
/// is doing or what it is costing you, and the single question it *can*
/// answer — "which one do I kill" — is one you only ask after you have
/// already decided to intervene, using facts this card was not showing.
///
/// It is kept, demoted, in two places where it costs no layout: the row's
/// `.help` tooltip and its VoiceOver label. That is deliberate rather than a
/// deletion, because when you *do* want it (`kill`, `lsof -p`, finding the
/// row in Activity Monitor) no other identifier substitutes, and a card that
/// forced you to go re-derive it would have overcorrected. Discoverable, not
/// primary — the same treatment `TopProcessesCard` gives its "Quit" action.
///
/// What replaced it, in priority order, is what a person actually asks about
/// something that is talking to their Mac:
///   1. **Is it holding my Mac awake right now** — the only thing an agent
///      does with a physical consequence (a laptop that won't sleep in a
///      bag). `AgentSessionSummary.holdsKeepAwakeNow`.
///   2. **Did anything get refused** — a denied or rate-limited call means a
///      guardrail fired or an agent misbehaved, and is far more interesting
///      than any number of allowed ones. `blockedCount`.
///   3. **What did it last do, and how long ago** — `lastTool` + `end`.
///   4. **How much of the machine is it responsible for** — CPU *and*
///      resident memory, which `ProcessStats` has always carried and this
///      card was silently dropping.
///   5. **How long has it been connected** — `start`…`end`.
///
/// # Three lists, because they are three different claims
///
/// This card used to show three categorically different things under one
/// AI-branded heading, in one undifferentiated column of names, and say
/// nothing about which was which. That is what made the old layout read as
/// self-contradictory ("four agents… no MCP actions") and, worse, made it
/// overclaim: `xcodebuild` at 29% CPU appeared as a row on a card titled
/// "AI Agent Activity". A compile is not an AI agent. It is exactly as
/// likely to be the user pressing ⌘B, and Sentry cannot tell the difference.
///
/// They are now three separately headed, separately captioned groups, in
/// descending order of how much Sentry actually knows:
///
///   1. **Connected over MCP** — from `agent_activity_log`. A row here is a
///      *fact*: something completed an MCP handshake with this Mac and
///      called a tool, and the client name came off that handshake. This is
///      the only group that has earned the words "AI agent" without a
///      qualifier, so it goes first even though it is the group most users
///      will most often see empty.
///   2. **Agent processes running** — `ProcessMonitor` rows whose role is
///      `AgentProcessRole.isAIAgent`. An *inference* from an executable
///      name: a program called `claude` is running. It may not be talking
///      to Sentry at all.
///   3. **Builds and tooling running** — the compilers and runtimes agents
///      spend their lives driving. Kept, because an agent's real cost to
///      this Mac is usually the compile it started rather than the CLI
///      itself, and `TopProcessesCard`'s top-5-by-CPU cut misses a `swiftc`
///      at 3%. But **never presented as an agent**, and never counted in any
///      "AI agent" number.
///
/// **Why the two process groups are not one list with a per-row kind.** A
/// mixed list sorted agents-first was the cheaper option and was rejected:
/// the row that does the damage is the one a user glances at without
/// reading the kind caption, and in a mixed list that row still sits under
/// an agent-flavoured heading. Two headings make the claim structural
/// rather than something the reader has to assemble.
///
/// **MCP sessions and processes are deliberately not correlated.** A
/// session whose client name resembles a running process name is a
/// coincidence Sentry cannot verify — `clientName` is self-reported (see
/// `AgentSessionRegistry`'s trust note) and `proc_name` is a different
/// namespace entirely. So each group is rendered on its own evidence: an
/// MCP session appears whether or not a matching process is running (the
/// agent may be on another machine, over the remote transport), and a
/// process appears whether or not anything has connected. Joining them
/// would manufacture a third claim out of two, which is precisely the kind
/// of plausible-looking fabrication this codebase's honesty rules forbid.
struct AgentActivityCard: View {
    @Environment(\.themePalette) private var palette

    let summary: AgentActivitySummary?
    /// The window every count on this card is scoped to. Passed in rather
    /// than inferred so the card can *name* it ("Last 24 hours") instead of
    /// saying "in this range" and leaving the reader to go find the range
    /// switcher at the top of the window and work out which pill is bold.
    let range: TimeRangePicker
    /// Live agent/build-tool processes from `ProcessMonitor.agentProcesses`
    /// — the orchestration half of this card: who is running *right now*,
    /// how hard, next to what agents have *done* over the selected range.
    ///
    /// Passed **uncapped**: the card partitions this into its two process
    /// groups and caps each one separately (`partitionProcesses`). Capping
    /// at the call site, as this used to, silently discarded rows before
    /// they could be classified — four idle `node` processes would push a
    /// working `claude` out of the list entirely.
    var agentProcesses: [ProcessStats] = []
    /// Per-session rollups from `AgentSessionReport.sessions` via
    /// `DashboardViewModel.agentSessions` (agent-session attribution pass)
    /// — one row per MCP connection: who, when, how many calls, and how
    /// long it held the machine awake. Shown *in addition to* the aggregate
    /// stat row, which stays as the range-wide headline.
    var sessions: [AgentSessionSummary] = []
    /// `SystemSnapshot.agentAccessPaused` — the kill switch.
    ///
    /// `nil` means "this Mac has not reported a pause state yet" (the very
    /// first snapshot of a run predates the settings store's first read).
    /// The card renders a banner only for `true` and renders *nothing* for
    /// `false` or `nil`: "paused" is the only state that changes what the
    /// numbers below mean, and a "not paused" badge drawn from a `nil` would
    /// be asserting something this card was never told.
    var agentAccessPaused: Bool?

    /// Sessions rendered before the rest collapse into a "+N more" line —
    /// the card is one tile in a three-across row, not a table view.
    private static let maxSessionRows = 4

    /// Same cap, applied to each process group independently rather than to
    /// the two of them together: a Mac mid-build can easily have four
    /// `swift-frontend` processes, and letting them crowd out the one
    /// `claude` row would invert the card's priorities.
    private static let maxProcessRows = 4

    /// CPU at/above this reads as "working"; below it, "idle". Chosen well
    /// above libproc sampling noise but below any real compile/inference load.
    static let workingCPUThreshold: Double = 5

    var body: some View {
        // Partitioned once, up here, rather than inside each group: the
        // empty-state sentence below refers to "the rows below," and it can
        // only tell the truth about them if it is looking at the same
        // filtered result they are. Reading the raw `agentProcesses` there
        // would have it promise rows that the load filter then removed.
        let processes = Self.partitionProcesses(agentProcesses, limitPerGroup: Self.maxProcessRows)
        return VStack(alignment: .leading, spacing: palette.spacing) {
            header
            if agentAccessPaused == true {
                pausedBanner
            }
            content(hasProcessRows: !processes.agents.isEmpty || !processes.tools.isEmpty)
            if !sessions.isEmpty {
                sessionList
            }
            if !processes.agents.isEmpty {
                agentProcessList(processes.agents)
            }
            if !processes.tools.isEmpty {
                toolProcessList(processes.tools)
            }
        }
    }

    /// **Retitled from "AI Agent Activity".** That title was only ever
    /// correct for part of what the card shows, and the part it was wrong
    /// about (`xcodebuild`, `make`, `node`) is the part most likely to be
    /// eating the machine and therefore most likely to be read. A title has
    /// to cover everything under it, so this one names both halves and lets
    /// the group headings below draw the line precisely.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("AI Agents & Builds")
                .font(palette.font(size: 14, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text(range.accessibilityLabel)
                .font(palette.font(size: 12))
                .foregroundStyle(palette.textTertiary)
        }
    }

    /// Warning-toned, not danger: the kill switch being on is a state the
    /// user chose, not a fault. It leads the card because it changes how
    /// every number under it should be read — an agent showing zero calls
    /// while access is paused is not a quiet agent, it is a blocked one.
    private var pausedBanner: some View {
        Text("Agent access is paused — every tool call is being declined.")
            .font(palette.font(size: 11, weight: .medium))
            .foregroundStyle(palette.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Light accent tint, per the mock's `#c3caf7`-on-Slate readout color —
    /// a step lighter than the flat `palette.accent` dot/border/fill
    /// treatment used everywhere else, since here the color *is* the value's
    /// own text rather than a small signal next to it.
    private var statTint: Color { palette.accent.opacity(0.85) }

    @ViewBuilder
    private func content(hasProcessRows: Bool) -> some View {
        if let summary, summary.eventCount > 0 {
            HStack(alignment: .top, spacing: palette.spacingSection) {
                stat(
                    value: "\(summary.eventCount)",
                    label: summary.eventCount == 1 ? "action" : "actions"
                )
                if let client = summary.mostActiveClient {
                    stat(value: client, label: "most active")
                }
                stat(
                    value: "\(summary.distinctToolCount)",
                    label: summary.distinctToolCount == 1 ? "tool used" : "tools used"
                )
            }
            .padding(.top, 2)
        } else if hasProcessRows {
            // The old wording here ("No MCP actions in this range.") sat
            // directly *under* a list of named processes and read as the
            // card contradicting itself. It never was a contradiction —
            // those rows are name-matched processes, not MCP clients — so
            // the sentence now says which of the two it is talking about,
            // and each process group below carries its own caption saying
            // the same thing from the other side.
            Text("No MCP tool calls in the \(rangeNoun). Nothing below is talking to Sentry — those rows are matched by executable name only.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("No AI agent activity in the \(rangeNoun). Enable write tools in Settings → AI Access to let Claude Code, Cursor, or another MCP client act on this Mac.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "last 24 hours" — the header's own label, lowercased so it reads as a
    /// noun phrase mid-sentence. Derived from the same `TimeRangePicker`
    /// case the header renders, so the two can never disagree about which
    /// window the empty state is denying activity in.
    private var rangeNoun: String {
        range.accessibilityLabel.lowercased()
    }

    // MARK: - MCP sessions

    /// One two-line row per session: who and how much on the first line,
    /// what it is doing / what got refused on the second.
    ///
    /// Two lines rather than one wide row because the facts have different
    /// urgencies and a single line forces them to compete for the same
    /// truncation budget — "holding awake" losing its tail to a long client
    /// name would be the worst possible thing to drop.
    private var sessionList: some View {
        VStack(alignment: .leading, spacing: palette.spacingTight) {
            // "Connected over MCP", not "Sessions": the heading is the
            // confidence statement. Everything under it completed a
            // handshake with this Mac; everything under the two headings
            // below is a guess from a process name.
            Text("Connected over MCP")
                .font(palette.font(size: 11, weight: .medium))
                .foregroundStyle(palette.textTertiary)
            // Ages the "3m ago" captions between the view model's own
            // history refreshes, which for a `.halfYear` range are 15
            // minutes apart — the same `TimelineView` idiom, and the same
            // reason, as `DashboardView.headerCaption`. Only ticks while
            // the window is actually on screen.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: palette.spacingTight) {
                    ForEach(sessions.prefix(Self.maxSessionRows)) { session in
                        sessionRow(session, now: context.date)
                    }
                }
            }
            if sessions.count > Self.maxSessionRows {
                Text("+\(sessions.count - Self.maxSessionRows) more")
                    .font(palette.font(size: 11))
                    .foregroundStyle(palette.textTertiary)
            }
        }
    }

    private func sessionRow(_ session: AgentSessionSummary, now: Date) -> some View {
        let isActive = session.isActive(asOf: now)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: palette.spacingTight) {
                // The dot repeats what the row's words already say (an
                // active session's second line reads "…ago"; an ended one
                // says "ended"), so color is never the only carrier — see
                // `Self.sessionAccessibilityLabel`, which spells it out.
                Circle()
                    .fill(isActive ? palette.success : palette.textTertiary)
                    .frame(width: 6, height: 6)
                Text(session.clientName.isEmpty ? "Unknown client" : session.clientName)
                    .font(palette.font(size: 12, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Text(Self.durationLabel(session.end.timeIntervalSince(session.start)))
                    .font(palette.numericFont(size: 11))
                    .foregroundStyle(palette.textTertiary)
                Spacer(minLength: palette.spacingTight)
                Text(session.callCount == 1 ? "1 call" : "\(session.callCount) calls")
                    .font(palette.numericFont(size: 11))
                    .foregroundStyle(palette.textSecondary)
                    .layoutPriority(1)
            }
            HStack(spacing: 4) {
                if let awake = Self.awakePhrase(session) {
                    Text(awake)
                        .font(palette.font(size: 11, weight: session.holdsKeepAwakeNow ? .medium : .regular))
                        .foregroundStyle(statTint)
                        .layoutPriority(2)
                    separator
                }
                if let blocked = Self.blockedPhrase(session) {
                    Text(blocked)
                        .font(palette.font(size: 11, weight: .medium))
                        .foregroundStyle(palette.warning)
                        .layoutPriority(2)
                    separator
                }
                Text(Self.lastToolPhrase(session))
                    .font(palette.font(size: 11))
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Self.agoLabel(now.timeIntervalSince(session.end)))
                    .font(palette.numericFont(size: 11))
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(1)
                    // Never the thing that gets clipped — see
                    // `lastToolPhrase`'s doc comment.
                    .fixedSize()
                    .layoutPriority(3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.sessionAccessibilityLabel(session, now: now))
    }

    /// The middot between the second line's segments. A view rather than a
    /// character baked into each phrase, so the phrase functions stay pure
    /// strings a test can assert on and a translator can reorder — the same
    /// separator-as-a-view treatment `TimeRangePickerView` uses, including
    /// hiding it from VoiceOver (the accessibility label reads the row as
    /// prose, not as punctuation).
    private var separator: some View {
        Text("·")
            .font(palette.font(size: 11))
            .foregroundStyle(palette.textTertiary)
            .accessibilityHidden(true)
    }

    // MARK: - Live processes

    /// Splits `ProcessMonitor.agentProcesses` into the card's two process
    /// groups, and applies the one asymmetry between them.
    ///
    /// **Agents are listed whether or not they are busy; build tools are
    /// listed only while they are working.** For an agent, *presence* is the
    /// fact worth showing — `ProcessCollector`'s own doc comment makes this
    /// point ("`claude` at 0.2% CPU is exactly the row that never makes a
    /// top-8 cut"), and an idle agent sitting on your Mac is precisely what
    /// this card exists to surface. For a build tool or a runtime, presence
    /// is nearly meaningless: `node` and `make` are two of the most common
    /// process names on any developer's Mac, started by dev servers,
    /// language servers, Homebrew, and Xcode itself, none of which have
    /// anything to do with an agent. An idle `node` at 0% CPU carries no
    /// information and costs a row that a real one needs; a `node` at 140%
    /// is genuine load worth attributing, and is the only reason to match
    /// the name at all.
    ///
    /// That rule is what keeps `node`/`make`/`ninja` in the match set
    /// (`AgentProcessRole.namesByRole`) rather than deleting them, which was
    /// the alternative considered. Deleting them would have thrown away the
    /// card's answer to "what is the build my agent started actually costing
    /// me" — the thing `TopProcessesCard`'s top-5-by-CPU cut only shows once
    /// it is already the biggest thing on the machine. Gating on load keeps
    /// the signal and drops the noise, and the group heading and role
    /// caption make sure neither is ever called an AI agent.
    ///
    /// Sorted busiest-first inside each group, and capped independently.
    /// `ProcessCollector` already returns its matched list CPU-sorted, but
    /// this re-sorts rather than trusting the caller — the same reasoning
    /// `DropdownProcessList.topThree` documents for not trusting its input.
    static func partitionProcesses(
        _ processes: [ProcessStats],
        limitPerGroup: Int
    ) -> (agents: [ProcessStats], tools: [ProcessStats]) {
        var agents: [ProcessStats] = []
        var tools: [ProcessStats] = []
        for process in processes {
            guard let role = AgentProcessRole.role(forProcessNamed: process.name) else { continue }
            if role.isAIAgent {
                agents.append(process)
            } else if process.cpuPercent >= workingCPUThreshold {
                tools.append(process)
            }
        }
        let byCPU: (ProcessStats, ProcessStats) -> Bool = { $0.cpuPercent > $1.cpuPercent }
        return (
            agents: Array(agents.sorted(by: byCPU).prefix(max(0, limitPerGroup))),
            tools: Array(tools.sorted(by: byCPU).prefix(max(0, limitPerGroup)))
        )
    }

    /// The inferred-agent group. One row per live process: name, what kind
    /// of thing it is, CPU, and resident memory. Grouping instances would
    /// hide exactly what an orchestration view exists to show — three
    /// parallel `claude` processes are three rows.
    ///
    /// **On `claude` and `Claude` appearing as two rows:** they are two
    /// genuinely different programs, not a duplicate and not a
    /// name-normalisation bug. `ProcessMonitor.agentProcessNames` is matched
    /// case-insensitively (`ProcessCollector.collect`), so the single entry
    /// `"claude"` matches both the lowercase Claude Code CLI and
    /// `/Applications/Claude.app/Contents/MacOS/Claude`, whose executable is
    /// capitalised by app-bundle convention. Both are legitimately coding
    /// agents and both belong here. What was missing was any way to tell
    /// them apart at a glance, since the row carried only a name and a PID —
    /// which is now fixed by the thing that replaced the PID: the desktop
    /// app's resident memory is an order of magnitude larger than the CLI's,
    /// so the two rows are immediately distinguishable by the numbers a
    /// person actually cares about.
    private func agentProcessList(_ processes: [ProcessStats]) -> some View {
        VStack(alignment: .leading, spacing: palette.spacingTight) {
            Text("Agent processes running")
                .font(palette.font(size: 11, weight: .medium))
                .foregroundStyle(palette.textTertiary)
            ForEach(processes) { process in
                processRow(process)
            }
            Text("Matched by executable name — running is not the same as connected to Sentry.")
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The build/runtime group. Heading and caption both say, in different
    /// words, the thing the old single list never said: Sentry does not know
    /// who started these, and a compile is not an agent.
    private func toolProcessList(_ processes: [ProcessStats]) -> some View {
        VStack(alignment: .leading, spacing: palette.spacingTight) {
            Text("Builds and tooling running")
                .font(palette.font(size: 11, weight: .medium))
                .foregroundStyle(palette.textTertiary)
            ForEach(processes) { process in
                processRow(process)
            }
            Text("Work an agent may have started — or Xcode, or you. Sentry can't tell which.")
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func processRow(_ process: ProcessStats) -> some View {
        let isWorking = process.cpuPercent >= Self.workingCPUThreshold
        return HStack(spacing: palette.spacingTight) {
            Circle()
                .fill(isWorking ? palette.success : palette.textTertiary)
                .frame(width: 6, height: 6)
            Text(process.name)
                .font(palette.numericFont(size: 12, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
            if let role = AgentProcessRole.role(forProcessNamed: process.name) {
                Text(role.label)
                    .font(palette.font(size: 11))
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: palette.spacingTight)
            // CPU always, never the word "idle" on its own: "0% CPU" says
            // idle *and* says how idle, and it means the coloured dot is
            // repeating a number the row already shows rather than being
            // the only place the state lives.
            Text(Self.cpuLabel(process.cpuPercent))
                .font(palette.numericFont(size: 11))
                .foregroundStyle(palette.textSecondary)
                .layoutPriority(1)
            Text(MetricFormatting.bytes(process.residentMemoryBytes))
                .font(palette.numericFont(size: 11))
                .foregroundStyle(palette.textTertiary)
                .layoutPriority(1)
        }
        // The demoted PID. `.help` is the standard macOS place for the
        // identifier you only want when you have already decided to act on
        // the row (see this type's doc comment).
        .help(Self.pidTooltip(process))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.processAccessibilityLabel(process))
    }

    // MARK: - Pure formatting (unit-tested in AgentActivityCardFormattingTests)

    /// Compact duration for a session row: `<1m`, `Nm`, or `Nh Mm` — a
    /// per-row spelled-out duration would crowd a card row that also
    /// carries a name, call count, and awake time.
    static func durationLabel(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        if totalMinutes < 1 { return "<1m" }
        if totalMinutes < 60 { return "\(totalMinutes)m" }
        return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
    }

    /// "just now" / "3m ago" / "2h ago" / "4d ago".
    ///
    /// Deliberately not `RelativeDateTimeFormatter`: this range spans
    /// seconds to six months (the widest `TimeRangePicker` case), and the
    /// system formatter's spelled-out output ("4 days ago", "about 2 hours
    /// ago") is several times wider than the slot on a third-width card. A
    /// negative interval — a clock adjustment between the sample and the
    /// render — clamps to "just now" rather than rendering a future.
    static func agoLabel(_ seconds: TimeInterval) -> String {
        let elapsed = max(0, seconds)
        if elapsed < 60 { return String(localized: "just now") }
        if elapsed < 3600 { return String(localized: "\(Int(elapsed / 60))m ago") }
        if elapsed < 86400 { return String(localized: "\(Int(elapsed / 3600))h ago") }
        return String(localized: "\(Int(elapsed / 86400))d ago")
    }

    /// The tool's user-facing name, matching what the AI Access pane's own
    /// activity log calls it (`MCPToolID.displayName`). Falls back to the
    /// raw persisted string for a tool this build doesn't know — a row
    /// written by a newer version, or a hand-edited database. Returning the
    /// raw name is the honest fallback; inventing a prettified version of a
    /// string we can't identify would be worse than showing it verbatim.
    static func toolLabel(_ rawTool: String) -> String {
        MCPToolID(rawValue: rawTool)?.displayName ?? rawTool
    }

    /// "Keep Awake", or "Keep Awake denied" when the last call didn't run.
    /// The outcome is inline rather than a separate badge because it
    /// qualifies *that* call specifically — the `blockedPhrase` badge counts
    /// the whole session.
    ///
    /// Split from the age (`agoLabel`) so the row can render them as two
    /// `Text`s and give the age the layout priority: on a third-width card
    /// this line is the first thing to truncate, and losing "3m ago" off the
    /// tail would leave a phrase that describes a call without saying
    /// whether it happened seconds or months ago — strictly worse than
    /// clipping a long tool name, which the reader can still recognise from
    /// its prefix.
    ///
    /// `nil` `lastTool`/`lastOutcome` (a summary built with no event behind
    /// it — see `AgentSessionSummary.lastTool`) renders the explicit "last
    /// tool not reported", never a plausible-looking guess.
    static func lastToolPhrase(_ session: AgentSessionSummary) -> String {
        guard let tool = session.lastTool else {
            return String(localized: "last tool not reported")
        }
        let name = toolLabel(tool)
        switch session.lastOutcome {
        case .denied: return String(localized: "\(name) denied")
        case .rateLimited: return String(localized: "\(name) rate-limited")
        case .errored: return String(localized: "\(name) failed")
        case .succeeded: return name
        case nil: return String(localized: "\(name), outcome not reported")
        }
    }

    /// The two halves joined — what VoiceOver reads, where there is no
    /// truncation to design around and the row wants to be one sentence.
    static func lastActivityPhrase(_ session: AgentSessionSummary, now: Date) -> String {
        String(localized: "\(lastToolPhrase(session)) \(agoLabel(now.timeIntervalSince(session.end)))")
    }

    /// "holding awake" while a hold owned by this session is still open;
    /// otherwise the total it held during the window, if any; otherwise
    /// `nil` (no segment rendered at all rather than "0m awake", which would
    /// draw attention to the absence of the one thing worth noticing).
    static func awakePhrase(_ session: AgentSessionSummary) -> String? {
        if session.holdsKeepAwakeNow { return String(localized: "holding awake now") }
        guard session.awakeSecondsHeld >= 1 else { return nil }
        return String(localized: "\(durationLabel(session.awakeSecondsHeld)) awake")
    }

    /// How many of this session's calls never ran, worded by *why*.
    ///
    /// The two reasons stay distinct when only one occurred, because they
    /// point at completely different follow-ups: "denied" means a guardrail
    /// or a toggle said no and the user should look at Settings → AI Access;
    /// "rate-limited" means the agent itself is calling too fast and the
    /// user should look at the agent. Only when both happened does it
    /// collapse to the neutral "blocked", since one badge cannot lead
    /// somewhere two different investigations start.
    static func blockedPhrase(_ session: AgentSessionSummary) -> String? {
        switch (session.deniedCount, session.rateLimitedCount) {
        case (0, 0): return nil
        case let (denied, 0): return String(localized: "\(denied) denied")
        case let (0, limited): return String(localized: "\(limited) rate-limited")
        default: return String(localized: "\(session.blockedCount) blocked")
        }
    }

    /// "0% CPU" / "42% CPU". Whole percent, matching `TopProcessesCard` —
    /// `ProcessCollector`'s sampling noise makes a decimal place a false
    /// precision, and this is a scanning column, not a measurement.
    static func cpuLabel(_ cpuPercent: Double) -> String {
        String(localized: "\(Int(max(0, cpuPercent).rounded()))% CPU")
    }

    /// The tooltip the PID retired into. Says what it is for, because a
    /// bare number in a tooltip would be exactly as opaque as the bare
    /// number in the row was.
    static func pidTooltip(_ process: ProcessStats) -> String {
        String(localized: "\(process.name) — process ID \(String(process.pid)), for Activity Monitor or `kill`")
    }

    /// Spells out the dot's meaning ("working"/"idle") because the dot is
    /// colour, and carries the PID because VoiceOver users have no tooltip
    /// to hover.
    static func processAccessibilityLabel(_ process: ProcessStats) -> String {
        let role = AgentProcessRole.role(forProcessNamed: process.name)?.label ?? String(localized: "agent process")
        let state = process.cpuPercent >= workingCPUThreshold
            ? String(localized: "working at \(Int(process.cpuPercent.rounded())) percent CPU")
            : String(localized: "idle at \(Int(max(0, process.cpuPercent).rounded())) percent CPU")
        return String(localized: "\(process.name), \(role), \(state), \(MetricFormatting.bytes(process.residentMemoryBytes)) memory, process ID \(String(process.pid))")
    }

    /// The whole row as one sentence, in the same priority order the visual
    /// row uses — keep-awake first, refusals second, activity last — and
    /// with the dot's colour spelled out as "connected"/"ended".
    static func sessionAccessibilityLabel(_ session: AgentSessionSummary, now: Date) -> String {
        let name = session.clientName.isEmpty ? String(localized: "Unknown client") : session.clientName
        let state = session.isActive(asOf: now)
            ? String(localized: "connected")
            : String(localized: "ended")
        var label = String(localized: "\(name), \(state), \(session.callCount) \(session.callCount == 1 ? String(localized: "call") : String(localized: "calls")) over \(durationLabel(session.end.timeIntervalSince(session.start)))")
        if session.holdsKeepAwakeNow {
            label += String(localized: ", holding this Mac awake now")
        } else if session.awakeSecondsHeld >= 1 {
            label += String(localized: ", held awake \(durationLabel(session.awakeSecondsHeld))")
        }
        if session.deniedCount > 0 {
            label += String(localized: ", \(session.deniedCount) denied")
        }
        if session.rateLimitedCount > 0 {
            label += String(localized: ", \(session.rateLimitedCount) rate-limited")
        }
        if session.erroredCount > 0 {
            label += String(localized: ", \(session.erroredCount) failed")
        }
        label += ", " + lastActivityPhrase(session, now: now)
        return label
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(statTint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
                .lineLimit(1)
        }
    }
}
