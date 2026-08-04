import XCTest
@testable import Sentry
@testable import SentryKit

/// Covers the pure, service-free logic behind `Sentry/Intents/SentryMacIntents.swift`:
/// `SentryMacIntentFormatting`'s dialog composition and duration clamping, and
/// `AwakeModeAppEnum`'s mapping onto `AwakeMode`. None of this touches
/// `AppIntents`, `NSApp`, or `SentryMacRuntimeServices` — those need a real,
/// running `AppDelegate` (`NSApp.delegate`) to resolve against, which isn't
/// available in a unit-test host the way it is in the actual app, so the
/// Mirror-based bridge itself is exercised by launching the built app instead
/// (see this task's verification notes), not by an XCTest.
final class SentryMacIntentsTests: XCTestCase {

    // MARK: batteryDialog

    func testBatteryDialogDescribesChargingWithWattage() {
        let battery = BatteryStats(
            chargePercent: 62,
            isCharging: true,
            isPluggedIn: true,
            chargingWatts: 30.4,
            systemPowerInWatts: nil,
            adapterRatedWatts: nil,
            adapterDescription: nil,
            adapterCount: 1
        )
        let dialog = SentryMacIntentFormatting.batteryDialog(battery)
        XCTAssertEqual(dialog, "This Mac's battery is at 62%, charging at 30 watts.")
    }

    func testBatteryDialogDescribesPluggedInNotCharging() {
        let battery = BatteryStats(
            chargePercent: 100,
            isCharging: false,
            isPluggedIn: true,
            chargingWatts: nil,
            systemPowerInWatts: nil,
            adapterRatedWatts: nil,
            adapterDescription: nil,
            adapterCount: 1
        )
        XCTAssertEqual(SentryMacIntentFormatting.batteryDialog(battery), "This Mac's battery is at 100%, plugged in.")
    }

    func testBatteryDialogDescribesOnBattery() {
        let battery = BatteryStats(
            chargePercent: 41,
            isCharging: false,
            isPluggedIn: false,
            chargingWatts: nil,
            systemPowerInWatts: nil,
            adapterRatedWatts: nil,
            adapterDescription: nil,
            adapterCount: 0
        )
        XCTAssertEqual(SentryMacIntentFormatting.batteryDialog(battery), "This Mac's battery is at 41%, on battery.")
    }

    func testBatteryDialogAppendsHealthWhenPresent() {
        var battery = BatteryStats(
            chargePercent: 80,
            isCharging: false,
            isPluggedIn: false,
            chargingWatts: nil,
            systemPowerInWatts: nil,
            adapterRatedWatts: nil,
            adapterDescription: nil,
            adapterCount: 0
        )
        battery.healthPercent = 91.6
        XCTAssertEqual(
            SentryMacIntentFormatting.batteryDialog(battery),
            "This Mac's battery is at 80%, on battery. Battery health is 92%."
        )
    }

    // MARK: thermalDialog

    func testThermalDialogDescribesNominalWithNoExtraClauses() {
        let thermal = ThermalStats(pressureLevel: .nominal, isThrottling: false)
        XCTAssertEqual(SentryMacIntentFormatting.thermalDialog(thermal), "This Mac's thermal pressure is nominal.")
    }

    func testThermalDialogAppendsSoCTemperature() {
        let thermal = ThermalStats(socTemperatureCelsius: 78.4, pressureLevel: .fair, isThrottling: false)
        XCTAssertEqual(
            SentryMacIntentFormatting.thermalDialog(thermal),
            "This Mac's thermal pressure is fair — it's running a bit warm. SoC temperature is 78°C."
        )
    }

    func testThermalDialogFlagsThrottling() {
        let thermal = ThermalStats(socTemperatureCelsius: 99, pressureLevel: .critical, isThrottling: true)
        XCTAssertEqual(
            SentryMacIntentFormatting.thermalDialog(thermal),
            "This Mac's thermal pressure is critical. SoC temperature is 99°C. It's currently throttling performance to cool down."
        )
    }

    func testThermalDialogEveryPressureLevelGetsItsOwnSentence() {
        let levels: [ThermalStats.PressureLevel: String] = [
            .nominal: "This Mac's thermal pressure is nominal.",
            .fair: "This Mac's thermal pressure is fair — it's running a bit warm.",
            .serious: "This Mac's thermal pressure is serious.",
            .critical: "This Mac's thermal pressure is critical.",
        ]
        for (level, expected) in levels {
            let thermal = ThermalStats(pressureLevel: level, isThrottling: false)
            XCTAssertEqual(SentryMacIntentFormatting.thermalDialog(thermal), expected)
        }
    }

    // MARK: keepAwakeDialog / clampedKeepAwakeMinutes

    func testKeepAwakeDialogReportsMinutesWhenPositive() {
        XCTAssertEqual(SentryMacIntentFormatting.keepAwakeDialog(minutes: 90), "This Mac will stay awake for 90 minutes.")
    }

    func testKeepAwakeDialogReportsIndefiniteAtZero() {
        XCTAssertEqual(SentryMacIntentFormatting.keepAwakeDialog(minutes: 0), "This Mac will stay awake until you release it.")
    }

    func testClampedKeepAwakeMinutesFloorsAtZero() {
        XCTAssertEqual(SentryMacIntentFormatting.clampedKeepAwakeMinutes(-30), 0)
    }

    func testClampedKeepAwakeMinutesCapsAtTwentyFourHours() {
        XCTAssertEqual(SentryMacIntentFormatting.clampedKeepAwakeMinutes(10_000), 24 * 60)
    }

    func testClampedKeepAwakeMinutesPassesThroughOrdinaryValues() {
        XCTAssertEqual(SentryMacIntentFormatting.clampedKeepAwakeMinutes(45), 45)
    }

    // MARK: AwakeModeAppEnum mapping

    func testAwakeModeAppEnumMapsEveryCaseToItsCoreMode() {
        XCTAssertEqual(AwakeModeAppEnum.displayAndSystem.coreMode, .displayAndSystem)
        XCTAssertEqual(AwakeModeAppEnum.systemOnly.coreMode, .systemOnly)
        XCTAssertEqual(AwakeModeAppEnum.systemWhileOnAC.coreMode, .systemWhileOnAC)
    }
}
