import XCTest
@testable import Sentry
@testable import SentryKit

/// Coverage for the pure remote-access copy in `SyncPane`
/// (Sentry/Settings/Panes/SyncPane.swift) — the `ProFeature.remoteSync`
/// gate's on-screen words, pinned as static functions of plain values, no
/// view hierarchy.
///
/// What these tests defend is honesty, not phrasing: a locked copy's
/// Remote Access section must (a) stop claiming other-network
/// reachability it will refuse at accept time, (b) name Sentry Pro rather
/// than hiding why, and (c) disclose the lapsed-with-it-enabled state in
/// words — never silently. Editors may reword freely as long as those
/// stay true; the assertions below check for the load-bearing phrases,
/// not full sentences.
@MainActor
final class SyncPaneRemoteAccessCopyTests: XCTestCase {

    // MARK: - Toggle label

    func testToggleLabelsDifferAndTheLockedOneDropsTheOtherNetworksClaim() {
        let unlocked = SyncPane.remoteToggleLabel(isProUnlocked: true)
        let locked = SyncPane.remoteToggleLabel(isProUnlocked: false)

        XCTAssertFalse(unlocked.isEmpty)
        XCTAssertFalse(locked.isEmpty)
        XCTAssertNotEqual(unlocked, locked)

        // Unlocked keeps the pre-gate label — that surface is unchanged.
        XCTAssertTrue(unlocked.localizedCaseInsensitiveContains("other networks"))
        // Locked must not: while locked, the listener the toggle opens
        // answers this network only (`LocalSyncServer`'s accept gate), and
        // a label claiming otherwise is house rule P5's exact bug.
        XCTAssertFalse(
            locked.localizedCaseInsensitiveContains("other networks"),
            "the locked toggle label may not claim other-network reachability"
        )
    }

    // MARK: - Locked row

    func testLockedExplanationNamesTheProductAndTheRefusal() {
        let text = SyncPane.lockedOffLANExplanation
        XCTAssertTrue(text.contains("Sentry Pro"))
        // The lapse disclosure: the refusal happens even with the pairing
        // code — i.e. even with Remote Access already enabled — and the
        // sentence says so rather than leaving enforcement silent.
        XCTAssertTrue(text.localizedCaseInsensitiveContains("turns away"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("pairing code"))
        // The free half is stated too — withheld is the off-LAN grant, not
        // the pairing surface.
        XCTAssertTrue(text.localizedCaseInsensitiveContains("free"))
    }

    /// Same admission, same words, as `FanControlPane`'s locked state: no
    /// checkout exists, so no copy anywhere may imply a Buy button could.
    func testPurchaseNoticeAdmitsCheckoutDoesNotExist() {
        let text = SyncPane.lockedPurchaseNotice
        XCTAssertTrue(text.localizedCaseInsensitiveContains("isn't available"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("buy now"))
    }

    // MARK: - Footer

    func testUnlockedFootersKeepThePreGatePromises() {
        let enabled = SyncPane.remoteAccessFooter(enabled: true, isProUnlocked: true)
        let disabled = SyncPane.remoteAccessFooter(enabled: false, isProUnlocked: true)

        // The unlocked surface is unchanged by the gate — including the
        // reachability guidance that is only honest to show someone whose
        // Mac will actually answer.
        XCTAssertTrue(enabled.contains("Tailscale"))
        XCTAssertTrue(enabled.localizedCaseInsensitiveContains("forward the port"))
        XCTAssertTrue(disabled.localizedCaseInsensitiveContains("isn't on this Wi-Fi"))
    }

    func testLockedFootersNeverCoachOffLANReachability() {
        for enabled in [true, false] {
            let text = SyncPane.remoteAccessFooter(enabled: enabled, isProUnlocked: false)
            XCTAssertFalse(text.isEmpty)
            // Coaching a locked user through Tailscale or a port-forward
            // would walk them into a connection this Mac then refuses.
            XCTAssertFalse(
                text.contains("Tailscale"),
                "locked footer (enabled: \(enabled)) must not coach a tunnel setup"
            )
            XCTAssertFalse(
                text.localizedCaseInsensitiveContains("forward the port"),
                "locked footer (enabled: \(enabled)) must not coach a port-forward"
            )
            // And both locked variants say why, by name.
            XCTAssertTrue(
                text.contains("Sentry Pro"),
                "locked footer (enabled: \(enabled)) must name Sentry Pro"
            )
        }
    }

    /// The lapsed shape specifically: Remote Access on, entitlement off.
    /// The footer for that exact state must disclose the narrowed scope —
    /// this is the "with clear disclosure, never silent" half of the lapse
    /// behavior, paired with `LocalSyncServer`'s accept-time refusal.
    func testLapsedFooterDisclosesTheThisNetworkOnlyScope() {
        let text = SyncPane.remoteAccessFooter(enabled: true, isProUnlocked: false)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("only answers devices on this network"))
        // Pairing instructions stay — the QR and code remain real and free.
        XCTAssertTrue(text.localizedCaseInsensitiveContains("scan the QR code"))
    }

    func testEveryFooterVariantIsNonEmptyAndDistinct() {
        let variants = [
            SyncPane.remoteAccessFooter(enabled: true, isProUnlocked: true),
            SyncPane.remoteAccessFooter(enabled: false, isProUnlocked: true),
            SyncPane.remoteAccessFooter(enabled: true, isProUnlocked: false),
            SyncPane.remoteAccessFooter(enabled: false, isProUnlocked: false),
        ]
        for text in variants {
            XCTAssertFalse(text.isEmpty)
        }
        XCTAssertEqual(Set(variants).count, variants.count, "each state earns its own sentence")
    }
}
