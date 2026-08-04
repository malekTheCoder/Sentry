import XCTest
@testable import SentryKit

/// Covers the one piece of genuinely load-bearing pure logic added alongside
/// the alerts UI: `AppSettings`' forward-compatible decode of the new
/// `alertRules` key. Getting this wrong doesn't produce a visible bug — it
/// produces a user whose alerts quietly stopped existing after an update,
/// which is precisely the failure mode `AppSettings`' hand-written
/// `init(from:)` exists to prevent.
@MainActor
final class AlertRuleSettingsTests: XCTestCase {

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    // MARK: - Missing key → shipped defaults, never empty

    func testSettingsFileWithoutAlertRulesDecodesToDefaultRules() throws {
        // A settings file written by a build from before alert rules existed.
        let settings = try decode(#"{"themeID":"terminal","alertCooldownMinutes":30}"#)

        XCTAssertEqual(settings.alertRules.count, 14)
        XCTAssertEqual(settings.alertRules, AppSettings.defaultAlertRules)
        XCTAssertFalse(
            settings.alertRules.isEmpty,
            "an upgrading install must not silently end up with zero alert rules"
        )
    }

    func testSettingsFileWithoutAlertRulesKeepsTheSpecialCasedRuleIDs() throws {
        let settings = try decode("{}")
        let ids = Set(settings.alertRules.map(\.id))

        // These three IDs are how `AlertEngine` routes to its special-cased
        // evaluators; a default set that lost them would leave the rules
        // present but silently evaluated as their placeholder comparisons.
        XCTAssertTrue(ids.contains(AlertEngine.chargingPausedRuleID))
        XCTAssertTrue(ids.contains(AlertEngine.slowChargingRuleID))
        XCTAssertTrue(ids.contains(AlertEngine.batteryHealthDropRuleID))
    }

    // MARK: - Explicit empty is honored, not "repaired"

    func testExplicitlyEmptyAlertRulesDecodesAsEmpty() throws {
        // Distinct from the missing-key case above: this is a user who
        // removed every rule in AlertsPane, and re-adding the defaults under
        // them on next launch would be the app overruling a deliberate edit.
        let settings = try decode(#"{"alertRules":[]}"#)
        XCTAssertTrue(settings.alertRules.isEmpty)
    }

    // MARK: - Round trip

    func testEditedRulesSurviveAnEncodeDecodeRoundTrip() throws {
        var settings = AppSettings()
        var edited = settings.alertRules[0]
        edited.name = "Renamed"
        edited.isEnabled = false
        edited.threshold = 42
        edited.sustainedFor = 15
        edited.cooldown = 900
        edited.quietHours = AlertRule.QuietHours(startHour: 23, endHour: 8)
        edited.onlyWhen = [.charging]
        settings.alertRules[0] = edited

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.alertRules, settings.alertRules)
        XCTAssertEqual(decoded.alertRules[0].quietHours?.startHour, 23)
        XCTAssertEqual(decoded.alertRules[0].onlyWhen, [.charging])
        XCTAssertEqual(decoded, settings)
    }

    // MARK: - alertPersistedState (verified-bug pass: AlertEngine persistence)

    func testSettingsFileWithoutAlertPersistedStateDefaultsToEmpty() throws {
        // A settings file written before this key existed must decode to
        // "nothing has fired yet" — the same state such an install was
        // already implicitly in.
        let settings = try decode("{}")
        XCTAssertEqual(settings.alertPersistedState, AlertEnginePersistedState())
    }

    func testAlertPersistedStateSurvivesAnEncodeDecodeRoundTrip() throws {
        var settings = AppSettings()
        let ruleID = settings.alertRules[0].id
        settings.alertPersistedState = AlertEnginePersistedState(
            lastFiredAt: [ruleID.uuidString: Date(timeIntervalSince1970: 1_700_000_000)],
            recentDeliveryTimestamps: [Date(timeIntervalSince1970: 1_700_000_100)],
            batteryHealthBaselinePercent: 87.5,
            batteryHealthBaselineCapturedAt: Date(timeIntervalSince1970: 1_690_000_000)
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.alertPersistedState, settings.alertPersistedState)
        XCTAssertEqual(decoded.alertPersistedState.batteryHealthBaselinePercent, 87.5)
        XCTAssertEqual(decoded.alertPersistedState.lastFiredAt[ruleID.uuidString], Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - Do Not Disturb (plan §11.3 master toggle)

    func testSettingsFileWithoutDoNotDisturbDefaultsToOff() throws {
        // A settings file written before this key existed must not come
        // back up muted — that would be a silent, unexplained loss of every
        // alert on upgrade, the same failure mode `alertRules` itself guards
        // against above.
        let settings = try decode("{}")
        XCTAssertFalse(settings.doNotDisturb)
    }

    func testExplicitDoNotDisturbValueRoundTrips() throws {
        let settings = try decode(#"{"doNotDisturb":true}"#)
        XCTAssertTrue(settings.doNotDisturb)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.doNotDisturb)
    }

    // MARK: - Defaults agree with the cooldown setting

    func testDefaultRuleCooldownMatchesTheDefaultCooldownSetting() {
        let settings = AppSettings()
        let expected = TimeInterval(settings.alertCooldownMinutes * 60)

        // `AlertRule`'s doc comment is explicit that the shipped cooldown
        // must come from this setting rather than a second literal; this
        // guards the two from drifting apart.
        XCTAssertTrue(settings.alertRules.allSatisfy { $0.cooldown == expected })
    }

    func testDefaultAlertRulesIsStableAcrossInstances() {
        // `AlertEngine.defaultRules` mints fresh UUIDs per call, so if
        // `AppSettings.defaultAlertRules` were computed rather than a stored
        // `static let`, two default-constructed settings would compare
        // unequal — and `SettingsStore` writes to disk on exactly that
        // inequality.
        XCTAssertEqual(AppSettings(), AppSettings())
        XCTAssertEqual(AppSettings().alertRules, AppSettings().alertRules)
    }
}
