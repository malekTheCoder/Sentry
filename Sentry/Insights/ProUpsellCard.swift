import SwiftUI
import SentryKit

/// The paywall, written to the same honesty rules as everything else here.
///
/// **What it deliberately does not do:** invent urgency, count down, imply
/// the Mac is in danger it isn't in, nag on a timer, or reappear once
/// dismissed within a session. It states how many findings are withheld and
/// how many of those are warnings or worse — both of which are true numbers
/// taken from the real, evaluated set — and offers to unlock them.
///
/// **There is no purchase flow yet, and this card says so rather than
/// showing a Buy button that can't work.** StoreKit is absent by design
/// (Apple Developer Program enrollment is blocked — see `PROGRESS.md`), and
/// a "Upgrade" button wired to nothing would be precisely the inert control
/// this project has removed before. When the purchase path exists it
/// replaces `unavailableNotice` below and nothing else on this card changes.
struct ProUpsellCard: View {
    @Environment(\.themePalette) private var palette

    let gated: ProGate.GatedInsights
    let unlockSource: ProUnlockSource

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            header
            withheldBlock
            unavailableNotice
        }
        .quietCard(palette)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 12))
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            Text(ProFeature.protectionInsights.displayName)
                .font(palette.font(size: 14, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
        }
    }

    private var withheldBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(withheldSentence)
                .font(palette.font(size: 12))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("The protection score and the two highest-priority findings stay free, permanently — including their evidence and what to do about them.")
                .font(palette.font(size: 11))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Says what is actually behind the wall. `lockedActionableCount` is the
    /// honest qualifier: "and 6 more" when five of them are informational
    /// would be technically true and materially misleading.
    private var withheldSentence: String {
        let totalText = "\(gated.lockedCount)"
        guard gated.lockedActionableCount > 0 else {
            return String(localized: "\(totalText) further findings on this Mac are withheld. None of them are warnings — the important ones are already shown above.")
        }
        let actionableText = "\(gated.lockedActionableCount)"
        return String(localized: "\(totalText) further findings on this Mac are withheld, \(actionableText) of them at warning level or higher.")
    }

    private var unavailableNotice: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(palette.textTertiary)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(noticeText)
                .font(palette.font(size: 10))
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var noticeText: String {
        switch unlockSource {
        case .locked:
            // Still true after the license system landed: verification
            // exists (`LicenseProEntitlementStore`), but no checkout does —
            // there is nowhere to buy a license yet, so a Buy button here
            // would still be the inert control this copy refuses to be.
            // Deliberately no pointer to the developer-override toggle:
            // that UI exists only in DEBUG builds (AdvancedPane), and copy
            // that names a control release users can't find is the exact
            // bug this card exists to avoid.
            return String(localized: "Purchasing isn't available yet — Sentry's license checkout hasn't opened, so there is deliberately no Buy button here that couldn't work. Checkout is coming in an update; everything above stays free.")
        case .developerOverride:
            return String(localized: "Unlocked by the local developer override. This is not a purchase.")
        case .license:
            return String(localized: "Unlocked by your Sentry Pro license.")
        }
    }
}
