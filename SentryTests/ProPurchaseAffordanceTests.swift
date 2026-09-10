import XCTest
@testable import Sentry
@testable import SentryKit

/// The honest-gating rule for the Buy button (`Sentry/App/ProPurchase.swift`
/// and `ProUpsellCard.footer`): a purchase control appears only when
/// `AppCredits.proCheckoutURL` is a real address, and every locked surface
/// says the same not-on-sale sentence until then. Same shape as
/// `UpdateFeedConfigurationTests` for the Sparkle key — the placeholder
/// state is the shipped state, so it is the one that must be verified.
@MainActor
final class ProPurchaseAffordanceTests: XCTestCase {

    private let realLookingURL = URL(string: "https://sentry.example-vendor.com/checkout/pro")!

    // MARK: - The gate

    func testPlaceholderCheckoutYieldsNotOnSaleYet() {
        let placeholderURL = AppCredits.checkoutURL(from: AppCredits.placeholderProCheckoutURLString)
        XCTAssertNil(placeholderURL)
        XCTAssertEqual(ProPurchase.affordance(checkoutURL: placeholderURL), .notOnSaleYet)
    }

    func testRealCheckoutYieldsBuy() {
        XCTAssertEqual(ProPurchase.affordance(checkoutURL: realLookingURL), .buy(realLookingURL))
    }

    /// The build as it ships: whatever `AppCredits` currently says, the
    /// affordance must be consistent with it — a Buy button iff a URL.
    func testShippedDefaultFollowsAppCredits() {
        switch ProPurchase.affordance() {
        case .buy(let url):
            XCTAssertEqual(url, AppCredits.proCheckoutURL)
        case .notOnSaleYet:
            XCTAssertNil(AppCredits.proCheckoutURL)
        }
    }

    // MARK: - ProUpsellCard's footer

    func testLockedFooterFollowsTheGate() {
        XCTAssertEqual(
            ProUpsellCard.footer(unlockSource: .locked, checkoutURL: nil),
            .purchase(.notOnSaleYet)
        )
        XCTAssertEqual(
            ProUpsellCard.footer(unlockSource: .locked, checkoutURL: realLookingURL),
            .purchase(.buy(realLookingURL))
        )
    }

    /// An unlocked card never sells — it attributes, and the two sources
    /// must stay visibly distinct (`ProUnlockSource`'s contract).
    func testUnlockedFootersAttributeAndNeverSell() {
        for url in [nil, realLookingURL] {
            guard case .attribution(let override) = ProUpsellCard.footer(unlockSource: .developerOverride, checkoutURL: url) else {
                return XCTFail("developer override must render an attribution, not a purchase")
            }
            guard case .attribution(let license) = ProUpsellCard.footer(unlockSource: .license, checkoutURL: url) else {
                return XCTFail("license must render an attribution, not a purchase")
            }
            XCTAssertTrue(override.localizedCaseInsensitiveContains("not a purchase"))
            XCTAssertTrue(license.localizedCaseInsensitiveContains("license"))
            XCTAssertNotEqual(override, license)
        }
    }

    // MARK: - Copy

    /// The not-on-sale sentence is the marketing site's own current claim
    /// ("Not on sale, and no price set yet … a single purchase when it
    /// happens, not a subscription"), so app and website agree. No
    /// fabricated urgency, no date, no price.
    func testNotOnSaleNoticeMatchesTheWebsiteAndInventsNothing() {
        let text = ProPurchase.notOnSaleNotice
        XCTAssertTrue(text.localizedCaseInsensitiveContains("isn't on sale yet"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("no price"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("not a subscription"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("buy now"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("coming soon"))
        XCTAssertFalse(text.contains("$"))
    }

    func testBuyCaptionSaysWhereTheClickGoesAndWhatComesNext() {
        let text = ProPurchase.buyCaption
        XCTAssertTrue(text.localizedCaseInsensitiveContains("browser"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("email"))
        XCTAssertTrue(text.contains("Sentry Pro"))
    }

    /// The three locked surfaces share one sentence — the reason
    /// `ProPurchase` exists.
    func testSyncPaneReadsTheSharedNotice() {
        XCTAssertEqual(SyncPane.lockedPurchaseNotice, ProPurchase.notOnSaleNotice)
    }

    /// A Form footer can't hold a control, so it gets a sentence: the
    /// not-on-sale admission, or a pointer to the pane that has the link.
    func testFooterSentenceFollowsTheGate() {
        XCTAssertEqual(ProPurchase.footerSentence(checkoutURL: nil), ProPurchase.notOnSaleNotice)
        let live = ProPurchase.footerSentence(checkoutURL: realLookingURL)
        XCTAssertTrue(live.contains("Settings ▸ Sentry Pro"))
        XCTAssertFalse(live.localizedCaseInsensitiveContains("isn't on sale"))
    }

    /// The Alerts pane's locked footer used to hard-code "checkout hasn't
    /// opened"; it now reads the shared decision so it can't lie after
    /// go-live.
    func testAlertsPaneLockedFooterFollowsTheGate() throws {
        let placeholder = try XCTUnwrap(AlertsPane.lockedConditionFooter(kind: .generic, processMatchUnlocked: false, checkoutURL: nil))
        XCTAssertTrue(placeholder.contains(ProPurchase.notOnSaleNotice))
        XCTAssertFalse(placeholder.localizedCaseInsensitiveContains("hasn't opened"))

        let live = try XCTUnwrap(AlertsPane.lockedConditionFooter(kind: .generic, processMatchUnlocked: false, checkoutURL: realLookingURL))
        XCTAssertFalse(live.localizedCaseInsensitiveContains("isn't on sale"))
        XCTAssertTrue(live.contains("Settings ▸ Sentry Pro"))
    }
}
