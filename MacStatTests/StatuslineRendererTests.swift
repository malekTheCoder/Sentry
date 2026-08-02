import XCTest
@testable import MacStatKit

/// Covers `StatuslineRenderer` — the formatting half of `macstat statusline`
/// (plan §21.3).
///
/// **What this suite is really guarding.** A status line is the one MacStat
/// surface a user reads without looking at it. Nothing about a wrong number
/// there announces itself: there is no chart to compare against, no unit
/// label to notice is missing, and the reader has already moved on to their
/// next command. So the tests that matter most below are not the happy-path
/// string comparisons — they are the ones asserting that a Mac which cannot
/// report a temperature produces a *shorter line*, never a `0°C`, and that a
/// snapshot recovered from cache is never rendered without its age attached.
/// Both are single `if let`s in the renderer that a well-meaning refactor
/// could turn into a `?? 0` without any other test in this repo objecting.
final class StatuslineRendererTests: XCTestCase {

    // MARK: - Fixtures

    private func snapshot(
        battery: BatteryStats? = nil,
        cpu: CPUStats? = nil,
        thermal: ThermalStats? = nil,
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> SystemSnapshot {
        SystemSnapshot(
            timestamp: timestamp,
            deviceID: "test-device",
            battery: battery,
            cpu: cpu,
            thermal: thermal
        )
    }

    private func battery(
        charge: Double = 78,
        isCharging: Bool = false,
        isPluggedIn: Bool = false,
        chargingWatts: Double? = nil,
        systemWatts: Double? = nil
    ) -> BatteryStats {
        BatteryStats(
            chargePercent: charge,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            chargingWatts: chargingWatts,
            systemPowerInWatts: systemWatts
        )
    }

    private func cpu(_ percent: Double) -> CPUStats {
        CPUStats(totalPercent: percent, perCorePercent: [])
    }

    private func thermal(_ celsius: Double?) -> ThermalStats {
        ThermalStats(socTemperatureCelsius: celsius, pressureLevel: .nominal, isThrottling: false)
    }

    /// The full, everything-populated snapshot §21.3's example line describes.
    private func fullSnapshot() -> SystemSnapshot {
        snapshot(
            battery: battery(charge: 78, isCharging: true, isPluggedIn: true, chargingWatts: 45),
            cpu: cpu(12),
            thermal: thermal(62)
        )
    }

    // MARK: - The documented shapes

    func testCompactMatchesThePlannedShape() {
        let line = StatuslineRenderer.render(snapshot: fullSnapshot(), format: .compact)
        XCTAssertEqual(line, "🔌78%  45W  ⚙️12%  🌡️62°C")
    }

    func testPlainCarriesNoGlyphsAndNamesWhichWattageItPicked() {
        let line = StatuslineRenderer.render(snapshot: fullSnapshot(), format: .plain)
        XCTAssertEqual(line, "batt=78% watts=45 charging=1 cpu=12% temp=62")
        XCTAssertTrue(
            line.allSatisfy { $0.isASCII },
            "`plain` exists for terminals and parsers without glyph coverage; a non-ASCII byte defeats the point."
        )
    }

    func testPlainDistinguishesSystemDrawFromChargingInput() {
        let discharging = snapshot(
            battery: battery(charge: 64, isCharging: false, isPluggedIn: false, systemWatts: 11.4),
            cpu: cpu(8)
        )
        let line = StatuslineRenderer.render(snapshot: discharging, format: .plain)
        XCTAssertTrue(line.contains("charging=0"), line)
        // `MetricFormatter` drops the decimal at or above 10W — asserted
        // here so this test documents the shared formatter's rule rather
        // than accidentally re-specifying it.
        XCTAssertTrue(line.contains("watts=11"), line)
    }

    func testNerdfontUsesGlyphsFromTheStableFontAwesomeBlockRatherThanEmoji() {
        let line = StatuslineRenderer.render(snapshot: fullSnapshot(), format: .nerdfont)
        XCTAssertTrue(line.contains("\u{f1e6}"), "plug glyph")
        XCTAssertTrue(line.contains("\u{f2db}"), "microchip glyph")
        XCTAssertTrue(line.contains("\u{f2c7}"), "thermometer glyph")
        XCTAssertFalse(line.contains("🔋"))
        XCTAssertFalse(line.contains("🔌"))
        XCTAssertFalse(line.contains("🌡️"))
    }

    func testBatteryGlyphReflectsWhetherThePowerAdapterIsAttached() {
        let unplugged = snapshot(battery: battery(charge: 55, isPluggedIn: false))
        XCTAssertTrue(StatuslineRenderer.render(snapshot: unplugged, format: .compact).hasPrefix("🔋"))

        let plugged = snapshot(battery: battery(charge: 55, isPluggedIn: true))
        XCTAssertTrue(StatuslineRenderer.render(snapshot: plugged, format: .compact).hasPrefix("🔌"))
    }

    // MARK: - Absent readings (the reason this suite exists)

    func testAMissingTemperatureDropsTheSegmentRatherThanRenderingZero() {
        // `socTemperatureCelsius` is nil on any Mac where the HID sensor
        // bridge didn't resolve — a supported state, not an error. Note the
        // snapshot still *has* a `thermal` block, which is exactly the trap:
        // checking `thermal != nil` instead of the temperature would render
        // "0°C" here and be wrong on real hardware, not just in this test.
        let line = StatuslineRenderer.render(
            snapshot: snapshot(cpu: cpu(30), thermal: thermal(nil)),
            format: .compact
        )
        XCTAssertEqual(line, "⚙️30%")
        XCTAssertFalse(line.contains("🌡️"))
        XCTAssertFalse(line.contains("0°"))
    }

    func testAMissingBatteryBlockDropsBothBatterySegments() {
        let line = StatuslineRenderer.render(
            snapshot: snapshot(cpu: cpu(30), thermal: thermal(55)),
            format: .plain
        )
        XCTAssertEqual(line, "cpu=30% temp=55")
        XCTAssertFalse(line.contains("batt="))
        XCTAssertFalse(line.contains("watts="))
    }

    func testAMissingWattageKeepsTheChargePercentButDropsTheWattage() {
        let line = StatuslineRenderer.render(
            snapshot: snapshot(battery: battery(charge: 41, isCharging: true, chargingWatts: nil)),
            format: .plain
        )
        XCTAssertEqual(line, "batt=41%")
    }

    func testANonFiniteReadingIsTreatedAsAbsent() {
        // `Double.nan` reaching a status line is not hypothetical: several
        // collectors divide by a delta that can be zero. `MetricFormatter`
        // already refuses to format it; this asserts the renderer drops the
        // segment rather than printing the formatter's "—" placeholder,
        // which in a status line reads as a real, meaningless reading.
        let line = StatuslineRenderer.render(
            snapshot: snapshot(cpu: cpu(20), thermal: thermal(.nan)),
            format: .compact
        )
        XCTAssertEqual(line, "⚙️20%")
    }

    func testAnEmptySnapshotRendersAnEmptyStringSoTheCLICanSaySoOnStderr() {
        // The CLI branches on this: an empty return means "print nothing and
        // explain on stderr", never "print a blank line and exit 0".
        XCTAssertEqual(StatuslineRenderer.render(snapshot: snapshot(), format: .compact), "")
        XCTAssertEqual(StatuslineRenderer.render(snapshot: snapshot(), format: .plain), "")
        XCTAssertEqual(StatuslineRenderer.render(snapshot: snapshot(), format: .tmux), "")
    }

    // MARK: - Staleness

    func testAStaleSnapshotIsAlwaysLabeledWithItsAge() {
        for format in StatuslineFormat.allCases {
            let line = StatuslineRenderer.render(snapshot: fullSnapshot(), format: format, staleBy: 137)
            XCTAssertNotEqual(
                line,
                StatuslineRenderer.render(snapshot: fullSnapshot(), format: format, staleBy: nil),
                "\(format.rawValue) rendered a cached reading indistinguishably from a live one"
            )
        }
        XCTAssertTrue(StatuslineRenderer.render(snapshot: fullSnapshot(), format: .compact, staleBy: 137).hasSuffix("⏳2m"))
        XCTAssertTrue(StatuslineRenderer.render(snapshot: fullSnapshot(), format: .plain, staleBy: 137).hasSuffix("stale_s=137"))
    }

    func testFreshOutputCarriesNoStalenessMarker() {
        let line = StatuslineRenderer.render(snapshot: fullSnapshot(), format: .compact, staleBy: nil)
        XCTAssertFalse(line.contains("⏳"))
        // Zero is treated as fresh: a "⏳0s" is true and useless.
        XCTAssertFalse(StatuslineRenderer.render(snapshot: fullSnapshot(), format: .compact, staleBy: 0).contains("⏳"))
    }

    // MARK: - tmux styling

    func testTmuxColorsEachSegmentAndResetsAtTheEnd() {
        let line = StatuslineRenderer.render(snapshot: fullSnapshot(), theme: .defaultTheme, format: .tmux)
        XCTAssertTrue(line.hasSuffix("#[default]"), "an unreset foreground bleeds into the rest of the status bar")
        XCTAssertTrue(line.contains("#[fg=#"), line)
    }

    func testTmuxUsesTheDangerTokenForAHotCPUEvenWhenTheThemeAssignsCPUItsOwnColor() {
        var theme = Theme.defaultTheme
        theme.danger = ThemeColor(hex: "#FF0000")
        theme.metricColors[MetricID.cpuTotalPercent.rawValue] = ThemeColor(hex: "#00FFFF")

        let calm = StatuslineRenderer.render(snapshot: snapshot(cpu: cpu(5)), theme: theme, format: .tmux)
        XCTAssertTrue(calm.contains("#[fg=#00FFFF]"), "an idle CPU should wear the theme's own metric color")

        let hot = StatuslineRenderer.render(snapshot: snapshot(cpu: cpu(97)), theme: theme, format: .tmux)
        XCTAssertTrue(hot.contains("#[fg=#FF0000]"), "severity has to win over the palette, or nothing ever looks alarming")
        XCTAssertFalse(hot.contains("#[fg=#00FFFF]"))
    }

    func testTmuxNormalizesAThemeHexThatIsMissingItsLeadingHash() {
        // tmux silently drops a whole style spec it can't parse, leaving the
        // text uncolored rather than erroring — so a malformed color here
        // would look like "theming doesn't work" with nothing to debug.
        var theme = Theme.defaultTheme
        theme.danger = ThemeColor(hex: "FF0000")
        let hot = StatuslineRenderer.render(snapshot: snapshot(cpu: cpu(97)), theme: theme, format: .tmux)
        XCTAssertTrue(hot.contains("#[fg=#FF0000]"), hot)
    }

    func testTmuxTakesTheDarkSideOfEveryThemeColorPair() {
        var theme = Theme.defaultTheme
        theme.metricColors[MetricID.cpuTotalPercent.rawValue] = ThemeColor(light: "#111111", dark: "#EEEEEE")
        let line = StatuslineRenderer.render(snapshot: snapshot(cpu: cpu(5)), theme: theme, format: .tmux)
        XCTAssertTrue(line.contains("#EEEEEE"), "a terminal has no appearance to query; dark is the documented assumption")
        XCTAssertFalse(line.contains("#111111"))
    }

    // MARK: - Severity bands

    func testSeverityBandsAreDrivenByTheReadingRatherThanTheModule() {
        var theme = Theme.defaultTheme
        theme.warning = ThemeColor(hex: "#FFAA00")
        theme.danger = ThemeColor(hex: "#FF0000")

        let warm = StatuslineRenderer.render(snapshot: snapshot(thermal: thermal(85)), theme: theme, format: .tmux)
        XCTAssertTrue(warm.contains("#FFAA00"), warm)

        let scorching = StatuslineRenderer.render(snapshot: snapshot(thermal: thermal(99)), theme: theme, format: .tmux)
        XCTAssertTrue(scorching.contains("#FF0000"), scorching)
    }

    func testALowBatteryIsOnlyAlarmingWhenItIsNotPluggedIn() {
        var theme = Theme.defaultTheme
        theme.danger = ThemeColor(hex: "#FF0000")

        let dying = snapshot(battery: battery(charge: 6, isPluggedIn: false))
        XCTAssertTrue(StatuslineRenderer.render(snapshot: dying, theme: theme, format: .tmux).contains("#FF0000"))

        // 6% while charging is a machine that is fine and getting better.
        let recovering = snapshot(battery: battery(charge: 6, isCharging: true, isPluggedIn: true))
        XCTAssertFalse(StatuslineRenderer.render(snapshot: recovering, theme: theme, format: .tmux).contains("#FF0000"))
    }

    // MARK: - Format identifiers are a dotfile contract

    func testEveryFormatIdentifierRoundTripsFromItsCommandLineSpelling() {
        // These strings live in users' `.tmux.conf` and `starship.toml`,
        // where nothing in this repo can see them break.
        for spelling in ["compact", "plain", "tmux", "nerdfont"] {
            XCTAssertNotNil(StatuslineFormat(rawValue: spelling), spelling)
        }
        XCTAssertEqual(StatuslineFormat.allCases.count, 4)
    }
}
