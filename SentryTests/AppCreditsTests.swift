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
}
