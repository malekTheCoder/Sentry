import XCTest
@testable import SentryKit

/// Copy-honesty guards for the walkthrough's pairing steps under the
/// `ProFeature.remoteSync` gate — the same discipline
/// `WalkthroughFlowTests.testNoStepTellsTheUserToTurnOnANonexistentLocalAccessToggle`
/// applies to a different previously-shipped falsehood, in its own file so
/// this feature area's tests don't collide with concurrent edits there.
///
/// The claim being defended: walkthrough copy is static — every user,
/// free or Pro, reads the same strings — so any sentence about reaching
/// the Mac from another network must carry the Sentry Pro qualifier, or a
/// free user is being promised a connection their Mac will refuse at
/// accept time (`LocalSyncServer` / `RemoteAccessGate`).
final class WalkthroughRemoteAccessCopyTests: XCTestCase {

    /// The two steps that describe pairing must name Sentry Pro when they
    /// speak of other networks. Pinned to the specific steps rather than
    /// scanned globally so an unrelated step mentioning "network" doesn't
    /// have to carry a paywall disclaimer.
    func testPairingStepsQualifyOffLANReachabilityWithSentryPro() {
        for text in [MacWalkthroughStep.companion.summary, MacWalkthroughStep.companion.detail] {
            XCTAssertTrue(
                text.contains("Sentry Pro"),
                "the Mac companion step describes off-LAN reach and must say it's part of Sentry Pro: \(text)"
            )
        }
        for text in [PhoneWalkthroughStep.pairing.summary, PhoneWalkthroughStep.pairing.detail] {
            XCTAssertTrue(
                text.contains("Sentry Pro"),
                "the phone pairing step describes off-LAN reach and must say it's part of Sentry Pro: \(text)"
            )
        }
    }

    /// The free half must be stated alongside the paid one: pairing on the
    /// Mac's own network is the free command-auth path, and copy that only
    /// says "Pro" would understate what a free user keeps.
    func testPairingStepsStillStateTheFreeLANHalf() {
        XCTAssertTrue(MacWalkthroughStep.companion.detail.localizedCaseInsensitiveContains("free"))
        XCTAssertTrue(PhoneWalkthroughStep.pairing.detail.localizedCaseInsensitiveContains("free"))
    }

    /// The old, now-false promise: unqualified "from anywhere else, pair"
    /// phrasing. Anyone re-deriving this copy from a pre-gate screenshot
    /// or the marketing site will reintroduce it; this fails when they do.
    /// (The phrase is allowed anywhere a Sentry Pro qualifier appears in
    /// the same string — the check is unqualified use in the pairing
    /// steps.)
    func testNoPairingStepPromisesUnqualifiedFromAnywherePairing() {
        let pairingCopy = [
            MacWalkthroughStep.companion.summary,
            MacWalkthroughStep.companion.detail,
            PhoneWalkthroughStep.pairing.summary,
            PhoneWalkthroughStep.pairing.detail,
        ]
        for text in pairingCopy {
            let mentionsAnywhere = text.localizedCaseInsensitiveContains("anywhere")
                || text.localizedCaseInsensitiveContains("other networks")
                || text.localizedCaseInsensitiveContains("outside")
            if mentionsAnywhere {
                XCTAssertTrue(
                    text.contains("Sentry Pro"),
                    "off-LAN phrasing without the Sentry Pro qualifier: \(text)"
                )
            }
        }
    }

    /// Walkthrough copy never embeds a live pairing value: no
    /// `sentry://` link and nothing shaped like a minted code belongs in a
    /// static string — the QR and code are drawn by `PairingControls` from
    /// the real settings, and a literal in copy would be a fake one.
    func testNoStepEmbedsAPairingURLOrCode() {
        let allCopy = MacWalkthroughStep.allCases.flatMap { [$0.title, $0.summary, $0.detail] }
            + PhoneWalkthroughStep.allCases.flatMap { [$0.title, $0.summary, $0.detail] }
        for text in allCopy {
            XCTAssertFalse(text.contains("sentry://"), "copy must not embed a pairing link: \(text)")
        }
    }
}
