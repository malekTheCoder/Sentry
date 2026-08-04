import XCTest
@testable import SentryKit

/// Covers `AppSettings.hasSeenWelcome`'s persistence contract (see that
/// property's doc comment, and `Sentry/Onboarding/OnboardingCoordinator.swift`
/// which is the only thing that ever sets it `true`): default `false`,
/// settable, and — the actually load-bearing part — a settings file written
/// before the flag existed must upgrade to `false`, not throw and not
/// silently opt an existing install out of ever seeing the welcome popover.
/// Same stakes and same shape as `AlertRuleSettingsTests`/
/// `FanControlSettingsTests` for their respective additive keys.
@MainActor
final class WelcomeOnboardingSettingsTests: XCTestCase {

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    // MARK: - Default

    func testShippedDefaultIsFalse() {
        XCTAssertFalse(AppSettings.default.hasSeenWelcome)
        XCTAssertFalse(AppSettings().hasSeenWelcome)
    }

    // MARK: - Additive decoding

    func testSettingsFileWithoutHasSeenWelcomeDecodesToFalse() throws {
        // A settings file written by any build from before the welcome
        // popover existed — must upgrade to "hasn't seen it," which is the
        // honest answer for a build that never had a welcome popover to see.
        let settings = try decode(#"{"themeID":"terminal"}"#)
        XCTAssertFalse(settings.hasSeenWelcome)
    }

    func testEveryOtherSettingStillDecodesAlongsideTheNewKey() throws {
        let settings = try decode(#"{"themeID":"terminal","mcpRemotePort":9000,"alertRules":[]}"#)
        XCTAssertEqual(settings.themeID, "terminal")
        XCTAssertEqual(settings.mcpRemotePort, 9000)
        XCTAssertTrue(settings.alertRules.isEmpty)
        XCTAssertFalse(settings.hasSeenWelcome)
    }

    func testExplicitTrueInAFileDecodesAsTrue() throws {
        let settings = try decode(#"{"hasSeenWelcome":true}"#)
        XCTAssertTrue(settings.hasSeenWelcome)
    }

    // MARK: - Settable, round-trips

    func testFlagIsSettableAndSurvivesAnEncodeDecodeRoundTrip() throws {
        var settings = AppSettings()
        XCTAssertFalse(settings.hasSeenWelcome)

        settings.hasSeenWelcome = true

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(restored.hasSeenWelcome)
    }

    func testTogglingTheFlagChangesEquality() {
        // `SettingsStore` writes to disk on `settings != oldValue` — this
        // flag has to actually participate in `Equatable`, not be a field
        // that's silently ignored by a stale synthesized conformance.
        var a = AppSettings()
        var b = AppSettings()
        XCTAssertEqual(a, b)

        b.hasSeenWelcome = true
        XCTAssertNotEqual(a, b)

        a.hasSeenWelcome = true
        XCTAssertEqual(a, b)
    }
}
