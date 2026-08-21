import XCTest
@testable import SentryKit

/// Coverage for the Celsius/Fahrenheit *display* preference
/// (`SentryKit/Models/TemperatureUnit.swift`) and everything that formats
/// through it.
///
/// **Two failure modes this file exists to catch**, both of which are silent
/// and both of which have bitten every codebase that has ever added this
/// feature:
///
/// 1. **A delta converted as an absolute.** `ΔC × 9/5 + 32` turns a 4-degree
///    thermal drift into a 39-degree one. The number still looks like a
///    temperature, the app still runs, and the copy now says the Mac is on
///    fire. `testDeltaHasNoOffset` and friends pin this.
/// 2. **A conversion leaking into storage.** Sensors, `HistoryStore`, the
///    sync wire and `AlertRule.threshold` are all Celsius by
///    contract; only strings change. `testAlertRuleThresholdRoundTripsThroughFahrenheitEditing`
///    and `testAppSettingsDecodesWithoutTheKey` guard the two places that
///    could plausibly get this wrong.
///
/// **Nothing here mutates `TemperatureUnit.display` except the two tests
/// that are specifically about it**, which save and restore it. Every other
/// assertion passes the unit explicitly through the `in:` parameter, so the
/// suite is order-independent — see `TemperatureUnit.display`'s doc comment
/// for why that parameter exists.
final class TemperatureUnitTests: XCTestCase {

    // MARK: - Conversion: absolute values

    func testCelsiusIsIdentity() {
        XCTAssertEqual(TemperatureUnit.celsius.value(fromCelsius: 58.4), 58.4, accuracy: 0.0001)
        XCTAssertEqual(TemperatureUnit.celsius.value(fromCelsius: -40), -40, accuracy: 0.0001)
        XCTAssertEqual(TemperatureUnit.celsius.value(fromCelsius: 0), 0, accuracy: 0.0001)
    }

    func testFahrenheitFixedPoints() {
        let f = TemperatureUnit.fahrenheit
        // Freezing, body-ish, boiling, and the one point where the two
        // scales agree — the classic four.
        XCTAssertEqual(f.value(fromCelsius: 0), 32, accuracy: 0.0001)
        XCTAssertEqual(f.value(fromCelsius: 37), 98.6, accuracy: 0.0001)
        XCTAssertEqual(f.value(fromCelsius: 100), 212, accuracy: 0.0001)
        XCTAssertEqual(f.value(fromCelsius: -40), -40, accuracy: 0.0001)
    }

    func testFahrenheitAtTheThresholdsThisAppActuallyUses() {
        let f = TemperatureUnit.fahrenheit
        // `SystemAdvisor.highSoCTempCelsius` and the shipped High
        // Temperature alert rule.
        XCTAssertEqual(f.value(fromCelsius: 95), 203, accuracy: 0.0001)
        // `ThermalHistorySummary.sustainedHeatThreshold`.
        XCTAssertEqual(f.value(fromCelsius: 90), 194, accuracy: 0.0001)
        // `BatteryHistorySummary.hotChargingSoCThreshold`.
        XCTAssertEqual(f.value(fromCelsius: 85), 185, accuracy: 0.0001)
        // `BatteryTemperatureExposureRule.thresholdCelsius`.
        XCTAssertEqual(f.value(fromCelsius: 35), 95, accuracy: 0.0001)
    }

    func testNegativeTemperaturesConvert() {
        let f = TemperatureUnit.fahrenheit
        // A Mac carried in from a cold car. Below freezing must stay below
        // freezing, and must not be clamped to zero anywhere.
        XCTAssertEqual(f.value(fromCelsius: -10), 14, accuracy: 0.0001)
        XCTAssertEqual(f.value(fromCelsius: -0.5), 31.1, accuracy: 0.0001)
        XCTAssertLessThan(f.value(fromCelsius: -0.1), 32)
    }

    func testNonFiniteInputIsPassedThroughRatherThanMangled() {
        XCTAssertTrue(TemperatureUnit.fahrenheit.value(fromCelsius: .nan).isNaN)
        XCTAssertEqual(TemperatureUnit.fahrenheit.value(fromCelsius: .infinity), .infinity)
    }

    // MARK: - Conversion: deltas

    func testDeltaHasNoOffset() {
        let f = TemperatureUnit.fahrenheit
        // The whole point: a 4 °C rise is a 7.2 °F rise, not 39.2 °F.
        XCTAssertEqual(f.delta(fromCelsius: 4), 7.2, accuracy: 0.0001)
        XCTAssertEqual(f.delta(fromCelsius: 8), 14.4, accuracy: 0.0001)
        XCTAssertNotEqual(f.delta(fromCelsius: 4), f.value(fromCelsius: 4), accuracy: 0.0001)
    }

    func testZeroDeltaIsZeroInBothUnits() {
        // The single clearest way to state the difference between the two
        // conversions: no change is no change, in any unit. The absolute
        // conversion of 0 is 32.
        XCTAssertEqual(TemperatureUnit.fahrenheit.delta(fromCelsius: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(TemperatureUnit.celsius.delta(fromCelsius: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(TemperatureUnit.fahrenheit.value(fromCelsius: 0), 32, accuracy: 0.0001)
    }

    func testNegativeDeltaStaysNegative() {
        XCTAssertEqual(TemperatureUnit.fahrenheit.delta(fromCelsius: -5), -9, accuracy: 0.0001)
    }

    // MARK: - Inverse conversion (the threshold editor's write path)

    func testCelsiusValueFromIsTheInverseOfValueFromCelsius() {
        for celsius in stride(from: -40.0, through: 120.0, by: 6.5) {
            let asFahrenheit = TemperatureUnit.fahrenheit.value(fromCelsius: celsius)
            XCTAssertEqual(
                TemperatureUnit.fahrenheit.celsiusValue(from: asFahrenheit),
                celsius,
                accuracy: 0.0001,
                "round trip failed at \(celsius) °C"
            )
        }
    }

    func testCelsiusValueFromIsIdentityForCelsius() {
        XCTAssertEqual(TemperatureUnit.celsius.celsiusValue(from: 95), 95, accuracy: 0.0001)
    }

    // MARK: - Suffixes and names

    func testSuffixes() {
        XCTAssertEqual(TemperatureUnit.celsius.suffix, "°C")
        XCTAssertEqual(TemperatureUnit.fahrenheit.suffix, "°F")
    }

    func testSpokenSuffixNamesTheScale() {
        // A VoiceOver user hearing "58 degrees" cannot tell which scale it
        // is; both must be named.
        XCTAssertTrue(TemperatureUnit.celsius.spokenSuffix.contains("Celsius"))
        XCTAssertTrue(TemperatureUnit.fahrenheit.spokenSuffix.contains("Fahrenheit"))
    }

    func testStaticMetricUnitSuffixIsUnaffectedByTheDisplayPreference() {
        // `MetricUnit.suffix` describes the unit a *stored* value is in and
        // must never follow a display preference — `CLIDuration` parses
        // against it and `HistoryExport` labels exported columns from
        // `MetricUnit`. Asserted with the ambient unit flipped, because a
        // future refactor making it dynamic would otherwise pass silently.
        let saved = TemperatureUnit.display
        defer { TemperatureUnit.display = saved }
        TemperatureUnit.display = .fahrenheit
        XCTAssertEqual(MetricUnit.celsius.suffix, "°C")
    }

    // MARK: - Formatting: styles

    func testStyleShapesInCelsius() {
        XCTAssertEqual(TemperatureFormatter.string(celsius: 58.4, style: .compact, in: .celsius), "58°")
        XCTAssertEqual(TemperatureFormatter.string(celsius: 58.4, style: .whole, in: .celsius), "58°C")
        XCTAssertEqual(TemperatureFormatter.string(celsius: 58.4, style: .wholeSpaced, in: .celsius), "58 °C")
        XCTAssertEqual(TemperatureFormatter.string(celsius: 58.44, style: .decimal, in: .celsius), "58.4°C")
        XCTAssertEqual(TemperatureFormatter.string(celsius: 58.44, style: .detailed, in: .celsius), "58.4 °C")
    }

    func testStyleShapesInFahrenheit() {
        // 58.4 °C = 137.12 °F.
        XCTAssertEqual(TemperatureFormatter.string(celsius: 58.4, style: .compact, in: .fahrenheit), "137°")
        XCTAssertEqual(TemperatureFormatter.string(celsius: 58.4, style: .whole, in: .fahrenheit), "137°F")
        XCTAssertEqual(TemperatureFormatter.string(celsius: 58.4, style: .wholeSpaced, in: .fahrenheit), "137 °F")
        XCTAssertEqual(TemperatureFormatter.string(celsius: 58.4, style: .decimal, in: .fahrenheit), "137.1°F")
        XCTAssertEqual(TemperatureFormatter.string(celsius: 58.4, style: .detailed, in: .fahrenheit), "137.1 °F")
    }

    func testCompactStyleNeverNamesTheUnit() {
        // The menu bar's bare degree sign is deliberate and must not gain a
        // letter when the unit changes — see `TemperatureFormatter.Style
        // .compact`.
        XCTAssertFalse(TemperatureFormatter.string(celsius: 58, style: .compact, in: .fahrenheit).contains("F"))
        XCTAssertFalse(TemperatureFormatter.string(celsius: 58, style: .compact, in: .celsius).contains("C"))
    }

    func testNumberOmitsEveryUnitMarker() {
        // `StatuslineRenderer`'s machine-readable `temp=` segment.
        XCTAssertEqual(TemperatureFormatter.number(celsius: 58.4, style: .compact, in: .celsius), "58")
        XCTAssertEqual(TemperatureFormatter.number(celsius: 58.4, style: .compact, in: .fahrenheit), "137")
        XCTAssertFalse(TemperatureFormatter.number(celsius: 58.4, style: .detailed, in: .fahrenheit).contains("°"))
    }

    func testSpokenFormNamesTheScale() {
        XCTAssertEqual(TemperatureFormatter.spoken(celsius: 58.4, in: .celsius), "58 degrees Celsius")
        XCTAssertEqual(TemperatureFormatter.spoken(celsius: 58.4, in: .fahrenheit), "137 degrees Fahrenheit")
    }

    // MARK: - Formatting: rounding and boundaries

    func testWholeStylesRoundRatherThanTruncate() {
        // 58.6 °C must not print as "58°C". Truncation is the obvious wrong
        // implementation and would be invisible on most readings.
        XCTAssertEqual(TemperatureFormatter.string(celsius: 58.6, style: .whole, in: .celsius), "59°C")
        // 36.7 °C = 98.06 °F, which must round to 98 and not up to 99.
        XCTAssertEqual(TemperatureFormatter.string(celsius: 36.7, style: .whole, in: .fahrenheit), "98°F")
    }

    func testTenthPrecisionRoundsRatherThanTruncates() {
        XCTAssertEqual(TemperatureFormatter.string(celsius: 58.46, style: .detailed, in: .celsius), "58.5 °C")
    }

    func testFreezingBoundary() {
        XCTAssertEqual(TemperatureFormatter.string(celsius: 0, style: .whole, in: .celsius), "0°C")
        XCTAssertEqual(TemperatureFormatter.string(celsius: 0, style: .whole, in: .fahrenheit), "32°F")
    }

    func testNegativeTemperaturesRenderWithTheirSign() {
        XCTAssertEqual(TemperatureFormatter.string(celsius: -10, style: .whole, in: .celsius), "-10°C")
        XCTAssertEqual(TemperatureFormatter.string(celsius: -10, style: .whole, in: .fahrenheit), "14°F")
        // −40 is the fixed point, and the only reading that formats
        // identically in both units.
        XCTAssertEqual(
            TemperatureFormatter.string(celsius: -40, style: .wholeSpaced, in: .celsius),
            "-40 °C"
        )
        XCTAssertEqual(
            TemperatureFormatter.string(celsius: -40, style: .wholeSpaced, in: .fahrenheit),
            "-40 °F"
        )
    }

    func testNonFiniteRendersAsUnavailableNotAsANumber() {
        // P5: "no data" must never masquerade as data — and "nan°F" would
        // be worse than either.
        for style in [TemperatureFormatter.Style.compact, .whole, .wholeSpaced, .decimal, .detailed] {
            XCTAssertEqual(
                TemperatureFormatter.string(celsius: .nan, style: style, in: .fahrenheit),
                MetricFormatter.unavailable
            )
            XCTAssertEqual(
                TemperatureFormatter.delta(celsius: .infinity, style: style, in: .fahrenheit),
                MetricFormatter.unavailable
            )
        }
        XCTAssertEqual(TemperatureFormatter.number(celsius: .nan, in: .celsius), MetricFormatter.unavailable)
        XCTAssertEqual(TemperatureFormatter.spoken(celsius: .nan, in: .celsius), MetricFormatter.unavailable)
    }

    // MARK: - Formatting: deltas

    func testDeltaFormattingCarriesNoOffset() {
        XCTAssertEqual(TemperatureFormatter.delta(celsius: 4, style: .decimal, in: .celsius), "4.0°C")
        XCTAssertEqual(TemperatureFormatter.delta(celsius: 4, style: .decimal, in: .fahrenheit), "7.2°F")
        // The bug this guards: the absolute conversion would say "39.2°F".
        XCTAssertNotEqual(
            TemperatureFormatter.delta(celsius: 4, style: .decimal, in: .fahrenheit),
            TemperatureFormatter.string(celsius: 4, style: .decimal, in: .fahrenheit)
        )
    }

    // MARK: - MetricFormatter integration

    func testMetricFormatterCompactFollowsTheUnit() {
        XCTAssertEqual(MetricFormatter.compact(58.4, unit: .celsius, temperatureUnit: .celsius), "58°")
        XCTAssertEqual(MetricFormatter.compact(58.4, unit: .celsius, temperatureUnit: .fahrenheit), "137°")
    }

    func testMetricFormatterCompactWithoutUnitStillConverts() {
        // `includeUnit: false` drops the marker, not the conversion —
        // `StatuslineRenderer`'s plain format and `BarModuleRenderer`'s
        // "hide the unit" module option both take this path, and a bare
        // "58" next to a Fahrenheit-labelled everything-else would be the
        // worst of both.
        XCTAssertEqual(MetricFormatter.compact(58.4, unit: .celsius, includeUnit: false, temperatureUnit: .fahrenheit), "137")
        XCTAssertEqual(MetricFormatter.compact(58.4, unit: .celsius, includeUnit: false, temperatureUnit: .celsius), "58")
    }

    func testMetricFormatterDetailedFollowsTheUnit() {
        XCTAssertEqual(MetricFormatter.detailed(58.44, unit: .celsius, temperatureUnit: .celsius), "58.4 °C")
        XCTAssertEqual(MetricFormatter.detailed(58.44, unit: .celsius, temperatureUnit: .fahrenheit), "137.2 °F")
    }

    func testNonTemperatureUnitsAreUntouchedByThePreference() {
        // The preference must be inert everywhere else. A regression here
        // would be spectacular and is cheap to rule out.
        for unit in [MetricUnit.percent, .watts, .megahertz, .bytes, .bytesPerSecond,
                     .minutes, .seconds, .decimal, .count, .millivolts, .milliamps,
                     .decibelMilliwatts, .megabitsPerSecond, .boolean, .thermalLevel,
                     .operationsPerSecond] {
            XCTAssertEqual(
                MetricFormatter.compact(72, unit: unit, temperatureUnit: .fahrenheit),
                MetricFormatter.compact(72, unit: unit, temperatureUnit: .celsius),
                "\(unit) changed with the temperature preference"
            )
            XCTAssertEqual(
                MetricFormatter.detailed(72, unit: unit, temperatureUnit: .fahrenheit),
                MetricFormatter.detailed(72, unit: unit, temperatureUnit: .celsius),
                "\(unit) changed with the temperature preference"
            )
        }
    }

    func testUnavailableStillWinsOverTheUnit() {
        XCTAssertEqual(MetricFormatter.compact(.nan, unit: .celsius, temperatureUnit: .fahrenheit), MetricFormatter.unavailable)
        XCTAssertEqual(MetricFormatter.detailed(.infinity, unit: .celsius, temperatureUnit: .fahrenheit), MetricFormatter.unavailable)
    }

    // MARK: - The ambient preference

    func testAmbientDefaultIsCelsius() {
        // Guards the requirement that turning this feature on changes
        // nothing for anyone who does nothing.
        XCTAssertEqual(AppSettings().temperatureUnit, .celsius)
    }

    func testAmbientUnitIsWhatTheDefaultParameterReads() {
        let saved = TemperatureUnit.display
        defer { TemperatureUnit.display = saved }

        TemperatureUnit.display = .fahrenheit
        XCTAssertEqual(TemperatureFormatter.string(celsius: 100, style: .whole), "212°F")
        XCTAssertEqual(MetricFormatter.compact(100, unit: .celsius), "212°")

        TemperatureUnit.display = .celsius
        XCTAssertEqual(TemperatureFormatter.string(celsius: 100, style: .whole), "100°C")
        XCTAssertEqual(MetricFormatter.compact(100, unit: .celsius), "100°")
    }

    func testSettingsStorePublishesTheUnitOnLoadAndOnChange() throws {
        let saved = TemperatureUnit.display
        defer { TemperatureUnit.display = saved }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentry-temp-unit-\(UUID().uuidString)")
            .appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // A file that already says Fahrenheit must be adopted at
        // construction — `didSet` does not fire for an assignment made in
        // `init`, which is the exact bug this asserts against.
        var stored = AppSettings()
        stored.temperatureUnit = .fahrenheit
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(stored).write(to: url)

        let store = SettingsStore(fileURL: url, debounceInterval: 0.01)
        XCTAssertEqual(TemperatureUnit.display, .fahrenheit)

        store.settings.temperatureUnit = .celsius
        XCTAssertEqual(TemperatureUnit.display, .celsius)
    }

    // MARK: - Persistence

    func testAppSettingsRoundTripsTheUnit() throws {
        var settings = AppSettings()
        settings.temperatureUnit = .fahrenheit

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.temperatureUnit, .fahrenheit)

        // Self-describing on disk, not an opaque boolean — see
        // `TemperatureUnit`'s doc comment on why it is a String-raw enum.
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"fahrenheit\""))
    }

    func testAppSettingsDecodesWithoutTheKeyAsCelsius() throws {
        // The upgrade path: a settings file written by a build from before
        // this key existed belongs to somebody who has been reading Celsius.
        // They must keep reading Celsius, whatever their locale says.
        let json = Data(#"{"schemaVersion": 1}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.temperatureUnit, .celsius)
    }

    func testAppSettingsRejectsAnUnknownUnitRatherThanGuessing() {
        // Consistent with this decoder's stated contract: an absent key is
        // an upgrade and falls back; a present-but-wrong value is a broken
        // file and throws, which `SettingsStore` turns into a
        // whole-file reset with a log line.
        let json = Data(#"{"temperatureUnit": "kelvin"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: json))
    }

    // MARK: - Storage stays Celsius

    func testAlertRuleThresholdRoundTripsThroughFahrenheitEditing() {
        // Mirrors `AlertsPane.temperatureThresholdBinding`: the field shows
        // Fahrenheit, the user types Fahrenheit, and what lands in
        // `AlertRule.threshold` — the number `AlertEngine` compares raw
        // sensor Celsius against — is still Celsius.
        let displayed = TemperatureUnit.fahrenheit.value(fromCelsius: 95)
        XCTAssertEqual(displayed, 203, accuracy: 0.0001)

        let typedBack = TemperatureUnit.fahrenheit.celsiusValue(from: 203)
        XCTAssertEqual(typedBack, 95, accuracy: 0.0001)
    }

    /// Fan RPM is a *reading*, and a reading with no temperature in it —
    /// so switching the display unit must not touch it. This is what is
    /// left of the two fan-curve tests that used to sit here: fan control
    /// was removed, the curve types went with it, and the surviving
    /// obligation is that the unit setting stays confined to temperatures.
    func testSwitchingDisplayUnitDoesNotTouchFanRPM() {
        let saved = TemperatureUnit.display
        defer { TemperatureUnit.display = saved }

        let thermal = ThermalStats(socTemperatureCelsius: 70, fanRPMs: [1200, 5000])

        TemperatureUnit.display = .fahrenheit
        XCTAssertEqual(thermal.fanRPMs, [1200, 5000])
        TemperatureUnit.display = .celsius
        XCTAssertEqual(thermal.fanRPMs, [1200, 5000])
    }
}
