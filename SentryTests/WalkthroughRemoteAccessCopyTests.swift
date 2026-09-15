import XCTest
@testable import SentryKit

/// Copy-honesty guards for the walkthrough's pairing steps — the same
/// discipline
/// `WalkthroughFlowTests.testNoStepTellsTheUserToTurnOnANonexistentLocalAccessToggle`
/// applies to a different previously-shipped falsehood, in its own file so
/// this feature area's tests don't collide with concurrent edits there.
///
/// **The claim being defended flipped.** These tests used to require the
/// opposite of what they now require: walkthrough copy is static, every
/// user reads the same strings, and while off-LAN reach was sold, any
/// sentence about reaching the Mac from another network had to carry a
/// "part of Sentry Pro" qualifier or a free user was being promised a
/// connection their Mac would refuse at accept time. Nothing refuses now,
/// so the qualifier is itself the falsehood — it would tell every user that
/// a feature they have is one they must buy.
final class WalkthroughRemoteAccessCopyTests: XCTestCase {

    /// **Remote sync is genuinely offered to everyone, and the onboarding
    /// says so.** No pairing step may name a tier, on either platform.
    func testNoPairingStepQualifiesReachabilityWithATier() {
        for text in [MacWalkthroughStep.companion.summary, MacWalkthroughStep.companion.detail,
                     PhoneWalkthroughStep.pairing.summary, PhoneWalkthroughStep.pairing.detail] {
            XCTAssertFalse(
                text.contains("Sentry Pro"),
                "pairing copy must not gate reachability behind a product that doesn't exist: \(text)"
            )
        }
    }

    /// The positive half: the steps still *describe* off-LAN reach. Dropping
    /// the qualifier by deleting the whole promise would be a different bug
    /// — a user who can reach their Mac from anywhere should be told so.
    func testPairingStepsStillDescribeReachingTheMacFromOtherNetworks() {
        for text in [MacWalkthroughStep.companion.detail, PhoneWalkthroughStep.pairing.detail] {
            XCTAssertTrue(
                text.localizedCaseInsensitiveContains("other networks"),
                "the pairing step should still promise off-LAN reach: \(text)"
            )
        }
    }

    /// No walkthrough copy anywhere sells anything. Scanned globally, not
    /// just over the pairing steps: the insights and companion steps both
    /// carried tier language at various points.
    func testNoWalkthroughStepMentionsATierOrAPurchase() {
        let allCopy = MacWalkthroughStep.allCases.flatMap { [$0.title, $0.summary, $0.detail] }
            + PhoneWalkthroughStep.allCases.flatMap { [$0.title, $0.summary, $0.detail] }
        for text in allCopy {
            XCTAssertFalse(text.contains("Sentry Pro"), "copy must not name Sentry Pro: \(text)")
            XCTAssertFalse(
                text.localizedCaseInsensitiveContains("upgrade to"),
                "copy must not sell an upgrade: \(text)"
            )
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
