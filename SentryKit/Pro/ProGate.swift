import Foundation

/// The free/paid cut for Protection Insights, as a pure function.
///
/// **What the free tier genuinely gets:** the whole protection score
/// (overall and per-category), and the two highest-priority findings in
/// full — evidence, explanation, recommended action, and any deep link.
/// Those two are the ones that matter most, not a teaser: a free user with
/// FileVault off sees "the disk is not encrypted", why it matters for their
/// machine, and the button that takes them to the setting.
///
/// **What the paywall withholds:** the remaining findings' text. Locked
/// rows show their category and severity — enough to know *that* there are
/// three more warnings about storage, not enough to act on them.
///
/// **Withheld, not obscured.** `LockedInsightPreview` carries no title,
/// summary, detail, recommendation, or evidence — the strings are never
/// constructed into the view hierarchy at all, so there is nothing to
/// recover with an accessibility inspector, a screenshot filter, or a view
/// dump. A blurred `Text` containing the real sentence would leak it to all
/// three. (It would also be a lie of a different kind: the content would be
/// *there*, just cosmetically hidden.)
///
/// **Not a dark pattern, deliberately:** the count of what's hidden is
/// stated plainly, severities are honest (a locked `critical` says
/// `critical`), nothing is fabricated to inflate the number, and no
/// countdown, fake scarcity, or nagging repetition is involved. If a user
/// never buys, the two most important findings on their Mac stay visible
/// forever.
public enum ProGate {

    /// How many findings the free tier sees in full.
    ///
    /// Two, not one and not five. One is a teaser rather than a useful
    /// product; five would cover the entire finding list on a well-kept Mac,
    /// leaving nothing to buy on exactly the machines whose owners care
    /// most. Two is enough for the feature to be genuinely useful for free
    /// on a Mac with real problems.
    public static let freeInsightAllowance = 2

    /// Everything a locked row is allowed to know.
    ///
    /// Note what is absent: every user-facing string. See the type doc
    /// comment on why this is a separate type rather than a
    /// `ProtectionInsight` with a `isLocked` flag.
    public struct LockedInsightPreview: Identifiable, Sendable, Equatable, Hashable {
        public let id: String
        public let category: InsightCategory
        public let severity: InsightSeverity

        public init(id: String, category: InsightCategory, severity: InsightSeverity) {
            self.id = id
            self.category = category
            self.severity = severity
        }
    }

    public struct GatedInsights: Sendable, Equatable {
        /// Shown in full.
        public var unlocked: [ProtectionInsight]
        /// Shown as category + severity only.
        public var locked: [LockedInsightPreview]

        public var isGated: Bool { !locked.isEmpty }
        public var lockedCount: Int { locked.count }

        /// How many locked findings are warnings or worse — the honest
        /// version of "and N more", which says something true about what is
        /// behind the wall instead of just counting rows.
        public var lockedActionableCount: Int {
            locked.filter { $0.severity >= .warning }.count
        }

        public init(unlocked: [ProtectionInsight], locked: [LockedInsightPreview]) {
            self.unlocked = unlocked
            self.locked = locked
        }
    }

    /// - Parameters:
    ///   - isUnlocked: from `ProEntitlementProviding.isUnlocked(_:)`.
    ///   - insights: the visible (non-suppressed) findings. Re-sorted
    ///     internally through `ProtectionInsightsEngine.prioritised` rather
    ///     than trusted to arrive ordered — which two findings a free user
    ///     sees is too important to depend on a caller remembering to sort.
    public static func apply(isUnlocked: Bool, to insights: [ProtectionInsight]) -> GatedInsights {
        let ordered = ProtectionInsightsEngine.prioritised(insights)

        guard !isUnlocked else {
            return GatedInsights(unlocked: ordered, locked: [])
        }

        let visible = Array(ordered.prefix(freeInsightAllowance))
        let withheld = ordered.dropFirst(freeInsightAllowance).map {
            LockedInsightPreview(id: $0.id, category: $0.category, severity: $0.severity)
        }
        return GatedInsights(unlocked: visible, locked: Array(withheld))
    }
}
