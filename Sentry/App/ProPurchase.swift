import SwiftUI
import SentryKit

/// The one purchase decision every locked surface shares: is there
/// somewhere to buy Sentry Pro, or not yet?
///
/// **Why one type.** `ProUpsellCard`, `ThemePane`'s upsell card, and
/// `SyncPane`'s locked row each used to carry their own copy of the same
/// admission — "purchasing isn't available yet" — and each doc comment
/// pointed at the others to keep them in step. That worked while the
/// answer was a constant. It stops working the day the checkout opens:
/// three sentences to flip by hand is three chances to ship an app that
/// offers a Buy button on one screen and denies checkout exists on the
/// next. So the decision lives here, as a pure function of the checkout
/// URL, and every surface renders whatever it returns.
///
/// **The gate is `AppCredits.proCheckoutURL`.** It is nil for the
/// placeholder string that ships today (`AppCredits.proCheckoutURLString`)
/// and a URL only once the owner has pasted the real checkout address —
/// the same honest gating `UpdateController` applies to the Sparkle key.
/// Until then `affordance()` is `.notOnSaleYet`, and the copy for that
/// state is the marketing site's own current wording, so the app and the
/// website say the same thing about the same fact.
enum ProPurchase {

    enum Affordance: Equatable {
        /// Offer a Buy button/link that opens this checkout page.
        case buy(URL)
        /// Say, plainly, that there is nothing to buy yet.
        case notOnSaleYet
    }

    /// The decision. Defaults to the shipped constant; tests pass their own.
    static func affordance(checkoutURL: URL? = AppCredits.proCheckoutURL) -> Affordance {
        if let checkoutURL { return .buy(checkoutURL) }
        return .notOnSaleYet
    }

    // MARK: - Copy

    static let buyButtonTitle = String(localized: "Buy Sentry Pro…")

    /// Under the button. Says where the click goes (the browser — the
    /// purchase is not in-app, and the privacy policy draft is explicit
    /// that the app takes no part in it) and what happens next, so the
    /// license pane is not a surprise.
    static let buyCaption = String(
        localized: "Opens the checkout in your web browser. Your license arrives by email; paste it into Settings ▸ Sentry Pro to activate it on this Mac."
    )

    /// The not-on-sale state, in the marketing site's words — see the
    /// type doc comment. No "coming soon" date, no countdown, no price
    /// (there isn't one).
    static let notOnSaleNotice = String(
        localized: "Sentry Pro isn't on sale yet, and no price is set. These features stay locked for everyone until there is one — a single purchase when it happens, not a subscription."
    )

    /// For surfaces that are plain sentences with no room for a control
    /// (a Form footer): where to go, or the not-on-sale admission. Points
    /// at the pane rather than embedding a link because a footer can't
    /// carry one — and the pane is where the license ends up anyway.
    static func footerSentence(checkoutURL: URL? = AppCredits.proCheckoutURL) -> String {
        switch affordance(checkoutURL: checkoutURL) {
        case .buy:
            return String(localized: "Sentry Pro is sold from Settings ▸ Sentry Pro, and a license is activated there too.")
        case .notOnSaleYet:
            return notOnSaleNotice
        }
    }
}

/// The palette-styled rendering of a `ProPurchase.Affordance`, shared by
/// the two upsell cards (`ProUpsellCard`, `ThemePane`'s). `SyncPane`
/// renders the same decision in its plain-Form idiom instead.
///
/// A `Button` driving `openURL` rather than a `Link`, so the control can
/// take a real button style: a bare text link at the bottom of a card
/// reads as a footnote, and the one control on this card that costs money
/// should look like a control. Accessibility: the button carries a hint
/// that it leaves the app, and the caption is combined into one element so
/// VoiceOver reads the destination and the consequence together.
struct ProPurchaseAffordanceView: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.openURL) private var openURL

    let affordance: ProPurchase.Affordance

    var body: some View {
        switch affordance {
        case .buy(let url):
            VStack(alignment: .leading, spacing: 6) {
                Button(ProPurchase.buyButtonTitle) {
                    openURL(url)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .accessibilityHint("Opens the checkout page in your web browser")
                Text(ProPurchase.buyCaption)
                    .font(palette.font(size: 10))
                    .foregroundStyle(palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .notOnSaleYet:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.textTertiary)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                Text(ProPurchase.notOnSaleNotice)
                    .font(palette.font(size: 10))
                    .foregroundStyle(palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
