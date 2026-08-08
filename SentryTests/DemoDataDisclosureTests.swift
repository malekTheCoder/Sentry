import XCTest
@testable import SentryKit

/// Covers `DemoDataDisclosure` — the decision and the wording behind the
/// banner `SentryMobile` pins above every tab while it is rendering
/// `MockDataSource`'s invented readings.
///
/// **Why these assertions are worth having and are not tautologies.** Two of
/// the three things this file pins are real, previously-shipped bugs in this
/// app, not hypotheticals. The app disclosed fabricated data on two of four
/// tabs (Alerts and Settings showed a screen of invented numbers with nothing
/// saying so), and the History tab's wording blamed iCloud — a transport this
/// build never attempts — for a Wi-Fi problem, sending users to look for a fix
/// in a feature that was never involved (connection-honesty review, bug #6).
/// The failure mode both share is a sentence quietly drifting away from what
/// it has to say. So the copy tests below assert *content requirements* —
/// that the headline still denies the data comes from a real Mac, that the
/// cause still names the network, that the remedy still explains what this
/// app is for and never re-blames iCloud — rather than comparing strings to
/// themselves.
///
/// **Why this is in a macOS test bundle at all.** `SentryTests` is
/// `platform: macOS`, hosted by the `Sentry` app, and cannot import
/// `SentryMobile`. Anything written inside that target is untestable here by
/// construction — which is the whole reason `DemoDataDisclosure` lives in
/// `SentryKit`. Same trade, same argument, as `WalkthroughFlow.swift` and
/// `WatchRelayPolicy.swift` before it.
///
/// The view layer (`DemoDataBanner`, `RootTabView`'s `safeAreaInset`) is
/// deliberately not faked out with a stub here. It is SwiftUI, it is in the
/// unreachable target, and a test asserting that a `some View` was
/// constructed would prove nothing about whether anything is on screen —
/// that half was verified by running the app in the Simulator with no Mac
/// present and reading all four tabs.
final class DemoDataDisclosureTests: XCTestCase {

    // MARK: - The decision

    /// The whole truth table, spelled out. Four inputs, and the two that
    /// matter most are the ones a future edit is most likely to get wrong:
    /// live data must show nothing *whatever the user tapped earlier*, and
    /// demo data must show something *whatever the user tapped earlier*.
    func testProminenceCoversEveryCombination() {
        XCTAssertEqual(
            DemoDataDisclosure.prominence(isShowingDemoData: true, isQuieted: false),
            .full
        )
        XCTAssertEqual(
            DemoDataDisclosure.prominence(isShowingDemoData: true, isQuieted: true),
            .marker
        )
        XCTAssertEqual(
            DemoDataDisclosure.prominence(isShowingDemoData: false, isQuieted: false),
            .hidden
        )
        XCTAssertEqual(
            DemoDataDisclosure.prominence(isShowingDemoData: false, isQuieted: true),
            .hidden
        )
    }

    /// The property the whole feature rests on: **there is no way to be
    /// showing fabricated numbers and disclosing nothing.** Written as a loop
    /// over the quiet flag rather than as a second copy of the case above, so
    /// that adding a third dismissal state later (a "don't show again," say)
    /// has to confront this assertion rather than slip past it.
    func testDemoDataIsNeverSilentlyHidden() {
        for isQuieted in [true, false] {
            let prominence = DemoDataDisclosure.prominence(isShowingDemoData: true, isQuieted: isQuieted)
            XCTAssertNotEqual(
                prominence, .hidden,
                "Quieting the banner must never remove the disclosure entirely (isQuieted: \(isQuieted))."
            )
            XCTAssertFalse(
                DemoDataDisclosure.accessibilityLabel(for: prominence).isEmpty,
                "A visible disclosure must always announce itself to VoiceOver (isQuieted: \(isQuieted))."
            )
        }
    }

    /// The obligation running the other way, and it is not the lesser one: a
    /// stale "this is a sample" strip sitting over a real Mac's real readings
    /// is the same lie inverted, and worse, because it teaches the reader to
    /// ignore the strip.
    func testRealDataDisclosesNothing() {
        let prominence = DemoDataDisclosure.prominence(isShowingDemoData: false, isQuieted: false)
        XCTAssertEqual(prominence, .hidden)
        XCTAssertFalse(prominence.marksIndividualValues)
        XCTAssertEqual(DemoDataDisclosure.accessibilityLabel(for: prominence), "")
    }

    /// Quieting is a statement about the banner, not a licence to let a chart
    /// full of invented numbers pass as telemetry — and the inline tags are
    /// what survives a cropped screenshot of a single card, which a banner
    /// never does.
    func testQuietedBannerStillMarksTheDataItself() {
        XCTAssertTrue(DemoDataDisclosure.Prominence.full.marksIndividualValues)
        XCTAssertTrue(DemoDataDisclosure.Prominence.marker.marksIndividualValues)
        XCTAssertFalse(DemoDataDisclosure.Prominence.hidden.marksIndividualValues)
    }

    // MARK: - The three things it has to say

    /// Thing one: these numbers are a sample, and they are not from a real
    /// Mac. Both halves, because either alone is ambiguous — "sample" alone
    /// invites "a sample of *my* Mac's data, then," and "not from a real Mac"
    /// alone leaves open that these are stale real readings after a failure.
    func testHeadlineDeniesRealDataAndNamesItASample() {
        let headline = DemoDataDisclosure.headline.lowercased()
        XCTAssertTrue(headline.contains("sample"), DemoDataDisclosure.headline)
        XCTAssertTrue(headline.contains("not from a real mac"), DemoDataDisclosure.headline)
    }

    /// Thing two: *why*. Names the network, because the cause a user can
    /// actually act on is "nothing answered here," and because the previous
    /// wording on the History tab named iCloud instead.
    func testCauseNamesTheNetworkAndNotICloud() {
        let cause = DemoDataDisclosure.cause.lowercased()
        XCTAssertTrue(cause.contains("network"), DemoDataDisclosure.cause)
        XCTAssertTrue(cause.contains("no mac"), DemoDataDisclosure.cause)
        XCTAssertFalse(cause.contains("icloud"), "Regression of connection-honesty bug #6: iCloud is not why demo data is showing, and this build never attempts it.")
    }

    /// Thing three: what to do about it — written so it also answers the
    /// question a first-time App Store reviewer actually has, which is not
    /// "how do I fix this" but "what *is* this app." Someone who never
    /// installs the Mac app should still close this app understanding that it
    /// is a readout of one.
    func testRemedyExplainsTheCompanionRelationshipAndAnAction() {
        let remedy = DemoDataDisclosure.remedy.lowercased()
        XCTAssertTrue(remedy.contains("mac"), DemoDataDisclosure.remedy)
        XCTAssertTrue(remedy.contains("install"), DemoDataDisclosure.remedy)
        XCTAssertFalse(remedy.contains("icloud"), DemoDataDisclosure.remedy)
    }

    /// A VoiceOver user who quiets the banner has not thereby agreed to be
    /// told less than a sighted one: the marker shows one line and still says
    /// all three things.
    func testAccessibilityLabelCarriesAllThreeSentencesInBothProminences() {
        for prominence in [DemoDataDisclosure.Prominence.full, .marker] {
            let label = DemoDataDisclosure.accessibilityLabel(for: prominence)
            XCTAssertTrue(label.contains(DemoDataDisclosure.headline), "\(prominence): \(label)")
            XCTAssertTrue(label.contains(DemoDataDisclosure.cause), "\(prominence): \(label)")
            XCTAssertTrue(label.contains(DemoDataDisclosure.remedy), "\(prominence): \(label)")
        }
    }

    // MARK: - Presentation metadata

    /// Every label a control renders has to be non-empty, or a button ships
    /// as a blank tap target. The same "every case has usable presentation
    /// metadata" ground `MetricModuleSymbolTests` covers for a different
    /// enum.
    func testEveryVisibleLabelIsNonEmpty() {
        for label in [
            DemoDataDisclosure.symbolName,
            DemoDataDisclosure.headline,
            DemoDataDisclosure.cause,
            DemoDataDisclosure.remedy,
            DemoDataDisclosure.markerLabel,
            DemoDataDisclosure.quietActionLabel,
            DemoDataDisclosure.retryActionLabel,
            DemoDataDisclosure.setUpActionLabel,
        ] {
            XCTAssertFalse(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// The quiet control must not promise a disappearance the type does not
    /// offer — "Dismiss"/"Close"/"Hide" would all be claims
    /// `prominence(isShowingDemoData:isQuieted:)` refuses to honour, and a
    /// control whose label lies about its own effect is exactly the
    /// "settings slider that silently does nothing" failure this codebase
    /// names as its own prior bug.
    func testQuietActionDoesNotPromiseDismissal() {
        let label = DemoDataDisclosure.quietActionLabel.lowercased()
        for forbidden in ["dismiss", "close", "hide", "never", "don't show"] {
            XCTAssertFalse(label.contains(forbidden), "Quiet action label must not promise \"\(forbidden)\": \(label)")
        }
    }
}
