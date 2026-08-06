import XCTest
@testable import Sentry
@testable import SentryKit

/// Coverage for `SystemVitals.vitals(for:enabledModules:)`
/// (Sentry/Dropdown/SystemVitals.swift) — the pure, testable half of the
/// bug this pins down: a user who disabled CPU/Memory/Disk/Battery and
/// enabled GPU/Network/Thermal instead used to see "No modules are turned
/// on" in the dropdown, and had no way to reach network throughput or SoC
/// temperature from this surface at all, because `vitals(for:)` only ever
/// emitted the original four rows regardless of what was actually enabled.
final class SystemVitalsTests: XCTestCase {

    private func fullSnapshot() -> SystemSnapshot {
        var snapshot = SystemSnapshot(deviceID: "test-device")
        snapshot.cpu = CPUStats(totalPercent: 42)
        snapshot.memory = MemoryStats(
            usedBytes: 8_000_000_000,
            appMemoryBytes: 4_000_000_000,
            wiredBytes: 1_000_000_000,
            compressedBytes: 0,
            cachedBytes: 0,
            totalBytes: 16_000_000_000
        )
        snapshot.disk = DiskStats(
            freeBytes: 250_000_000_000,
            totalBytes: 500_000_000_000
        )
        snapshot.battery = BatteryStats(chargePercent: 80, isCharging: false, isPluggedIn: true)
        snapshot.gpu = GPUStats(utilizationPercent: 12)
        snapshot.network = NetworkStats(
            rxBytesPerSec: 500_000,
            txBytesPerSec: 100_000,
            rxSessionTotalBytes: 0,
            txSessionTotalBytes: 0
        )
        snapshot.thermal = ThermalStats(socTemperatureCelsius: 55, pressureLevel: .nominal, isThrottling: false)
        snapshot.ane = ANEStats(powerWatts: 0.2, isActive: false)
        return snapshot
    }

    // MARK: - The bug: newly-enabled modules must produce rows

    /// The exact scenario from the review: CPU/Memory/Disk/Battery off,
    /// GPU/Network/Thermal on. Must not come back empty, and must contain
    /// exactly the three enabled modules.
    func testDisablingOriginalFourAndEnablingGPUNetworkThermalProducesTheirRows() {
        let vitals = SystemVitals.vitals(
            for: fullSnapshot(),
            enabledModules: [.gpu, .network, .thermal]
        )

        XCTAssertEqual(Set(vitals.map(\.module)), [.gpu, .network, .thermal])
        XCTAssertFalse(vitals.isEmpty, "three enabled modules with data must not read as \"no modules on\"")
    }

    /// ANE joins the same way — a fourth previously-unreachable module.
    func testANEProducesARowWhenEnabled() {
        let vitals = SystemVitals.vitals(for: fullSnapshot(), enabledModules: [.ane])
        XCTAssertEqual(vitals.map(\.module), [.ane])
    }

    /// `.system` has no snapshot field of its own (uptime/process count
    /// surface elsewhere in the dropdown already), so it never produces a
    /// row even when "enabled" — there is nothing to build one from.
    func testSystemModuleNeverProducesARow() {
        let vitals = SystemVitals.vitals(for: fullSnapshot(), enabledModules: Set(MetricModule.allCases))
        XCTAssertFalse(vitals.map(\.module).contains(.system))
    }

    // MARK: - Regression: the original four are unchanged

    func testOriginalFourModulesStillProduceRowsInTheirOriginalOrderWhenOnlyTheyAreEnabled() {
        let vitals = SystemVitals.vitals(
            for: fullSnapshot(),
            enabledModules: [.cpu, .memory, .disk, .battery]
        )
        XCTAssertEqual(vitals.map(\.module), [.cpu, .memory, .disk, .battery])
    }

    func testEveryEnabledSupportedModuleWithDataProducesExactlyOneRowEach() {
        let enabled: Set<MetricModule> = [.cpu, .memory, .disk, .battery, .gpu, .network, .thermal, .ane]
        let vitals = SystemVitals.vitals(for: fullSnapshot(), enabledModules: enabled)
        XCTAssertEqual(Set(vitals.map(\.module)), enabled)
        XCTAssertEqual(vitals.count, enabled.count, "no module should produce more than one row")
    }

    // MARK: - No snapshot, no vitals

    func testNilSnapshotProducesNoVitals() {
        XCTAssertTrue(SystemVitals.vitals(for: nil, enabledModules: Set(MetricModule.allCases)).isEmpty)
    }

    // MARK: - Enabled but no data still produces nothing (never a fabricated row)

    func testEnabledModuleWithNoDataInTheSnapshotProducesNoRow() {
        var snapshot = fullSnapshot()
        snapshot.gpu = nil
        let vitals = SystemVitals.vitals(for: snapshot, enabledModules: [.gpu, .network])
        XCTAssertEqual(vitals.map(\.module), [.network])
    }

    // MARK: - Disabled modules never produce a row even with data present

    func testDisabledModuleWithDataStillProducesNoRow() {
        let vitals = SystemVitals.vitals(for: fullSnapshot(), enabledModules: [.cpu])
        XCTAssertEqual(vitals.map(\.module), [.cpu])
    }

    // MARK: - New rows carry real values, not placeholders

    func testGPURowReadsThePercentAndFillsTheMeter() {
        let vitals = SystemVitals.vitals(for: fullSnapshot(), enabledModules: [.gpu])
        let gpu = try? XCTUnwrap(vitals.first)
        XCTAssertEqual(gpu?.value.number, "12")
        XCTAssertEqual(gpu?.fraction ?? -1, 0.12, accuracy: 0.0001)
    }

    func testNetworkRowHasNoBoundedMeterButStillReportsAValue() {
        let vitals = SystemVitals.vitals(for: fullSnapshot(), enabledModules: [.network])
        let network = try? XCTUnwrap(vitals.first)
        XCTAssertNil(network?.fraction, "throughput is unbounded, unlike the percent-based rows")
        XCTAssertFalse(network?.value.plain.isEmpty ?? true)
    }

    // MARK: - Thermal row severity mirrors the verdict's own thermal reasoning

    func testThrottlingProducesACriticalThermalRow() {
        var snapshot = fullSnapshot()
        snapshot.thermal = ThermalStats(socTemperatureCelsius: 60, pressureLevel: .nominal, isThrottling: true)
        let vitals = SystemVitals.vitals(for: snapshot, enabledModules: [.thermal])
        XCTAssertEqual(vitals.first?.level, .critical)
    }

    func testFairPressureProducesAWarningThermalRow() {
        var snapshot = fullSnapshot()
        snapshot.thermal = ThermalStats(socTemperatureCelsius: 60, pressureLevel: .fair, isThrottling: false)
        let vitals = SystemVitals.vitals(for: snapshot, enabledModules: [.thermal])
        XCTAssertEqual(vitals.first?.level, .warning)
    }

    func testNominalThermalsProduceANormalRow() {
        let vitals = SystemVitals.vitals(for: fullSnapshot(), enabledModules: [.thermal])
        XCTAssertEqual(vitals.first?.level, .normal)
    }

    // MARK: - Status: thermal is not double-counted between the row and the verdict

    /// `status(for:vitals:enabledModules:)` has a bespoke thermal block that
    /// predates `thermalVital`; the generic "every flagged vital contributes
    /// a finding" loop excludes `.thermal` specifically so a throttling Mac
    /// doesn't get two differently-worded reasons for the same condition.
    func testThrottlingContributesExactlyOneReasonToTheVerdictNotTwo() {
        var snapshot = fullSnapshot()
        snapshot.thermal = ThermalStats(socTemperatureCelsius: 60, pressureLevel: .nominal, isThrottling: true)
        let enabled: Set<MetricModule> = [.thermal]
        let vitals = SystemVitals.vitals(for: snapshot, enabledModules: enabled)
        let status = SystemVitals.status(for: snapshot, vitals: vitals, enabledModules: enabled)

        // Counted across the headline AND the reasons line: since the
        // headline finding's own reason is dropped from `reasons` (it would
        // narrate the same condition twice — see `status(for:)`), a
        // throttling-only snapshot names the condition once, in the headline,
        // and `reasons` is rightly empty. What this test pins is the original
        // intent — the condition is narrated exactly once, never twice.
        let narrated = [status.headline] + status.reasons
        let thermalMentions = narrated.filter { $0.localizedCaseInsensitiveContains("thermal") || $0.localizedCaseInsensitiveContains("throttling") }
        XCTAssertEqual(thermalMentions.count, 1, "expected the throttling condition narrated exactly once, got headline \"\(status.headline)\" + reasons \(status.reasons)")
        XCTAssertEqual(status.level, .critical)
    }
}
