import XCTest
@testable import SentryKit

/// Persistence for the fan-control block (plan §5.2, §12's "persisted mode
/// restoration").
///
/// Same stakes as `AlertRuleSettingsTests`: getting this wrong doesn't
/// produce a visible bug, it produces a user whose carefully composed curve
/// quietly evaporated after an update — or, worse in this direction, an
/// upgrading install that silently acquired a non-`auto` fan mode it never
/// asked for.
@MainActor
final class FanControlSettingsTests: XCTestCase {

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    // MARK: - Additive decoding

    func testSettingsFileWithoutFanControlDecodesToAnInertDefault() throws {
        // A settings file written by any build from before the fan-control
        // shell existed. The fallback must be fully inert: an upgrading
        // install has not opted into a thermal feature.
        let settings = try decode(#"{"themeID":"terminal"}"#)

        XCTAssertEqual(settings.fanControl.defaultPolicy.mode, .auto)
        XCTAssertFalse(settings.fanControl.controlEnabledOnLaunch)
        XCTAssertTrue(settings.fanControl.restoreAutoOnLaunch)
        XCTAssertTrue(settings.fanControl.perFanOverrides.isEmpty)
    }

    func testEveryOtherSettingStillDecodesAlongsideTheNewKey() throws {
        // The whole point of the additive pattern: adding `fanControl`
        // must not have disturbed anything already in the file.
        let settings = try decode(#"{"themeID":"terminal","mcpRemotePort":9000,"alertRules":[]}"#)
        XCTAssertEqual(settings.themeID, "terminal")
        XCTAssertEqual(settings.mcpRemotePort, 9000)
        XCTAssertTrue(settings.alertRules.isEmpty)
        XCTAssertEqual(settings.fanControl, FanControlSettings())
    }

    func testPartialFanControlBlockFillsTheRestFromDefaults() throws {
        // A block written by a build that had fewer fields than today's.
        let settings = try decode(#"{"fanControl":{"controlEnabledOnLaunch":true}}"#)
        XCTAssertTrue(settings.fanControl.controlEnabledOnLaunch)
        XCTAssertEqual(settings.fanControl.defaultPolicy.mode, .auto)
        XCTAssertEqual(
            settings.fanControl.defaultPolicy.curve,
            FanControlPolicy.defaultCurve
        )
    }

    func testPartialPolicyFillsTheRestFromDefaults() throws {
        let settings = try decode(#"{"fanControl":{"defaultPolicy":{"mode":"hybrid"}}}"#)
        XCTAssertEqual(settings.fanControl.defaultPolicy.mode, .hybrid)
        XCTAssertEqual(settings.fanControl.defaultPolicy.safetyCeilingCelsius, 95)
        XCTAssertEqual(settings.fanControl.defaultPolicy.hysteresisCelsius, 3)
        // Genuinely optional values stay absent rather than being filled in
        // with a number nobody chose.
        XCTAssertNil(settings.fanControl.defaultPolicy.manualTargetRPM)
        XCTAssertNil(settings.fanControl.defaultPolicy.sensorName)
    }

    // MARK: - Mode restoration (plan §12)

    func testPersistedModeAndCurveSurviveARoundTrip() throws {
        var settings = AppSettings()
        settings.fanControl.defaultPolicy.mode = .hybrid
        settings.fanControl.defaultPolicy.manualTargetRPM = 3400
        settings.fanControl.defaultPolicy.sensorName = "PMU tdev1"
        settings.fanControl.defaultPolicy.safetyCeilingCelsius = 92
        settings.fanControl.defaultPolicy.hysteresisCelsius = 5
        settings.fanControl.defaultPolicy.curve = FanCurve(points: [
            FanCurvePoint(celsius: 55, rpm: 1500),
            FanCurvePoint(celsius: 88, rpm: 5200),
        ])
        settings.fanControl.controlEnabledOnLaunch = true

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(restored.fanControl, settings.fanControl)
        XCTAssertEqual(restored.fanControl.defaultPolicy.mode, .hybrid)
        XCTAssertEqual(restored.fanControl.defaultPolicy.sensorName, "PMU tdev1")
        XCTAssertEqual(restored.fanControl.defaultPolicy.curve.points.count, 2)
    }

    func testCurveDecodedFromAHandEditedFileIsStillSorted() throws {
        // Synthesized `Codable` would assign `points` verbatim and hand
        // `targetRPM(atCelsius:)` an unsorted array. `FanCurve.init(from:)`
        // routes through the sorting initializer instead.
        let settings = try decode("""
        {"fanControl":{"defaultPolicy":{"curve":{"points":[
          {"celsius":95,"rpm":6000},{"celsius":50,"rpm":1200},{"celsius":70,"rpm":2000}]}}}}
        """)
        XCTAssertEqual(settings.fanControl.defaultPolicy.curve.points.map(\.celsius), [50, 70, 95])
        XCTAssertEqual(
            settings.fanControl.defaultPolicy.curve.targetRPM(atCelsius: 60) ?? -1,
            1600,
            accuracy: 0.0001
        )
    }

    // MARK: - Per-fan overrides

    func testPerFanOverrideWinsOverTheDefaultPolicy() {
        var fanControl = FanControlSettings()
        fanControl.defaultPolicy.mode = .auto
        fanControl.setPolicy(FanControlPolicy(mode: .manual, manualTargetRPM: 2500), forFan: 1)

        XCTAssertEqual(fanControl.policy(forFan: 0).mode, .auto)
        XCTAssertEqual(fanControl.policy(forFan: 1).mode, .manual)
        XCTAssertEqual(fanControl.policy(forFan: 1).manualTargetRPM, 2500)
    }

    func testSettingAnOverrideTwiceReplacesRatherThanAccumulates() {
        var fanControl = FanControlSettings()
        fanControl.setPolicy(FanControlPolicy(mode: .manual), forFan: 0)
        fanControl.setPolicy(FanControlPolicy(mode: .hybrid), forFan: 0)

        XCTAssertEqual(fanControl.perFanOverrides.count, 1)
        XCTAssertEqual(fanControl.policy(forFan: 0).mode, .hybrid)
    }

    func testClearingAnOverrideFallsBackToTheDefault() {
        var fanControl = FanControlSettings()
        fanControl.defaultPolicy.mode = .sensorCurve
        fanControl.setPolicy(FanControlPolicy(mode: .manual), forFan: 0)
        fanControl.clearPolicy(forFan: 0)

        XCTAssertTrue(fanControl.perFanOverrides.isEmpty)
        XCTAssertEqual(fanControl.policy(forFan: 0).mode, .sensorCurve)
    }

    func testPerFanOverridesRoundTripAsAReadableArray() throws {
        var settings = AppSettings()
        settings.fanControl.setPolicy(FanControlPolicy(mode: .manual, manualTargetRPM: 2000), forFan: 1)

        let data = try JSONEncoder().encode(settings.fanControl)
        // Not a `[Int: Policy]` dictionary, which `Codable` would flatten
        // into an alternating-pairs array — a hostile shape in a file a
        // user might open.
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"fanIndex\""), json)

        let restored = try JSONDecoder().decode(FanControlSettings.self, from: data)
        XCTAssertEqual(restored.policy(forFan: 1).manualTargetRPM, 2000)
    }

    func testDuplicateOverrideInAHandEditedFileResolvesRatherThanCrashing() throws {
        let restored = try JSONDecoder().decode(FanControlSettings.self, from: Data("""
        {"perFanOverrides":[
          {"fanIndex":0,"policy":{"mode":"manual"}},
          {"fanIndex":0,"policy":{"mode":"hybrid"}}]}
        """.utf8))
        XCTAssertEqual(restored.policy(forFan: 0).mode, .manual)
    }

    // MARK: - Defaults are inert

    func testShippedDefaultsChangeNothingAboutFanBehaviour() {
        let defaults = AppSettings.default.fanControl
        XCTAssertEqual(defaults.defaultPolicy.mode, .auto)
        XCTAssertFalse(defaults.controlEnabledOnLaunch)
        // Plan §8's "if state is ambiguous, default to Auto", persisted now
        // so Phase 3's startup recovery has a setting to obey.
        XCTAssertTrue(defaults.restoreAutoOnLaunch)
    }
}
