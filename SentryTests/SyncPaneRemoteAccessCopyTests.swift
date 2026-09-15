import XCTest
@testable import Sentry
@testable import SentryKit

/// Coverage for the pure remote-access copy in `SyncPane`
/// (Sentry/Settings/Panes/SyncPane.swift), pinned as static values, no view
/// hierarchy.
///
/// **This file used to pin a paywall's honesty.** Two toggle labels and
/// four footers existed so that an unlicensed copy stopped claiming
/// other-network reachability it would refuse at accept time, named Sentry
/// Pro rather than hiding why, and disclosed a lapse in words. One label
/// and two footers are left, and what they defend now is the opposite
/// claim: the broad promise is true for everybody, so no surface here may
/// narrow it or mention a tier.
@MainActor
final class SyncPaneRemoteAccessCopyTests: XCTestCase {

    /// **Remote sync is genuinely offered to everyone, and the toggle says
    /// so.** The narrowed label ("Allow a paired iPhone to control this
    /// Mac") was the visible half of the gate; the surviving one is the
    /// pre-gate promise.
    func testTheOneToggleLabelPromisesOtherNetworks() {
        let label = SyncPane.remoteToggleLabel
        XCTAssertFalse(label.isEmpty)
        XCTAssertTrue(label.localizedCaseInsensitiveContains("other networks"))
        XCTAssertFalse(label.contains("Sentry Pro"))
    }

    func testBothFootersKeepThePreGatePromisesAndNameNoTier() {
        let enabled = SyncPane.remoteAccessFooter(enabled: true)
        let disabled = SyncPane.remoteAccessFooter(enabled: false)

        // The reachability guidance used to be unlocked-only, because it is
        // only honest to show someone whose Mac will actually answer. Every
        // Mac answers now, so everyone gets the guidance.
        XCTAssertTrue(enabled.contains("Tailscale"))
        XCTAssertTrue(enabled.localizedCaseInsensitiveContains("forward the port"))
        XCTAssertTrue(enabled.localizedCaseInsensitiveContains("scan the QR code"))
        XCTAssertTrue(disabled.localizedCaseInsensitiveContains("isn't on this Wi-Fi"))

        for text in [enabled, disabled] {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(
                text.contains("Sentry Pro"),
                "no remote-access copy may name a tier that doesn't exist"
            )
            XCTAssertFalse(
                text.localizedCaseInsensitiveContains("only answers devices on this network"),
                "the narrowed-scope disclosure described a refusal that no longer happens"
            )
        }
        XCTAssertNotEqual(enabled, disabled, "each state earns its own sentence")
    }
}
