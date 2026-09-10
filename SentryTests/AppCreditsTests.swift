import XCTest
@testable import SentryKit

/// `AppCredits` is the single source both About screens read, so the things
/// worth testing are the ones a human would get wrong twice: the version
/// string's edge cases, and the invariants that keep the credit itself
/// honest (both authors named, every acknowledgement complete).
final class AppCreditsTests: XCTestCase {

    // MARK: - Version formatting

    func testVersionSummaryShowsBuildWhenItDiffersFromMarketingVersion() {
        XCTAssertEqual(
            AppCredits.versionSummary(shortVersion: "0.1.0", build: "42"),
            "Version 0.1.0 (42)"
        )
    }

    /// A build number identical to the marketing version carries no
    /// information — "Version 1.0 (1.0)" is noise, not detail.
    func testVersionSummaryOmitsRedundantBuild() {
        XCTAssertEqual(
            AppCredits.versionSummary(shortVersion: "1.0", build: "1.0"),
            "Version 1.0"
        )
    }

    func testVersionSummaryOmitsMissingOrBlankBuild() {
        XCTAssertEqual(AppCredits.versionSummary(shortVersion: "2.3.1", build: nil), "Version 2.3.1")
        XCTAssertEqual(AppCredits.versionSummary(shortVersion: "2.3.1", build: "   "), "Version 2.3.1")
    }

    /// A bundle can legitimately carry `CFBundleVersion` and nothing else
    /// (some appex and tool bundles do), so this degrades to the build
    /// number rather than to an empty "Version ".
    func testVersionSummaryFallsBackToBuildAloneWhenMarketingVersionIsMissing() {
        XCTAssertEqual(AppCredits.versionSummary(shortVersion: nil, build: "77"), "Build 77")
        XCTAssertEqual(AppCredits.versionSummary(shortVersion: "", build: "77"), "Build 77")
    }

    /// The genuinely broken case says so in words. It must never render as
    /// "Version " or "Version nil" — both read as a bug in the app rather
    /// than a bug in the bundle.
    func testVersionSummaryReportsUnavailableWhenBundleHasNoVersionAtAll() {
        XCTAssertEqual(AppCredits.versionSummary(shortVersion: nil, build: nil), "Version unavailable")
    }

    func testVersionSummaryTrimsSurroundingWhitespace() {
        XCTAssertEqual(
            AppCredits.versionSummary(shortVersion: " 0.1.0 ", build: " 9 "),
            "Version 0.1.0 (9)"
        )
    }

    // MARK: - Attribution invariants

    /// The bug this whole change exists to fix was a shipped copyright
    /// string naming one of two authors. Asserting both names appear stops
    /// it from regressing through a careless edit to `contributors`.
    func testCopyrightNamesEveryContributor() {
        XCTAssertEqual(AppCredits.contributors.count, 2)
        for name in AppCredits.contributors {
            XCTAssertTrue(
                AppCredits.copyright.contains(name),
                "copyright line must name \(name)"
            )
        }
        XCTAssertTrue(AppCredits.copyright.contains(AppCredits.copyrightYear))
        XCTAssertTrue(AppCredits.copyright.contains("All rights reserved"))
    }

    // MARK: - Acknowledgements

    /// Every field is displayed verbatim on both About screens, so a blank
    /// one ships as a blank line in a legal notice.
    func testEveryThirdPartyComponentIsFullyPopulated() {
        XCTAssertFalse(AppCredits.thirdPartyComponents.isEmpty)
        for component in AppCredits.thirdPartyComponents {
            XCTAssertFalse(component.name.isEmpty)
            XCTAssertFalse(component.version.isEmpty, "\(component.name) has no version")
            XCTAssertFalse(component.license.isEmpty, "\(component.name) has no license")
            XCTAssertFalse(component.copyright.isEmpty, "\(component.name) has no copyright line")
            XCTAssertNotNil(URL(string: component.url), "\(component.name) has an unusable URL")
        }
    }

    func testThirdPartyComponentNamesAreUnique() {
        let names = AppCredits.thirdPartyComponents.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }

    /// GRDB is the only package `SentryKit_iOS` links (`project.yml`), so it
    /// must be the whole iPhone acknowledgement list. If a second package is
    /// ever added to that target, this failing test is the reminder that the
    /// iPhone About screen's list has to change with it.
    func testIOSAcknowledgementsAreExactlyGRDB() {
        XCTAssertEqual(AppCredits.iOSThirdPartyComponents.map(\.name), ["GRDB.swift"])
    }

    /// The placeholder is allowed to be unpublished; it is not allowed to be
    /// malformed, because both About screens build a `Link` from it and a
    /// nil URL would silently drop the row.
    func testPrivacyPolicyURLParses() {
        XCTAssertNotNil(AppCredits.privacyPolicyURL)
    }

    /// Same contract as the privacy-policy link: the iPhone About screen
    /// builds a `Link` from it, and a nil URL would silently drop the row
    /// pointing at the published `docs/third-party-licenses.md`.
    func testThirdPartyLicensesURLParses() {
        XCTAssertNotNil(AppCredits.thirdPartyLicensesURL)
    }

    /// Same contract again — `AboutView` and the onboarding's companion-role
    /// card both build a `Link` from it — and until now the one URL here
    /// with no test.
    func testMacAppDownloadURLParses() {
        XCTAssertNotNil(AppCredits.macAppDownloadURL)
    }

    /// The support address is compiled into the app *and* typed by hand into
    /// App Store Connect's Support URL field, so beyond parsing it has to
    /// round-trip byte-for-byte: `URL` normalising the literal (a trailing
    /// slash, an added `.html`) would leave the shipped link and the ASC
    /// field disagreeing with nothing to say so. The literal is repeated
    /// here on purpose — changing the published path is the kind of edit
    /// that should have to be made twice.
    func testSupportURLParsesAndMatchesPinnedString() {
        let url = AppCredits.supportURL
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.absoluteString, AppCredits.supportURLString)
        XCTAssertEqual(AppCredits.supportURLString, "https://malekthecoder.github.io/Sentry/support")
    }

    // MARK: - Sentry Pro checkout (honest gating)

    /// The placeholder must never be offered as a link. It is deliberately
    /// not a URL at all, so that forgetting to replace it renders the
    /// not-on-sale state rather than a Buy button that opens nothing.
    func testProCheckoutPlaceholderIsNeverOfferedAsAURL() {
        let placeholder = AppCredits.placeholderProCheckoutURLString
        XCTAssertNil(AppCredits.checkoutURL(from: placeholder))
        XCTAssertNotEqual(URL(string: placeholder)?.scheme?.lowercased(), "https",
                          "the placeholder parses as an HTTPS URL, so forgetting to replace it would look like a working checkout")
    }

    func testProCheckoutGateAcceptsOnlyHTTPSWithAHost() {
        XCTAssertEqual(
            AppCredits.checkoutURL(from: "https://sentry.example-vendor.com/checkout/pro")?.absoluteString,
            "https://sentry.example-vendor.com/checkout/pro"
        )
        // A pasted address arrives with whitespace; that's formatting, not
        // misconfiguration.
        XCTAssertNotNil(AppCredits.checkoutURL(from: "  https://sentry.example-vendor.com/checkout/pro\n"))
        XCTAssertNotNil(AppCredits.checkoutURL(from: "HTTPS://sentry.example-vendor.com/checkout"))

        // A checkout collects payment details: plaintext is refused, not
        // tolerated.
        XCTAssertNil(AppCredits.checkoutURL(from: "http://sentry.example-vendor.com/checkout/pro"))
        XCTAssertNil(AppCredits.checkoutURL(from: "https://"))
        XCTAssertNil(AppCredits.checkoutURL(from: "checkout/pro"))
        XCTAssertNil(AppCredits.checkoutURL(from: ""))
        XCTAssertNil(AppCredits.checkoutURL(from: "   "))
    }

    /// The invariant that stays true across go-live: the shipped constant
    /// is either exactly the placeholder or a usable HTTPS address — never
    /// a half-edited string that gates to nothing while looking filled in.
    func testShippedProCheckoutConstantIsThePlaceholderOrALiveHTTPSAddress() {
        if AppCredits.proCheckoutURLString == AppCredits.placeholderProCheckoutURLString {
            XCTAssertNil(AppCredits.proCheckoutURL)
        } else {
            XCTAssertNotNil(AppCredits.proCheckoutURL, "proCheckoutURLString was edited to something the gate refuses")
        }
    }
}
