import Foundation

// MARK: - WCAG relative luminance and contrast ratio

/// The WCAG 2.1 contrast math, and the theme-wide audit built on it, for
/// plan §9.4: *"Every preset must pass WCAG AA (4.5:1) for text tokens. Add a
/// contrast checker in the theme editor that flags failing combinations
/// inline."*
///
/// **Pure, synchronous, and in `MacStatKit` on purpose.** The point of §9.4 is
/// that a user must not be able to build an unreadable theme without being
/// told — which means the check has to run on every keystroke of every color
/// well, and has to be cheap enough that running it on every keystroke is not
/// a decision anyone has to think about. Sixty-odd ratio computations over
/// parsed hex is microseconds. Nothing here touches AppKit, so it is also
/// testable without a UI, which is the only way the numbers below get
/// verified against WCAG's own published pairs.
///
/// **What this cannot know.** A translucent theme's real backdrop is the
/// user's desktop — an image this app has never seen and could not audit
/// against anyway. Rather than skip those themes (leaving the most
/// contrast-hostile presets unchecked) or quietly pretend alpha is 1 (which
/// overstates contrast, the dangerous direction), the auditor flattens a
/// translucent backdrop against pure white for `.light` and pure black for
/// `.dark` and marks the finding `backdropIsApproximate`. The editor prints
/// that caveat next to the result. See `ThemeContrast.flatten(_:onto:)`.
public enum ThemeContrast {

    /// WCAG 2.1's sRGB → linear transfer function, applied per channel.
    ///
    /// The 0.03928 threshold and 2.4 exponent are quoted from the spec
    /// verbatim rather than replaced with the sRGB standard's own slightly
    /// different 0.04045 — the requirement being tested is WCAG's, and a
    /// checker that disagrees with the tool an accessibility auditor uses is
    /// worse than no checker, even when it is arguably more correct about
    /// color science.
    public static func linearize(_ channel: Double) -> Double {
        let c = min(max(channel, 0), 1)
        return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// WCAG 2.1 relative luminance, 0 (black) ... 1 (white).
    public static func relativeLuminance(_ color: ThemeColor.RGBA) -> Double {
        0.2126 * linearize(color.red)
            + 0.7152 * linearize(color.green)
            + 0.0722 * linearize(color.blue)
    }

    /// Contrast ratio between two *opaque* colors, 1...21.
    ///
    /// Alpha is ignored here by design — a ratio between two semi-transparent
    /// colors is meaningless without knowing what is behind them. Callers
    /// composite first (`flatten(_:onto:)`), which forces the question of
    /// what the backdrop actually is to be answered explicitly rather than
    /// dropped.
    public static func ratio(_ a: ThemeColor.RGBA, _ b: ThemeColor.RGBA) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        let lighter = max(la, lb)
        let darker = min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Standard source-over alpha compositing. The result is opaque when
    /// `backdrop` is opaque, which is the only case `ratio(_:_:)` accepts.
    public static func flatten(_ color: ThemeColor.RGBA, onto backdrop: ThemeColor.RGBA) -> ThemeColor.RGBA {
        let a = min(max(color.alpha, 0), 1)
        let ba = min(max(backdrop.alpha, 0), 1)
        let outAlpha = a + ba * (1 - a)
        guard outAlpha > 0 else { return ThemeColor.RGBA(red: 0, green: 0, blue: 0, alpha: 0) }
        func blend(_ c: Double, _ b: Double) -> Double {
            (c * a + b * ba * (1 - a)) / outAlpha
        }
        return ThemeColor.RGBA(
            red: blend(color.red, backdrop.red),
            green: blend(color.green, backdrop.green),
            blue: blend(color.blue, backdrop.blue),
            alpha: outAlpha
        )
    }

    /// One decimal, truncated rather than rounded — see
    /// `ContrastFinding.formattedRatio` for why the direction matters.
    public static func format(_ ratio: Double) -> String {
        String(format: "%.1f:1", (ratio * 10).rounded(.down) / 10)
    }

    /// What a translucent theme is flattened against when the real backdrop
    /// is the user's desktop. White under `.light`, black under `.dark` —
    /// the assumption a light theme sits on light content and vice versa,
    /// which is the *optimistic* choice and therefore the one that never
    /// invents a failure the user can't reproduce. Findings computed against
    /// it are marked approximate.
    public static func assumedBackdrop(for appearance: ThemeAppearance) -> ThemeColor.RGBA {
        switch appearance {
        case .light: return ThemeColor.RGBA(red: 1, green: 1, blue: 1, alpha: 1)
        case .dark: return ThemeColor.RGBA(red: 0, green: 0, blue: 0, alpha: 1)
        }
    }
}

// MARK: - Requirements

/// The threshold a pair is held to, and why.
public enum ContrastRequirement: Equatable, Sendable {
    /// WCAG 2.1 SC 1.4.3, normal-size text: 4.5:1. §9.4's stated bar.
    case textAA
    /// WCAG 2.1 SC 1.4.11, non-text UI components and graphical objects:
    /// 3:1. Applied to per-metric colors, which are chart strokes, fill bars
    /// and status dots rather than prose.
    case nonText

    public var minimumRatio: Double {
        switch self {
        case .textAA: return 4.5
        case .nonText: return 3.0
        }
    }

    public var shortLabel: String {
        switch self {
        case .textAA: return String(localized: "AA 4.5:1")
        case .nonText: return String(localized: "3:1")
        }
    }

    public var explanation: String {
        switch self {
        case .textAA:
            return String(localized: "WCAG AA for normal-size text.")
        case .nonText:
            return String(localized: "WCAG AA for graphics and UI components — these are chart strokes and dots, not prose.")
        }
    }
}

/// Which color is being checked. Metric colors aren't `ThemeColorToken`s (see
/// that type's doc comment), but they still need auditing, so findings are
/// keyed by this rather than by token alone.
public enum ContrastSubject: Equatable, Hashable, Sendable {
    case token(ThemeColorToken)
    case metric(MetricID)
    /// A per-metric entry whose key isn't a `MetricID` this build knows —
    /// possible only in a hand-edited file that got past import, and worth
    /// auditing anyway rather than silently skipping.
    case unknownMetric(String)

    public var displayName: String {
        switch self {
        case .token(let token): return token.displayName
        case .metric(let metric): return metric.shortLabel
        case .unknownMetric(let key): return key
        }
    }

    /// Stable, collision-free string for `ContrastFinding.id`. Spelled out
    /// rather than interpolating the enum, because `"\(self)"` on an enum is
    /// a reflection detail that has changed shape between Swift releases and
    /// would silently churn every `ForEach` identity in the editor if it did
    /// so again.
    public var identifierComponent: String {
        switch self {
        case .token(let token): return "token:\(token.rawValue)"
        case .metric(let metric): return "metric:\(metric.rawValue)"
        case .unknownMetric(let key): return "unknown:\(key)"
        }
    }
}

// MARK: - Findings

/// One foreground/background pair, evaluated.
public struct ContrastFinding: Identifiable, Equatable, Sendable {
    public let subject: ContrastSubject
    public let backdrop: ThemeColorToken
    public let appearance: ThemeAppearance
    public let requirement: ContrastRequirement
    /// `nil` when either color's hex failed to parse — an unparseable color
    /// has no ratio, and reporting 1.0 or 21.0 would be a fabricated number.
    /// The renderer draws these as neutral gray; the editor reports them as
    /// "couldn't read this color" rather than as a contrast result.
    public let ratio: Double?
    /// True when the backdrop was translucent and had to be flattened against
    /// an assumed desktop. See `ThemeContrast`'s doc comment.
    public let backdropIsApproximate: Bool

    public var id: String {
        "\(subject.identifierComponent)|\(backdrop.rawValue)|\(appearance.rawValue)"
    }

    public var passes: Bool {
        guard let ratio else { return false }
        return ratio >= requirement.minimumRatio
    }

    public var isUnreadable: Bool { ratio == nil }

    /// "3.1:1" — one decimal, which is the precision WCAG tooling reports and
    /// the precision a user can act on.
    ///
    /// **Rounded down, not to nearest.** `#0969DA` on Paper's elevated
    /// surface measures 4.4996:1 — it fails AA, and `%.1f` printed it as
    /// "4.5:1" next to a red warning triangle, which reads as the checker
    /// contradicting itself. Truncating means the number shown is always a
    /// value the pair genuinely reaches, so a displayed "4.5:1" is never a
    /// failing pair. The cost is that a passing 4.5001 also prints "4.5:1",
    /// which is fine — it's true either way.
    public var formattedRatio: String {
        guard let ratio else { return String(localized: "—") }
        return ThemeContrast.format(ratio)
    }

    /// One line, suitable for both the inline flag and the VoiceOver label —
    /// §9.4 forbids carrying the pass/fail state in color alone, so the text
    /// has to stand on its own.
    public var summary: String {
        if isUnreadable {
            return String(localized: "\(subject.displayName) on \(backdrop.displayName): color couldn't be read.")
        }
        let verdict = passes
            ? String(localized: "passes \(requirement.shortLabel)")
            : String(localized: "fails \(requirement.shortLabel)")
        let base = String(localized: "\(subject.displayName) on \(backdrop.displayName) in \(appearance.displayName): \(formattedRatio), \(verdict).")
        return backdropIsApproximate
            ? base + " " + String(localized: "Approximate — this backdrop is translucent.")
            : base
    }
}

// MARK: - The audit

/// Every contrast finding for one theme, with the lookups the editor needs to
/// flag a well inline the moment its color changes.
public struct ThemeContrastAudit: Equatable, Sendable {

    public let findings: [ContrastFinding]

    /// Text tokens, in the order the editor lists them. Each is audited
    /// against all three surface tokens because Sentry genuinely draws text on
    /// all three: the dropdown paints on `background`, grouped rows and the
    /// settings sidebar on `surface`, Dashboard cards and the selected sidebar
    /// row on `surfaceElevated`. Auditing only against `background` would pass
    /// a theme whose card text is invisible.
    public static let auditedTextTokens: [ThemeColorToken] =
        ThemeColorToken.allCases.filter(\.isTextToken)

    public static let auditedBackdrops: [ThemeColorToken] =
        ThemeColorToken.allCases.filter(\.isBackdropToken)

    /// Per-metric colors are checked against `background` and `surface` only,
    /// not `surfaceElevated`: they are drawn as chart strokes and dots, and
    /// every surface that hosts a chart paints one of those two. Adding a
    /// third backdrop would add findings for a combination that never renders,
    /// which is noise a user cannot act on.
    public static let auditedMetricBackdrops: [ThemeColorToken] = [.background, .surface]

    public init(theme: Theme) {
        var results: [ContrastFinding] = []
        results.reserveCapacity(
            Self.auditedTextTokens.count * Self.auditedBackdrops.count * 2
                + theme.metricColors.count * Self.auditedMetricBackdrops.count * 2
        )

        for appearance in ThemeAppearance.allCases {
            for backdrop in Self.auditedBackdrops {
                let resolved = Self.resolveBackdrop(theme[backdrop], for: appearance)

                for token in Self.auditedTextTokens {
                    results.append(Self.evaluate(
                        subject: .token(token),
                        color: theme[token],
                        backdrop: backdrop,
                        resolvedBackdrop: resolved,
                        appearance: appearance,
                        requirement: .textAA
                    ))
                }

                guard Self.auditedMetricBackdrops.contains(backdrop) else { continue }
                // Sorted so the audit is deterministic — `metricColors` is a
                // Dictionary, and an unsorted iteration would reorder the
                // editor's issue list on every rebuild for no reason.
                for key in theme.metricColors.keys.sorted() {
                    guard let color = theme.metricColors[key] else { continue }
                    let subject: ContrastSubject = MetricID(rawValue: key)
                        .map { .metric($0) } ?? .unknownMetric(key)
                    results.append(Self.evaluate(
                        subject: subject,
                        color: color,
                        backdrop: backdrop,
                        resolvedBackdrop: resolved,
                        appearance: appearance,
                        requirement: .nonText
                    ))
                }
            }
        }

        self.findings = results
    }

    /// A backdrop token as an opaque color, plus whether that required
    /// assuming a desktop behind it.
    private static func resolveBackdrop(
        _ color: ThemeColor,
        for appearance: ThemeAppearance
    ) -> (rgba: ThemeColor.RGBA?, approximate: Bool) {
        guard let raw = color.rgba(for: appearance) else { return (nil, false) }
        guard raw.alpha < 0.999 else { return (raw, false) }
        return (
            ThemeContrast.flatten(raw, onto: ThemeContrast.assumedBackdrop(for: appearance)),
            true
        )
    }

    private static func evaluate(
        subject: ContrastSubject,
        color: ThemeColor,
        backdrop: ThemeColorToken,
        resolvedBackdrop: (rgba: ThemeColor.RGBA?, approximate: Bool),
        appearance: ThemeAppearance,
        requirement: ContrastRequirement
    ) -> ContrastFinding {
        guard
            let backdropRGBA = resolvedBackdrop.rgba,
            let foreground = color.rgba(for: appearance)
        else {
            return ContrastFinding(
                subject: subject,
                backdrop: backdrop,
                appearance: appearance,
                requirement: requirement,
                ratio: nil,
                backdropIsApproximate: resolvedBackdrop.approximate
            )
        }

        // A translucent *foreground* is composited onto its backdrop, which
        // is exact rather than approximate — we know precisely what is behind
        // a 50%-opacity text token, because it is the backdrop token we just
        // resolved. Only a translucent *backdrop* forces a guess.
        let composited = ThemeContrast.flatten(foreground, onto: backdropRGBA)
        return ContrastFinding(
            subject: subject,
            backdrop: backdrop,
            appearance: appearance,
            requirement: requirement,
            ratio: ThemeContrast.ratio(composited, backdropRGBA),
            backdropIsApproximate: resolvedBackdrop.approximate
        )
    }

    // MARK: Lookups

    public var failures: [ContrastFinding] { findings.filter { !$0.passes } }

    /// Failures for one subject, for the inline flag beside its color well.
    public func failures(for subject: ContrastSubject) -> [ContrastFinding] {
        findings.filter { $0.subject == subject && !$0.passes }
    }

    public func failures(for token: ThemeColorToken) -> [ContrastFinding] {
        failures(for: .token(token))
    }

    /// The worst ratio recorded for a subject — what the inline badge shows,
    /// because a token that fails on one surface out of three is still a
    /// token the user needs to fix. `nil` when the subject was never audited
    /// (a non-text token) or couldn't be read.
    public func worstRatio(for subject: ContrastSubject) -> Double? {
        findings
            .filter { $0.subject == subject }
            .compactMap(\.ratio)
            .min()
    }

    public var passesTextAA: Bool {
        !findings.contains { $0.requirement == .textAA && !$0.passes }
    }

    /// The one-line verdict the editor shows above the token list, and the
    /// sentence the export/apply path uses to warn before saving.
    public var headline: String {
        let textFailures = findings.filter { $0.requirement == .textAA && !$0.passes }
        let otherFailures = findings.filter { $0.requirement != .textAA && !$0.passes }
        if textFailures.isEmpty && otherFailures.isEmpty {
            return String(localized: "Every color passes its contrast requirement in both light and dark.")
        }
        if textFailures.isEmpty {
            return String(localized: "Text passes WCAG AA. \(otherFailures.count) metric color(s) fall below 3:1.")
        }
        return String(localized: "\(textFailures.count) text combination(s) fall below WCAG AA's 4.5:1.")
    }
}

extension Theme {
    /// Convenience so call sites read as `theme.contrastAudit` rather than
    /// naming the auditor type. Computed fresh each time deliberately —
    /// caching it on the value would mean an editor mutation could leave a
    /// stale audit attached to a theme that no longer matches it, which is
    /// precisely the "silently unreadable" outcome §9.4 exists to prevent.
    public var contrastAudit: ThemeContrastAudit { ThemeContrastAudit(theme: self) }
}
