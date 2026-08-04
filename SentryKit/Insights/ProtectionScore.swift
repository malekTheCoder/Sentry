import Foundation

/// The standard point weights every rule draws its `scoreImpact` from.
///
/// **Why a fixed vocabulary instead of per-rule numbers.** With free-form
/// weights, "how bad is this?" becomes a judgement each rule author makes in
/// isolation, and the scale drifts until a 100-point total means nothing.
/// Six named tiers force each rule to answer a comparative question instead:
/// *is this as bad as an unencrypted disk, or as bad as a slightly full
/// drive?* The tiers are also what makes the score explainable — every
/// deduction the UI shows traces back to one of these six, not to an
/// unexplained 13.
///
/// **The tiers, and the rationale for the gaps between them.**
/// - `criticalSecurity` (25): a defeated protection whose absence loses the
///   user *everything* in one bad event — an unencrypted disk on a stolen
///   laptop, SIP disabled. Four of these floor the score at 0, which is the
///   correct verdict for a machine with four of them.
/// - `majorSecurity` (15): a wide-open door that still needs an attacker to
///   walk through it — firewall off, screen sharing reachable, updates never
///   checked.
/// - `minorSecurity` (6): real but conditional — stealth mode off, guest
///   account enabled, a long screen-lock delay.
/// - `majorHardware` (12): measurable, ongoing damage to the machine's
///   lifespan — a startup disk with no headroom, weeks of thermal
///   saturation. Deliberately below `majorSecurity`: worn hardware costs
///   money, a breach costs more.
/// - `moderateHardware` (7): a habit that shortens life at a slower rate —
///   high-state-of-charge residency, heavy swap.
/// - `minorHardware` (3): worth knowing, not worth worrying about.
public enum InsightWeight {
    public static let criticalSecurity = 25
    public static let majorSecurity = 15
    public static let minorSecurity = 6
    public static let majorHardware = 12
    public static let moderateHardware = 7
    public static let minorHardware = 3
    /// Positive findings and pure-awareness notes cost nothing. A `good`
    /// insight never *raises* the score either — the score starts at 100 and
    /// only falls, so "nothing wrong" and "nothing wrong, and here are six
    /// things you're doing right" both read 100, which is honest.
    public static let none = 0
}

/// The verdict printed beside the score numeral: three words the user reads
/// instead of doing arithmetic.
///
/// A separate type rather than a string the view derives, because the band is
/// a *product claim* ("you are well protected") and every surface that makes
/// it — the Insights card today, Watch/iOS/MCP payloads later — has to make it
/// from the same rule. The previous arrangement had the thresholds inlined in
/// a SwiftUI view, which is exactly how a second surface ends up disagreeing
/// with the first.
///
/// `Comparable` ascends by seriousness, so "cap the band at `needsAttention`"
/// is expressible as `Swift.max(pointsBand, .needsAttention)` rather than as a
/// nest of ifs.
public enum ProtectionBand: String, Codable, Sendable, CaseIterable, Comparable {
    case wellProtected
    case needsAttention
    case actOnThis

    /// Ascending seriousness. Not the raw enum order by accident — code
    /// depends on it, so it is stated.
    public var rank: Int {
        switch self {
        case .wellProtected: return 0
        case .needsAttention: return 1
        case .actOnThis: return 2
        }
    }

    public static func < (lhs: ProtectionBand, rhs: ProtectionBand) -> Bool {
        lhs.rank < rhs.rank
    }

    /// The words shown to the user. Lower case: they sit beside a 64pt
    /// numeral as a continuation of it, not as a heading.
    public var caption: String {
        switch self {
        case .wellProtected: return String(localized: "well protected")
        case .needsAttention: return String(localized: "needs attention")
        case .actOnThis: return String(localized: "act on this")
        }
    }
}

/// A deterministic, explainable 0–100 rating of how well this Mac is
/// protected, plus the same rating per category.
///
/// **The whole model in two sentences:** each half — hardware and security —
/// starts at 100 and subtracts every firing insight in its own domain. The
/// overall score is the average of those two halves, and the *verdict* beside
/// it comes from whichever half is weaker.
///
/// **Why the overall is not itself a subtraction.** It used to be: `100 minus
/// every finding, globally`. That is arithmetically consistent but produces a
/// headline number *below both of its own halves* — a Mac scoring 72 hardware
/// and 85 security showed an overall of 57, which no aggregation a reader can
/// imagine (average, minimum, weighted) could yield. The same deductions were
/// being applied three times over: once per category, again per domain, and
/// again globally, with every level restarting at 100. Averaging the halves
/// keeps subtraction where it belongs — *within* a domain, where one critical
/// finding still guts that half — while guaranteeing the headline always sits
/// between the two numbers printed directly beneath it.
///
/// **Why the verdict follows the weaker half instead of the average.**
/// Protection does not average: a pristine battery does not compensate for an
/// unencrypted disk, because they are not the same currency. Left to the
/// average alone, FileVault off (−25) on an otherwise clean Mac reads 88 and
/// would print "well protected" — the app reassuring someone at the exact
/// moment it should not. Deriving the band from `weakerSubscore` means the
/// score can never claim to be in better shape than its worst side. The
/// number keeps all the information; the words carry the severity.
///
/// **Why the band is not points alone — the firewall case.** Banding the
/// weaker half on points was still not enough, and a real machine proved it:
/// a Mac with its firewall off fires exactly one `majorSecurity` finding,
/// which costs 15, which lands the security half on exactly 85 — the "well
/// protected" boundary. The app named a defeated protection in the list and
/// called the machine well protected in the same view. Any point threshold
/// has such a boundary; moving it to 86 would just relocate the contradiction
/// to the next weight. So the band is gated on *severity* as well as points:
/// - a `.critical` finding forces `.actOnThis`, whatever the arithmetic says.
///   A defeated protection is not a "needs attention" situation, and a Mac
///   with an unencrypted disk should not be one clean hardware half away from
///   a softer word.
/// - a `.warning` finding caps the band at `.needsAttention`. It can still be
///   worse than that when the points say so.
/// - with neither present, points decide, so a pile of `advice`-level
///   findings can still push the verdict down on its own.
///
/// The severity is read from the *same insight set the score was computed
/// over* (`highestSeverity`, populated by `compute`), which is the visible,
/// unsuppressed set. A finding the user dismissed or snoozed is not on screen
/// and therefore must not drive the verdict — the same auditability rule that
/// keeps suppressed findings out of the points. It is a stored property, not
/// derived from `deductions`, because a finding can be severe and cost zero
/// points (a `warning` whose weight is `InsightWeight.none`) and such a
/// finding must still gate the verdict.
///
/// Consequences of that choice, all deliberate:
/// - **Monotonic.** Adding a finding can never raise the score. A user who
///   fixes something and re-runs can never see it drop for that reason.
/// - **Deterministic.** No randomness, no time decay, no dependence on
///   evaluation order. The same insight set always produces the same number,
///   which is what makes the unit tests meaningful and the UI trustworthy.
/// - **Explainable.** `deductions` lists exactly which finding cost how many
///   points, so the number can always be taken apart on screen. A score a
///   user can't audit is a vibe, not a measurement.
/// - **No bonus points.** Positive (`good`) findings are shown but scored at
///   zero. Awarding points for them would mean the ceiling depends on how
///   many `good` rules happen to be implemented, so shipping a new positive
///   rule would silently change every user's score.
///
/// **Categories without data don't score.** A Mac whose thermal sensors
/// aren't readable has no thermal history, and a 100/100 "Thermals" chip
/// would be a fabricated pass. Those categories carry `hasData == false` and
/// the UI renders them as "not enough data" rather than as perfect.
public struct ProtectionScore: Codable, Sendable, Equatable {

    public static let maximum = 100

    /// One line of the score's arithmetic.
    public struct Deduction: Codable, Sendable, Equatable, Identifiable {
        public var id: String { insightID }
        public var insightID: String
        public var title: String
        public var category: InsightCategory
        public var severity: InsightSeverity
        public var points: Int

        public init(
            insightID: String,
            title: String,
            category: InsightCategory,
            severity: InsightSeverity,
            points: Int
        ) {
            self.insightID = insightID
            self.title = title
            self.category = category
            self.severity = severity
            self.points = points
        }
    }

    public struct CategoryScore: Codable, Sendable, Equatable, Identifiable {
        public var id: String { category.rawValue }
        public var category: InsightCategory
        /// 0…100, or `nil` when `hasData` is false — see the type doc.
        public var score: Int?
        public var pointsLost: Int
        public var findingCount: Int
        /// `false` when this Mac produced nothing for this category to judge.
        public var hasData: Bool

        public init(
            category: InsightCategory,
            score: Int?,
            pointsLost: Int,
            findingCount: Int,
            hasData: Bool
        ) {
            self.category = category
            self.score = score
            self.pointsLost = pointsLost
            self.findingCount = findingCount
            self.hasData = hasData
        }
    }

    public var overall: Int
    public var categories: [CategoryScore]
    public var deductions: [Deduction]

    /// 0…100 for each half of "protection", computed the same way as
    /// `overall` but only over that domain's categories.
    public var hardwareSubscore: Int
    public var securitySubscore: Int

    /// The most serious severity among the insights this score was computed
    /// from — i.e. among the findings the user can actually see. `.good` when
    /// nothing but positives fired. Gates `band`; see the type doc.
    public var highestSeverity: InsightSeverity

    /// `true` when the hardware half rests on less than
    /// `InsightContext.minimumHistoryDays` of history. The UI labels the
    /// score "provisional" rather than presenting a number built on four
    /// days as settled.
    public var isProvisional: Bool

    /// Distinct calendar days of history behind the hardware half.
    public var historyCoverageDays: Int

    /// Categories the app genuinely couldn't judge, for the UI's honest
    /// "not scored" list.
    public var unscoredCategories: [InsightCategory] {
        categories.filter { !$0.hasData }.map(\.category)
    }

    /// The half in worse shape — the one the UI names and takes its verdict
    /// from. Ties resolve to `.security`: when both halves are equal there is
    /// no "worse" one to point at, and of the two, security is the side whose
    /// findings a user should look at first.
    public var weakerDomain: InsightDomain {
        securitySubscore <= hardwareSubscore ? .security : .hardware
    }

    /// The weaker half's score. The UI bands *this*, not `overall` — see the
    /// type doc on why the verdict does not follow the average.
    public var weakerSubscore: Int {
        Swift.min(hardwareSubscore, securitySubscore)
    }

    /// Score at or above which points alone would say "well protected".
    public static let wellProtectedThreshold = 85
    /// Below this, points alone say "act on this".
    public static let needsAttentionThreshold = 60

    /// The points-only band for a 0…100 figure. Exposed so the per-number
    /// meters elsewhere in the UI (category rows, subscore bars) tint from the
    /// same boundaries the verdict starts from, instead of re-typing 85 and 60
    /// in each view — a divergent literal in a second view is how the
    /// contradiction this type documents got shipped in the first place.
    ///
    /// This is deliberately *not* the verdict: it knows nothing about
    /// severity. Use `band` for anything that puts words on the screen.
    public static func pointsBand(for score: Int) -> ProtectionBand {
        if score >= wellProtectedThreshold { return .wellProtected }
        if score >= needsAttentionThreshold { return .needsAttention }
        return .actOnThis
    }

    /// The verdict. Points from the weaker half, floored by severity — see
    /// the type doc's firewall case for why both are needed.
    public var band: ProtectionBand {
        let byPoints = Self.pointsBand(for: weakerSubscore)
        switch highestSeverity {
        case .critical:
            // A defeated protection is never anything but the worst band.
            return .actOnThis
        case .warning:
            // A cap, not an override: 40 points with a warning is still
            // "act on this".
            return Swift.max(byPoints, .needsAttention)
        case .good, .advice:
            return byPoints
        }
    }

    public init(
        overall: Int,
        categories: [CategoryScore],
        deductions: [Deduction],
        hardwareSubscore: Int,
        securitySubscore: Int,
        highestSeverity: InsightSeverity = .good,
        isProvisional: Bool,
        historyCoverageDays: Int
    ) {
        self.overall = overall
        self.categories = categories
        self.deductions = deductions
        self.hardwareSubscore = hardwareSubscore
        self.securitySubscore = securitySubscore
        self.highestSeverity = highestSeverity
        self.isProvisional = isProvisional
        self.historyCoverageDays = historyCoverageDays
    }

    // MARK: - Computation

    /// - Parameters:
    ///   - insights: the insights that will actually be shown. Suppressed
    ///     (dismissed/snoozed) insights are deliberately **not** passed here
    ///     by `ProtectionInsightsEngine` — hiding a finding from the list
    ///     hides it from the score too, because a score that silently
    ///     accounts for something the user can no longer see is
    ///     unauditable. The UI says so where it shows the suppressed count.
    ///   - context: only read for data-availability and history coverage;
    ///     never for extra scoring signal.
    public static func compute(insights: [ProtectionInsight], context: InsightContext) -> ProtectionScore {
        let deductions = insights
            .filter { $0.scoreImpact > 0 }
            .map {
                Deduction(
                    insightID: $0.id,
                    title: $0.title,
                    category: $0.category,
                    severity: $0.severity,
                    points: $0.scoreImpact
                )
            }
            .sorted { $0.points > $1.points }

        let categories: [CategoryScore] = InsightCategory.allCases.map { category in
            let inCategory = insights.filter { $0.category == category }
            let lost = inCategory.reduce(0) { $0 + $1.scoreImpact }
            let hasData = categoryHasData(category, context: context)
            return CategoryScore(
                category: category,
                score: hasData ? clamp(maximum - lost) : nil,
                pointsLost: lost,
                findingCount: inCategory.count,
                hasData: hasData
            )
        }

        func subscore(for domain: InsightDomain) -> Int {
            let lost = insights
                .filter { $0.category.domain == domain }
                .reduce(0) { $0 + $1.scoreImpact }
            return clamp(maximum - lost)
        }

        let hardware = subscore(for: .hardware)
        let security = subscore(for: .security)

        // The average of the two halves, rounded half-up so a 72/85 split
        // reads 79 rather than silently truncating to 78. Never below either
        // half, never above either half — see the type doc.
        let overall = clamp((hardware + security + 1) / 2)

        return ProtectionScore(
            overall: overall,
            categories: categories,
            deductions: deductions,
            hardwareSubscore: hardware,
            securitySubscore: security,
            // Read from `insights` — the same set the points came from, which
            // the engine has already stripped of suppressed findings. A
            // dismissed finding is off the screen and off the verdict.
            highestSeverity: insights.map(\.severity).max() ?? .good,
            isProvisional: !context.hasEnoughHistory,
            historyCoverageDays: context.historyCoverageDays
        )
    }

    private static func clamp(_ value: Int) -> Int {
        Swift.min(maximum, Swift.max(0, value))
    }

    /// Whether this Mac produced anything for `category` to be judged on.
    /// Kept `internal` rather than private so the tests can pin the
    /// "categories without data are not scored" contract directly.
    static func categoryHasData(_ category: InsightCategory, context: InsightContext) -> Bool {
        switch category {
        case .batteryLongevity:
            return (context.battery?.chargeSampleCount ?? 0) > 0
        case .thermal:
            return (context.thermal?.sampleCount ?? 0) > 0 || (context.load?.cpuSampleCount ?? 0) > 0
        case .storage:
            return (context.storage?.sampleCount ?? 0) > 0
        case .memory:
            return (context.memory?.sampleCount ?? 0) > 0
        case .powerHabits:
            return context.powerHabits != nil
        case .maintenance:
            return context.device.uptimeSeconds != nil
        case .security:
            // At least one posture probe returned a definite answer. All
            // `.unknown` means the collector couldn't read anything, which
            // is not the same as a clean bill of health.
            let posture = context.posture
            let states: [PostureState] = [
                posture.fileVault, posture.systemIntegrityProtection, posture.gatekeeper,
                posture.firewall, posture.firewallStealthMode, posture.automaticUpdateChecks,
                posture.automaticSecurityResponses, posture.automaticMacOSUpdates,
                posture.screenLockOnSleep, posture.remoteLogin, posture.screenSharing,
                posture.fileSharing, posture.remoteManagement, posture.guestAccount
            ]
            return states.contains { !$0.isUnknown }
        case .privacy:
            // Sentry's own settings are always readable — this category is
            // never "no data".
            return true
        }
    }
}
