import XCTest
@testable import Sentry
@testable import SentryKit

/// Covers the pure formatting rules behind the Dashboard's "AI Agent
/// Activity" card after the legibility pass that removed the raw PID from
/// every row (`Sentry/Dashboard/AgentActivityCard.swift`) — plus the
/// `AgentProcessRole` classification that replaced part of what the PID slot
/// used to occupy (`Sentry/Dashboard/ProcessMonitor.swift`).
///
/// Static, side-effect-free functions only: the card's *layout* is not what
/// these assert, its *claims* are. Every one of these strings is a sentence
/// the app puts in front of a user (or reads aloud to a VoiceOver user)
/// about what an AI agent is doing to their Mac, and the house rule that a
/// missing reading must render as an explicit "not reported" rather than a
/// plausible zero is only checkable here.
final class AgentActivityCardFormattingTests: XCTestCase {

    private func date(_ epoch: Double) -> Date { Date(timeIntervalSince1970: epoch) }

    private func session(
        id: String = "s1",
        clientName: String = "Claude Code",
        start: Double = 1_000,
        end: Double = 2_000,
        callCount: Int = 4,
        awakeSecondsHeld: Double = 0,
        lastTool: String? = "keep_awake",
        lastOutcome: AgentActivityOutcome? = .succeeded,
        deniedCount: Int = 0,
        rateLimitedCount: Int = 0,
        erroredCount: Int = 0,
        holdsKeepAwakeNow: Bool = false
    ) -> AgentSessionSummary {
        AgentSessionSummary(
            id: id,
            clientName: clientName,
            start: date(start),
            end: date(end),
            callCount: callCount,
            toolCallCounts: [:],
            awakeSecondsHeld: awakeSecondsHeld,
            lastTool: lastTool,
            lastOutcome: lastOutcome,
            deniedCount: deniedCount,
            rateLimitedCount: rateLimitedCount,
            erroredCount: erroredCount,
            holdsKeepAwakeNow: holdsKeepAwakeNow
        )
    }

    // MARK: - durationLabel (pre-existing behaviour, pinned)

    func testDurationLabelBucketsSubMinuteHoursAndMinutes() {
        XCTAssertEqual(AgentActivityCard.durationLabel(0), "<1m")
        XCTAssertEqual(AgentActivityCard.durationLabel(59), "<1m")
        XCTAssertEqual(AgentActivityCard.durationLabel(60), "1m")
        XCTAssertEqual(AgentActivityCard.durationLabel(59 * 60), "59m")
        XCTAssertEqual(AgentActivityCard.durationLabel(3600), "1h 0m")
        XCTAssertEqual(AgentActivityCard.durationLabel(3600 + 25 * 60), "1h 25m")
    }

    // MARK: - agoLabel

    func testAgoLabelBucketsBySecondsMinutesHoursDays() {
        XCTAssertEqual(AgentActivityCard.agoLabel(0), "just now")
        XCTAssertEqual(AgentActivityCard.agoLabel(59), "just now")
        XCTAssertEqual(AgentActivityCard.agoLabel(60), "1m ago")
        XCTAssertEqual(AgentActivityCard.agoLabel(3 * 60 + 30), "3m ago")
        XCTAssertEqual(AgentActivityCard.agoLabel(2 * 3600), "2h ago")
        XCTAssertEqual(AgentActivityCard.agoLabel(4 * 86400), "4d ago")
    }

    /// A negative interval means the clock moved between the sample and the
    /// render (NTP correction, sleep/wake, a timezone-less `Date` round
    /// trip). Rendering "-3m ago" — or worse, a future — would make the card
    /// look broken over a fact that is not the user's problem.
    func testAgoLabelClampsNegativeIntervalsToJustNow() {
        XCTAssertEqual(AgentActivityCard.agoLabel(-500), "just now")
    }

    // MARK: - toolLabel

    func testToolLabelUsesTheSameDisplayNameTheAIAccessPaneUses() {
        XCTAssertEqual(AgentActivityCard.toolLabel("keep_awake"), MCPToolID.keepAwake.displayName)
        XCTAssertEqual(AgentActivityCard.toolLabel("get_system_snapshot"), MCPToolID.getSystemSnapshot.displayName)
    }

    /// A row written by a newer build (or a hand-edited database) carries a
    /// tool name this build has no case for. Showing it verbatim is honest;
    /// dropping the row, or prettifying a string we cannot identify, is not.
    func testToolLabelFallsBackToTheRawPersistedNameForAnUnknownTool() {
        XCTAssertEqual(AgentActivityCard.toolLabel("summon_kraken"), "summon_kraken")
    }

    // MARK: - lastToolPhrase / lastActivityPhrase

    func testLastToolPhraseIsJustTheToolWhenTheCallSucceeded() {
        XCTAssertEqual(
            AgentActivityCard.lastToolPhrase(session()),
            MCPToolID.keepAwake.displayName
        )
    }

    /// A denied call is the whole reason the outcome is rendered at all —
    /// "Keep Awake" and "Keep Awake denied" describe opposite events and
    /// must never collapse into the same phrase.
    func testLastToolPhraseDistinguishesDeniedRateLimitedAndFailed() {
        XCTAssertEqual(
            AgentActivityCard.lastToolPhrase(session(lastOutcome: .denied)),
            "\(MCPToolID.keepAwake.displayName) denied"
        )
        XCTAssertEqual(
            AgentActivityCard.lastToolPhrase(session(lastOutcome: .rateLimited)),
            "\(MCPToolID.keepAwake.displayName) rate-limited"
        )
        XCTAssertEqual(
            AgentActivityCard.lastToolPhrase(session(lastOutcome: .errored)),
            "\(MCPToolID.keepAwake.displayName) failed"
        )
    }

    /// House rule: a missing reading renders as an explicit "not reported",
    /// never as a plausible-looking default. A summary with no event behind
    /// it must not silently claim the last call succeeded.
    func testLastToolPhraseSaysNotReportedRatherThanGuessing() {
        XCTAssertEqual(
            AgentActivityCard.lastToolPhrase(session(lastTool: nil, lastOutcome: nil)),
            "last tool not reported"
        )
        XCTAssertEqual(
            AgentActivityCard.lastToolPhrase(session(lastOutcome: nil)),
            "\(MCPToolID.keepAwake.displayName), outcome not reported"
        )
    }

    /// The joined form is what VoiceOver reads — the visual row renders the
    /// two halves separately so the age can never be the part that clips.
    func testLastActivityPhraseJoinsToolAndAge() {
        XCTAssertEqual(
            AgentActivityCard.lastActivityPhrase(session(end: 2_000), now: date(2_180)),
            "\(MCPToolID.keepAwake.displayName) 3m ago"
        )
        XCTAssertEqual(
            AgentActivityCard.lastActivityPhrase(session(end: 2_000, lastOutcome: .denied), now: date(2_180)),
            "\(MCPToolID.keepAwake.displayName) denied 3m ago"
        )
    }

    // MARK: - awakePhrase

    func testAwakePhrasePrefersTheLiveHoldOverTheAccumulatedTotal() {
        // Holding *now* is the actionable fact (the Mac will not sleep);
        // the historical total is not what someone needs in that moment.
        let phrase = AgentActivityCard.awakePhrase(
            session(awakeSecondsHeld: 900, holdsKeepAwakeNow: true)
        )
        XCTAssertEqual(phrase, "holding awake now")
    }

    func testAwakePhraseReportsAccumulatedTimeWhenNoHoldIsOpen() {
        XCTAssertEqual(AgentActivityCard.awakePhrase(session(awakeSecondsHeld: 900)), "15m awake")
    }

    /// No segment at all rather than "0m awake": drawing attention to the
    /// absence of the one thing worth noticing is noise.
    func testAwakePhraseIsNilWhenNothingWasHeld() {
        XCTAssertNil(AgentActivityCard.awakePhrase(session(awakeSecondsHeld: 0)))
        XCTAssertNil(AgentActivityCard.awakePhrase(session(awakeSecondsHeld: 0.4)))
    }

    // MARK: - blockedPhrase

    func testBlockedPhraseIsNilWhenNothingWasRefused() {
        XCTAssertNil(AgentActivityCard.blockedPhrase(session()))
    }

    /// The two reasons point at two different investigations (Settings → AI
    /// Access vs. the agent itself), so a single-reason session keeps its
    /// specific word.
    func testBlockedPhraseKeepsDeniedAndRateLimitedDistinctWhenOnlyOneOccurred() {
        XCTAssertEqual(AgentActivityCard.blockedPhrase(session(deniedCount: 2)), "2 denied")
        XCTAssertEqual(AgentActivityCard.blockedPhrase(session(rateLimitedCount: 3)), "3 rate-limited")
    }

    func testBlockedPhraseCollapsesToNeutralBlockedWhenBothOccurred() {
        XCTAssertEqual(
            AgentActivityCard.blockedPhrase(session(deniedCount: 2, rateLimitedCount: 3)),
            "5 blocked"
        )
    }

    /// An errored call ran — it was allowed — so it is not "blocked", even
    /// though it also produced no result.
    func testBlockedPhraseIgnoresErroredCalls() {
        XCTAssertNil(AgentActivityCard.blockedPhrase(session(erroredCount: 4)))
    }

    // MARK: - cpuLabel

    func testCPULabelIsWholePercentAndNeverNegative() {
        XCTAssertEqual(AgentActivityCard.cpuLabel(0), "0% CPU")
        XCTAssertEqual(AgentActivityCard.cpuLabel(0.4), "0% CPU")
        XCTAssertEqual(AgentActivityCard.cpuLabel(41.6), "42% CPU")
        // ProcessCollector clamps its own negatives, but the label must not
        // depend on that to avoid rendering "-0% CPU".
        XCTAssertEqual(AgentActivityCard.cpuLabel(-3), "0% CPU")
    }

    // MARK: - The PID, demoted but not deleted

    /// The PID left the row and moved into the tooltip and the VoiceOver
    /// label. Both must still carry it — a user who has decided to
    /// intervene has no other identifier, and a VoiceOver user has no
    /// tooltip to hover.
    func testPIDSurvivesInTheTooltipAndTheAccessibilityLabel() {
        let process = ProcessStats(pid: 79408, name: "claude", cpuPercent: 0, residentMemoryBytes: 184 * 1024 * 1024)
        XCTAssertTrue(AgentActivityCard.pidTooltip(process).contains("79408"))
        XCTAssertTrue(AgentActivityCard.processAccessibilityLabel(process).contains("79408"))
    }

    /// The dot is colour. The spoken row must say what it means, and must
    /// carry the two attributions that replaced the PID visually.
    func testProcessAccessibilityLabelSpellsOutStateRoleAndFootprint() {
        let busy = ProcessStats(pid: 42, name: "xcodebuild", cpuPercent: 240, residentMemoryBytes: 1_073_741_824)
        let label = AgentActivityCard.processAccessibilityLabel(busy)
        XCTAssertTrue(label.contains("working"), label)
        XCTAssertTrue(label.contains("build tool"), label)
        XCTAssertTrue(label.contains("240 percent CPU"), label)

        let quiet = ProcessStats(pid: 43, name: "claude", cpuPercent: 0.2, residentMemoryBytes: 1024)
        let quietLabel = AgentActivityCard.processAccessibilityLabel(quiet)
        XCTAssertTrue(quietLabel.contains("idle"), quietLabel)
        XCTAssertTrue(quietLabel.contains("coding agent"), quietLabel)
    }

    // MARK: - Session accessibility label

    func testSessionAccessibilityLabelLeadsWithKeepAwakeThenRefusals() {
        let label = AgentActivityCard.sessionAccessibilityLabel(
            session(end: 2_000, callCount: 12, deniedCount: 2, rateLimitedCount: 1, holdsKeepAwakeNow: true),
            now: date(2_180)
        )
        XCTAssertTrue(label.hasPrefix("Claude Code, connected, 12 calls over 16m"), label)
        XCTAssertTrue(label.contains("holding this Mac awake now"), label)
        XCTAssertTrue(label.contains("2 denied"), label)
        XCTAssertTrue(label.contains("1 rate-limited"), label)
        XCTAssertTrue(label.hasSuffix("3m ago"), label)
    }

    /// The dot's colour again: "ended" has to be a word, not a grey circle.
    func testSessionAccessibilityLabelSaysEndedForAStaleSession() {
        let stale = date(2_000 + AgentSessionReport.activeWithin + 60)
        let label = AgentActivityCard.sessionAccessibilityLabel(session(end: 2_000), now: stale)
        XCTAssertTrue(label.contains("ended"), label)
        XCTAssertFalse(label.contains("connected"), label)
    }

    func testSessionAccessibilityLabelNamesAnUnnamedClient() {
        let label = AgentActivityCard.sessionAccessibilityLabel(
            session(clientName: "", end: 2_000), now: date(2_100)
        )
        XCTAssertTrue(label.hasPrefix("Unknown client,"), label)
    }

    // MARK: - partitionProcesses: agents are never mixed with build tools

    private func process(_ name: String, cpu: Double, pid: Int32 = 1, memory: UInt64 = 0) -> ProcessStats {
        ProcessStats(pid: pid, name: name, cpuPercent: cpu, residentMemoryBytes: memory)
    }

    /// The finding this rule exists for: a card headed "AI Agent Activity"
    /// was listing `xcodebuild` at 29% CPU as one of its rows. A compile is
    /// not an AI agent, and no partition may ever put one in the agent group.
    func testBuildToolsNeverLandInTheAgentGroup() {
        let partitioned = AgentActivityCard.partitionProcesses(
            [
                process("xcodebuild", cpu: 29, pid: 96370),
                process("claude", cpu: 16, pid: 79408),
                process("Claude", cpu: 0, pid: 39872),
                process("codex", cpu: 0, pid: 30607),
            ],
            limitPerGroup: 4
        )
        XCTAssertEqual(partitioned.agents.map(\.name), ["claude", "Claude", "codex"])
        XCTAssertEqual(partitioned.tools.map(\.name), ["xcodebuild"])
    }

    /// Presence is the fact for an agent — an idle `claude` is still an
    /// agent sitting on this Mac, and is exactly the row that never makes a
    /// top-N-by-CPU cut anywhere else in the app.
    func testIdleAgentsAreStillListed() {
        let partitioned = AgentActivityCard.partitionProcesses(
            [process("claude", cpu: 0), process("codex", cpu: 0.3)],
            limitPerGroup: 4
        )
        XCTAssertEqual(partitioned.agents.count, 2)
    }

    /// Load is the fact for a build tool. `node` and `make` are two of the
    /// most common process names on a developer's Mac and are usually
    /// nothing to do with an agent; an idle one is pure noise occupying a
    /// row a working process needs.
    func testIdleBuildToolsAndRuntimesAreDropped() {
        let partitioned = AgentActivityCard.partitionProcesses(
            [
                process("node", cpu: 0),
                process("make", cpu: 1),
                process("ninja", cpu: AgentActivityCard.workingCPUThreshold - 0.1),
                process("swiftc", cpu: AgentActivityCard.workingCPUThreshold),
            ],
            limitPerGroup: 4
        )
        XCTAssertEqual(partitioned.tools.map(\.name), ["swiftc"])
        XCTAssertTrue(partitioned.agents.isEmpty)
    }

    func testEachGroupIsSortedBusiestFirstAndCappedIndependently() {
        let partitioned = AgentActivityCard.partitionProcesses(
            [
                process("claude", cpu: 1, pid: 1),
                process("codex", cpu: 90, pid: 2),
                process("gemini", cpu: 50, pid: 3),
                process("aider", cpu: 70, pid: 4),
                process("Claude", cpu: 5, pid: 5),
                process("swiftc", cpu: 40, pid: 6),
                process("rustc", cpu: 80, pid: 7),
            ],
            limitPerGroup: 2
        )
        XCTAssertEqual(partitioned.agents.map(\.name), ["codex", "aider"])
        // Capping the two groups together would have let five busy agents
        // push every build row out, or vice versa.
        XCTAssertEqual(partitioned.tools.map(\.name), ["rustc", "swiftc"])
    }

    /// A name the match set doesn't cover can only arrive from a caller
    /// that didn't use `ProcessMonitor.agentProcessNames`; it must be
    /// dropped rather than silently rendered as an unlabelled fourth kind.
    func testUnclassifiableProcessesAreDropped() {
        let partitioned = AgentActivityCard.partitionProcesses(
            [process("Finder", cpu: 90), process("claude", cpu: 1)],
            limitPerGroup: 4
        )
        XCTAssertEqual(partitioned.agents.map(\.name), ["claude"])
        XCTAssertTrue(partitioned.tools.isEmpty)
    }

    func testEmptyInputProducesTwoEmptyGroups() {
        let partitioned = AgentActivityCard.partitionProcesses([], limitPerGroup: 4)
        XCTAssertTrue(partitioned.agents.isEmpty)
        XCTAssertTrue(partitioned.tools.isEmpty)
    }

    // MARK: - AgentProcessRole

    /// The classification table and the match set are the same table — a
    /// name that can be matched but not described would render a row the
    /// card has no words for.
    func testEveryMatchedProcessNameHasARole() {
        XCTAssertFalse(ProcessMonitor.agentProcessNames.isEmpty)
        for name in ProcessMonitor.agentProcessNames {
            XCTAssertNotNil(AgentProcessRole.role(forProcessNamed: name), name)
        }
        XCTAssertEqual(ProcessMonitor.agentProcessNames, AgentProcessRole.allMatchedNames)
    }

    func testRolesGroupAgentsBuildToolsAndRuntimesSeparately() {
        XCTAssertEqual(AgentProcessRole.role(forProcessNamed: "claude"), .codingAgent)
        XCTAssertEqual(AgentProcessRole.role(forProcessNamed: "codex"), .codingAgent)
        XCTAssertEqual(AgentProcessRole.role(forProcessNamed: "xcodebuild"), .buildTool)
        XCTAssertEqual(AgentProcessRole.role(forProcessNamed: "swift-frontend"), .buildTool)
        XCTAssertEqual(AgentProcessRole.role(forProcessNamed: "node"), .runtime)
        XCTAssertEqual(AgentProcessRole.role(forProcessNamed: "bun"), .runtime)
    }

    /// The `claude`/`Claude` question. `ProcessCollector` lowercases an
    /// observed `proc_name` before testing membership, so the single entry
    /// `"claude"` legitimately matches both the Claude Code CLI and
    /// `/Applications/Claude.app/Contents/MacOS/Claude`. They are two
    /// different programs, not a duplicated row — and both are coding
    /// agents, so the classification must agree regardless of case.
    func testRoleLookupIsCaseInsensitiveSoTheCLIAndTheDesktopAppBothClassify() {
        XCTAssertEqual(AgentProcessRole.role(forProcessNamed: "Claude"), .codingAgent)
        XCTAssertEqual(AgentProcessRole.role(forProcessNamed: "claude"), .codingAgent)
        XCTAssertEqual(AgentProcessRole.role(forProcessNamed: "CLAUDE"), .codingAgent)
    }

    func testUnmatchedNameHasNoRole() {
        XCTAssertNil(AgentProcessRole.role(forProcessNamed: "Finder"))
        XCTAssertNil(AgentProcessRole.role(forProcessNamed: ""))
    }

    func testEveryRoleHasANonEmptyLabel() {
        for role in AgentProcessRole.allCases {
            XCTAssertFalse(role.label.isEmpty, role.rawValue)
        }
    }

    /// Exactly one role may claim to be an AI agent. If a future role is
    /// added on the tooling side and quietly answers `true` here, the card
    /// starts calling compiles agents again — the exact regression this
    /// pass exists to prevent.
    func testOnlyTheCodingAgentRoleClaimsToBeAnAIAgent() {
        XCTAssertEqual(AgentProcessRole.allCases.filter(\.isAIAgent), [.codingAgent])
    }

    /// The build/tooling half of the match set is where the false positives
    /// live, and it must stay there — a name moving into `.codingAgent`
    /// would put it back under an AI heading.
    func testCommonNonAgentToolNamesAreClassifiedAsToolingNotAgents() {
        for name in ["xcodebuild", "make", "node", "ninja", "cargo", "bun", "sourcekit-lsp"] {
            let role = AgentProcessRole.role(forProcessNamed: name)
            XCTAssertNotNil(role, name)
            XCTAssertEqual(role?.isAIAgent, false, name)
        }
    }
}
