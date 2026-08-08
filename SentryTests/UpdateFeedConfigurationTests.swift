import XCTest
@testable import SentryKit

/// The gate that decides whether Sentry is allowed to have an updater at all.
///
/// Sentry ships outside the Mac App Store, so Sparkle is the only channel an
/// installed copy will ever have — and every way this configuration can be
/// wrong fails *quietly*. A placeholder signing key doesn't produce an error
/// dialog; it produces "You're up to date!" for a user who isn't. These tests
/// exist so that the decision to build no updater at all (see
/// `UpdateController`) is driven by logic that is verified on every run
/// rather than by a boolean somebody remembers to flip.
final class UpdateFeedConfigurationTests: XCTestCase {

    private let validFeed = "https://malekthecoder.github.io/Sentry/appcast.xml"

    /// A well-formed Ed25519 public key as Sparkle stores it: base64 of
    /// exactly 32 bytes. Content is irrelevant — only the shape is checked
    /// here, because whether it's the *right* key is unknowable without the
    /// signature it's meant to verify.
    private let validKey = Data(repeating: 0x2A, count: 32).base64EncodedString()

    // MARK: - The happy path

    func testWellFormedFeedAndKeyIsReady() {
        let config = UpdateFeedConfiguration(feedURLString: validFeed, publicKeyString: validKey)
        XCTAssertEqual(config.availability, .ready(feedURL: URL(string: validFeed)!))
        XCTAssertTrue(config.availability.canCheckForUpdates)
    }

    func testSurroundingWhitespaceIsToleratedInBothValues() {
        // A pasted key or URL routinely arrives with a trailing newline; that
        // is a formatting artifact, not a misconfiguration, and refusing it
        // would send someone hunting for a bug that isn't there.
        let config = UpdateFeedConfiguration(
            feedURLString: "  \(validFeed)\n",
            publicKeyString: "\n\(validKey)  "
        )
        XCTAssertEqual(config.availability, .ready(feedURL: URL(string: validFeed)!))
    }

    // MARK: - The state this build actually ships in

    func testPlaceholderKeyIsCalledOutAsAPlaceholder() {
        let config = UpdateFeedConfiguration(
            feedURLString: validFeed,
            publicKeyString: UpdateFeedConfiguration.placeholderPublicKey
        )
        // Distinct from `.publicKeyMalformed`: "you haven't generated the key
        // pair yet" and "this key is corrupt" have different owners and
        // different fixes, and collapsing them would make the on-screen
        // explanation useless to both.
        XCTAssertEqual(config.availability, .publicKeyPlaceholder)
        XCTAssertFalse(config.availability.canCheckForUpdates)
    }

    /// The placeholder must never accidentally be a *valid-looking* key —
    /// if it were base64 of 32 bytes, a forgotten replacement would sail
    /// through as `.ready` and ship an app that can verify nothing.
    func testPlaceholderIsNotItselfAWellFormedKey() {
        let placeholder = UpdateFeedConfiguration.placeholderPublicKey
        let decoded = Data(base64Encoded: placeholder)
        XCTAssertTrue(
            decoded == nil || decoded!.count != UpdateFeedConfiguration.publicKeyByteCount,
            "The placeholder decodes to a plausible Ed25519 key, so forgetting to replace it would look like a working configuration"
        )
    }

    // MARK: - Key failures

    func testMissingKeyIsNotReady() {
        XCTAssertEqual(
            UpdateFeedConfiguration(feedURLString: validFeed, publicKeyString: nil).availability,
            .publicKeyMissing
        )
        XCTAssertEqual(
            UpdateFeedConfiguration(feedURLString: validFeed, publicKeyString: "   ").availability,
            .publicKeyMissing
        )
    }

    func testNonBase64KeyIsMalformed() {
        let config = UpdateFeedConfiguration(feedURLString: validFeed, publicKeyString: "not base64!!!")
        guard case .publicKeyMalformed = config.availability else {
            return XCTFail("Expected .publicKeyMalformed, got \(config.availability)")
        }
    }

    func testTruncatedKeyIsMalformedRatherThanAccepted() {
        // The realistic corruption: a copy-paste that clipped the end. It is
        // still valid base64, so only the byte count catches it.
        let short = Data(repeating: 0x2A, count: 31).base64EncodedString()
        guard case .publicKeyMalformed = UpdateFeedConfiguration(feedURLString: validFeed, publicKeyString: short).availability else {
            return XCTFail("A 31-byte key was accepted; Ed25519 public keys are exactly 32 bytes")
        }

        let long = Data(repeating: 0x2A, count: 33).base64EncodedString()
        guard case .publicKeyMalformed = UpdateFeedConfiguration(feedURLString: validFeed, publicKeyString: long).availability else {
            return XCTFail("A 33-byte key was accepted; Ed25519 public keys are exactly 32 bytes")
        }
    }

    // MARK: - Feed failures

    func testMissingFeedIsNotReady() {
        XCTAssertEqual(
            UpdateFeedConfiguration(feedURLString: nil, publicKeyString: validKey).availability,
            .feedURLMissing
        )
        XCTAssertEqual(
            UpdateFeedConfiguration(feedURLString: "  ", publicKeyString: validKey).availability,
            .feedURLMissing
        )
    }

    func testHostlessFeedIsMalformed() {
        XCTAssertEqual(
            UpdateFeedConfiguration(feedURLString: "appcast.xml", publicKeyString: validKey).availability,
            .feedURLMalformed("appcast.xml")
        )
    }

    /// Plaintext is refused, not tolerated. The EdDSA signature protects the
    /// downloaded payload, but the appcast itself is what says *which*
    /// payload to fetch — over HTTP, a network attacker can serve a
    /// genuinely-signed older build (a downgrade) or an endless "nothing
    /// new," and both survive signature verification untouched.
    func testPlaintextFeedIsRefused() {
        let insecure = "http://malekthecoder.github.io/Sentry/appcast.xml"
        XCTAssertEqual(
            UpdateFeedConfiguration(feedURLString: insecure, publicKeyString: validKey).availability,
            .feedURLInsecure(insecure)
        )
    }

    func testHTTPSSchemeIsMatchedCaseInsensitively() {
        let shouty = "HTTPS://malekthecoder.github.io/Sentry/appcast.xml"
        XCTAssertTrue(
            UpdateFeedConfiguration(feedURLString: shouty, publicKeyString: validKey).availability.canCheckForUpdates
        )
    }

    // MARK: - Precedence

    /// Both wrong at once, and only one message fits on screen. The key wins:
    /// a bad feed URL fails *visibly* (a check that errors), whereas a bad key
    /// fails by silently finding nothing — the more dangerous of the two, and
    /// the one worth naming first.
    func testKeyProblemIsReportedBeforeFeedProblem() {
        let config = UpdateFeedConfiguration(
            feedURLString: "http://insecure.example.com/appcast.xml",
            publicKeyString: UpdateFeedConfiguration.placeholderPublicKey
        )
        XCTAssertEqual(config.availability, .publicKeyPlaceholder)
    }

    // MARK: - Every non-ready state must be able to explain itself

    /// The house rule this whole type serves: never ship a control that
    /// silently does nothing. A blocked state with an empty explanation is
    /// the same failure wearing a label.
    func testEveryFailureCarriesAHeadlineAndAnExplanation() {
        let states: [UpdaterAvailability] = [
            .feedURLMissing,
            .feedURLMalformed("appcast.xml"),
            .feedURLInsecure("http://example.com/appcast.xml"),
            .publicKeyMissing,
            .publicKeyPlaceholder,
            .publicKeyMalformed("it isn't valid base64"),
            .startFailed("no such feed")
        ]
        for state in states {
            XCTAssertFalse(state.canCheckForUpdates, "\(state) should block update checks")
            XCTAssertFalse(state.headline.isEmpty, "\(state) has no headline")
            XCTAssertFalse(state.explanation.isEmpty, "\(state) has no explanation")
            // Every blocked state must tell the user what to do instead —
            // "updates are unavailable" with no way forward is a dead end.
            XCTAssertTrue(
                state.explanation.contains("manually"),
                "\(state)'s explanation doesn't offer the manual-download fallback"
            )
        }
    }

    func testReadyStateNamesTheFeedItWillActuallyUse() {
        let config = UpdateFeedConfiguration(feedURLString: validFeed, publicKeyString: validKey)
        XCTAssertTrue(config.availability.explanation.contains(validFeed))
    }

    // MARK: - The shipped bundle

    /// Guards the bug this pass was written to fix. `CFBundleShortVersionString`
    /// and `CFBundleVersion` were hardcoded to "1.0"/"1" in Info.plist while
    /// `project.yml` set a different MARKETING_VERSION — and Sparkle compares
    /// exactly these Info.plist keys, not the build settings, to decide
    /// whether a feed item is newer. Shipped as-is, a "1.0" build would have
    /// judged every 0.x release older than itself and installed nothing,
    /// forever, with no error anywhere. These keys now substitute the build
    /// settings, so this asserts the substitution actually resolved rather
    /// than landing in the bundle as a literal "$(MARKETING_VERSION)".
    ///
    /// **Why this no longer asserts one exact version string.** It used to
    /// end with `XCTAssertEqual(short, "0.1.0")`, and that assertion did the
    /// opposite of its job: bumping MARKETING_VERSION to 1.0.0 for the first
    /// public release turned the suite red, in the release commit itself,
    /// for a version change that was entirely correct. A guard that fails on
    /// every legitimate release is one that gets deleted or ignored, and
    /// either outcome loses the real protection.
    ///
    /// So the assertions below are the ones that stay true across every
    /// future bump while still catching all three ways this can actually
    /// break: the substitution not resolving (a literal `$(...)` in the
    /// bundle), a regression to XcodeGen's "1.0"/"1" defaults, and a version
    /// that is not a plausible MARKETING_VERSION at all. What the version
    /// *is* belongs in project.yml; what this test knows is that the bundle
    /// faithfully reports it.
    func testHostAppReportsASubstitutedMarketingVersion() throws {
        // The test bundle's host is Sentry.app (TEST_HOST/BUNDLE_LOADER in
        // project.yml), so `.main` is the app under test.
        let bundle = Bundle.main
        let short = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let build = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)

        XCTAssertFalse(short.contains("$("), "CFBundleShortVersionString wasn't substituted: \(short)")
        XCTAssertFalse(build.contains("$("), "CFBundleVersion wasn't substituted: \(build)")
        XCTAssertNotEqual(short, "1.0", "CFBundleShortVersionString is back to XcodeGen's default, which does not match MARKETING_VERSION")

        // Three dot-separated numeric components — the shape every
        // MARKETING_VERSION in this project has had, and the shape Sparkle's
        // version comparison expects. This is what "1.0" (XcodeGen's
        // default) fails and what any real release version passes.
        let components = short.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(
            components.count, 3,
            "CFBundleShortVersionString should be a three-component version tracking MARKETING_VERSION, got: \(short)"
        )
        XCTAssertTrue(
            components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) },
            "CFBundleShortVersionString components should all be numeric, got: \(short)"
        )
    }

    /// The two Sparkle keys really are in the shipped bundle, and the app
    /// really is in the honest-refusal state documented in
    /// `UpdateController` — not accidentally `.ready` against a key nobody
    /// holds the private half of.
    func testHostAppCarriesTheSparkleKeysAndIsHonestlyBlocked() {
        let config = UpdateFeedConfiguration(bundle: .main)
        XCTAssertEqual(config.feedURLString, "https://malekthecoder.github.io/Sentry/appcast.xml")
        XCTAssertEqual(config.publicKeyString, UpdateFeedConfiguration.placeholderPublicKey)
        XCTAssertEqual(
            config.availability,
            .publicKeyPlaceholder,
            "Replace this expectation with `.ready` in the same commit that pastes the real SUPublicEDKey — see docs/sparkle-release-signing.md"
        )
    }
}
