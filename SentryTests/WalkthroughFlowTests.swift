import XCTest
@testable import SentryKit

/// Covers the pure half of both walkthroughs: step ordering, the structural
/// rules the two step lists have to satisfy, `WalkthroughFlow`'s navigation
/// clamping, and `WalkthroughGate`'s three gating decisions.
///
/// **Why the phone's flow is tested here, in a macOS test bundle.** It is
/// the only place it can be. `SentryTests` is `platform: macOS`, hosted by
/// the `Sentry` app, and cannot import `SentryMobile` — so any walkthrough
/// logic living inside that target is untestable by construction. Putting
/// `PhoneWalkthroughStep` in `SentryKit` is what makes the assertions below
/// on the phone's ordering and copy possible at all; see
/// `WalkthroughFlow.swift`'s header for the full argument.
///
/// Shape and stakes match `WelcomeOnboardingSettingsTests` (which covers the
/// *persistence* half of the same feature — `AppSettings.hasSeenWelcome`'s
/// additive-decoding contract) and `MetricModuleSymbolTests` (which covers
/// the same "every case has usable presentation metadata" ground for a
/// different enum).
final class WalkthroughFlowTests: XCTestCase {

    // MARK: - Ordering

    /// Spelled out rather than asserted structurally, because the *order* is
    /// the design. The Mac flow opens with where the app is (a user can use
    /// nothing else until they know), then the three undiscoverable
    /// features, then the permission ask inside the step that motivates it.
    /// `.locationLog` is deliberately absent for 1.0 — the Location Log pane
    /// is hidden this release, so its permission step is excluded from
    /// `allCases` (see that property's doc comment). Reordering any of this
    /// should be a deliberate edit that breaks this assertion, not a silent
    /// consequence of moving a `case` while editing something else.
    func testMacStepsAreInTheDesignedOrder() {
        XCTAssertEqual(MacWalkthroughStep.allCases, [
            .menuBar,
            .composeBar,
            .keepAwake,
            .alerts,
            .insights,
            .agents,
            .companion,
            .done,
        ])
    }

    /// Same reasoning as above. The phone opens by naming the relationship
    /// (this app reads a Mac) because the most likely first-run outcome is a
    /// user who sees demo data and concludes the app is broken; pairing is
    /// second because it is the step that decides whether the install
    /// survives.
    func testPhoneStepsAreInTheDesignedOrder() {
        XCTAssertEqual(PhoneWalkthroughStep.allCases, [
            .companionRole,
            .pairing,
            .tabs,
            .controls,
            .agents,
            .watch,
            .done,
        ])
    }

    /// The counts are quoted in user-facing copy — "the nine-step
    /// introduction" in `Sentry/Settings/Panes/GeneralPane.swift`'s
    /// walkthrough section, "The seven-step introduction, again." in
    /// `SentryMobile/Settings/SettingsTabView.swift`'s walkthrough row, and
    /// the Mac's replay button accessibility hint. Adding a step without
    /// updating those leaves two sentences quietly lying about the app,
    /// which is the exact failure this whole feature was written to avoid.
    /// This assertion is the thing that makes that a compile-then-fail
    /// rather than a ship.
    func testStepCountsMatchTheCountsQuotedInSettingsCopy() {
        XCTAssertEqual(MacWalkthroughStep.allCases.count, 8)
        XCTAssertEqual(PhoneWalkthroughStep.allCases.count, 7)
    }

    // MARK: - Structural rules

    func testEveryMacStepHasUsableCopy() {
        assertUsableCopy(MacWalkthroughStep.allCases)
    }

    func testEveryPhoneStepHasUsableCopy() {
        assertUsableCopy(PhoneWalkthroughStep.allCases)
    }

    private func assertUsableCopy<Step: WalkthroughStep>(_ steps: [Step], file: StaticString = #filePath, line: UInt = #line) {
        for step in steps {
            XCTAssertFalse(step.id.isEmpty, "\(step) has no id", file: file, line: line)
            XCTAssertFalse(step.symbolName.isEmpty, "\(step) has no symbol", file: file, line: line)
            XCTAssertFalse(step.title.isEmpty, "\(step) has no title", file: file, line: line)
            XCTAssertFalse(step.summary.isEmpty, "\(step) has no summary", file: file, line: line)
            XCTAssertFalse(step.detail.isEmpty, "\(step) has no detail", file: file, line: line)

            // Titles are headlines, not sentences — they sit beside a symbol
            // in a header row on both platforms, and a trailing period there
            // reads as a typo. Consistency across nine plus seven of them is
            // exactly the sort of thing nobody re-checks by eye.
            XCTAssertFalse(
                step.title.hasSuffix("."),
                "\(step)'s title should not end in a period",
                file: file, line: line
            )
        }
    }

    func testStepIdentifiersAreUnique() {
        XCTAssertEqual(Set(MacWalkthroughStep.allCases.map(\.id)).count, MacWalkthroughStep.allCases.count)
        XCTAssertEqual(Set(PhoneWalkthroughStep.allCases.map(\.id)).count, PhoneWalkthroughStep.allCases.count)
    }

    /// Both views render Back/Next for every step and swap Next for
    /// Done/Get Started on `.finish` alone. Two finish steps would give the
    /// user two ways out with different meanings; zero would give them none
    /// but Skip, which sets the same flag but reads as an admission of
    /// defeat.
    func testEachFlowHasExactlyOneFinishStepAndItIsLast() {
        assertSingleTrailingFinish(MacWalkthroughStep.allCases)
        assertSingleTrailingFinish(PhoneWalkthroughStep.allCases)
    }

    private func assertSingleTrailingFinish<Step: WalkthroughStep>(_ steps: [Step], file: StaticString = #filePath, line: UInt = #line) {
        let finishes = steps.filter { $0.role == .finish }
        XCTAssertEqual(finishes.count, 1, "expected exactly one finish step", file: file, line: line)
        XCTAssertEqual(steps.last?.role, .finish, "the finish step must be last", file: file, line: line)
    }

    /// A first-run flow that opens with a system permission prompt is asking
    /// before it has earned the right to. Both flows are ordered so the
    /// first step explains something; this pins that rather than trusting it
    /// to survive a reorder.
    func testNeitherFlowOpensWithAPermissionRequest() {
        XCTAssertEqual(MacWalkthroughStep.allCases.first?.role, .teach)
        XCTAssertEqual(PhoneWalkthroughStep.allCases.first?.role, .teach)
    }

    /// The phone genuinely has nothing to ask for — no notifications of its
    /// own, no camera (pairing goes through the system Camera app via a
    /// `sentry://pair` deep link precisely so it doesn't), no location (the
    /// Mac collects that). If a `.permission` step ever appears in this
    /// flow, either the app grew a real permission or somebody added a
    /// prompt for nothing; both deserve a failing test and a second look.
    func testPhoneFlowRequestsNoSystemPermissions() {
        XCTAssertFalse(PhoneWalkthroughStep.allCases.contains { $0.role == .permission })
    }

    /// The Mac's two permission asks, pinned to the steps that motivate
    /// them. Moving the notification request out of the alerts step (or the
    /// location request out of the location-log step) would put a prompt in
    /// front of a user who has not been told why.
    func testMacPermissionStepsAreTheOnesThatExplainThem() {
        XCTAssertEqual(
            MacWalkthroughStep.allCases.filter { $0.role == .permission },
            [.alerts, .locationLog]
        )
    }

    /// A regression guard for a specific, previously-shipped falsehood: the
    /// phone's old three-screen onboarding told users to "turn on Local
    /// Access (same Wi-Fi)" on the Mac, and there is no such toggle —
    /// `AppDelegate` starts the local sync server unconditionally, and
    /// `SyncPane`'s only sync switch is Remote Access. Anyone re-deriving
    /// onboarding copy from that old file, or from a screenshot of it, will
    /// reintroduce the phrase; this fails when they do.
    func testNoStepTellsTheUserToTurnOnANonexistentLocalAccessToggle() {
        for text in allCopy() {
            XCTAssertFalse(
                text.localizedCaseInsensitiveContains("local access"),
                "Sentry has no \"Local Access\" toggle — local sync is always on. Offending copy: \(text)"
            )
        }
    }

    /// The other pinned falsehood. `GetAgentGuardrailsStatusIntent` reads
    /// `SystemSnapshot.agentAccessPaused`, which `StatsCoordinator`'s own doc
    /// comment says no composition root assigns yet — so on every real Mac
    /// it answers "your Mac hasn't reported whether agent access is paused."
    /// Sending a brand-new user to a Siri phrase that cannot work today is
    /// worse than not mentioning it; if that hook lands, delete this test in
    /// the same change that adds the sentence back.
    func testNoStepPromisesSiriCanReportAgentGuardrailState() {
        for text in allCopy() {
            let mentionsSiri = text.localizedCaseInsensitiveContains("siri")
            let mentionsAgents = text.localizedCaseInsensitiveContains("agent")
            XCTAssertFalse(
                mentionsSiri && mentionsAgents,
                "Agent guardrail state isn't reported to Siri in this build. Offending copy: \(text)"
            )
        }
    }

    private func allCopy() -> [String] {
        MacWalkthroughStep.allCases.flatMap { [$0.title, $0.summary, $0.detail] }
            + PhoneWalkthroughStep.allCases.flatMap { [$0.title, $0.summary, $0.detail] }
    }

    // MARK: - Navigation

    func testAFreshFlowStartsAtTheFirstStep() {
        let flow = WalkthroughFlow<MacWalkthroughStep>()
        XCTAssertEqual(flow.stepIndex, 0)
        XCTAssertEqual(flow.step, .menuBar)
        XCTAssertEqual(flow.stepNumber, 1)
        XCTAssertTrue(flow.isFirst)
        XCTAssertFalse(flow.isLast)
    }

    func testAdvanceWalksTheWholeFlowAndThenStops() {
        var flow = WalkthroughFlow<MacWalkthroughStep>()

        for expected in MacWalkthroughStep.allCases.dropFirst() {
            XCTAssertTrue(flow.advance(), "advance should report movement while steps remain")
            XCTAssertEqual(flow.step, expected)
        }

        XCTAssertTrue(flow.isLast)
        // The clamp, and the reason it returns `false` rather than trapping:
        // "Next on the last step" is a legitimate thing for a caller (or a
        // repeated key press) to do, and it must mean "nothing left," not
        // "crash in front of a first-time user."
        XCTAssertFalse(flow.advance())
        XCTAssertEqual(flow.step, .done)
    }

    func testRetreatStopsAtTheFirstStep() {
        var flow = WalkthroughFlow<PhoneWalkthroughStep>()
        XCTAssertFalse(flow.retreat())
        XCTAssertEqual(flow.step, .companionRole)

        flow.go(to: .tabs)
        XCTAssertTrue(flow.retreat())
        XCTAssertEqual(flow.step, .pairing)
    }

    func testGoToJumpsDirectlyAndRestartReturnsToTheTop() {
        var flow = WalkthroughFlow<MacWalkthroughStep>()

        flow.go(to: .agents)
        XCTAssertEqual(flow.step, .agents)
        XCTAssertEqual(flow.stepNumber, 6)
        XCTAssertFalse(flow.isFirst)

        flow.restart()
        XCTAssertEqual(flow.step, .menuBar)
        XCTAssertTrue(flow.isFirst)
    }

    /// The Mac's replay path reuses a long-lived coordinator, so a flow that
    /// remembered its position between presentations would drop a returning
    /// user back on step 7. `restart()` is what stops that, and this is the
    /// assertion that keeps it doing so.
    func testRestartIsWhatMakesAReplayStartFromTheBeginning() {
        var flow = WalkthroughFlow<MacWalkthroughStep>(presentation: .replay)
        flow.go(to: .locationLog)
        flow.restart()
        XCTAssertEqual(flow.stepIndex, 0)
        XCTAssertEqual(flow.presentation, .replay, "restart must not change why the flow is on screen")
    }

    func testProgressLabelIsOneBasedAndCountsEveryStep() {
        var flow = WalkthroughFlow<MacWalkthroughStep>()
        XCTAssertEqual(flow.progressLabel, "Step 1 of 9")

        flow.go(to: .done)
        XCTAssertEqual(flow.progressLabel, "Step 9 of 9")
    }

    func testIndexInFlowMatchesDeclarationOrder() {
        for (offset, step) in MacWalkthroughStep.allCases.enumerated() {
            XCTAssertEqual(step.indexInFlow, offset)
        }
        for (offset, step) in PhoneWalkthroughStep.allCases.enumerated() {
            XCTAssertEqual(step.indexInFlow, offset)
        }
    }

    // MARK: - Gating

    func testTheWalkthroughIsPresentedOnLaunchOnlyUntilItHasBeenSeen() {
        XCTAssertTrue(WalkthroughGate.shouldPresentOnLaunch(hasCompletedWalkthrough: false))
        XCTAssertFalse(WalkthroughGate.shouldPresentOnLaunch(hasCompletedWalkthrough: true))
    }

    /// The crash-safety rule inherited from `AppSettings.hasSeenWelcome`: a
    /// first run marks itself seen the instant it is shown, so a quit or a
    /// crash mid-flow can't leave the app believing this is still first run.
    /// A replay must not write anything — the flag is already set, and a
    /// replay path that touched it is one inverted boolean away from turning
    /// "show me that again" into "nag me forever."
    func testOnlyAFirstRunMarksItselfSeenAtPresentTime() {
        XCTAssertTrue(WalkthroughGate.shouldMarkCompletedOnPresent(.firstRun))
        XCTAssertFalse(WalkthroughGate.shouldMarkCompletedOnPresent(.replay))
    }

    /// Skip means done, not "later" — on both platforms, by construction.
    /// This is the assertion that makes the policy a decision rather than an
    /// accident of two call sites happening to agree: changing it requires
    /// editing a test that says, in its name, what is being changed.
    func testSkippingCountsAsCompletingJustAsFinishingDoes() {
        XCTAssertTrue(WalkthroughGate.completedFlag(after: .finished))
        XCTAssertTrue(WalkthroughGate.completedFlag(after: .skipped))
    }

    /// Every outcome has to have an answer — a case added later without one
    /// would otherwise fail to compile in `WalkthroughGate` (good) or, if
    /// somebody reached for a `default:`, silently inherit `true` (bad).
    func testEveryOutcomeHasACompletionAnswer() {
        for outcome in WalkthroughOutcome.allCases {
            XCTAssertTrue(WalkthroughGate.completedFlag(after: outcome))
        }
    }

    // MARK: - Value semantics

    /// `WalkthroughFlow` is a value passed from `OnboardingCoordinator` into
    /// a SwiftUI `@State`. If it were reference-like, the coordinator and the
    /// view would share a cursor and a replay would resume mid-flow.
    func testFlowIsAValueAndComparesOnPositionAndPresentation() {
        var a = WalkthroughFlow<MacWalkthroughStep>()
        let b = a
        a.advance()

        XCTAssertEqual(b.stepIndex, 0, "mutating a copy must not move the original")
        XCTAssertNotEqual(a, b)

        XCTAssertNotEqual(
            WalkthroughFlow<MacWalkthroughStep>(presentation: .firstRun),
            WalkthroughFlow<MacWalkthroughStep>(presentation: .replay)
        )
    }
}
