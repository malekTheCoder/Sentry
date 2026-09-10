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
/// **The purchase path is gated on a real checkout address, not on a
/// build flag.** The bottom of the card is `ProPurchaseAffordanceView`,
/// which renders a Buy button only when `AppCredits.proCheckoutURL` is a
/// real URL and otherwise says, in the marketing site's own words, that
/// Sentry Pro is not on sale yet. Today it is the latter: no payment vendor
/// exists (`docs/STATUS.md`), and an "Upgrade" button wired to nothing
/// would be precisely the inert control this project has removed before.
/// The day the owner pastes the checkout URL into `AppCredits`, this card
/// grows a working button and nothing else on it changes — which is what
/// the older version of this comment promised, now built.
struct ProUpsellCard: View {
    @Environment(\.themePalette) private var palette

    let gated: ProGate.GatedInsights
    let unlockSource: ProUnlockSource

    /// Injected so tests can pin the card's gating against the placeholder
    /// and against a real-looking address without rebuilding `AppCredits`.
    /// Production callers take the default.
    var checkoutURL: URL? = AppCredits.proCheckoutURL

    var body: some View {
        VStack(alignment: .leading, spacing: palette.spacing) {
            header
            withheldBlock
            footer
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

    /// What the card ends with, decided per unlock source. Locked is the
    /// only state that asks the purchase question; the other two are the
    /// attribution sentences an unlocked build owes the user (see
    /// `ProUnlockSource`), unchanged.
    @ViewBuilder
    private var footer: some View {
        switch Self.footer(unlockSource: unlockSource, checkoutURL: checkoutURL) {
        case .purchase(let affordance):
            ProPurchaseAffordanceView(affordance: affordance)
        case .attribution(let sentence):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.textTertiary)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                Text(sentence)
                    .font(palette.font(size: 10))
                    .foregroundStyle(palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The footer decision as a value, so the honest-gating rule is pinned
    /// by tests without a view hierarchy (same convention as
    /// `SyncPane.remoteToggleLabel`).
    enum Footer: Equatable {
        case purchase(ProPurchase.Affordance)
        case attribution(String)
    }

    static func footer(unlockSource: ProUnlockSource, checkoutURL: URL?) -> Footer {
        switch unlockSource {
        case .locked:
            return .purchase(ProPurchase.affordance(checkoutURL: checkoutURL))
        case .developerOverride:
            return .attribution(String(localized: "Unlocked by the local developer override. This is not a purchase."))
        case .license:
            return .attribution(String(localized: "Unlocked by your Sentry Pro license."))
        }
    }
}
