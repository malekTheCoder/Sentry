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
///
/// **A tier name describes a class of harm, not a domain.** Almost every
/// rule's category and weight tier agree on domain (a `.security`-category
/// rule uses a `*Security` weight), but a few hardware-domain findings —
/// no Time Machine backup at all, a SMART-failing drive — describe
/// irrecoverable total data loss, which is the class of harm
/// `criticalSecurity` names, not the gradual, fixable wear `majorHardware`
/// tops out at describing. Those rules stay filed under their honest
/// hardware category (so they land in the hardware subscore, where a
/// backup or a drive genuinely belongs) while borrowing the security tier's
/// *point value* to say "this is as bad as an unencrypted disk." Each such
/// rule documents this explicitly at its use site; it is the exception, not
/// a precedent for picking whichever number reads better.
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
/// **The whole model in one sentence, applied three times:** a category starts
/// at 100 and subtracts its own findings; a domain is the mean of its
/// categories; the overall is the mean of the two domains. The *verdict*
/// beside the number does not follow that arithmetic — it comes from whichever
/// half is weaker, floored by the most serious finding open.
///
/// **Why every level is a mean, and neither of the two things it used to be.**
/// This model has now been corrected twice, at two different levels, for the
/// same underlying reason: a composite score is only trustworthy if a reader
/// can check each level against the level printed directly beneath it.
///
/// The first version made `overall` a global subtraction — `100 minus every
/// finding, everywhere`. A Mac reading 72 hardware and 85 security showed an
/// overall of **57**, below both of its own halves, which no aggregation a
/// reader can imagine (mean, minimum, weighted) could produce. The same
/// deductions were being applied three times over: once per category, again
/// per domain, and again globally, each level restarting at 100.
///
/// Averaging the two halves fixed the headline and left the same fault one
/// level down, where a domain was still `100 minus the sum of all its
/// categories' deductions`. Six hardware categories reading 81 / 100 / 79 /
/// 94 / 100 / 100 — a mean of 92 — produced a Hardware & Longevity of **54**.
/// Individually correct numbers, no visible relationship.
///
/// So the rule is now uniform, and the card can be read downward or upward
/// with the same arithmetic at every step.
///
/// **What the mean gives up, and where that is paid for.** Summation punished
/// breadth: many mediocre categories compounded. A mean dilutes — one ruined
/// category among six moves its domain by at most a sixth of its fall. That
/// loss is deliberate and is covered by the verdict rather than by the number:
/// `band` reads `weakerSubscore` and is floored by `highestSeverity`, so an
/// open critical finding cannot be described as "well protected" however
/// flattering the average. Severity governs the words; the mean only sets the
/// digits.
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
///
/// **Why one category cannot spend the whole hardware domain's budget.** A
/// real machine surfaced the flip side of "one finding per fact": a single
/// hot, sustained workload can legitimately fire `SustainedHeatRule`,
/// `ThermalThrottlingRule`, and `SustainedCPULoadRule` (all `.thermal`) at
/// once, plus `RisingThermalBaselineRule` (`.maintenance`) and
/// `ChargingWhileHotRule` (`.batteryLongevity`) if it happened while
/// charging — five findings, one root cause, and at worst tier that is 45
/// points off a 100-point domain. Because the verdict is banded on the
/// weaker half, a Mac that is otherwise pristine and simply doing real work
/// it was asked to do can read "act on this" for a single afternoon of
/// rendering.
///
/// The fix is `categoryDeductionCapHardware`: **a category may not, by
/// itself, cost the hardware domain more than this many of its 100 points**,
/// no matter how many findings in that category fired or how they're
/// individually weighted. This is a domain-level aggregation rule, not a
/// per-finding one — `Deduction.points` and `CategoryScore.pointsLost` both
/// keep reporting the true, uncapped total for that category (so the
/// Thermals chip in the UI still honestly shows how bad thermals are); only
/// the *slice of the hardware subscore* a single category is allowed to
/// consume is bounded. This is exactly the aggregation `CategoryScore`
/// already computes per category, applied one level up to how those
/// categories sum into the domain, rather than a new mechanism.
///
/// **The cap value: 24, or two `majorHardware` findings' worth.** Two
/// independent, genuinely serious problems landing in the same category
/// (say, both `CapacityLossRateRule` and a hypothetical second
/// battery-longevity warning) still cost the domain their full combined
/// weight — the cap only starts trimming once a category's total goes
/// *past* what two unrelated significant findings would plausibly sum to,
/// which is the point past which more findings in one category are more
/// likely to be several rules describing the same underlying event than
/// several unrelated ones. Applied to the scenario above: `.thermal`'s raw
/// 31 points (12 + 12 + 7) is capped to 24, `.maintenance`'s 7 and
/// `.batteryLongevity`'s 7 are both untouched, for a domain loss of 38
/// instead of 45 — hardware subscore 62 instead of 55, which crosses the
/// `needsAttention` boundary at 60 rather than landing in `actOnThis`.
///
/// **Deliberately scoped to the hardware domain only.** The security domain
/// has no equivalent to "one hot workload sets off five sensors" — a Mac
/// with FileVault, SIP, and Gatekeeper all independently disabled has three
/// genuinely separate, deliberate failures that happen to share the
/// `.security` category, and each one is exactly as bad as it looks. Capping
/// that category the same way would silently forgive the second and third
/// disabled protection, which is the opposite of this feature's purpose.
/// Hardware wear signals correlate through shared physical causes (heat,
/// charge, load) in a way that independently-configured security settings
/// do not, and the cap only fires where that correlation risk is real.
public struct ProtectionScore: Codable, Sendable, Equatable {

    public static let maximum = 100

    /// The most a single `InsightCategory` may subtract from the *hardware*
    /// domain's 100-point subscore, regardless of how many findings fired in
    /// it or how they're weighted. See the type doc's "Why one category
    /// cannot spend the whole hardware domain's budget" section for the
    /// reasoning and the worked example behind the number 24. Not applied to
    /// the security domain — same section, last paragraph, for why.
    public static let categoryDeductionCapHardware = 24

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
            // **A category that produced a finding is scored, whatever the
            // coverage heuristic thinks.** `categoryHasData` asks whether
            // enough of the right metrics were collected to judge the
            // category *in general*; a rule that actually fired is direct
            // evidence that it was judgeable in this instance, and the two
            // can disagree — `.security` findings, for one, come from a live
            // posture read rather than from sampled history.
            //
            // Before this, such a category reported `score == nil` while its
            // deductions still moved the domain: the card listed it under
            // "not scored" and the half dropped anyway, with nothing on
            // screen to explain the gap. Scoring it makes the displayed
            // categories and the arithmetic above them the same set of
            // numbers, which is the property `subscore(for:)` depends on.
            return CategoryScore(
                category: category,
                score: (hasData || !inCategory.isEmpty) ? clamp(maximum - lost) : nil,
                pointsLost: lost,
                findingCount: inCategory.count,
                hasData: hasData
            )
        }

        // **A domain is the mean of its own categories' scores.**
        //
        // This used to be `100 - (the sum of every deduction in the domain)`,
        // and that is what made the card unreadable: six hardware categories
        // reading 81 / 100 / 79 / 94 / 100 / 100 produced a Hardware &
        // Longevity of 54. Every number on the screen was individually
        // correct and their relationship was not explainable by any
        // aggregation a person can perform by eye — which is exactly the
        // complaint that produced this change, twice, about two different
        // levels of the same card.
        //
        // Averaging makes the whole card one rule applied three times:
        // a category is 100 minus its own findings, a domain is the mean of
        // its categories, and `overall` is the mean of the two domains. A
        // reader can check any level against the level below it, which is
        // the property that makes a composite score trustworthy at all.
        //
        // **What this deliberately gives up.** Summation punished breadth:
        // five mediocre categories dragged the domain down hard. The mean
        // dilutes instead — one catastrophic category among six can only
        // move the domain by a sixth of its fall. That is a real loss and it
        // is covered elsewhere rather than here: `band` takes the verdict
        // from `weakerSubscore` and is floored by `highestSeverity`, so a
        // critical finding cannot read "well protected" no matter how
        // flattering the arithmetic above it. Severity gates the words;
        // the average only sets the number.
        //
        // **Categories with no data are excluded, not counted as perfect.**
        // `CategoryScore.score` is nil when the app genuinely could not
        // judge that category (see `categoryHasData`), and folding a nil in
        // as 100 would let silence raise the score — the precise inversion
        // of this codebase's rule that an absent reading is never a good
        // reading. They are dropped from the mean and listed separately by
        // the UI as "not scored".
        //
        // `categoryDeductionCapHardware` no longer participates. It existed
        // to stop one category's deductions dominating a *sum*; under a mean
        // each category's influence is inherently bounded to its own 0…100
        // range and its share of the divisor, so the cap has nothing left to
        // do. It is kept as a constant because the per-category truth it
        // documents is still the right ceiling for a single finding's
        // weight, and the engine's tests assert against it.
        func subscore(for domain: InsightDomain) -> Int {
            let scored = categories
                .filter { $0.category.domain == domain }
                // Exactly the scores the card prints — `CategoryScore.score`
                // is nil only for a category the app genuinely could not
                // judge and which produced no findings (see its assignment
                // above). Nothing is recomputed here, so the half can never
                // disagree with the chips beneath it.
                .compactMap(\.score)
            guard !scored.isEmpty else {
                // Nothing in this half could be judged at all. Reporting 100
                // would assert a clean bill of health from zero evidence;
                // reporting 0 would invent a crisis. `maximum` is returned
                // only because the type's contract is non-Optional, and the
                // UI never shows a half whose categories are all unscored
                // without also showing the "not scored" list beside it —
                // see `unscoredCategories`.
                return maximum
            }
            // Integer mean, rounded half-up: 85 and 100 give 93, not 92.
            return clamp((scored.reduce(0, +) + scored.count / 2) / scored.count)
        }

        let hardware = subscore(for: .hardware)
        let security = subscore(for: .security)

        // The mean of the two halves, rounded half-up so a 72/85 split reads
        // 79 rather than silently truncating to 78. Never below either half,
        // never above either half — and now the same operation applied at
        // the level above `subscore(for:)`, so the card reads consistently
        // from category to domain to headline.
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
