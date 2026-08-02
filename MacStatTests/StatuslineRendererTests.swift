import XCTest
@testable import MacStatKit

/// Coverage for `StatuslineRenderer`
/// (`MacStatKit/CLI/StatuslineRenderer.swift`), the pure formatter behind
/// `macstat statusline`. Same testing posture as `MetricFormatterTests`:
/// this line is glanced at hundreds of times a day from tmux/Starship/
/// Claude Code, so the honesty rules (absent reading → "—", never a
/// fabricated zero; bolt only while actually charging) and the exact byte
/// shape (locale-stable byte units, no ANSI escapes unless opted in) are
/// contracts, not styling — a regression in any of them ships a lie to a
/// prompt line.
final class StatuslineRendererTests: XCTestCase {

    // MARK: - Fixtures

    /// A fully-populated snapshot matching the usage example:
    /// `cpu 42% · mem 12.6G · 89%⚡`.
    private func fullSnapshot(
        cpuPercent: Double = 42,
        memUsedBytes: UInt64 = 13_529_146_982, // 12.6 GiB
        pressure: MemoryPressureLevel? = .normal,
        batteryPercent: Double = 89,
        isCharging: Bool = true
    ) -> SystemSnapshot {
        SystemSnapshot(
            deviceID: "test-device",
            battery: BatteryStats(chargePercent: batteryPercent, isCharging: isCharging, isPluggedIn: isCharging),
            cpu: CPUStats(totalPercent: cpuPercent),
            memory: MemoryStats(
                usedBytes: memUsedBytes,
                appMemoryBytes: 0,
                wiredBytes: 0,
                compressedBytes: 0,
                cachedBytes: 0,
                totalBytes: 34_359_738_368,
                pressureLevel: pressure
            )
        )
    }

    /// What a Mac mini (or a snapshot taken before the first sample of
    /// each collector) actually produces: every sub-struct nil.
    private var emptySnapshot: SystemSnapshot {
        SystemSnapshot(deviceID: "test-device")
    }

    private func render(
        _ snapshot: SystemSnapshot,
        segments: [StatuslineSegment] = StatuslineSegment.allCases,
        colorized: Bool = false
    ) -> String {
        StatuslineRenderer.render(snapshot: snapshot, segments: segments, colorized: colorized)
    }

    // MARK: - The canonical line

    func testFullSnapshotRendersTheDocumentedExample() {
        XCTAssertEqual(render(fullSnapshot()), "cpu 42% · mem 12.6G · 89%⚡")
    }

    func testSingleLineInvariant() {
        // The CLI prints this with a single `print`; a newline from the
        // renderer would produce a second line and break every status-line
        // consumer.
        XCTAssertFalse(render(fullSnapshot()).contains("\n"))
    }

    // MARK: - Segment selection and order

    func testSegmentsRenderInCallerOrder() {
        // Order is positional real estate, not just membership — see
        // `StatuslineRenderer.render`.
        XCTAssertEqual(render(fullSnapshot(), segments: [.battery, .cpu]), "89%⚡ · cpu 42%")
    }

    func testSingleSegmentHasNoSeparator() {
        XCTAssertEqual(render(fullSnapshot(), segments: [.cpu]), "cpu 42%")
    }

    // MARK: - Honesty: absent readings

    func testAbsentEverythingRendersDashesNotZeros() {
        // Labeled segments keep their labels ("cpu —") so a multi-segment
        // line keeps its shape; the unlabeled battery segment is a bare
        // "—". No zeros anywhere: "cpu 0%" on a Mac mini is a lie.
        XCTAssertEqual(render(emptySnapshot), "cpu — · mem — · —")
    }

    func testAbsentBatteryOnlyAffectsItsOwnSegment() {
        var snapshot = fullSnapshot()
        snapshot.battery = nil
        XCTAssertEqual(render(snapshot), "cpu 42% · mem 12.6G · —")
    }

    func testNonFiniteCPURendersDash() {
        // Same trap `MetricFormatter.compact` guards: NaN through Int() is
        // a runtime trap and any rendered number would be fiction.
        var snapshot = fullSnapshot()
        snapshot.cpu = CPUStats(totalPercent: .nan)
        XCTAssertEqual(render(snapshot, segments: [.cpu]), "cpu —")
    }

    // MARK: - Battery bolt (BatteryGlyph.State.showsBolt's rule)

    func testPluggedInButNotChargingShowsNoBolt() {
        // macOS holds batteries at 80% routinely; a bolt there claims the
        // battery is filling when it is not.
        var snapshot = fullSnapshot(isCharging: false)
        snapshot.battery?.isPluggedIn = true
        XCTAssertEqual(render(snapshot, segments: [.battery]), "89%")
    }

    func testChargingShowsBolt() {
        XCTAssertEqual(render(fullSnapshot(isCharging: true), segments: [.battery]), "89%⚡")
    }

    // MARK: - compactBytes

    func testCompactBytesGigabytesKeepOneDecimalUnderOneHundred() {
        XCTAssertEqual(StatuslineRenderer.compactBytes(13_529_146_982), "12.6G")
        XCTAssertEqual(StatuslineRenderer.compactBytes(1_073_741_824), "1.0G")
    }

    func testCompactBytesGigabytesDropDecimalAtOneHundred() {
        // 100 GiB exactly — the same "one decimal stops being informative"
        // threshold MetricFormatter applies to watts at 10.
        XCTAssertEqual(StatuslineRenderer.compactBytes(107_374_182_400), "100G")
    }

    func testCompactBytesTerabytes() {
        // 1.5 TiB.
        XCTAssertEqual(StatuslineRenderer.compactBytes(1_649_267_441_664), "1.5T")
    }

    func testCompactBytesSmallerUnitsHaveNoDecimals() {
        XCTAssertEqual(StatuslineRenderer.compactBytes(5_242_880), "5M") // 5 MiB
        XCTAssertEqual(StatuslineRenderer.compactBytes(2_048), "2K")
        XCTAssertEqual(StatuslineRenderer.compactBytes(512), "512B")
        XCTAssertEqual(StatuslineRenderer.compactBytes(0), "0B")
    }

    func testCompactBytesIsLocaleStable() {
        // The whole reason this doesn't use ByteCountFormatter: the output
        // must never grow a locale decimal comma or a localized unit. The
        // decimal separator is a period regardless of the process locale.
        XCTAssertTrue(StatuslineRenderer.compactBytes(13_529_146_982).contains("."))
        XCTAssertFalse(StatuslineRenderer.compactBytes(13_529_146_982).contains(","))
    }

    // MARK: - Color

    func testDefaultOutputContainsNoEscapeBytes() {
        // Not "renders invisibly" — the escape bytes must not exist, or
        // they leak as ^[[31m garbage in consumers that don't interpret
        // ANSI. Even an alarming snapshot must stay plain without --color.
        let alarming = fullSnapshot(cpuPercent: 97, pressure: .critical, batteryPercent: 4, isCharging: false)
        XCTAssertFalse(render(alarming).contains("\u{1B}"))
    }

    func testColorizedHealthyLineStaysUncolored() {
        // Color present == something worth a glance; a permanently-green
        // line would destroy that signal.
        XCTAssertEqual(
            render(fullSnapshot(cpuPercent: 12, pressure: .normal, batteryPercent: 89), colorized: true),
            "cpu 12% · mem 12.6G · 89%⚡"
        )
    }

    func testColorizedAlarmStatesWrapValuesInSGR() {
        let alarming = fullSnapshot(cpuPercent: 97, pressure: .critical, batteryPercent: 4, isCharging: false)
        let line = render(alarming, colorized: true)
        XCTAssertTrue(line.contains("\u{1B}[31m97%\u{1B}[0m"))
        XCTAssertTrue(line.contains("\u{1B}[31m12.6G\u{1B}[0m"))
        XCTAssertTrue(line.contains("\u{1B}[31m4%\u{1B}[0m"))
        // Labels stay uncolored — the value is the signal, not the word.
        XCTAssertTrue(line.contains("cpu \u{1B}["))
    }

    // MARK: - Tint thresholds

    func testCPUTintThresholds() {
        XCTAssertEqual(StatuslineRenderer.Tint.forCPU(percent: 59.9), .none)
        XCTAssertEqual(StatuslineRenderer.Tint.forCPU(percent: 60), .caution)
        XCTAssertEqual(StatuslineRenderer.Tint.forCPU(percent: 85), .alarm)
        XCTAssertEqual(StatuslineRenderer.Tint.forCPU(percent: .nan), .none)
    }

    func testMemoryTintFollowsKernelPressureOnly() {
        XCTAssertEqual(StatuslineRenderer.Tint.forMemory(pressure: .warning), .caution)
        XCTAssertEqual(StatuslineRenderer.Tint.forMemory(pressure: .critical), .alarm)
        // nil pressure is "unknown", not "assume normal" — either way, no
        // color, because an inferred threshold is a fabricated signal.
        XCTAssertEqual(StatuslineRenderer.Tint.forMemory(pressure: nil), .none)
    }

    func testBatteryTintDowngradesWhileCharging() {
        XCTAssertEqual(StatuslineRenderer.Tint.forBattery(percent: 8, isCharging: false), .alarm)
        // 8% and filling is a resolving situation, not an emergency.
        XCTAssertEqual(StatuslineRenderer.Tint.forBattery(percent: 8, isCharging: true), .caution)
        XCTAssertEqual(StatuslineRenderer.Tint.forBattery(percent: 15, isCharging: false), .caution)
        XCTAssertEqual(StatuslineRenderer.Tint.forBattery(percent: 55, isCharging: false), .none)
    }
}
