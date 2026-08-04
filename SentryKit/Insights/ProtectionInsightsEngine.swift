import Foundation

/// One complete evaluation: what fired, what was hidden, and the score that
/// follows from the former.
public struct ProtectionInsightsReport: Sendable, Equatable {

    /// `context.now`, carried through so the UI's "as of" label and the
    /// report's arithmetic can never disagree.
    public var generatedAt: Date

    /// Everything that fired and isn't suppressed, already prioritised.
    public var insights: [ProtectionInsight]

    /// Fired, but currently dismissed or snoozed. Surfaced (as a count, and
    /// behind a disclosure) rather than dropped, so hiding a finding is
    /// never the same as it not existing.
    public var suppressed: [ProtectionInsight]

    /// Computed from `insights` only — see `ProtectionScore.compute`.
    public var score: ProtectionScore

    /// Distinct calendar days of history the hardware half rests on.
    public var historyCoverageDays: Int

    /// `0` once there's enough history for the hardware rules to speak.
    public var additionalDaysNeeded: Int

    /// When the posture half was actually read. A cached posture from ten
    /// minutes ago is a fact about ten minutes ago, and the UI says so.
    public var postureCollectedAt: Date

    public var hasEnoughHistory: Bool { additionalDaysNeeded == 0 }

    public init(
        generatedAt: Date,
        insights: [ProtectionInsight],
        suppressed: [ProtectionInsight],
        score: ProtectionScore,
        historyCoverageDays: Int,
        additionalDaysNeeded: Int,
        postureCollectedAt: Date
    ) {
        self.generatedAt = generatedAt
        self.insights = insights
        self.suppressed = suppressed
        self.score = score
        self.historyCoverageDays = historyCoverageDays
        self.additionalDaysNeeded = additionalDaysNeeded
        self.postureCollectedAt = postureCollectedAt
    }

    /// Only the findings worth acting on — the list the UI leads with.
    public var actionable: [ProtectionInsight] {
        insights.filter { $0.severity != .good }
    }

    /// The positive findings, shown after the actionable ones.
    public var positives: [ProtectionInsight] {
        insights.filter { $0.severity == .good }
    }

    /// An empty report is a legitimate, expected state on a well-kept Mac
    /// with thin history — not an error, and not something to fill with
    /// placeholder cards.
    public var isEmpty: Bool { insights.isEmpty }
}

/// Runs every `ProtectionInsightRule` against one `InsightContext` and
/// assembles the result.
///
/// **Pure.** No I/O, no clock, no actor isolation. `evaluate` is a function
/// of `(context, suppressions)` and nothing else, which is what lets the
/// whole rule set be tested by constructing literal contexts and lets the
/// caller run it off the main thread without ceremony.
///
/// **Two invariants the engine enforces on rules, rather than trusting
/// them:**
/// 1. *Evidence or silence.* An insight with an empty `evidence` array is
///    dropped. `ProtectionInsight`'s doc comment explains why a finding
///    without a measured number on it is a defect and not a lesser feature;
///    enforcing it here means a rule that regresses disappears loudly in
///    tests rather than quietly shipping a poster slogan.
/// 2. *Unique ids.* Two rules claiming the same id would make dismissals
///    ambiguous, so only the first is kept and the duplicate is discarded.
public struct ProtectionInsightsEngine: Sendable {

    /// Every shipped rule, grouped by what it looks at. Order here is
    /// irrelevant to output — `prioritised(_:)` fully determines the final
    /// ordering — but it is the list a reader scans to see what the feature
    /// actually checks, so it is grouped for reading.
    public static let allRules: [any ProtectionInsightRule] = [
        // Battery longevity
        HighChargeResidencyRule(),
        BatteryNeverExercisedRule(),
        DeepDischargeRule(),
        CapacityLossRateRule(),
        CycleBurnRateRule(),
        ChargingWhileHotRule(),
        BatteryTemperatureExposureRule(),
        BatteryInGoodShapeRule(),

        // Thermal & load
        SustainedHeatRule(),
        ThermalThrottlingRule(),
        SustainedCPULoadRule(),
        SustainedGPULoadRule(),
        ThermalsWellBehavedRule(),

        // Memory
        HighMemoryUtilizationRule(),
        SwapThrashRule(),
        MemoryCompressionRule(),

        // Storage
        LowStorageHeadroomRule(),
        StorageFillingTrendRule(),
        StorageWriteVolumeRule(),
        StorageHeadroomHealthyRule(),

        // Power habits & maintenance
        LongUptimeRule(),
        KeepAwakeHeldRule(),
        UnderpoweredAdapterRule(),
        RisingThermalBaselineRule(),

        // Backup
        TimeMachineNoBackupDestinationRule(),
        TimeMachineBackupStaleRule(),
        TimeMachineBackupHealthyRule(),

        // Drive health
        DriveSMARTFailingRule(),
        DriveSMARTHealthyRule(),

        // Kernel panics
        KernelPanicHistoryRule(),

        // Security posture
        FileVaultOffRule(),
        FileVaultOnRule(),
        SIPDisabledRule(),
        GatekeeperDisabledRule(),
        FirewallOffRule(),
        FirewallStealthModeRule(),
        AutomaticUpdateChecksOffRule(),
        SecurityResponsesOffRule(),
        AutomaticMacOSUpdatesOffRule(),
        ScreenLockOffRule(),
        ScreenLockDelayRule(),
        RemoteLoginListeningRule(),
        ScreenSharingListeningRule(),
        FileSharingListeningRule(),
        RemoteManagementListeningRule(),
        GuestAccountEnabledRule(),
        OutdatedMacOSVersionRule(),
        PostureUnknownRule(),
        HardenedBaselineRule(),

        // Sentry's own posture
        RemoteMCPAccessRule(),
        LocalMCPWriteToolsRule()
    ]

    public let rules: [any ProtectionInsightRule]

    public init(rules: [any ProtectionInsightRule] = ProtectionInsightsEngine.allRules) {
        self.rules = rules
    }

    /// - Parameter suppressions: the user's dismissals and snoozes, usually
    ///   `AppSettings.protectionInsightSuppressions`. Expired snoozes are
    ///   ignored here rather than needing to be pruned first, so a stale
    ///   list can never hide a finding past its horizon.
    public func evaluate(
        _ context: InsightContext,
        suppressions: [InsightSuppression] = []
    ) -> ProtectionInsightsReport {
        var seenIDs = Set<String>()
        var fired: [ProtectionInsight] = []

        for rule in rules {
            guard let insight = rule.evaluate(context) else { continue }
            // Invariant 1: evidence or silence.
            guard !insight.evidence.isEmpty else { continue }
            // Invariant 2: unique ids.
            guard seenIDs.insert(insight.id).inserted else { continue }
            fired.append(insight)
        }

        let activeSuppressionIDs = Set(
            suppressions.filter { $0.isActive(at: context.now) }.map(\.insightID)
        )

        let visible = Self.prioritised(fired.filter { !activeSuppressionIDs.contains($0.id) })
        let hidden = Self.prioritised(fired.filter { activeSuppressionIDs.contains($0.id) })

        return ProtectionInsightsReport(
            generatedAt: context.now,
            insights: visible,
            suppressed: hidden,
            score: ProtectionScore.compute(insights: visible, context: context),
            historyCoverageDays: context.historyCoverageDays,
            additionalDaysNeeded: context.additionalDaysNeeded,
            postureCollectedAt: context.posture.collectedAt
        )
    }

    /// Severity first, then confidence, then point impact, then id.
    ///
    /// The id tiebreak is not cosmetic: without a total order, two insights
    /// equal on every other key could swap places between runs depending on
    /// rule-array order, which would make the list jitter on refresh and
    /// make the tests non-deterministic. Sorting on `id` makes the whole
    /// ordering a pure function of the insight set.
    ///
    /// Confidence outranking impact is deliberate — a low-confidence
    /// finding from six days of history should not outrank a well-evidenced
    /// one merely because its category carries a heavier weight.
    public static func prioritised(_ insights: [ProtectionInsight]) -> [ProtectionInsight] {
        insights.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            if lhs.scoreImpact != rhs.scoreImpact { return lhs.scoreImpact > rhs.scoreImpact }
            return lhs.id < rhs.id
        }
    }
}
