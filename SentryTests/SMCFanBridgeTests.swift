import XCTest
@testable import SystemMetricsKit

/// `SMCFanBridge` is hardware-backed, so these tests are written to pass on
/// *any* Mac — a fanless Air legitimately returns no fans, and asserting a
/// specific count would just encode this development machine into the
/// suite. What is asserted unconditionally: the pure encoding helpers, and
/// the invariants every reading must satisfy when one is produced at all.
final class SMCFanBridgeTests: XCTestCase {

    // MARK: - fourCC encoding (pure)

    func testFourCCEncodesKnownKey() {
        // 'F' 'N' 'u' 'm' big-endian — the exact value the SMC expects for
        // the fan-count key.
        XCTAssertEqual(SMCFanBridge.fourCC("FNum"), 0x464E_756D)
    }

    func testFourCCRejectsWrongLength() {
        XCTAssertNil(SMCFanBridge.fourCC("FN"))
        XCTAssertNil(SMCFanBridge.fourCC("FNumX"))
        XCTAssertNil(SMCFanBridge.fourCC(""))
    }

    func testFourCCRejectsNonASCII() {
        XCTAssertNil(SMCFanBridge.fourCC("F€um"))
    }

    // MARK: - Live readings (invariants only, hardware-agnostic)

    func testFanRPMsAreAlwaysPlausible() {
        // Empty is a fully legitimate result (fanless hardware, denied
        // connection). But anything the bridge *does* report must be a
        // physically plausible RPM — the bridge promises "no data" over
        // fabricated data.
        for rpm in SMCFanBridge.shared.readFanRPMs() {
            XCTAssertGreaterThanOrEqual(rpm, 0)
            XCTAssertLessThanOrEqual(rpm, 20_000)
            XCTAssertTrue(rpm.isFinite)
        }
    }

    func testFanCountAgreesWithReadings() {
        // Readings can only come from fans the SMC says exist. (Fewer is
        // fine — an individual key read may fail — but never more.)
        let rpms = SMCFanBridge.shared.readFanRPMs()
        guard let count = SMCFanBridge.shared.readFanCount() else {
            XCTAssertTrue(rpms.isEmpty, "no fan count must mean no readings")
            return
        }
        XCTAssertLessThanOrEqual(rpms.count, count)
    }

    // MARK: - Hardware description (still read-only)

    func testFanHardwareMatchesTheFanCount() {
        // Added for the fan-control shell, which clamps against the SMC's
        // own `F{i}Mn`/`F{i}Mx` rather than hardcoded numbers. Same
        // hardware-agnostic posture as everything above: an empty result is
        // legitimate, an oversized one is not.
        let hardware = SMCFanBridge.shared.readFanHardware()
        guard let count = SMCFanBridge.shared.readFanCount() else {
            XCTAssertTrue(hardware.isEmpty, "no fan count must mean no hardware descriptions")
            return
        }
        XCTAssertLessThanOrEqual(hardware.count, count)
        XCTAssertEqual(hardware.map(\.index), Array(0..<hardware.count))
    }

    func testFanHardwareValuesAreEitherPlausibleOrAbsent() {
        // The bridge's contract, all the way down: a misdecoded field
        // becomes `nil`, never a number the fan-control layer would then
        // trust as a clamp.
        for fan in SMCFanBridge.shared.readFanHardware() {
            for value in [fan.minRPM, fan.maxRPM, fan.targetRPM].compactMap({ $0 }) {
                XCTAssertTrue(value.isFinite)
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, 20_000)
            }
            if let minRPM = fan.minRPM, let maxRPM = fan.maxRPM {
                XCTAssertLessThanOrEqual(minRPM, maxRPM, "a fan's floor cannot exceed its ceiling")
            }
        }
    }
}
