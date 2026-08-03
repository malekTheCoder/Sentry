import Foundation

/// How long a snoozed insight stays out of the way.
///
/// Deliberately coarse. A finding about battery wear or thermal exposure
/// changes over weeks, not hours, so an hour-granularity snooze would only
/// produce a control that looks precise while doing nothing useful.
public enum SnoozeDuration: String, Codable, Sendable, CaseIterable, Hashable {
    case week
    case month
    case quarter

    public var timeInterval: TimeInterval {
        switch self {
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        case .quarter: return 90 * 86_400
        }
    }

    public var displayName: String {
        switch self {
        case .week: return String(localized: "1 week")
        case .month: return String(localized: "1 month")
        case .quarter: return String(localized: "3 months")
        }
    }
}

/// A user's decision to stop seeing a particular insight, either for a
/// while or for good.
///
/// **Keyed by the rule's stable `id`, not by a snapshot of the insight.**
/// A rule that fires again next week with different numbers is still the
/// same finding, and a user who dismissed "the disk is filling up" does not
/// want it back tomorrow because the projected date moved.
///
/// **Suppressed insights leave the score too.** See
/// `ProtectionScore.compute`'s doc comment: a score that quietly accounts
/// for findings the user can no longer see is not auditable. The engine
/// returns the suppressed set separately so the UI can say how many are
/// hidden and offer to bring them back.
public struct InsightSuppression: Codable, Sendable, Equatable, Identifiable, Hashable {

    public enum Kind: String, Codable, Sendable, Hashable {
        /// Hidden until the user explicitly restores it.
        case dismissed
        /// Hidden until `until`.
        case snoozed
    }

    public var id: String { insightID }

    /// The `ProtectionInsight.id` / rule id this applies to.
    public var insightID: String
    public var kind: Kind
    public var createdAt: Date

    /// When a snooze lapses. Always `nil` for `.dismissed` — a dismissal
    /// has no horizon by construction, and storing one would create a
    /// second, contradictory source of truth about when it ends.
    public var until: Date?

    public init(insightID: String, kind: Kind, createdAt: Date, until: Date? = nil) {
        self.insightID = insightID
        self.kind = kind
        self.createdAt = createdAt
        // Enforce the invariant rather than trusting callers or a
        // hand-edited settings.json.
        self.until = kind == .snoozed ? until : nil
    }

    public static func dismiss(insightID: String, at date: Date = Date()) -> InsightSuppression {
        InsightSuppression(insightID: insightID, kind: .dismissed, createdAt: date)
    }

    public static func snooze(
        insightID: String,
        for duration: SnoozeDuration,
        from date: Date = Date()
    ) -> InsightSuppression {
        InsightSuppression(
            insightID: insightID,
            kind: .snoozed,
            createdAt: date,
            until: date.addingTimeInterval(duration.timeInterval)
        )
    }

    /// `true` while this suppression is still hiding its insight.
    ///
    /// A `.snoozed` entry with a `nil` `until` (only reachable through a
    /// hand-edited settings file) is treated as **expired**, not as
    /// indefinite: silently upgrading a snooze into a permanent dismissal
    /// is the failure mode that loses a security finding forever.
    public func isActive(at date: Date) -> Bool {
        switch kind {
        case .dismissed:
            return true
        case .snoozed:
            guard let until else { return false }
            return date < until
        }
    }

    /// "Hidden until 12 Aug" / "Dismissed" — the horizon the UI is required
    /// to show, so a snooze is never an invisible state.
    public func horizonDescription(relativeTo date: Date = Date()) -> String {
        switch kind {
        case .dismissed:
            return String(localized: "Dismissed")
        case .snoozed:
            guard let until, until > date else { return String(localized: "Snooze expired") }
            let untilText = until.formatted(date: .abbreviated, time: .omitted)
            return String(localized: "Hidden until \(untilText)")
        }
    }

    // MARK: - Collection helpers

    /// Drops entries that no longer hide anything, so the persisted list
    /// can't grow without bound as snoozes lapse. Dismissals are kept —
    /// they are the user's standing decision and have no expiry.
    public static func pruned(_ suppressions: [InsightSuppression], at date: Date) -> [InsightSuppression] {
        suppressions.filter { $0.isActive(at: date) }
    }

    /// Replaces any existing entry for the same insight rather than
    /// appending a second one — otherwise "snooze, then dismiss" would
    /// leave two records and the older one would win or lose depending on
    /// lookup order.
    public static func upserting(
        _ suppression: InsightSuppression,
        into suppressions: [InsightSuppression]
    ) -> [InsightSuppression] {
        var result = suppressions.filter { $0.insightID != suppression.insightID }
        result.append(suppression)
        return result
    }

    public static func removing(
        insightID: String,
        from suppressions: [InsightSuppression]
    ) -> [InsightSuppression] {
        suppressions.filter { $0.insightID != insightID }
    }

    /// The active suppression for `insightID`, if any.
    public static func active(
        forInsightID insightID: String,
        in suppressions: [InsightSuppression],
        at date: Date
    ) -> InsightSuppression? {
        suppressions.first { $0.insightID == insightID && $0.isActive(at: date) }
    }
}
