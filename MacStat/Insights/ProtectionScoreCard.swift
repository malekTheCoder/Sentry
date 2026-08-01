import SwiftUI
import MacStatKit

/// The score ring.
///
/// Mirrors `MacStatWidget/Views/BatteryArcView.swift`'s construction exactly
/// — a `Circle().trim(from:to:)` stroked with a round cap and rotated −90°
/// so it starts at twelve o'clock — rather than inventing a second arc
/// idiom. The differences are all theming: the track and fill come from the
/// palette instead of `Color.secondary`/`.green`, and the centre carries the
/// score plus a caption rather than a percentage.
struct ProtectionScoreRing: View {
    @Environment(\.themePalette) private var palette

    let score: Int
    let caption: String
    var diameter: CGFloat = 150
    var lineWidth: CGFloat = 12

    private var fraction: Double {
        min(max(Double(score) / 100, 0), 1)
    }

    /// Bands, and why these boundaries: 85 is "nothing here needs your
    /// attention today" (at most one minor finding), 60 is "there is at
    /// least one warning-level problem", below that means something critical
    /// or several serious things. They line up with `InsightWeight` — one
    /// `majorSecurity` finding (15 points) lands you at 85, and one
    /// `criticalSecurity` (25) lands you below it.
    private var tint: Color {
        if score >= 85 { return palette.success }
        if score >= 60 { return palette.warning }
        return palette.danger
    }

    var body: some View {
        ZStack {
            // Track is surfaceElevated per the handoff's fill rules —
            // separators are for hairlines, not gauge tracks.
            Circle()
                .stroke(palette.surfaceElevated, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text("\(score)")
                    .font(palette.font(size: 38, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(palette.textPrimary)
                Text(caption)
                    .font(palette.font(size: 10))
                    .foregroundStyle(palette.textTertiary)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Protection score")
        .accessibilityValue("\(score) out of 100, \(caption)")
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

    /// Subscore rows read best as a compact ledger; unbounded they stretch
    /// the value digits away from their labels on a wide window.
    private static let subscoreMaxWidth: CGFloat = 300

    var body: some View {
        HStack(alignment: .center, spacing: palette.spacingSection) {
            ProtectionScoreRing(score: score.overall, caption: bandCaption)
            VStack(alignment: .leading, spacing: palette.spacingRow) {
                title
                VStack(alignment: .leading, spacing: palette.spacingTight) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Protection Score")
                .font(palette.font(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text("100 minus the weight of everything Sentry found. Nothing adds points back.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bandCaption: String {
        if score.overall >= 85 { return String(localized: "well protected") }
        if score.overall >= 60 { return String(localized: "needs attention") }
        return String(localized: "act on this")
    }

    private func subscoreRow(label: String, value: Int, symbol: String) -> some View {
        HStack(spacing: palette.spacingTight) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(palette.textTertiary)
                .frame(width: 16)
            Text(label)
                .font(palette.font(size: 12))
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: palette.spacing)
            Text("\(value)")
                .font(palette.font(size: 15, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(palette.textPrimary)
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
