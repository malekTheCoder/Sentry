import SwiftUI
import MacStatKit

/// One finding, collapsed to a headline and expandable to the full case:
/// why it matters for *this* Mac, the measurements behind it, and what to
/// do.
///
/// The evidence list is the part that justifies the price of the feature, so
/// it is given its own visually distinct block rather than being folded into
/// prose — a reader should be able to scan the numbers without reading the
/// paragraph, and check them against the Dashboard if they want to.
struct InsightRowView: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let insight: ProtectionInsight

    /// Non-nil when this row is currently hidden — the restore affordance
    /// and the horizon are shown instead of dismiss/snooze.
    let suppression: InsightSuppression?

    let onAction: (InsightAction) -> Bool
    let onDismiss: () -> Void
    let onSnooze: (SnoozeDuration) -> Void
    let onRestore: () -> Void

    @State private var isExpanded = false
    /// Set when a System Settings deep link refused to open, so the written
    /// path is revealed rather than the button appearing to do nothing.
    @State private var deepLinkFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? palette.spacing : 0) {
            headerButton
            if isExpanded {
                expandedBody
            }
        }
        // Quiet tile, not a bordered card — same weight as the Dashboard's
        // grid cells, so a finding reads as a row of the page rather than a
        // box competing with it. The fill doubles as the click affordance.
        .quietCard(palette)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Collapsed header

    private var headerButton: some View {
        Button {
            withAnimation(ThemePalette.disclosureMotion(reduceMotion: reduceMotion)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(alignment: .top, spacing: palette.spacing) {
                severityBadge
                VStack(alignment: .leading, spacing: 3) {
                    Text(insight.title)
                        .font(palette.font(size: 13, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Text(insight.summary)
                        .font(palette.font(size: 11))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    metaLine
                }
                Spacer(minLength: palette.spacingTight)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.top, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(insight.title)
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint(Text(isExpanded ? "Collapses this finding" : "Expands this finding"))
        .accessibilityAddTraits(.isButton)
    }

    private var severityBadge: some View {
        Image(systemName: insight.severity.symbolName)
            .font(.system(size: 13))
            .foregroundStyle(severityColor)
            .frame(width: 18)
            .padding(.top, 1)
            .accessibilityHidden(true)
    }

    private var severityColor: Color {
        switch insight.severity {
        case .critical: return palette.danger
        case .warning: return palette.warning
        case .advice: return palette.accent
        case .good: return palette.success
        }
    }

    /// Category, and — when it's low — the confidence qualifier. A finding
    /// built on six days of history should say so on its face rather than
    /// only in the fine print of the score card.
    private var metaLine: some View {
        HStack(spacing: 5) {
            Label(insight.category.displayName, systemImage: insight.category.symbolName)
                .labelStyle(.titleAndIcon)
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)
            if insight.confidence < 0.75, insight.severity != .good {
                Text("· limited history")
                    .font(palette.font(size: 10))
                    .foregroundStyle(palette.textTertiary)
            }
            if let suppression {
                Text("· \(suppression.horizonDescription())")
                    .font(palette.font(size: 10))
                    .foregroundStyle(palette.textTertiary)
            }
        }
    }

    private var accessibilitySummary: String {
        "\(insight.severity.displayName). \(insight.summary)"
    }

    // MARK: - Expanded body

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            Divider().overlay(palette.separator)

            Text(insight.detail)
                .font(palette.font(size: 12))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            evidenceBlock

            VStack(alignment: .leading, spacing: 3) {
                MicroHeaderLabel(title: "What to do")
                Text(insight.recommendation)
                    .font(palette.font(size: 12))
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actionRow
        }
    }

    private var evidenceBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            MicroHeaderLabel(title: "Measured on this Mac")
            ForEach(Array(insight.evidence.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(palette.textTertiary)
                        .frame(width: 3, height: 3)
                        .padding(.top, 6)
                        .accessibilityHidden(true)
                    Text(line)
                        .font(palette.font(size: 11))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(palette.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                .fill(palette.surface)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Evidence measured on this Mac")
    }

    @ViewBuilder
    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: palette.spacing) {
                actionControl
                Spacer(minLength: palette.spacingTight)
                suppressionControl
            }
            // Shown either when the action was never launchable (a manual
            // change the user has to make) or when the deep link refused —
            // both cases need the path spelled out in words.
            if let description = insight.action?.fallbackDescription,
               shouldShowFallbackDescription {
                Text(description)
                    .font(palette.font(size: 10))
                    .foregroundStyle(palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var shouldShowFallbackDescription: Bool {
        guard let action = insight.action else { return false }
        if case .manual = action.target { return true }
        return deepLinkFailed
    }

    @ViewBuilder
    private var actionControl: some View {
        if let action = insight.action {
            switch action.target {
            case .manual:
                // No button, deliberately: there is nothing for Sentry to
                // launch, and a control that does nothing is exactly what
                // this codebase removes on sight. The instruction is the
                // `fallbackDescription` text below instead.
                Label(action.label, systemImage: "hand.point.right")
                    .labelStyle(.titleAndIcon)
                    .font(palette.font(size: 11))
                    .foregroundStyle(palette.textSecondary)
            case .systemSettings, .appSettings:
                Button {
                    let opened = onAction(action)
                    if !opened { deepLinkFailed = true }
                } label: {
                    Text(action.label)
                        .font(palette.font(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel(action.label)
            }
        }
    }

    @ViewBuilder
    private var suppressionControl: some View {
        if suppression != nil {
            Button {
                onRestore()
            } label: {
                Label("Show again", systemImage: "arrow.uturn.backward")
                    .font(palette.font(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.accent)
            .accessibilityLabel("Show this finding again")
        } else {
            Menu {
                Button("Snooze for \(SnoozeDuration.week.displayName)") { onSnooze(.week) }
                Button("Snooze for \(SnoozeDuration.month.displayName)") { onSnooze(.month) }
                Button("Snooze for \(SnoozeDuration.quarter.displayName)") { onSnooze(.quarter) }
                Divider()
                Button("Dismiss permanently") { onDismiss() }
            } label: {
                Label("Hide", systemImage: "eye.slash")
                    .font(palette.font(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Hide this finding")
            .accessibilityHint("Snooze it for a week, a month, or three months, or dismiss it permanently")
        }
    }
}

// MARK: - Locked row

/// A finding the free tier can see the *shape* of but not the content.
///
/// Note what this view has access to: `ProGate.LockedInsightPreview`, which
/// carries an id, a category, and a severity — and no strings at all. There
/// is nothing here to blur, because the withheld text was never built into
/// the view hierarchy, so it cannot be recovered from a screenshot, an
/// accessibility dump, or a view inspector. See `ProGate`'s doc comment.
struct LockedInsightRowView: View {
    @Environment(\.themePalette) private var palette

    let preview: ProGate.LockedInsightPreview

    /// Muted against the unlocked rows' full-strength severity colours — a
    /// locked `critical` still reads as critical (that is honest and the
    /// whole point of showing severity), just visibly not yet readable.
    private var severityColor: Color {
        switch preview.severity {
        case .critical: return palette.danger
        case .warning: return palette.warning
        case .advice: return palette.accent
        case .good: return palette.success
        }
    }

    var body: some View {
        HStack(spacing: palette.spacing) {
            Image(systemName: preview.severity.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(severityColor.opacity(0.6))
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(preview.severity.displayName)
                    .font(palette.font(size: 12, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                Label(preview.category.displayName, systemImage: preview.category.symbolName)
                    .labelStyle(.titleAndIcon)
                    .font(palette.font(size: 10))
                    .foregroundStyle(palette.textTertiary)
            }

            Spacer(minLength: palette.spacing)

            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(palette.textTertiary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, palette.spacingBlock)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Same quiet fill as the unlocked rows, no border — a locked row is
        // dimmer *content*, not a differently-chromed widget.
        .background(
            RoundedRectangle(cornerRadius: palette.cornerRadius, style: .continuous)
                .fill(palette.surface.opacity(0.6))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Locked finding")
        .accessibilityValue("\(preview.severity.displayName), \(preview.category.displayName). Details require Sentry Pro.")
    }
}
