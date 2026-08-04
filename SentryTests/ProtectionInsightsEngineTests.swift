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

    // MARK: - Banding (severity floor + points)

    /// Builds a finding with the exact shape the band rule cares about.
    private func finding(
        _ id: String,
        category: InsightCategory,
        severity: InsightSeverity,
        impact: Int
    ) -> ProtectionInsight {
        ProtectionInsight(
            id: id, title: "t", summary: "", detail: "", recommendation: "",
            category: category, severity: severity, evidence: ["e"], scoreImpact: impact
        )
    }

    /// **The bug this rule exists for, reproduced exactly.** A Mac whose only
    /// problem is its firewall being off fires one `majorSecurity` warning,
    /// costing 15, which lands the security half on precisely 85 — the
    /// points-only "well protected" boundary. Verified on a real machine: it
    /// read "93 · well protected" while listing "The firewall is off".
    func testFirewallOffIsNeverWellProtected() {
        let score = ProtectionScore.compute(
            insights: [finding("security.firewall-off", category: .security, severity: .warning, impact: InsightWeight.majorSecurity)],
            context: InsightContext(now: now)
        )

        // The arithmetic is unchanged — the numeral still reports the average.
        XCTAssertEqual(score.securitySubscore, 85)
        XCTAssertEqual(score.hardwareSubscore, 100)
        XCTAssertEqual(score.overall, 93)
        XCTAssertEqual(score.weakerSubscore, 85)
        // Points alone would still say "well protected"; the verdict must not.
        XCTAssertEqual(ProtectionScore.pointsBand(for: score.weakerSubscore), .wellProtected)
        XCTAssertEqual(score.band, .needsAttention)
    }

    func testCriticalFindingForcesTheWorstBandRegardlessOfPoints() {
        // One point of deduction, but the finding is critical: a defeated
        // protection is not a "needs attention" situation.
        let score = ProtectionScore.compute(
            insights: [finding("crit", category: .security, severity: .critical, impact: 1)],
            context: InsightContext(now: now)
        )
        XCTAssertEqual(score.weakerSubscore, 99)
        XCTAssertEqual(ProtectionScore.pointsBand(for: score.weakerSubscore), .wellProtected)
        XCTAssertEqual(score.band, .actOnThis)
    }

    /// A `critical` finding that costs nothing still forces the band —
    /// severity is read from the insights, not reconstructed from
    /// `deductions` (which only carries findings with points).
    func testZeroPointCriticalStillForcesTheWorstBand() {
        let score = ProtectionScore.compute(
            insights: [finding("crit", category: .security, severity: .critical, impact: InsightWeight.none)],
            context: InsightContext(now: now)
        )
        XCTAssertEqual(score.overall, 100)
        XCTAssertTrue(score.deductions.isEmpty)
        XCTAssertEqual(score.band, .actOnThis)
    }

    /// `.warning` is a *cap*, not an override: it can only make the band
    /// worse than points, never better.
    func testWarningCapsTheBandButDoesNotSoftenAWorseOne() {
        let score = ProtectionScore.compute(
            insights: [
                finding("a", category: .security, severity: .warning, impact: InsightWeight.majorSecurity),
                finding("b", category: .security, severity: .warning, impact: InsightWeight.majorSecurity),
                finding("c", category: .security, severity: .warning, impact: InsightWeight.majorSecurity)
            ],
            context: InsightContext(now: now)
        )
        XCTAssertEqual(score.securitySubscore, 55)
        XCTAssertEqual(ProtectionScore.pointsBand(for: 55), .actOnThis)
        XCTAssertEqual(score.band, .actOnThis)
    }

    /// With nothing above `advice`, points are still the whole story — so a
    /// pile of small findings can degrade the verdict on its own.
    func testAdviceOnlyFindingsAreStillBandedOnPoints() {
        let clean = ProtectionScore.compute(
            insights: [finding("a", category: .security, severity: .advice, impact: InsightWeight.minorSecurity)],
            context: InsightContext(now: now)
        )
        XCTAssertEqual(clean.weakerSubscore, 94)
        XCTAssertEqual(clean.band, .wellProtected)

        let many = ProtectionScore.compute(
            insights: (0..<4).map {
                finding("a\($0)", category: .security, severity: .advice, impact: InsightWeight.minorSecurity)
            },
            context: InsightContext(now: now)
        )
        XCTAssertEqual(many.weakerSubscore, 76)
        XCTAssertEqual(many.highestSeverity, .advice)
        XCTAssertEqual(many.band, .needsAttention)
    }

    func testNoFindingsBandsWellProtected() {
        let score = ProtectionScore.compute(insights: [], context: InsightContext(now: now))
        XCTAssertEqual(score.highestSeverity, .good)
        XCTAssertEqual(score.band, .wellProtected)
    }

    /// `good` findings are still findings; they must not float the band.
    func testGoodFindingsDoNotAffectTheBand() {
        let score = ProtectionScore.compute(
            insights: [finding("ok", category: .security, severity: .good, impact: InsightWeight.none)],
            context: InsightContext(now: now)
        )
        XCTAssertEqual(score.highestSeverity, .good)
        XCTAssertEqual(score.band, .wellProtected)
    }

    /// A hardware-side warning gates the verdict too — the rule is about
    /// severity, not about which half the finding landed in.
    func testHardwareWarningAlsoGatesTheBand() {
        let score = ProtectionScore.compute(
            insights: [finding("storage", category: .storage, severity: .warning, impact: InsightWeight.minorHardware)],
            context: InsightContext(now: now)
        )
        XCTAssertEqual(score.hardwareSubscore, 97)
        XCTAssertEqual(score.band, .needsAttention)
    }

    func testPointsBandBoundariesAreExact() {
        XCTAssertEqual(ProtectionScore.pointsBand(for: 100), .wellProtected)
        XCTAssertEqual(ProtectionScore.pointsBand(for: 85), .wellProtected)
        XCTAssertEqual(ProtectionScore.pointsBand(for: 84), .needsAttention)
        XCTAssertEqual(ProtectionScore.pointsBand(for: 60), .needsAttention)
        XCTAssertEqual(ProtectionScore.pointsBand(for: 59), .actOnThis)
        XCTAssertEqual(ProtectionScore.pointsBand(for: 0), .actOnThis)
    }

    func testBandOrdersBySeriousness() {
        XCTAssertTrue(ProtectionBand.wellProtected < .needsAttention)
        XCTAssertTrue(ProtectionBand.needsAttention < .actOnThis)
        XCTAssertEqual(ProtectionBand.allCases.count, 3)
    }

    // MARK: - Banding × suppression

    /// A dismissed finding is off the screen, so it must be off the verdict
    /// too — the band reads the same insight set the points do.
    func testDismissedCriticalDoesNotDriveTheBand() {
        let rule = FileVaultOffRule()
        let engine = ProtectionInsightsEngine(rules: [rule])
        let context = InsightContext(now: now, posture: SecurityPosture(fileVault: .off))

        let live = engine.evaluate(context)
        XCTAssertEqual(live.score.highestSeverity, .critical)
        XCTAssertEqual(live.score.band, .actOnThis)

        let dismissal = InsightSuppression(insightID: rule.id, kind: .dismissed, createdAt: now)
        let hidden = engine.evaluate(context, suppressions: [dismissal])
        XCTAssertTrue(hidden.insights.isEmpty)
        XCTAssertEqual(hidden.suppressed.map(\.id), [rule.id])
        XCTAssertEqual(hidden.score.highestSeverity, .good)
        XCTAssertEqual(hidden.score.band, .wellProtected)
    }

    /// The mirror of the above: a snooze that has expired brings the finding
    /// — and the verdict — back.
    func testExpiredSnoozeRestoresTheBand() {
        let rule = FirewallOffRule()
        let engine = ProtectionInsightsEngine(rules: [rule])
        let context = InsightContext(now: now, posture: SecurityPosture(firewall: .off))

        let active = InsightSuppression.snooze(insightID: rule.id, for: .week, from: now)
        XCTAssertEqual(engine.evaluate(context, suppressions: [active]).score.band, .wellProtected)

        let expired = InsightSuppression(
            insightID: rule.id,
            kind: .snoozed,
            createdAt: now.addingTimeInterval(-1_000_000),
            until: now.addingTimeInterval(-1)
        )
        let restored = engine.evaluate(context, suppressions: [expired])
        XCTAssertEqual(restored.score.highestSeverity, .warning)
        XCTAssertEqual(restored.score.band, .needsAttention)
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

    func testSubscoreClampsAtZeroRatherThanGoingNegative() {
        let insights = (0..<10).map { i in
            ProtectionInsight(
                id: "critical-\(i)", title: "t", summary: "", detail: "", recommendation: "",
                category: .security, severity: .critical, evidence: ["e"],
                scoreImpact: InsightWeight.criticalSecurity
            )
        }
        let score = ProtectionScore.compute(insights: insights, context: InsightContext(now: now))
        // 250 points of deductions against a 100-point half: the half floors
        // at 0 rather than going negative.
        XCTAssertEqual(score.securitySubscore, 0)
        XCTAssertEqual(score.weakerSubscore, 0)
        XCTAssertEqual(score.weakerDomain, .security)
        // The overall is the average of the halves, so a hardware side with
        // nothing wrong holds it at 50 — the *verdict* is what carries the
        // severity here, and it reads off the weaker half, which is 0.
        XCTAssertEqual(score.overall, 50)
    }

    /// The bug this model replaced: `overall` was `100 - every finding`,
    /// which could land below both halves it was printed above.
    func testOverallNeverFallsBelowEitherHalf() {
        let insights = [
            ProtectionInsight(
                id: "storage", title: "t", summary: "", detail: "", recommendation: "",
                category: .storage, severity: .warning, evidence: ["e"],
                scoreImpact: InsightWeight.majorHardware
            ),
            ProtectionInsight(
                id: "memory", title: "t", summary: "", detail: "", recommendation: "",
                category: .memory, severity: .advice, evidence: ["e"],
                scoreImpact: InsightWeight.minorHardware
            ),
            ProtectionInsight(
                id: "firewall", title: "t", summary: "", detail: "", recommendation: "",
                category: .security, severity: .warning, evidence: ["e"],
                scoreImpact: InsightWeight.majorSecurity
            )
        ]
        let score = ProtectionScore.compute(insights: insights, context: InsightContext(now: now))
        XCTAssertEqual(score.hardwareSubscore, 85)   // 100 - 12 - 3
        XCTAssertEqual(score.securitySubscore, 85)   // 100 - 15
        XCTAssertEqual(score.overall, 85)
        XCTAssertGreaterThanOrEqual(score.overall, min(score.hardwareSubscore, score.securitySubscore))
        XCTAssertLessThanOrEqual(score.overall, max(score.hardwareSubscore, score.securitySubscore))
    }

    /// A clean hardware half must not be able to average a critical security
    /// finding into a reassuring verdict.
    func testWeakerHalfDrivesTheVerdictNotTheAverage() {
        let fileVaultOff = ProtectionInsight(
            id: "filevault", title: "t", summary: "", detail: "", recommendation: "",
            category: .security, severity: .critical, evidence: ["e"],
            scoreImpact: InsightWeight.criticalSecurity
        )
        let score = ProtectionScore.compute(insights: [fileVaultOff], context: InsightContext(now: now))
        XCTAssertEqual(score.hardwareSubscore, 100)
        XCTAssertEqual(score.securitySubscore, 75)
        // The average alone would read 88 and band as "well protected".
        XCTAssertEqual(score.overall, 88)
        // The verdict reads off 75, which bands as "needs attention".
        XCTAssertEqual(score.weakerSubscore, 75)
        XCTAssertEqual(score.weakerDomain, .security)
    }

    func testWeakerDomainBreaksTiesTowardSecurity() {
        let score = ProtectionScore.compute(insights: [], context: InsightContext(now: now))
        XCTAssertEqual(score.hardwareSubscore, score.securitySubscore)
        XCTAssertEqual(score.weakerDomain, .security)
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

    // MARK: - Time Machine backup rules

    func testTimeMachineNoBackupDestinationRuleFiresOnlyWhenDefinitelyOff() {
        let rule = TimeMachineNoBackupDestinationRule()

        let off = InsightContext(now: now, posture: SecurityPosture(timeMachineDestinationConfigured: .off))
        let insight = rule.evaluate(off)
        XCTAssertNotNil(insight)
        XCTAssertEqual(insight?.severity, .critical)
        XCTAssertFalse(insight?.evidence.isEmpty ?? true)

        let on = InsightContext(now: now, posture: SecurityPosture(timeMachineDestinationConfigured: .on))
        XCTAssertNil(rule.evaluate(on))

        // Unknown must never be treated as "no destination" — the collector
        // couldn't tell, which is not the same fact as there being none.
        let unknown = InsightContext(now: now, posture: SecurityPosture(timeMachineDestinationConfigured: .unknown))
        XCTAssertNil(rule.evaluate(unknown))
    }

    func testTimeMachineBackupStaleRuleDistinguishesNeverCompletedFromStale() {
        let rule = TimeMachineBackupStaleRule()
        let staleDays = TimeMachineBackupStaleRule.staleWarningDays

        // Destination off entirely: this rule stays silent —
        // TimeMachineNoBackupDestinationRule covers that case instead.
        let noDestination = InsightContext(now: now, posture: SecurityPosture(timeMachineDestinationConfigured: .off))
        XCTAssertNil(rule.evaluate(noDestination))

        // Destination on, but no backup timestamp at all: never completed,
        // which is critical — functionally unprotected despite the setup.
        let neverCompleted = InsightContext(now: now, posture: SecurityPosture(
            timeMachineDestinationConfigured: .on, timeMachineLastBackupAt: nil
        ))
        let neverInsight = rule.evaluate(neverCompleted)
        XCTAssertEqual(neverInsight?.severity, .critical)
        XCTAssertEqual(neverInsight?.scoreImpact, InsightWeight.criticalSecurity)

        // Exactly at the stale threshold: fires as a warning.
        let atThreshold = InsightContext(now: now, posture: SecurityPosture(
            timeMachineDestinationConfigured: .on,
            timeMachineLastBackupAt: now.addingTimeInterval(-Double(staleDays) * 86_400)
        ))
        let staleInsight = rule.evaluate(atThreshold)
        XCTAssertEqual(staleInsight?.severity, .warning)
        XCTAssertEqual(staleInsight?.scoreImpact, InsightWeight.majorSecurity)

        // One day under the threshold: silent (TimeMachineBackupHealthyRule
        // covers this case).
        let underThreshold = InsightContext(now: now, posture: SecurityPosture(
            timeMachineDestinationConfigured: .on,
            timeMachineLastBackupAt: now.addingTimeInterval(-Double(staleDays - 1) * 86_400)
        ))
        XCTAssertNil(rule.evaluate(underThreshold))
    }

    func testTimeMachineBackupHealthyRuleFiresOnlyWhenRecent() {
        let rule = TimeMachineBackupHealthyRule()
        let staleDays = TimeMachineBackupStaleRule.staleWarningDays

        let recent = InsightContext(now: now, posture: SecurityPosture(
            timeMachineDestinationConfigured: .on,
            timeMachineLastBackupAt: now.addingTimeInterval(-3600)
        ))
        let insight = rule.evaluate(recent)
        XCTAssertEqual(insight?.severity, .good)
        XCTAssertFalse(insight?.evidence.isEmpty ?? true)

        let stale = InsightContext(now: now, posture: SecurityPosture(
            timeMachineDestinationConfigured: .on,
            timeMachineLastBackupAt: now.addingTimeInterval(-Double(staleDays) * 86_400)
        ))
        XCTAssertNil(rule.evaluate(stale))

        let noTimestamp = InsightContext(now: now, posture: SecurityPosture(
            timeMachineDestinationConfigured: .on, timeMachineLastBackupAt: nil
        ))
        XCTAssertNil(rule.evaluate(noTimestamp))

        let noDestination = InsightContext(now: now, posture: SecurityPosture(
            timeMachineDestinationConfigured: .off, timeMachineLastBackupAt: now
        ))
        XCTAssertNil(rule.evaluate(noDestination))
    }

    func testTimeMachineDestinationConfiguredParsing() {
        XCTAssertEqual(
            SecurityPostureParser.timeMachineDestinationConfigured("tmutil: No destinations configured."),
            .off
        )
        XCTAssertEqual(
            SecurityPostureParser.timeMachineDestinationConfigured("Name            : Backup Drive\nKind            : Local"),
            .on
        )
        XCTAssertEqual(SecurityPostureParser.timeMachineDestinationConfigured(nil), .unknown)
        XCTAssertEqual(SecurityPostureParser.timeMachineDestinationConfigured(""), .unknown)
    }

    func testTimeMachineLastBackupDateParsing() {
        let parsed = SecurityPostureParser.timeMachineLastBackupDate("2024-01-15-123456")
        XCTAssertNotNil(parsed)

        // Extra surrounding text (a full path, not just -t output) still
        // yields the timestamp.
        let fromPath = SecurityPostureParser.timeMachineLastBackupDate(
            "/Volumes/Backup/Backups.backupdb/Mac/2024-01-15-123456"
        )
        XCTAssertEqual(fromPath, parsed)

        XCTAssertNil(SecurityPostureParser.timeMachineLastBackupDate(nil))
        XCTAssertNil(SecurityPostureParser.timeMachineLastBackupDate(""))
        XCTAssertNil(SecurityPostureParser.timeMachineLastBackupDate("Failed to mount backup destination"))
    }

    // MARK: - Drive health (SMART)

    func testDriveSMARTFailingAndHealthyRulesRespectTriState() {
        let failingRule = DriveSMARTFailingRule()
        let healthyRule = DriveSMARTHealthyRule()

        let failing = InsightContext(now: now, posture: SecurityPosture(driveSMARTStatus: .failing))
        XCTAssertEqual(failingRule.evaluate(failing)?.severity, .critical)
        XCTAssertEqual(failingRule.evaluate(failing)?.scoreImpact, InsightWeight.criticalSecurity)
        XCTAssertNil(healthyRule.evaluate(failing))

        let verified = InsightContext(now: now, posture: SecurityPosture(driveSMARTStatus: .verified))
        XCTAssertNil(failingRule.evaluate(verified))
        XCTAssertEqual(healthyRule.evaluate(verified)?.severity, .good)

        // Unknown (unreadable, or a device that doesn't report SMART at
        // all) fires neither — never fabricate a pass or a failure.
        let unknown = InsightContext(now: now, posture: SecurityPosture(driveSMARTStatus: .unknown))
        XCTAssertNil(failingRule.evaluate(unknown))
        XCTAssertNil(healthyRule.evaluate(unknown))
    }

    func testDriveSMARTStatusParsing() {
        let verifiedPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>SMARTStatus</key><string>Verified</string></dict></plist>
        """
        XCTAssertEqual(SecurityPostureParser.driveSMARTStatus(verifiedPlist), .verified)

        let failingPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>SMARTStatus</key><string>Failing</string></dict></plist>
        """
        XCTAssertEqual(SecurityPostureParser.driveSMARTStatus(failingPlist), .failing)

        // No SMARTStatus key at all — some external/virtual volumes don't
        // report it. Honest unknown, not a fabricated pass.
        let noKeyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>FreeSpace</key><integer>0</integer></dict></plist>
        """
        XCTAssertEqual(SecurityPostureParser.driveSMARTStatus(noKeyPlist), .unknown)

        XCTAssertEqual(SecurityPostureParser.driveSMARTStatus(nil), .unknown)
        XCTAssertEqual(SecurityPostureParser.driveSMARTStatus("not a plist"), .unknown)
    }

    // MARK: - Kernel panic history

    func testKernelPanicHistoryRuleBoundary() {
        let rule = KernelPanicHistoryRule()
        let minimum = KernelPanicHistoryRule.minimumPanicsToFlag

        // Below the minimum: silent, even though a panic did occur — a
        // single panic isn't a pattern.
        let one = InsightContext(now: now, posture: SecurityPosture(recentKernelPanicCount: minimum - 1))
        XCTAssertNil(rule.evaluate(one))

        // At the minimum: fires.
        let atMinimum = InsightContext(now: now, posture: SecurityPosture(recentKernelPanicCount: minimum))
        let insight = rule.evaluate(atMinimum)
        XCTAssertEqual(insight?.severity, .warning)
        XCTAssertEqual(insight?.scoreImpact, InsightWeight.majorHardware)
        XCTAssertFalse(insight?.evidence.isEmpty ?? true)

        // Zero panics: silent, and deliberately not a positive finding
        // either — see the rule's doc comment on absence-of-evidence.
        let zero = InsightContext(now: now, posture: SecurityPosture(recentKernelPanicCount: 0))
        XCTAssertNil(rule.evaluate(zero))

        // Unknown (directory couldn't be listed): silent, never assumed
        // clean.
        let unknown = InsightContext(now: now, posture: SecurityPosture(recentKernelPanicCount: nil))
        XCTAssertNil(rule.evaluate(unknown))
    }

    func testKernelPanicCountParsing() {
        let windowStart = now.addingTimeInterval(-30 * 86_400)
        let entries: [(filename: String, modifiedAt: Date)] = [
            ("Kernel-2024-01-01-100000.panic", now.addingTimeInterval(-86_400)),
            ("Kernel-2023-01-01-100000.panic", now.addingTimeInterval(-1000 * 86_400)), // outside the window
            ("SomeApp-2024-01-01-100000.crash", now.addingTimeInterval(-86_400)), // not a panic
            ("KERNEL-RECENT.PANIC", now.addingTimeInterval(-86_400)) // case-insensitive match
        ]
        XCTAssertEqual(SecurityPostureParser.kernelPanicCount(entries: entries, windowStart: windowStart), 2)
        XCTAssertEqual(SecurityPostureParser.kernelPanicCount(entries: [], windowStart: windowStart), 0)
    }

    // MARK: - Outdated macOS version

    func testOutdatedMacOSVersionRuleBoundary() {
        let rule = OutdatedMacOSVersionRule()
        let minimum = OutdatedMacOSVersionRule.minimumSupportedMajorVersion

        // One major version below the cutoff: fires.
        let outdated = InsightContext(now: now, device: DeviceFacts(macOSVersion: "\(minimum - 1).6.3"))
        let insight = rule.evaluate(outdated)
        XCTAssertEqual(insight?.severity, .critical)
        XCTAssertEqual(insight?.scoreImpact, InsightWeight.criticalSecurity)

        // Exactly at the cutoff: still supported, stays silent.
        let atCutoff = InsightContext(now: now, device: DeviceFacts(macOSVersion: "\(minimum).0.0"))
        XCTAssertNil(rule.evaluate(atCutoff))

        // Well above the cutoff: silent.
        let current = InsightContext(now: now, device: DeviceFacts(macOSVersion: "\(minimum + 2).0.0"))
        XCTAssertNil(rule.evaluate(current))

        // No version string at all, or an unparseable one: honest silence
        // rather than a guess.
        let missing = InsightContext(now: now, device: DeviceFacts(macOSVersion: nil))
        XCTAssertNil(rule.evaluate(missing))

        let garbled = InsightContext(now: now, device: DeviceFacts(macOSVersion: "not-a-version"))
        XCTAssertNil(rule.evaluate(garbled))
    }

    // MARK: - Category deduction cap (correlated hardware findings)

    /// **The exact scenario from the review this cap was added for.** One
    /// hot, sustained workload fires `SustainedHeatRule` and
    /// `ThermalThrottlingRule` and `SustainedCPULoadRule` (all `.thermal`,
    /// 12 + 12 + 7 = 31), plus `RisingThermalBaselineRule` (`.maintenance`,
    /// 7) and `ChargingWhileHotRule` (`.batteryLongevity`, 7) — five
    /// findings, one root cause, 45 raw points. Before the cap, that reads
    /// hardware 55 / weakerSubscore 55 / `.actOnThis`. After it, `.thermal`'s
    /// 31 is capped to 24, for a domain loss of 38 and hardware 62 —
    /// crossing the `needsAttention` boundary.
    func testCategoryDeductionCapLimitsCorrelatedHardwareFindings() {
        let correlatedFindings = [
            finding("thermal.sustained-heat", category: .thermal, severity: .warning, impact: InsightWeight.majorHardware),
            finding("thermal.throttling-frequency", category: .thermal, severity: .warning, impact: InsightWeight.majorHardware),
            finding("load.sustained-cpu", category: .thermal, severity: .warning, impact: InsightWeight.moderateHardware),
            finding("thermal.rising-baseline", category: .maintenance, severity: .warning, impact: InsightWeight.moderateHardware),
            finding("battery.charging-while-hot", category: .batteryLongevity, severity: .warning, impact: InsightWeight.moderateHardware)
        ]
        let score = ProtectionScore.compute(insights: correlatedFindings, context: InsightContext(now: now))

        let thermalCategory = score.categories.first { $0.category == .thermal }
        // The category's own truth is uncapped — 31 raw points lost, so the
        // Thermals chip still honestly reports how bad thermals are.
        XCTAssertEqual(thermalCategory?.pointsLost, 31)

        // The domain aggregate is capped: 24 (thermal, capped from 31) + 7
        // (maintenance) + 7 (batteryLongevity) = 38 lost, not 45.
        XCTAssertEqual(score.hardwareSubscore, 100 - 38)
        XCTAssertEqual(score.hardwareSubscore, 62)

        // The before/after headline: uncapped this would have banded
        // `.actOnThis` (55 < 60); capped it bands `.needsAttention`.
        XCTAssertEqual(ProtectionScore.pointsBand(for: 55), .actOnThis)
        XCTAssertEqual(score.band, .needsAttention)
    }

    /// A category sitting exactly at the cap is untouched; one point past it
    /// is trimmed by exactly that one point — the cap is a ceiling, not a
    /// rounding step.
    func testCategoryDeductionCapBoundaryIsExact() {
        let atCap = ProtectionScore.compute(
            insights: [finding("a", category: .thermal, severity: .warning, impact: ProtectionScore.categoryDeductionCapHardware)],
            context: InsightContext(now: now)
        )
        XCTAssertEqual(atCap.hardwareSubscore, 100 - ProtectionScore.categoryDeductionCapHardware)

        let onePast = ProtectionScore.compute(
            insights: [finding("a", category: .thermal, severity: .warning, impact: ProtectionScore.categoryDeductionCapHardware + 1)],
            context: InsightContext(now: now)
        )
        // Capped at the same value as "atCap" above — the extra point is
        // absorbed, not applied.
        XCTAssertEqual(onePast.hardwareSubscore, 100 - ProtectionScore.categoryDeductionCapHardware)
    }

    /// The cap must never touch the security domain — a Mac with several
    /// independently-disabled protections that happen to share the
    /// `.security` category is not "one correlated event" the way a hot
    /// workload is, and each disabled protection must still cost its full
    /// weight. This is the same fixture `testSubscoreClampsAtZeroRatherThanGoingNegative`
    /// uses; restated here to pin the cap-exemption explicitly by name.
    func testCategoryDeductionCapDoesNotApplyToSecurityDomain() {
        let manyIndependentSecurityFindings = (0..<4).map { i in
            finding("critical-\(i)", category: .security, severity: .critical, impact: InsightWeight.criticalSecurity)
        }
        let score = ProtectionScore.compute(insights: manyIndependentSecurityFindings, context: InsightContext(now: now))
        // 4 × 25 = 100 lost, uncapped — if the hardware-domain cap of 24 had
        // leaked into security, this would floor at 76, not 0.
        XCTAssertEqual(score.securitySubscore, 0)
    }
}
