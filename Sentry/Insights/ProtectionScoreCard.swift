import SwiftUI
import SentryKit

extension ThemePalette {
    /// The one place a band becomes a colour. Every meter and every verdict
    /// in Insights goes through here, so a green bar can never sit under a red
    /// word.
    func tint(for band: ProtectionBand) -> Color {
        switch band {
        case .wellProtected: return success
        case .needsAttention: return warning
        case .actOnThis: return danger
        }
    }
}

/// The bare score numeral, per the redesign handoff: a 64pt figure with
/// the status word beside it in the status color — no ring, no gauge. The
/// number *is* the hero; drawing a circle around it added chrome without
/// adding information.
///
/// The verdict beside the numeral is a `ProtectionBand` handed in whole. This
/// view holds no thresholds of its own on purpose: banding lives in
/// `ProtectionScore` so the rule (points from the weaker half, floored by
/// finding severity) is testable and shared, and so a second surface can't
/// quietly disagree with this one.
struct ProtectionScoreFigure: View {
    @Environment(\.themePalette) private var palette

    let score: Int
    /// The verdict. Comes from `ProtectionScore.band`, which is deliberately
    /// derived from something other than the numeral beside it — see that
    /// type's doc.
    let band: ProtectionBand
    /// The half the verdict came from ("Security & Privacy"), or `nil` when
    /// nothing needs attention and naming a half would invent a problem.
    var qualifier: String?

    private var caption: String { band.caption }

    /// Tinted by the band so the colour and the word can never disagree.
    private var tint: Color { palette.tint(for: band) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: palette.spacingRow) {
            Text("\(score)")
                .font(palette.font(size: 64, weight: .semibold))
                .monospacedDigit()
                .tracking(-1.5)
                .foregroundStyle(palette.textPrimary)
            VStack(alignment: .leading, spacing: 1) {
                Text(caption)
                    .font(palette.font(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                if let qualifier {
                    Text(qualifier)
                        .font(palette.font(size: 11))
                        .foregroundStyle(palette.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Protection score")
        .accessibilityValue(
            qualifier.map { "\(score) out of 100, \(caption) — \($0)" }
                ?? "\(score) out of 100, \(caption)"
        )
    }
}

/// The Insights tab's hero: the overall score, the two domain subscores, and
/// — critically — the honest qualifiers that stop the number from reading as
/// more settled than it is.
///
/// Flat on the page like the Dashboard's `GlanceStrip` — the ring *is* the
/// hero; boxing it in a bordered card just muffled it. The ring sits left,
/// everything textual hangs off a single left-aligned column beside it.
struct ProtectionScoreCard: View {
    @Environment(\.themePalette) private var palette

    let score: ProtectionScore
    /// `true` while a refresh is in flight, so the card can say so rather
    /// than showing a stale number as current.
    let isRefreshing: Bool
    /// When the security half was actually read.
    let postureCollectedAt: Date
    /// How many findings the user has snoozed or dismissed. They are absent
    /// from the points *and* from the verdict, which is the auditable
    /// behaviour — but it means the number can only ever look better than
    /// the machine is, so the hero has to say so.
    var suppressedCount: Int = 0

    /// Subscore bars read best as a compact ledger; unbounded they stretch
    /// across the whole window and the bar becomes a highway.
    private static let subscoreMaxWidth: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacingRow) {
            ProtectionScoreFigure(
                score: score.overall,
                band: score.band,
                qualifier: weakerDomainCaption
            )
            title
            VStack(alignment: .leading, spacing: palette.spacingRow) {
                subscoreRow(
                    label: InsightDomain.hardware.displayName,
                    value: score.hardwareSubscore,
                    symbol: "laptopcomputer"
                )
                subscoreRow(
                    label: InsightDomain.security.displayName,
                    value: score.securitySubscore,
                    symbol: "lock.shield"
                )
            }
            .frame(maxWidth: Self.subscoreMaxWidth, alignment: .leading)
            qualifiers
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Protection Score")
                .font(palette.font(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text("The average of the two halves below — each of which is the average of its own categories, and each category starts at 100 and loses the weight of its own findings. The verdict beside the number follows the weaker half, and never reads \"well protected\" while a warning or critical finding is open — however high the average.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Names the half the verdict came from, so the number and the word
    /// beside it don't have to be reconciled by the reader. Suppressed when
    /// the verdict is "well protected" — naming a half there would imply a
    /// problem where there is none. Keyed off the band rather than off a
    /// point threshold so the qualifier appears exactly when the verdict is
    /// something other than clean, including the severity-driven cases where
    /// the points look fine.
    private var weakerDomainCaption: String? {
        guard score.band != .wellProtected else { return nil }
        return score.weakerDomain.displayName
    }

    /// Label, a thin horizontal bar, value — the handoff's subscore idiom.
    /// The bar is colored only by the score's own band (data, not accent),
    /// on a `surfaceElevated` track.
    ///
    /// Tinted by `pointsBand` rather than by the verdict: this bar *is* the
    /// number, so it should say what the number says. The severity floor
    /// belongs to the words above, where the claim is made.
    private func subscoreRow(label: String, value: Int, symbol: String) -> some View {
        let fraction = min(max(Double(value) / 100, 0), 1)
        let tint = palette.tint(for: ProtectionScore.pointsBand(for: value))
        return HStack(spacing: palette.spacingTight) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(palette.textTertiary)
                .frame(width: 16)
            Text(label)
                .font(palette.font(size: 12))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 76, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.surfaceElevated)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(3, geometry.size.width * fraction))
                }
            }
            .frame(height: 3)
            .frame(maxWidth: .infinity)
            Text("\(value)")
                .font(palette.font(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
                .frame(width: 30, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue("\(value) out of 100")
    }

    /// Every reason the number might be less than it appears, stated rather
    /// than hidden.
    @ViewBuilder
    private var qualifiers: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isRefreshing {
                qualifier(
                    symbol: "arrow.triangle.2.circlepath",
                    text: String(localized: "Recalculating…")
                )
            }
            if score.isProvisional {
                qualifier(
                    symbol: "clock.badge.questionmark",
                    text: String(localized: "Provisional — the hardware half rests on \(coverageText) of history. Longevity findings stay quiet until there are at least \(minimumDaysText).")
                )
            }
            if !score.unscoredCategories.isEmpty {
                qualifier(
                    symbol: "questionmark.circle",
                    text: String(localized: "Not scored, for lack of data on this Mac: \(unscoredText).")
                )
            }
            if suppressedCount > 0 {
                qualifier(
                    symbol: "eye.slash",
                    text: suppressedCount == 1
                        ? String(localized: "1 finding is hidden by you, and isn't counted in this score.")
                        : String(localized: "\(suppressedCount) findings are hidden by you, and aren't counted in this score.")
                )
            }
            qualifier(
                symbol: "shield.lefthalf.filled",
                text: String(localized: "Security posture read \(postureAgeText).")
            )
        }
    }

    private func qualifier(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(palette.textTertiary)
                .frame(width: 12)
                .padding(.top, 2)
            Text(text)
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var coverageText: String {
        InsightPhrasing.days(score.historyCoverageDays)
    }

    private var minimumDaysText: String {
        InsightPhrasing.days(InsightContext.minimumHistoryDays)
    }

    private var unscoredText: String {
        score.unscoredCategories.map(\.displayName).joined(separator: ", ")
    }

    private var postureAgeText: String {
        let seconds = Date().timeIntervalSince(postureCollectedAt)
        if seconds < 90 { return String(localized: "just now") }
        let formatted = postureCollectedAt.formatted(date: .omitted, time: .shortened)
        return String(localized: "at \(formatted)")
    }
}
