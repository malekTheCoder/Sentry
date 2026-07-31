import Foundation

// MARK: - Domain / category / severity

/// The two halves of "protecting your Mac" that Protection Insights covers.
///
/// Kept as an explicit axis rather than being inferred from
/// `InsightCategory` at every call site: the Insights screen groups by it,
/// the score reports a subscore per side, and a rule author has to state
/// which one their rule belongs to rather than have it guessed.
public enum InsightDomain: String, Codable, Sendable, CaseIterable, Hashable {
    /// Physical longevity of the machine — battery wear, heat exposure,
    /// SSD write volume, sustained load.
    case hardware
    /// Security and privacy posture — encryption, firewall, sharing
    /// services, update hygiene.
    case security

    public var displayName: String {
        switch self {
        case .hardware: return String(localized: "Hardware & Longevity")
        case .security: return String(localized: "Security & Privacy")
        }
    }
}

/// The bucket an insight is filed under. Drives grouping in the UI and the
/// per-category subscores in `ProtectionScore`.
public enum InsightCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case batteryLongevity
    case thermal
    case storage
    case memory
    case powerHabits
    case maintenance
    case security
    case privacy

    public var domain: InsightDomain {
        switch self {
        case .batteryLongevity, .thermal, .storage, .memory, .powerHabits, .maintenance:
            return .hardware
        case .security, .privacy:
            return .security
        }
    }

    public var displayName: String {
        switch self {
        case .batteryLongevity: return String(localized: "Battery Longevity")
        case .thermal: return String(localized: "Thermals")
        case .storage: return String(localized: "Storage")
        case .memory: return String(localized: "Memory")
        case .powerHabits: return String(localized: "Power Habits")
        case .maintenance: return String(localized: "Maintenance")
        case .security: return String(localized: "Security")
        case .privacy: return String(localized: "Privacy")
        }
    }

    /// SF Symbol for the category chip. Names chosen from symbols that have
    /// existed since SF Symbols 1–4 (macOS 11–13), so nothing here needs an
    /// availability fork on the macOS 14 deployment target.
    public var symbolName: String {
        switch self {
        case .batteryLongevity: return "battery.100.bolt"
        case .thermal: return "thermometer"
        case .storage: return "internaldrive"
        case .memory: return "memorychip"
        case .powerHabits: return "powerplug"
        case .maintenance: return "wrench.and.screwdriver"
        case .security: return "lock.shield"
        case .privacy: return "hand.raised"
        }
    }
}

/// How much attention an insight deserves.
///
/// `good` is a first-class case, not an absence: a protection report that
/// only ever lists problems reads as an accusation, and — more importantly
/// for this codebase's honesty rules — "we checked FileVault and it's on"
/// is a genuine finding the user paid for, not filler.
public enum InsightSeverity: String, Codable, Sendable, CaseIterable, Hashable, Comparable {
    case good
    case advice
    case warning
    case critical

    /// Ascending: `good` < `advice` < `warning` < `critical`. Used by
    /// `Comparable` and by the engine's sort (which sorts descending on it).
    public var rank: Int {
        switch self {
        case .good: return 0
        case .advice: return 1
        case .warning: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: InsightSeverity, rhs: InsightSeverity) -> Bool {
        lhs.rank < rhs.rank
    }

    public var displayName: String {
        switch self {
        case .good: return String(localized: "Good")
        case .advice: return String(localized: "Advice")
        case .warning: return String(localized: "Warning")
        case .critical: return String(localized: "Critical")
        }
    }

    public var symbolName: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .advice: return "lightbulb"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }
}

// MARK: - Actions

/// Well-known `x-apple.systempreferences:` URLs for the System Settings
/// panes this feature deep-links to.
///
/// **These are best-effort, and every call site must treat them as such.**
/// Apple has never documented these identifiers, and they changed wholesale
/// in the Ventura System Settings rewrite; a future macOS can rename or
/// remove any of them without notice. `NSWorkspace.open(_:)` returns `false`
/// for a URL no pane claims, so the UI layer's contract is: attempt the
/// open, and if it fails, fall back to telling the user the pane's name in
/// words rather than silently doing nothing (the repo deleted inert
/// controls on principle — a deep-link button that quietly no-ops is the
/// same failure wearing a different hat).
public enum SystemSettingsLink {
    public static let fileVault = "x-apple.systempreferences:com.apple.preference.security?FileVault"
    public static let firewall = "x-apple.systempreferences:com.apple.preference.security?Firewall"
    public static let privacyAndSecurity = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
    public static let softwareUpdate = "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
    public static let sharing = "x-apple.systempreferences:com.apple.Sharing-Settings.extension"
    public static let lockScreen = "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension"
    public static let usersAndGroups = "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension"
    public static let storage = "x-apple.systempreferences:com.apple.settings.Storage"
    public static let battery = "x-apple.systempreferences:com.apple.Battery-Settings.extension"
    public static let generalStorage = "x-apple.systempreferences:com.apple.settings.Storage"
}

/// What the user can actually *do* about an insight, and where.
///
/// Deliberately narrow. Every case here is something the app can genuinely
/// carry out (open a URL, switch to a pane it really ships) or an honest
/// admission that the fix is the user's to make by hand — there is no
/// "Fix it" case, because Sentry cannot turn on FileVault for you and a
/// button claiming otherwise would be a lie the moment it was tapped.
public struct InsightAction: Codable, Sendable, Equatable {

    public enum Target: Codable, Sendable, Equatable {
        /// Ask macOS to open System Settings at `urlString`. May fail — see
        /// `SystemSettingsLink`.
        case systemSettings(urlString: String)
        /// Switch Sentry's own window to its Settings tab. Only used for
        /// insights about Sentry's own configuration (e.g. its MCP remote
        /// access server), never as a stand-in for an OS setting.
        case appSettings
        /// Nothing to launch: the change is behavioral or physical (unplug
        /// overnight, move the Mac off the sofa cushion, restart).
        case manual
    }

    /// Button title, or — for `.manual` — the one-line instruction.
    public var label: String
    public var target: Target

    /// Optional extra sentence shown under the button, e.g. naming the exact
    /// System Settings path in words so the action is still followable when
    /// the deep link doesn't resolve.
    public var fallbackDescription: String?

    public init(label: String, target: Target, fallbackDescription: String? = nil) {
        self.label = label
        self.target = target
        self.fallbackDescription = fallbackDescription
    }
}

// MARK: - ProtectionInsight

/// One evidence-backed recommendation about protecting this specific Mac.
///
/// **The evidence array is the point of the whole feature.** A
/// `ProtectionInsight` with an empty `evidence` is generic advice that could
/// have been printed on a poster, and this codebase's honesty rules (see
/// `PROGRESS.md`, and `LocationService`'s doc comment for the register)
/// treat that as a defect rather than a lesser version of the feature. Every
/// rule that fires must be able to quote at least one number it actually
/// measured on *this* machine — a percentage of samples, a day count, a
/// capacity delta, a posture command's real output. `ProtectionInsightsEngine`
/// enforces this at runtime by dropping evidence-free insights.
///
/// **Stable `id`.** The id is the rule's own identifier (e.g.
/// `"battery.high-soc-residency"`), not a `UUID`: it has to survive app
/// relaunches so a dismissal or snooze the user set last week still applies
/// to the same finding this week. Never renumber or reuse one after
/// shipping — the same "raw values are the contract" rule `MetricID`'s doc
/// comment states.
public struct ProtectionInsight: Identifiable, Codable, Sendable, Equatable {

    /// Stable, rule-derived. See the type doc comment.
    public let id: String

    /// Short headline, sentence case, no trailing period.
    public var title: String

    /// One line the user can read at a glance in a collapsed row.
    public var summary: String

    /// The longer "why this matters for *your* Mac" paragraph shown when the
    /// row is expanded.
    public var detail: String

    /// The concrete thing to do. Phrased as an instruction, not a wish.
    public var recommendation: String

    public var category: InsightCategory
    public var severity: InsightSeverity

    /// Measured facts about this Mac, each already formatted for display and
    /// each naming a real number. Never empty for a shipped rule.
    public var evidence: [String]

    /// `nil` when there is genuinely nothing to launch or do beyond
    /// awareness.
    public var action: InsightAction?

    /// 0…1. How sure the rule is, given how much history it had to work
    /// with. Used as the secondary sort key after severity, and shown to the
    /// user as a qualifier when it's low — a finding from 4 days of history
    /// should not present itself with the same confidence as one from 30.
    public var confidence: Double

    /// Points this insight removes from `ProtectionScore.overall`, before
    /// per-category clamping. See `ProtectionScore`'s doc comment for the
    /// weighting rationale — nothing here is a magic number picked to make a
    /// demo look good.
    public var scoreImpact: Int

    public var domain: InsightDomain { category.domain }

    /// `true` when acting on this requires leaving Sentry (System Settings,
    /// or a physical change). The UI labels these differently so a user
    /// scanning the list can tell what they can fix from here.
    public var requiresSystemSettings: Bool {
        guard let action else { return false }
        if case .systemSettings = action.target { return true }
        return false
    }

    public init(
        id: String,
        title: String,
        summary: String,
        detail: String,
        recommendation: String,
        category: InsightCategory,
        severity: InsightSeverity,
        evidence: [String],
        action: InsightAction? = nil,
        confidence: Double = 1.0,
        scoreImpact: Int = 0
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.detail = detail
        self.recommendation = recommendation
        self.category = category
        self.severity = severity
        self.evidence = evidence
        self.action = action
        // Clamped rather than trusted: a rule computing confidence from a
        // ratio can hand back 1.0000000002 or a negative from a degenerate
        // denominator, and the sort/UI should never see either.
        self.confidence = Swift.min(Swift.max(confidence, 0), 1)
        self.scoreImpact = Swift.max(scoreImpact, 0)
    }
}
