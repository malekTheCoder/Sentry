import XCTest
@testable import Sentry
import SentryKit

/// Covers the pure reflection-to-string logic behind the debug window (plan
/// Phase 1 exit criterion). Deliberately not testing `DebugDumpView` itself —
/// per house convention, SwiftUI rendering isn't unit tested — only the
/// `Mirror`-based formatter it displays.
final class SnapshotDebugFormatterTests: XCTestCase {

    private func makeSnapshot(
        battery: BatteryStats? = nil,
        cpu: CPUStats? = nil,
        thermal: ThermalStats? = nil,
        sleepAssertion: SleepAssertionState? = nil
    ) -> SystemSnapshot {
        SystemSnapshot(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            deviceID: "test-device",
            schemaVersion: 1,
            battery: battery,
            cpu: cpu,
            thermal: thermal,
            sleepAssertion: sleepAssertion
        )
    }

    // MARK: - nil handling

    func testNilSubStructRendersLiteralNilNotHidden() {
        let snapshot = makeSnapshot()
        let sections = SnapshotDebugFormatter.sections(for: snapshot)

        guard let batterySection = sections.first(where: { $0.name == "Battery" }) else {
            return XCTFail("expected a Battery section even when battery is nil")
        }
        XCTAssertEqual(batterySection.fields.count, 1)
        XCTAssertEqual(batterySection.fields.first?.value, "nil")
    }

    func testNilLeafFieldRendersLiteralNil() {
        let battery = BatteryStats(chargePercent: 80, isCharging: false, isPluggedIn: false)
        let snapshot = makeSnapshot(battery: battery)
        let sections = SnapshotDebugFormatter.sections(for: snapshot)

        let batterySection = sections.first { $0.name == "Battery" }!
        let chargingWatts = batterySection.fields.first { $0.name == "chargingWatts" }
        XCTAssertEqual(chargingWatts?.value, "nil")
    }

    // MARK: - Raw values, not rounded/formatted

    func testDoubleFieldIsNotRoundedOrUnitSuffixed() {
        let battery = BatteryStats(chargePercent: 72.383294, isCharging: true, isPluggedIn: true)
        let snapshot = makeSnapshot(battery: battery)
        let sections = SnapshotDebugFormatter.sections(for: snapshot)

        let batterySection = sections.first { $0.name == "Battery" }!
        let chargePercent = batterySection.fields.first { $0.name == "chargePercent" }
        // Not "72%" (MetricFormatter's rounded/compact form) — the exact
        // Double, because this window exists to catch the discrepancy
        // rounding would hide.
        XCTAssertEqual(chargePercent?.value, "72.383294")
    }

    func testBoolFieldRendersAsTrueOrFalse() {
        let battery = BatteryStats(chargePercent: 50, isCharging: true, isPluggedIn: true)
        let snapshot = makeSnapshot(battery: battery)
        let sections = SnapshotDebugFormatter.sections(for: snapshot)
        let batterySection = sections.first { $0.name == "Battery" }!
        XCTAssertEqual(batterySection.fields.first { $0.name == "isCharging" }?.value, "true")
    }

    // MARK: - Collections

    func testArrayFieldRendersAllElements() {
        let cpu = CPUStats(totalPercent: 42, perCorePercent: [10.5, 20.25, 30.0])
        let snapshot = makeSnapshot(cpu: cpu)
        let sections = SnapshotDebugFormatter.sections(for: snapshot)
        let cpuSection = sections.first { $0.name == "CPU" }!
        let perCore = cpuSection.fields.first { $0.name == "perCorePercent" }
        XCTAssertEqual(perCore?.value, "[10.5, 20.25, 30.0]")
    }

    func testEmptyArrayFieldRendersAsEmptyBrackets() {
        let cpu = CPUStats(totalPercent: 0, perCorePercent: [])
        let snapshot = makeSnapshot(cpu: cpu)
        let sections = SnapshotDebugFormatter.sections(for: snapshot)
        let cpuSection = sections.first { $0.name == "CPU" }!
        XCTAssertEqual(cpuSection.fields.first { $0.name == "perCorePercent" }?.value, "[]")
    }

    // MARK: - Enums

    func testEnumWithoutAssociatedValueRendersCaseName() {
        let thermal = ThermalStats(pressureLevel: .serious)
        let snapshot = makeSnapshot(thermal: thermal)
        let sections = SnapshotDebugFormatter.sections(for: snapshot)
        let thermalSection = sections.first { $0.name == "Thermal" }!
        XCTAssertEqual(thermalSection.fields.first { $0.name == "pressureLevel" }?.value, "serious")
    }

    func testEnumWithAssociatedValuesRendersCaseNameAndPayload() {
        let expiry = Date(timeIntervalSince1970: 1_700_003_600)
        let sleepAssertion = SleepAssertionState.active(mode: .systemOnly, expiresAt: expiry, reason: "user request")
        let snapshot = makeSnapshot(sleepAssertion: sleepAssertion)
        let sections = SnapshotDebugFormatter.sections(for: snapshot)
        let section = sections.first { $0.name == "Sleep Assertion" }!

        // The whole section collapses to one field ("(value)") because
        // SleepAssertionState is the field itself, not a struct with named
        // properties — but its rendered value must still show every
        // associated value by name, not just the case name.
        let value = section.fields.first?.value ?? ""
        XCTAssertTrue(value.hasPrefix("active("), "expected case name prefix, got: \(value)")
        XCTAssertTrue(value.contains("mode:"), "expected labeled associated values, got: \(value)")
        // `String(describing:)`, not `debugDescription` — no added quotes,
        // consistent with every other leaf value in this formatter.
        XCTAssertTrue(value.contains("reason: user request"), "expected the reason payload, got: \(value)")
    }

    func testInactiveSleepAssertionRendersCaseNameWithNoPayload() {
        let snapshot = makeSnapshot(sleepAssertion: .inactive)
        let sections = SnapshotDebugFormatter.sections(for: snapshot)
        let section = sections.first { $0.name == "Sleep Assertion" }!
        XCTAssertEqual(section.fields.first?.value, "inactive")
    }

    // MARK: - Section coverage / stability

    func testSectionsCoverEverySnapshotSubStructInPlanOrder() {
        let snapshot = makeSnapshot()
        let sections = SnapshotDebugFormatter.sections(for: snapshot)
        let names = sections.map(\.name)
        XCTAssertEqual(
            names,
            ["Snapshot", "Battery", "CPU", "GPU", "ANE", "Memory", "Disk", "Network", "Thermal", "Sleep Assertion", "Location", "Top Processes", "Agent Activity"]
        )
    }

    func testSnapshotSectionCarriesTopLevelIdentityFields() {
        let snapshot = makeSnapshot()
        let sections = SnapshotDebugFormatter.sections(for: snapshot)
        let meta = sections.first { $0.name == "Snapshot" }!
        let names = Set(meta.fields.map(\.name))
        XCTAssertEqual(names, ["id", "timestamp", "deviceID", "schemaVersion", "agentAccessPaused", "protectionScore"])
        XCTAssertEqual(meta.fields.first { $0.name == "deviceID" }?.value, "test-device")
    }

    // MARK: - Plain text (Copy button)

    func testPlainTextIncludesSectionHeadersAndFields() {
        let battery = BatteryStats(chargePercent: 55, isCharging: false, isPluggedIn: true)
        let snapshot = makeSnapshot(battery: battery)
        let text = SnapshotDebugFormatter.plainText(for: snapshot)

        XCTAssertTrue(text.contains("== Battery =="))
        XCTAssertTrue(text.contains("chargePercent: Double = 55.0"))
        XCTAssertTrue(text.contains("== GPU =="))
    }
}
