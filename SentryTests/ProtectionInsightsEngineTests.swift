import XCTest
@testable import SentryKit
@testable import SystemMetricsKit

final class ProtectionInsightsEngineTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Rule fire / don't-fire boundaries

    func testFileVaultOffRuleFiresOnlyWhenDefinitelyOff() {
        let rule = FileVaultOffRule()

        let off = InsightContext(now: now, posture: SecurityPosture(fileVault: .off))
        XCTAssertNotNil(rule.evaluate(off))
        XCTAssertEqual(rule.evaluate(off)?.severity, .critical)

        let on = InsightContext(now: now, posture: SecurityPosture(fileVault: .on))
        XCTAssertNil(rule.evaluate(on))

        // Unknown must never be treated as off — that's the whole point of
        // the three-state posture model.
        let unknown = InsightContext(now: now, posture: SecurityPosture(fileVault: .unknown))
        XCTAssertNil(rule.evaluate(unknown))
    }

    func testFirewallOffSeverityFollowsActualExposure() {
        let rule = FirewallOffRule()

        // Nothing listening, no MCP remote access: warning, not critical.
        let quiet = InsightContext(now: now, posture: SecurityPosture(firewall: .off))
        XCTAssertEqual(rule.evaluate(quiet)?.severity, .warning)

        // Something is actually listening: critical.
        let exposed = InsightContext(
            now: now,
            posture: SecurityPosture(firewall: .off, remoteLogin: .on)
        )
        XCTAssertEqual(rule.evaluate(exposed)?.severity, .critical)

        // Firewall on: rule stays silent regardless of exposure.
        let protected = InsightContext(
            now: now,
            posture: SecurityPosture(firewall: .on, remoteLogin: .on)
        )
        XCTAssertNil(rule.evaluate(protected))
    }

    func testScreenLockDelayRuleBoundary() {
        let rule = ScreenLockDelayRule()
        let longDelay = ScreenLockDelayRule.longDelaySeconds

        // Exactly at the threshold: fires.
        let atThreshold = InsightContext(
            now: now,
            posture: SecurityPosture(screenLockOnSleep: .on, screenLockDelaySeconds: longDelay)
        )
        XCTAssertNotNil(rule.evaluate(atThreshold))

        // One second under: stays silent.
        let underThreshold = InsightContext(
            now: now,
            posture: SecurityPosture(screenLockOnSleep: .on, screenLockDelaySeconds: longDelay - 1)
        )
        XCTAssertNil(rule.evaluate(underThreshold))

        // Screen lock itself off: this rule (about the delay) doesn't apply —
        // `ScreenLockOffRule` covers that case instead.
        let lockOff = InsightContext(
            now: now,
            posture: SecurityPosture(screenLockOnSleep: .off, screenLockDelaySeconds: longDelay)
        )
        XCTAssertNil(rule.evaluate(lockOff))

        // No delay reading at all: silent rather than guessing.
        let noReading = InsightContext(
            now: now,
            posture: SecurityPosture(screenLockOnSleep: .on, screenLockDelaySeconds: nil)
        )
        XCTAssertNil(rule.evaluate(noReading))
    }

    func testDeepDischargeRuleRequiresEnoughHistoryAndDayCount() {
        let rule = DeepDischargeRule()
        let advisoryDays = DeepDischargeRule.advisoryDays
        let warningDays = DeepDischargeRule.warningDays

        // Below the minimum history window (`InsightContext.minimumHistoryDays`),
        // the rule must stay silent no matter how bad the underlying numbers are.
        let thinHistory = InsightContext(
            now: now,
            battery: BatteryHistorySummary(daysWithData: 10, daysWithDeepDischarge: warningDays),
            historyCoverageDays: InsightContext.minimumHistoryDays - 1
        )
        XCTAssertNil(rule.evaluate(thinHistory))

        // Enough history, below the advisory threshold: silent.
        let belowAdvisory = InsightContext(
            now: now,
            battery: BatteryHistorySummary(daysWithData: 10, daysWithDeepDischarge: advisoryDays - 1),
            historyCoverageDays: InsightContext.minimumHistoryDays
        )
        XCTAssertNil(rule.evaluate(belowAdvisory))

        // At the advisory threshold: fires as .advice.
        let atAdvisory = InsightContext(
            now: now,
            battery: BatteryHistorySummary(daysWithData: 10, daysWithDeepDischarge: advisoryDays),
            historyCoverageDays: InsightContext.minimumHistoryDays
        )
        XCTAssertEqual(rule.evaluate(atAdvisory)?.severity, .advice)

        // At the warning threshold: escalates to .warning.
        let atWarning = InsightContext(
            now: now,
            battery: BatteryHistorySummary(daysWithData: 10, daysWithDeepDischarge: warningDays),
            historyCoverageDays: InsightContext.minimumHistoryDays
        )
        XCTAssertEqual(rule.evaluate(atWarning)?.severity, .warning)
    }

    func testHardenedBaselineRuleRequiresAllFour() {
        let rule = HardenedBaselineRule()

        let allOn = InsightContext(
            now: now,
            posture: SecurityPosture(
                fileVault: .on,
                systemIntegrityProtection: .on,
                gatekeeper: .on,
                firewall: .on
            )
        )
        XCTAssertEqual(rule.evaluate(allOn)?.severity, .good)

        // Any single one missing (even unknown, not just off) drops the finding.
        let oneUnknown = InsightContext(
            now: now,
            posture: SecurityPosture(
                fileVault: .on,
                systemIntegrityProtection: .on,
                gatekeeper: .unknown,
                firewall: .on
            )
        )
        XCTAssertNil(rule.evaluate(oneUnknown))
    }

    func testPostureUnknownRuleFiresExactlyWhenSomethingIsUnknown() {
        let rule = PostureUnknownRule()

        XCTAssertNil(rule.evaluate(InsightContext(now: now, posture: SecurityPosture(
            fileVault: .on, systemIntegrityProtection: .on, gatekeeper: .on,
            firewall: .on, firewallStealthMode: .on, automaticUpdateChecks: .on,
            automaticSecurityResponses: .on, automaticMacOSUpdates: .on,
            screenLockOnSleep: .on, remoteLogin: .off, screenSharing: .off,
            fileSharing: .off, remoteManagement: .off, guestAccount: .off
        ))))

        let withUnknown = InsightContext(now: now, posture: .unknownPosture())
        let insight = rule.evaluate(withUnknown)
        XCTAssertNotNil(insight)
        XCTAssertEqual(insight?.severity, .advice)
        // Never affects the score, even though it fires.
        XCTAssertEqual(insight?.scoreImpact, InsightWeight.none)
    }

    // MARK: - Engine invariants

    func testEngineDropsEvidenceFreeInsights() {
        struct EvidenceFreeRule: ProtectionInsightRule {
            let id = "test.no-evidence"
            let category: InsightCategory = .security
            func evaluate(_ context: InsightContext) -> ProtectionInsight? {
                ProtectionInsight(
                    id: id, title: "t", summary: "s", detail: "d", recommendation: "r",
                    category: category, severity: .warning, evidence: []
                )
            }
        }
        let engine = ProtectionInsightsEngine(rules: [EvidenceFreeRule()])
        let report = engine.evaluate(InsightContext(now: now))
        XCTAssertTrue(report.insights.isEmpty)
    }

    func testEngineKeepsOnlyFirstRuleForADuplicateID() {
        struct DuplicateA: ProtectionInsightRule {
            let id = "test.duplicate"
            let category: InsightCategory = .security
            func evaluate(_ context: InsightContext) -> ProtectionInsight? {
                ProtectionInsight(
                    id: id, title: "first", summary: "s", detail: "d", recommendation: "r",
                    category: category, severity: .warning, evidence: ["e"]
                )
            }
        }
        struct DuplicateB: ProtectionInsightRule {
            let id = "test.duplicate"
            let category: InsightCategory = .security
            func evaluate(_ context: InsightContext) -> ProtectionInsight? {
                ProtectionInsight(
                    id: id, title: "second", summary: "s", detail: "d", recommendation: "r",
                    category: category, severity: .critical, evidence: ["e"]
                )
            }
        }
        let engine = ProtectionInsightsEngine(rules: [DuplicateA(), DuplicateB()])
        let report = engine.evaluate(InsightContext(now: now))
        XCTAssertEqual(report.insights.count, 1)
        XCTAssertEqual(report.insights.first?.title, "first")
    }

    func testPrioritisedOrdersBySeverityThenConfidenceThenImpactThenID() {
        let low = ProtectionInsight(
            id: "z", title: "low", summary: "", detail: "", recommendation: "",
            category: .security, severity: .advice, evidence: ["e"], confidence: 1.0, scoreImpact: 1
        )
        let highA = ProtectionInsight(
            id: "b", title: "highA", summary: "", detail: "", recommendation: "",
            category: .security, severity: .critical, evidence: ["e"], confidence: 0.5, scoreImpact: 25
        )
        let highB = ProtectionInsight(
            id: "a", title: "highB", summary: "", detail: "", recommendation: "",
            category: .security, severity: .critical, evidence: ["e"], confidence: 1.0, scoreImpact: 10
        )
        let ordered = ProtectionInsightsEngine.prioritised([low, highA, highB])
        // Both criticals outrank the advice; among the two criticals, the
        // higher-confidence one (highB) outranks the higher-impact one (highA).
        XCTAssertEqual(ordered.map(\.id), ["a", "b", "z"])
    }

    // MARK: - Suppression / snooze / dismiss filtering

    func testSuppressedInsightsAreFilteredFromVisibleButReportedAsSuppressed() {
        let rule = FileVaultOffRule()
        let engine = ProtectionInsightsEngine(rules: [rule])
        let context = InsightContext(now: now, posture: SecurityPosture(fileVault: .off))

        let dismissal = InsightSuppression.dismiss(insightID: rule.id, at: now)
        let report = engine.evaluate(context, suppressions: [dismissal])

        XCTAssertTrue(report.insights.isEmpty)
        XCTAssertEqual(report.suppressed.map(\.id), [rule.id])
        // A suppressed finding must not still cost points — see
        // `ProtectionScore.compute`'s doc comment on auditability.
        XCTAssertEqual(report.score.overall, ProtectionScore.maximum)
    }

    func testExpiredSnoozeNoLongerSuppresses() {
        let rule = FileVaultOffRule()
        let engine = ProtectionInsightsEngine(rules: [rule])
        let context = InsightContext(now: now, posture: SecurityPosture(fileVault: .off))

        let expiredSnooze = InsightSuppression(
            insightID: rule.id,
            kind: .snoozed,
            createdAt: now.addingTimeInterval(-1_000_000),
            until: now.addingTimeInterval(-1)
        )
        let report = engine.evaluate(context, suppressions: [expiredSnooze])

        XCTAssertEqual(report.insights.map(\.id), [rule.id])
        XCTAssertTrue(report.suppressed.isEmpty)
    }

    func testActiveSnoozeSuppresses() {
        let rule = FileVaultOffRule()
        let engine = ProtectionInsightsEngine(rules: [rule])
        let context = InsightContext(now: now, posture: SecurityPosture(fileVault: .off))

        let activeSnooze = InsightSuppression.snooze(insightID: rule.id, for: .week, from: now)
        let report = engine.evaluate(context, suppressions: [activeSnooze])

        XCTAssertTrue(report.insights.isEmpty)
        XCTAssertEqual(report.suppressed.map(\.id), [rule.id])
    }

    func testSnoozedWithNilUntilIsTreatedAsExpiredNotIndefinite() {
        // Only reachable through a hand-edited settings file, but the
        // contract (documented on `InsightSuppression.isActive`) is that this
        // must never behave as a permanent hide.
        let malformed = InsightSuppression(insightID: "x", kind: .snoozed, createdAt: now, until: nil)
        XCTAssertFalse(malformed.isActive(at: now))
    }

    func testDismissedSuppressionHasNoExpiry() {
        // The `until` invariant is enforced in `init`, not just documented.
        let dismissal = InsightSuppression(
            insightID: "x", kind: .dismissed, createdAt: now, until: now.addingTimeInterval(1000)
        )
        XCTAssertNil(dismissal.until)
        XCTAssertTrue(dismissal.isActive(at: now.addingTimeInterval(1_000_000_000)))
    }

    // MARK: - Score determinism / monotonicity

    func testScoreIsDeterministicForTheSameInputs() {
        let insights = [
            ProtectionInsight(
                id: "a", title: "t", summary: "", detail: "", recommendation: "",
                category: .security, severity: .critical, evidence: ["e"], scoreImpact: InsightWeight.criticalSecurity
            )
        ]
        let context = InsightContext(now: now, posture: SecurityPosture(fileVault: .off))
        let first = ProtectionScore.compute(insights: insights, context: context)
        let second = ProtectionScore.compute(insights: insights, context: context)
        XCTAssertEqual(first, second)
    }

    func testScoreIsOrderIndependent() {
        let a = ProtectionInsight(
            id: "a", title: "t", summary: "", detail: "", recommendation: "",
            category: .security, severity: .critical, evidence: ["e"], scoreImpact: 25
        )
        let b = ProtectionInsight(
            id: "b", title: "t", summary: "", detail: "", recommendation: "",
            category: .storage, severity: .warning, evidence: ["e"], scoreImpact: 12
        )
        let context = InsightContext(now: now)
        let forward = ProtectionScore.compute(insights: [a, b], context: context)
        let reversed = ProtectionScore.compute(insights: [b, a], context: context)
        XCTAssertEqual(forward.overall, reversed.overall)
        XCTAssertEqual(forward.hardwareSubscore, reversed.hardwareSubscore)
        XCTAssertEqual(forward.securitySubscore, reversed.securitySubscore)
    }

    func testAddingAFindingCanOnlyLowerOrHoldTheScoreNeverRaiseIt() {
        let context = InsightContext(now: now)
        let baseline = ProtectionScore.compute(insights: [], context: context)
        XCTAssertEqual(baseline.overall, ProtectionScore.maximum)

        let finding = ProtectionInsight(
            id: "a", title: "t", summary: "", detail: "", recommendation: "",
            category: .security, severity: .warning, evidence: ["e"], scoreImpact: InsightWeight.majorSecurity
        )
        let withFinding = ProtectionScore.compute(insights: [finding], context: context)
        XCTAssertLessThanOrEqual(withFinding.overall, baseline.overall)

        let critical = ProtectionInsight(
            id: "b", title: "t", summary: "", detail: "", recommendation: "",
            category: .security, severity: .critical, evidence: ["e"], scoreImpact: InsightWeight.criticalSecurity
        )
        let withBoth = ProtectionScore.compute(insights: [finding, critical], context: context)
        XCTAssertLessThanOrEqual(withBoth.overall, withFinding.overall)
    }

    func testScoreClampsAtZeroRatherThanGoingNegative() {
        let insights = (0..<10).map { i in
            ProtectionInsight(
                id: "critical-\(i)", title: "t", summary: "", detail: "", recommendation: "",
                category: .security, severity: .critical, evidence: ["e"],
                scoreImpact: InsightWeight.criticalSecurity
            )
        }
        let score = ProtectionScore.compute(insights: insights, context: InsightContext(now: now))
        XCTAssertEqual(score.overall, 0)
    }

    func testGoodFindingsNeverRaiseTheScoreAboveMaximum() {
        let goodOnly = [
            ProtectionInsight(
                id: "good", title: "t", summary: "", detail: "", recommendation: "",
                category: .security, severity: .good, evidence: ["e"], scoreImpact: InsightWeight.none
            )
        ]
        let score = ProtectionScore.compute(insights: goodOnly, context: InsightContext(now: now))
        XCTAssertEqual(score.overall, ProtectionScore.maximum)
    }

    func testCategoriesWithoutDataAreNotScored() {
        // No battery summary at all → batteryLongevity has no data and must
        // report `score == nil`, not a fabricated 100.
        let context = InsightContext(now: now)
        XCTAssertFalse(ProtectionScore.categoryHasData(.batteryLongevity, context: context))

        let withBattery = InsightContext(
            now: now,
            battery: BatteryHistorySummary(daysWithData: 1, chargeSampleCount: 1)
        )
        XCTAssertTrue(ProtectionScore.categoryHasData(.batteryLongevity, context: withBattery))

        let score = ProtectionScore.compute(insights: [], context: context)
        let batteryCategory = score.categories.first { $0.category == .batteryLongevity }
        XCTAssertEqual(batteryCategory?.hasData, false)
        XCTAssertNil(batteryCategory?.score)
    }

    // MARK: - Posture-string parsing, including malformed / empty input

    func testFileVaultParsing() {
        XCTAssertEqual(SecurityPostureParser.fileVault("FileVault is On."), .on)
        XCTAssertEqual(SecurityPostureParser.fileVault("FileVault is Off."), .off)
        XCTAssertEqual(
            SecurityPostureParser.fileVault("FileVault is Off, but will be enabled after the next restart."),
            .off
        )
        XCTAssertEqual(SecurityPostureParser.fileVault(nil), .unknown)
        XCTAssertEqual(SecurityPostureParser.fileVault(""), .unknown)
        XCTAssertEqual(SecurityPostureParser.fileVault("   \n  "), .unknown)
        XCTAssertEqual(SecurityPostureParser.fileVault("some garbage from a future macOS"), .unknown)
    }

    func testSystemIntegrityProtectionParsingTreatsCustomConfigurationAsUnknown() {
        XCTAssertEqual(
            SecurityPostureParser.systemIntegrityProtection("System Integrity Protection status: enabled."),
            .on
        )
        XCTAssertEqual(
            SecurityPostureParser.systemIntegrityProtection("System Integrity Protection status: disabled."),
            .off
        )
        // Partially-disabled SIP must never read as fully on, even though
        // the string literally contains "enabled".
        XCTAssertEqual(
            SecurityPostureParser.systemIntegrityProtection(
                "System Integrity Protection status: enabled (Custom Configuration)."
            ),
            .unknown
        )
        XCTAssertEqual(SecurityPostureParser.systemIntegrityProtection(nil), .unknown)
        XCTAssertEqual(SecurityPostureParser.systemIntegrityProtection(""), .unknown)
    }

    func testFirewallGlobalStateParsingPrefersNumericFormOverProse() {
        XCTAssertEqual(SecurityPostureParser.firewallGlobalState("Firewall is enabled. (State = 1)"), .on)
        XCTAssertEqual(SecurityPostureParser.firewallGlobalState("Firewall is enabled. (State = 2)"), .on)
        XCTAssertEqual(SecurityPostureParser.firewallGlobalState("Firewall is disabled. (State = 0)"), .off)
        XCTAssertEqual(SecurityPostureParser.firewallGlobalState(nil), .unknown)
        XCTAssertEqual(SecurityPostureParser.firewallGlobalState(""), .unknown)
        XCTAssertEqual(SecurityPostureParser.firewallGlobalState("nonsense"), .unknown)
    }

    func testBooleanDefaultParsingAcceptsBothSpellingsAndRejectsGarbage() {
        XCTAssertEqual(SecurityPostureParser.booleanDefault("1"), .on)
        XCTAssertEqual(SecurityPostureParser.booleanDefault("true"), .on)
        XCTAssertEqual(SecurityPostureParser.booleanDefault("0"), .off)
        XCTAssertEqual(SecurityPostureParser.booleanDefault("false"), .off)
        XCTAssertEqual(SecurityPostureParser.booleanDefault(nil), .unknown)
        XCTAssertEqual(SecurityPostureParser.booleanDefault(""), .unknown)
        XCTAssertEqual(SecurityPostureParser.booleanDefault("does not exist"), .unknown)
    }

    func testIntegerDefaultParsingReturnsNilForMalformedInput() {
        XCTAssertEqual(SecurityPostureParser.integerDefault("300"), 300)
        XCTAssertNil(SecurityPostureParser.integerDefault(nil))
        XCTAssertNil(SecurityPostureParser.integerDefault(""))
        XCTAssertNil(SecurityPostureParser.integerDefault("not a number"))
    }

    func testListeningPortsExcludesLoopbackAndParsesOnlyListeningTCP() {
        let output = """
        tcp4       0      0  *.22                   *.*                    LISTEN
        tcp4       0      0  127.0.0.1.5900         *.*                    LISTEN
        tcp4       0      0  192.168.1.5.445        *.*                    ESTABLISHED
        tcp6       0      0  *.3283                 *.*                    LISTEN
        garbage line that matches nothing
        """
        let ports = SecurityPostureParser.listeningPorts(netstatOutput: output)
        XCTAssertEqual(ports, [22, 3283])
        XCTAssertNil(SecurityPostureParser.listeningPorts(netstatOutput: nil))
    }

    func testListenerStateDistinguishesOffFromUnknown() {
        XCTAssertEqual(SecurityPostureParser.listenerState(port: 22, in: []), .off)
        XCTAssertEqual(SecurityPostureParser.listenerState(port: 22, in: [22]), .on)
        // A scan that failed entirely (nil set) must not be reported as "off"
        // — that would be a fabricated negative.
        XCTAssertEqual(SecurityPostureParser.listenerState(port: 22, in: nil), .unknown)
    }

    // MARK: - Pro gating cut

    func testFreeTierSeesOnlyTheTopTwoFindingsInFull() {
        let insights = (0..<5).map { i in
            ProtectionInsight(
                id: "finding-\(i)", title: "t\(i)", summary: "", detail: "", recommendation: "",
                category: .security, severity: .warning, evidence: ["e"], scoreImpact: InsightWeight.majorSecurity
            )
        }
        let gated = ProGate.apply(isUnlocked: false, to: insights)
        XCTAssertEqual(gated.unlocked.count, ProGate.freeInsightAllowance)
        XCTAssertEqual(gated.locked.count, insights.count - ProGate.freeInsightAllowance)
        XCTAssertTrue(gated.isGated)

        // Locked previews carry category/severity but nothing else that
        // could leak the finding's content.
        XCTAssertEqual(gated.locked.first?.severity, .warning)
    }

    func testUnlockedSeesEverythingAndNothingIsLocked() {
        let insights = (0..<5).map { i in
            ProtectionInsight(
                id: "finding-\(i)", title: "t\(i)", summary: "", detail: "", recommendation: "",
                category: .security, severity: .warning, evidence: ["e"]
            )
        }
        let gated = ProGate.apply(isUnlocked: true, to: insights)
        XCTAssertEqual(gated.unlocked.count, insights.count)
        XCTAssertTrue(gated.locked.isEmpty)
        XCTAssertFalse(gated.isGated)
    }

    func testFreeTierWithFewerThanTheAllowanceLocksNothing() {
        let insights = [
            ProtectionInsight(
                id: "only-one", title: "t", summary: "", detail: "", recommendation: "",
                category: .security, severity: .critical, evidence: ["e"]
            )
        ]
        let gated = ProGate.apply(isUnlocked: false, to: insights)
        XCTAssertEqual(gated.unlocked.count, 1)
        XCTAssertTrue(gated.locked.isEmpty)
    }
}
